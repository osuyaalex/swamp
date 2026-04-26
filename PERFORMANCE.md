# SWAMP_ — Performance Strategy

The performance section of Phase 4. Offline and security live in `ARCHITECTURE.md`.

Three questions. Three answers.

---

## Rendering 1,000+ tasks smoothly

Short version: it'll already mostly work, because the existing implementation is lazy and uses `Selector` for surgical rebuilds. To go from "good for 100" to "good for 1,000+" the levers are tighter widget rebuilds, smarter hit-testing during drag, and column-level virtualization at the data layer.

### What's already in place

`ListView.builder` per column, so only the cards near the viewport are constructed. A 1,000-card column doesn't materialise 1,000 widgets — it materialises maybe 15 at a time, growing or shrinking as you scroll.

Each card subscribes to *only* `DragController.activeTaskId` via `context.select`, not the whole controller. Pointer-move events that shift the ghost don't rebuild every visible card; only the dragged card and the active drop slot do.

Drop-slot indicators rebuild via `Selector<DragController, _SlotShape>` so they only react to changes in *their* slot's hover state.

The drag controller and the board controller are separate notifiers. Pointer-move events touch only the drag controller; the task list itself stays untouched during a drag.

Together that means the per-frame cost during a drag is proportional to "the dragged card + the active slot + the ghost overlay", not "everything visible."

### What I'd add for 1,000+

A `RepaintBoundary` wrapping each card. Without it, when the column header rebuilds (e.g. when a count changes because you added a task), the entire column repaints — every card's pixels redraw. With it, only the header repaints; card layers are reused. One line of code, negligible cost in render objects.

Drag hit-test from O(n) to O(log n). `_insertionIndex` currently walks every card in a column to find the slot whose midpoint is below the pointer. For 1,000 cards in a column that's 1,000 RenderBox lookups per `updatePointer` call — and `updatePointer` fires on every pointer move, which is sub-frame frequency on iOS/Android. The fix is to maintain a sorted list of `(taskId, midpointY)` pairs per column, refreshed on layout, and binary-search by pointer Y. The cache invalidates when (a) the task list mutates or (b) the column scrolls; we already know about both.

Memoise the rich-text parser. `TaskCardVisual` parses markdown via regex on every build, which is wasted work for descriptions that don't change. An LRU cache keyed on the source string handles this — size 256 covers all visible cards with room to spare.

`const` constructors everywhere it matters — card decorations, padding values, text styles, icon widgets. Already done where possible; `prefer_const_constructors` enforces it for new code.

Pagination at the data layer once tasks live in Drift. Cursor-based queries, ~50 tasks per column buffered. The `ListView.builder` infrastructure already handles dynamic itemCount, so the controller change is the only one — cards don't notice.

`RepaintBoundary` around the drag overlay too. The overlay rebuilds on every `notifyListeners` from `DragController`, which is roughly every pointer-move event (~120 Hz on modern phones). The rebuild is small but does paint a full shadow every frame; isolating it keeps the rest of the board from repainting in sympathy.

### Frame budget

At 60 fps the budget is 16.67 ms per frame (8.33 ms at 120 fps). Rough split with the optimisations above:

| Phase | Target | Notes |
|---|---|---|
| Build | <2 ms | Mostly hits the const + select fast path. |
| Layout | <3 ms | Most cards don't relayout; only the active slot does. |
| Paint | <4 ms | RepaintBoundary keeps card pixels cached. |
| Composite | <2 ms | One ghost layer. |
| Headroom | ~5 ms | For text shaping, GC, surprises. |

If we measure and any phase exceeds budget, there's a specific lever to pull. The point of the architecture is that no single thing is in the way of every frame.

---

## Memory for large documents

Headline: never load a full document into RAM unless the user is actively viewing it; cache thumbnails aggressively; clear bytes the moment they're no longer needed.

### Where memory is at risk today

`DocumentBytes` holds the full file as a `Uint8List`. A 10 MB upload sits in memory until the upload completes, including during the upload itself.

The optimistic upload flow keeps `bytes` on the local Document for retry support. With multiple queued uploads, that multiplies.

Image previews (when we add them) decode the full document into a bitmap that can be 4–8× the file size.

### What I'd do

Replace `DocumentBytes` with a file-handle-based payload — a `DocumentFileHandle` with a path to disk instead of in-memory bytes. The picker writes to a tmp file the moment it returns; from then on, nothing in the app holds the bytes in RAM. The HTTP upload streams from the path; encryption streams chunks; progress works the same way.

The retry path becomes "open the file" instead of "use cached bytes." That's a behaviour change — if the OS cleans up our tmp directory (unlikely but possible on Android), retry fails. Mitigation: write to `getApplicationDocumentsDirectory()` (private and persistent) instead of `getTemporaryDirectory()`.

Generate thumbnails for previews. Never decode the full image. A 320 px thumbnail of a 10 MP image is ~80 KB decoded vs. ~80 MB for the full bitmap. Thumbnail generation runs in an isolate (`Isolate.run`) so it doesn't block the UI thread. Thumbnails get cached on disk next to the encrypted file — content-addressed by checksum, so they're reused across re-uploads.

Tighten Flutter's `ImageCache`. Defaults are 100 MB, which is more than we need:

```dart
PaintingBinding.instance.imageCache.maximumSize = 200;
PaintingBinding.instance.imageCache.maximumSizeBytes = 50 * 1024 * 1024;
```

Combined with thumbnails, total image RAM stays well under 50 MB.

Evict on detail-sheet close. The preview is the heaviest in-memory image at any time. Evicting on close keeps memory flat as the user navigates between documents.

Stream uploads. The pipeline is:

```
File path
  → openRead() (Stream<List<int>>, 64 KB chunks)
  → AES-GCM streaming encrypt
  → MultipartRequest body stream
  → HTTP socket
```

At no point do we hold the whole file. Memory ceiling is the chunk size (64 KB) plus a few buffer copies — under 1 MB total per in-flight upload.

PDFs via thumbnails, not full render. Server-side thumbnail generation is the cleanest answer. Client-side fallback uses `pdfx` or `printing` — render at 100 DPI for previews, only re-render at higher DPI on explicit zoom.

Bytes are already cleared on cold start. `_hydrate` does this — anything in `uploading` state on cold start has its bytes cleared via `copyWith(clearBytes: true)`. The cold-start path is the worst-case "everything in memory at once" risk because every persisted doc would otherwise drag its bytes into RAM on launch.

### Targets

For a 4 GB phone:

| Workload | Target | Notes |
|---|---|---|
| Idle | <80 MB | Theme, fonts, framework. |
| Browsing tasks (100) | <100 MB | Mostly text. |
| Browsing documents (50, no preview) | <100 MB | Metadata + icons. |
| Document preview open (full-res) | <250 MB peak | Single full-res image; evicted on close. |
| Active upload | +10–20 MB | Chunked streaming. |

The 250 MB peak is acceptable for a foregrounded user-initiated action. If we ever served B2B / iPad workflows where users review many documents in sequence, we'd switch to "thumbnail strip + preview on tap" and tighten further.

---

## Tools and benchmarks

### Tools

Flutter DevTools is the single most important tool. Specifically:

- **Performance tab** — frame timeline with build/layout/paint phase breakdown. This is where you find which phase is over budget on janky frames.
- **CPU profiler** — sample-based profiling of the UI isolate. Best for finding hotspots in build methods, parse loops, layout calculations.
- **Memory tab** — allocation tracking, snapshot diffing. Use it to hunt leaks (typically subscriptions or listeners not disposed).
- **Network tab** — for the document feature, watch HTTP traffic to confirm we're not over-fetching.

The performance overlay (`showPerformanceOverlay: kDebugMode` on `MaterialApp`) renders two graphs — UI thread and raster thread. Bars cross the green line when a frame is over 16 ms. Indispensable during gesture-heavy interactions like drag.

For specific paths I want to measure, custom timeline slices via `developer.Timeline.startSync` / `finishSync`. They show up alongside framework slices in DevTools traces. Useful for measuring our own hot paths (`_applyStatusUpdate`, `_insertionIndex`) without instrumenting them with `print`.

`flutter run --profile` is the only mode where benchmarking numbers are valid. Debug includes assertions and slow framework paths and a JIT-compiled isolate. Release strips the symbols and tracing needed for DevTools. Profile is release-mode performance with the symbols left in.

For automated regression testing, `integration_test` with frame timing:

```dart
testWidgets('drag from To Do to Done holds 60fps', (tester) async {
  await binding.traceAction(() async {
    await _performDrag(tester);
  }, reportKey: 'drag_traceaction');
});
```

The JSON output diffs against a baseline in CI.

Static analysis: `flutter analyze` plus `prefer_const_constructors`, `avoid_unnecessary_containers`, and a custom `no_cross_feature_imports` lint.

Always benchmark on real devices. Simulators run on host-CPU performance, which is wildly different from a phone's CPU, and they hide raster-thread bottlenecks because Mac/Linux GPUs are far faster than mobile GPUs.

For a benchmarking matrix:

- Mid-range Android (Pixel 6a) — the 80th-percentile device.
- Low-end Android (Moto G Power) — the "if it works here, it works everywhere" device.
- iPhone 13 — current mid-range iPhone. iPhone SE first gen is the worst case.
- iPad Air — for the wide-layout perf path.

### Metrics and targets

Frame timing:

| Metric | Target | Worst-case acceptable |
|---|---|---|
| Median build+raster | <8 ms | <12 ms |
| 99th percentile frame | <16 ms (60 fps) | <33 ms (30 fps blip) |
| Janky frames | <1% | <5% |
| Janky frames during drag | 0% | <2% |

"Janky" defined as >16 ms on the UI thread.

Cold start:

| Metric | Target |
|---|---|
| First frame | <500 ms |
| Time to interactive | <1 s |
| Hydrated state visible | <1.5 s |

Network:

| Metric | Target |
|---|---|
| Upload, 5 MB doc, 4G | <8 s |
| WS message roundtrip, idle | <300 ms |
| Polling tick | every 4 s |
| Reconnect time after manual retry | <500 ms |

Any metric that exceeds target by >20% is treated as a regression in the next sprint.

### Benchmark methodology

Run benchmarks in `--profile` mode on physical devices. Warm up for 30 seconds before measuring (first-frame caches, image decode, etc.) and discard the first run. Run each benchmark 5 times and report median ± 95th percentile. Pin device state — airplane-mode toggle to clear background network, screen brightness fixed, Do Not Disturb on. Tag each result with git SHA, Flutter version, target device. Persist in CI and diff every PR against `main`'s last numbers.

The scenarios I'd script:

| Scenario | What it measures |
|---|---|
| Cold launch → Tasks tab → first tap | Time-to-tap on mid-Android. |
| Long-press card → drag to opposite column → drop | Frame timings during drag. |
| Switch between tabs 10× | Frame timings; verify IndexedStack keeps both alive. |
| Upload 5 docs in parallel | Memory growth, upload latency. |
| Process 50 incoming WS updates in 2s | Whether the build pipeline keeps up. |
| Receive WS drop, reconnect, replay | End-to-end latency to UI catching up. |

### Where I'd profile first

Based on what the code looks like today, my priority order:

1. `DragController.updatePointer` — runs on every pointer-move event during a drag.
2. `DragController._insertionIndex` — the O(n) walk.
3. `DocumentRepositoryImpl._applyStatusUpdate` — runs on every WS push and every poll tick.
4. `SharedPreferences.setString` on every `_emit()` — `_persist` writes the full document list as JSON every change. For 100+ documents this is non-trivial.
5. `TaskColumn` rebuild path when a card is added or removed — make sure the column header isn't forcing the body to rebuild.

The architecture concentrates work in named, testable methods rather than scattering it across widgets. That makes each of these a discrete profiling target rather than "the framework is slow."

---

The shape of the optimisations matters more than any single one of them. Phase 1 and Phase 2 are built with this in mind even though they don't ship the full optimisation suite — the points where you'd intervene first are narrowly scoped. That's an app built to measure well, rather than an app that claims it's fast.
