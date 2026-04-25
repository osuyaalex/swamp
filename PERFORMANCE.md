# SWAMP_ — Performance Strategy

This document covers the performance section of Phase 4. The other
Phase 4 sections (offline + security) live in `ARCHITECTURE.md`.

The three questions, answered:

---

## Q1. Rendering 1,000+ tasks smoothly

**Headline:** the existing implementation is already lazy and uses
`Selector` for surgical rebuilds. To go from "good for 100" to "good
for 1,000+" the levers are: tighter widget rebuilds, smarter
hit-testing during drag, and column-level virtualization.

### What's already in place

- **`ListView.builder` per column** at
  `lib/features/task_board/presentation/widgets/task_column.dart:171`.
  Only the cards in or near the viewport are constructed. A 1,000-card
  column doesn't materialise 1,000 widgets — it materialises ~15 at a
  time as you scroll.
- **`context.select<DragController, String?>((d) => d.activeTaskId)`**
  at `widgets/task_card.dart:159`. Each card subscribes to *only* the
  active drag id, not the whole `DragController`. Cards rebuild only
  when drag activity actually targets them — pointer-move events that
  shift the ghost don't rebuild every visible card.
- **`Selector<DragController, _SlotShape>`** at
  `widgets/task_column.dart:213`. The drop-slot indicators rebuild
  only when *their slot's* hover state changes, not on every pointer
  move.
- **Drag controller and board controller are separate notifiers**.
  Pointer-move events touch only the drag controller. The task list
  itself doesn't rebuild during a drag — only the dragged card and
  the active drop slot do.

These four together mean the per-frame cost during a drag is
proportional to "the dragged card + the active slot + the ghost
overlay", not "everything visible".

### What I would add for 1,000+ tasks

#### 1. `RepaintBoundary` per card

```dart
return RepaintBoundary(
  child: GestureDetector(
    key: GlobalObjectKey(widget.task.id),
    ...
  ),
);
```

A `RepaintBoundary` causes the card to paint into its own layer.
Without it, when the column header rebuilds (e.g. count changes), the
entire column repaints, including all card pixels. With it, only the
header repaints — the cards' rasterised layers are reused as-is.

This is a one-line change; the cost is roughly one extra render
object per card, which is negligible.

#### 2. Drag hit-test from O(n) to O(log n)

`DragController._insertionIndex` at `drag_controller.dart:234`
currently walks every card in a column to find the slot whose
midpoint is below the pointer. For 1,000 cards in a column that's
1,000 RenderBox lookups per `updatePointer` call, which fires on
every pointer move (sub-frame frequency on iOS/Android).

**Fix:** maintain a sorted list of `(taskId, midpointY)` pairs per
column, refreshed on layout, and binary-search by pointer Y.

```dart
class _ColumnLayoutCache {
  List<({String id, double midY})> sortedMidpoints = [];
}
```

The cache is invalidated whenever (a) the task list mutates or
(b) the column scrolls. We already know about both — the controller
is the source of truth for (a), and the column's `ScrollController`
notifies us about (b). Cache rebuild is O(n) but only fires on
layout, not on every pointer move.

For 1,000 cards, this turns drag hit-testing from "1,000 ops × 60 fps
= 60,000 ops/sec" into "10 ops × 60 fps + 1,000 ops on layout
changes" — comfortably under 1 ms/frame.

#### 3. Avoid building rich text on every paint

`TaskCardVisual` parses markdown via regex on every build
(`widgets/rich_text.dart:25`, `_parse`). For descriptions that don't
change, this is wasted work.

**Fix:** memoise parsed `TextSpan` lists keyed on the source string.
A simple `LruCache<String, List<TextSpan>>` of size ~256 covers all
visible cards with room to spare.

#### 4. `const` constructors everywhere it matters

Card decorations, padding values, text styles, icon widgets — making
them `const` lets Flutter skip equality checks during widget diffing.
Already done where possible; for new widgets, enforced by the
`prefer_const_constructors` lint.

#### 5. Pagination + virtualization at the data layer

Once tasks live in Drift, the controller would no longer hold all
tasks in memory grouped by status. Instead:

- **For the visible viewport:** Stream<List<Task>> from a paged query (cursor-based, ~50 tasks per column buffered).
- **For drag operations:** when the dragged card is in flight, ensure the destination's neighborhood is loaded so the slot indicator can place correctly.
- **For search/filter:** a single Drift query streams matching tasks; the columns rebuild from that.

The `ListView.builder` infrastructure already handles dynamic
itemCount, so the controller change is the only change required —
cards don't care.

#### 6. Drag overlay perf

`DragOverlayLayer` at
`drag/drag_overlay.dart:14` rebuilds on every `notifyListeners()` from
`DragController`. During a drag that's roughly every pointer-move
event (~120 Hz on modern phones).

The overlay is small — one positioned card with a shadow — so the
rebuild cost is tiny. But it does paint a full shadow every frame.
Wrapping the ghost in a `RepaintBoundary` ensures the underlying
board doesn't repaint when the ghost moves.

### Concrete frame budget

At 60 fps the frame budget is **16.67 ms** (8.33 ms at 120 fps).
Phases:

| Phase | Budget at 60 fps | Notes |
|---|---|---|
| Build (widget tree) | <2 ms | With above optimisations, mostly hits the const + select fast path. |
| Layout | <3 ms | Most cards don't re-layout — only the active slot does. |
| Paint | <4 ms | RepaintBoundary keeps card pixels cached. |
| Compositing | <2 ms | One ghost layer. |
| Headroom | ~5 ms | For text shaping, GC, surprises. |

If we measure and any phase goes over budget, we have a specific
lever to pull. The point of the architecture is that no single thing
is in the way of every frame.

---

## Q2. Memory for large documents and image previews

**Headline:** never load a full document into memory unless the user
is actively viewing it; cache thumbnails aggressively; clear bytes
the moment they're no longer needed.

### Where memory is at risk today

- `DocumentBytes` (in `document.dart`) holds the full file as a
  `Uint8List`. A 10 MB upload sits in RAM until the upload completes,
  including during the upload itself.
- The optimistic upload flow stores `bytes` on the local `Document`
  for retry support
  (`document_repository_impl.dart:90`). For multiple queued uploads,
  this multiplies.
- Image previews (when we add them) decode the full document into a
  bitmap that can easily be 4–8× the file size.

### What I would do

#### 1. File-handle-based payload, not in-memory bytes

Replace `DocumentBytes` with `DocumentFileHandle`:

```dart
@immutable
class DocumentFileHandle {
  final String path;        // location on disk (encrypted)
  final String originalName;
  final String mimeType;
  final int size;
  final String checksum;
}
```

The picker writes to a tmp file the moment it returns; from then on,
nothing in the app holds the bytes in RAM. The HTTP upload streams
from the path; the encryption layer streams chunks; the progress
indicator works the same way.

The retry path becomes "open the file" instead of "use cached bytes".
That's a behaviour change — if the OS cleans up our tmp directory
(unlikely but possible on Android), retry fails. Mitigation: write to
`getApplicationDocumentsDirectory()` (private, persistent) instead of
`getTemporaryDirectory()`.

#### 2. Thumbnail generation

For previews, never decode the full image. Instead:

```dart
final thumb = await Isolate.run(() {
  final image = decodeImageFromList(bytes);
  return resizeImage(image, maxDim: 320);
});
```

(`Isolate.run` keeps the decode off the UI thread.) A 320 px
thumbnail of a 10 MP image is ~80 KB decoded, vs ~80 MB for the full
bitmap.

Thumbnails get cached on disk next to the encrypted file. Cache key
is the document's checksum — content-addressed, so thumbnails are
reused if the same image is re-uploaded.

#### 3. Aggressive `ImageCache` configuration

Flutter's global `ImageCache` defaults to 100 MB. For an app whose
worst-case is "hundreds of document thumbnails plus rich text icons",
that's far more than needed. I'd configure:

```dart
PaintingBinding.instance.imageCache.maximumSize = 200;        // images
PaintingBinding.instance.imageCache.maximumSizeBytes = 50 * 1024 * 1024; // 50 MB
```

Combined with thumbnails, total image RAM stays well under 50 MB.

#### 4. Evict on detail-sheet close

When the document detail sheet closes, evict the full preview from
`ImageCache`:

```dart
imageCache.evict(NetworkImage(url));
```

The preview is the heaviest in-memory image at any time. Evicting on
close keeps memory flat as the user navigates between documents.

#### 5. Stream uploads, never buffer

The upload pipeline becomes:

```
File path
  → openRead() (Stream<List<int>>, 64 KB chunks)
  → AES-GCM streaming encrypt
  → MultipartRequest body stream
  → HTTP socket
```

At no point do we hold the whole file. Memory ceiling is the chunk
size (64 KB) plus a few buffer copies — under 1 MB total per
in-flight upload.

#### 6. PDF previews via thumbnails, not full render

For PDFs, server-side thumbnail generation is the cleanest answer.
If we must render client-side, `pdfx` or `printing` packages decode
PDFs into images; we'd cap render DPI at 100 for the preview and only
re-render at higher DPI for explicit zoom.

#### 7. Bytes cleared on cold start (already done)

`DocumentRepositoryImpl._hydrate` at line 379 already clears bytes on
cold start: `doc.copyWith(status: queued, clearBytes: true)`. The
cold-start path is the worst-case "everything in memory at once" risk
because every persisted doc would otherwise drag its bytes into RAM
on launch. We avoid that by design.

### Memory targets

For a phone with 4 GB RAM, our target ceilings are:

| Workload | Target | Notes |
|---|---|---|
| Idle | <80 MB | Theme, fonts, framework. |
| Browsing tasks (100 tasks) | <100 MB | Mostly text. |
| Browsing documents (50 docs, no preview open) | <100 MB | Metadata + icons. |
| Document preview open (full-res) | <250 MB peak | Single full-res image; evicted on close. |
| Active upload | +10–20 MB | Chunked streaming. |

The 250 MB peak is acceptable for a foregrounded user-initiated
action. If we ever serve B2B/iPad tablet workflows where a user
reviews many documents in sequence, we'd switch from "open one preview
at a time" to "thumbnail strip + preview on tap" and tighten the
ceiling further.

---

## Q3. Tools, metrics, and benchmarks

### Tools

#### Flutter DevTools

The single most important tool. Specifically:

- **Performance tab** — timeline tracing of frames, with build/layout/paint phase breakdown. Use this to find which phase is over budget on janky frames.
- **CPU Profiler** — sample-based profiling of the UI isolate. Best for finding hotspots in build methods, parse loops, or layout calculations.
- **Memory tab** — allocation tracking, snapshot diffing, retained-object analysis. Use for hunting leaks (typically subscriptions or listeners not disposed).
- **Network tab** — for the document feature, watch HTTP traffic to confirm we're not over-fetching.

#### Performance overlay

```dart
MaterialApp(
  showPerformanceOverlay: kDebugMode,
  ...
)
```

Renders two stacked graphs (UI thread, raster thread). Bars cross the
green line when a frame is over 16 ms. Indispensable during
gesture-heavy interactions like drag.

#### Timeline tracing in code

For specific paths we care about:

```dart
import 'dart:developer' as developer;

developer.Timeline.startSync('DragController.updatePointer');
// ...
developer.Timeline.finishSync();
```

The custom slices show up in DevTools Performance traces alongside
framework slices. Useful for measuring our own hot paths
(`_applyStatusUpdate`, `_insertionIndex`) without instrumenting them
with `print`.

#### `flutter run --profile`

Profile mode is the only mode where benchmarking numbers are valid.
Debug mode includes assertions, asserts, slow framework paths, and a
JIT-compiled isolate; release mode strips debugging symbols. Profile
is release-mode performance with the symbols and tracing needed for
DevTools.

```bash
flutter run --profile -d <device-id>
```

#### `integration_test` with frame timing

For automated regression testing:

```dart
testWidgets('drag from To Do to Done holds 60fps', (tester) async {
  await binding.traceAction(() async {
    await _performDrag(tester);
  }, reportKey: 'drag_traceaction');
});
```

The `IntegrationTestWidgetsFlutterBinding.traceAction` API records
frame times during the action; the JSON output can be diffed against
a baseline in CI.

#### `flutter analyze` and custom lints

Static analysis. We have it green; for a production team I'd add:
- `prefer_const_constructors`
- `avoid_unnecessary_containers`
- A custom `no_cross_feature_imports` lint (sketched in
  `ARCHITECTURE.md` Phase 3).

#### Real devices, not the simulator

Always benchmark on real hardware. Simulators run on host-CPU
performance which is wildly different from a phone's CPU. The
simulator will hide raster-thread bottlenecks because Mac/Linux GPUs
are far faster than mobile GPUs.

Recommended device matrix for benchmarking:
- **Mid-range Android** — Pixel 6a or similar. The 80th-percentile
  device.
- **Low-end Android** — Moto G Power or similar. The "if it works
  here, it works everywhere" device.
- **iPhone 13** — current mid-range iPhone. iOS perf is usually fine
  on iPhone 12+; iPhone SE (1st gen) is the worst case.
- **iPad Air** — for the wide-layout perf path.

### Metrics

#### Frame timing

| Metric | Target | Worst-case acceptable |
|---|---|---|
| Median build+raster time | <8 ms | <12 ms |
| 99th-percentile frame time | <16 ms (60 fps) | <33 ms (30 fps blip) |
| Janky frames | <1 % | <5 % |
| Janky frames during drag | 0 % | <2 % |

"Janky" defined as `>16 ms` on the UI thread.

#### Cold-start time

| Metric | Target | Notes |
|---|---|---|
| First frame (any pixel rendered) | <500 ms | On mid-range Android. |
| Time to interactive (you can tap) | <1 s | On mid-range Android. |
| Hydrated state visible | <1.5 s | Includes SharedPreferences read + initial layout. |

#### Memory (see Q2 for breakdown)

Monitor with `dart:io` `ProcessInfo.currentRss` periodically and via
DevTools snapshots at:
- App launch
- After scrolling 100 tasks
- After uploading 5 docs
- After 30 minutes of background activity

Any metric that exceeds target by >20 % is treated as a regression in
the next sprint.

#### Network

| Metric | Target |
|---|---|
| Upload time, 5 MB doc, on 4G | <8 s |
| WS message roundtrip, idle | <300 ms |
| Polling tick (when ws offline) | every 4 s |
| Reconnect time after manual retry | <500 ms |

### Benchmark methodology

1. **Run all benchmarks in `--profile` mode** on physical devices.
2. **Warm up** for 30 seconds before measuring (first-frame caches,
   image decode caches, etc.). Discard the first measurement run.
3. **Run each benchmark 5 times**, report median ± 95th percentile.
4. **Pin device state**: airplane-mode toggle to clear background
   network activity, screen brightness fixed, "Don't Disturb" on.
5. **Tag the build** in benchmark results: git SHA, Flutter version,
   target device.
6. **Persist results in CI**. We diff every PR against `main`'s last
   recorded numbers. PRs that regress >5 % on any tracked metric
   require explicit sign-off.

#### Specific scripted benchmarks

| Scenario | Measure |
|---|---|
| Cold launch → Tasks tab → first tap | Time-to-tap on mid-Android. |
| Long-press card → drag to opposite column → drop | Frame timings during drag. |
| Switch between Tasks ↔ Documents tabs (10×) | Frame timings; verify IndexedStack keeps both alive. |
| Upload 5 docs in parallel | Memory growth, upload latency. |
| Process 50 incoming WS updates in 2 seconds | Whether the build pipeline keeps up. |
| Receive WS drop, reconnect, replay | End-to-end latency to UI catching up. |

### Specific places I would profile first

Based on what the code already looks like, my priorities for the
first profiling pass:

1. **`DragController.updatePointer`** at
   `lib/features/task_board/presentation/drag/drag_controller.dart:115`. Called on every pointer-move event during a drag.
2. **`DragController._insertionIndex`** at line 234. The O(n) walk
   over column cards.
3. **`DocumentRepositoryImpl._applyStatusUpdate`** at
   `lib/features/document_verification/data/document_repository_impl.dart:300`. Called on every WS push and every poll tick.
4. **`SharedPreferences.setString`** path on every `_emit` —
   `_persist` writes the full document list as JSON every change,
   which for 100+ documents is non-trivial.
5. **`TaskColumn` rebuild path** when a card is added/removed —
   ensure the column header isn't forcing the body to rebuild.

The architecture deliberately concentrates work in named, testable
methods rather than scattering it across widgets. That makes each of
these a discrete profiling target rather than "the framework is slow".

---

## Closing

Phase 1 and Phase 2's existing implementation is built with these
performance constraints in mind even though it doesn't ship the full
optimisation suite. The points where we'd intervene first are
narrowly scoped — `RepaintBoundary` per card, binary-search hit-test,
streaming uploads — rather than architectural rewrites. That is the
shape of an app that has been built to *measure* well rather than to
*claim* it's fast.
