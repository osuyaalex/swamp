# SWAMP_ — Architecture

This document covers Phase 3 (state management, dependency injection,
data layer, project structure) and the offline + security sections of
Phase 4. The performance section of Phase 4 lives in `PERFORMANCE.md`.

References to source files use the live repository layout — every
claim about "how it's done" maps to a real path you can open.

---

## Phase 3 — State Management

### Q1. Which approach did you choose and why?

**Per-feature `ChangeNotifier`s exposed through `provider`.** Each feature
owns one or more notifiers; the screen creates them in `initState` and
exposes them via a `MultiProvider`. Concretely:

- **`TaskBoardController`** at `lib/features/task_board/presentation/task_board_controller.dart` owns the board's grouped task lists, CRUD operations, and activity-log appends.
- **`DragController`** at `lib/features/task_board/presentation/drag/drag_controller.dart` owns drag-gesture state (phase, pointer, hover slot, ticker-driven auto-scroll).
- **`DocumentDashboardController`** at `lib/features/document_verification/presentation/document_dashboard_controller.dart` owns the document list and connection state.
- **`DocumentRepositoryImpl`** at `lib/features/document_verification/data/document_repository_impl.dart` is not a `ChangeNotifier` itself but exposes broadcast streams; the controller subscribes to them.

#### Trade-offs I weighed

**`provider` (chosen):**
- Picked deliberately at project setup as the state-management library, before either build phase started. Both phases proved out without me hitting limitations that would have forced a switch.
- One-way data flow is enough for the data shapes here — there are no cross-screen subscriptions, no shared mutable state, no need for compile-time DI.
- The `Selector` widget gives surgical rebuilds when only a slice of a notifier matters (used in `TaskCard` to subscribe to `DragController.activeTaskId` alone).
- Tests construct controllers directly with fake repos — no special test bootstrapping is needed.

**`flutter_bloc`:**
- Strong choice for forms with discrete events (login, checkout). For a Trello board where mutations are direct method calls (`createTask`, `moveTask`), the event-class boilerplate adds noise without buying anything. Half a dozen `TaskCreated`/`TaskMoved`/etc. event classes per feature would make small commits two files larger.
- Side-effect handling via `BlocListener` is good but the document feature already has a clean side-effect place: the repository orchestrates side effects, not the controller.

**Riverpod:**
- The compile-time DI and `ProviderScope` testing story is genuinely nicer than `provider`.
- For a 2-feature app where each feature owns its dependencies via constructor injection, the DI advantage doesn't pay back the cost of pulling in another paradigm. The architecture would tolerate a future migration without rewriting business logic — controllers are pure Dart `ChangeNotifier`s that could become `Notifier`s with renamed methods.

**`signals` / `mobx`:**
- Reactive primitives are fine for fine-grained state, but they encourage scattering state across many small variables. The two features here have a clear single-controller shape that maps better to one notifier per feature.

#### What I would change if the app grew

If the document feature added a second screen (verification history,
admin review) that needed access to the same controller across routes,
I would lift `DocumentDashboardController` to a route-scoped provider —
above `MaterialApp.builder` so modal routes can read it without the
re-provide trick. For the current scope, screen-scoped is correct.

### Q2. Do the two features share state, or are they isolated?

**Fully isolated.** `lib/features/task_board/` and
`lib/features/document_verification/` import nothing from each other.

The only files both features touch live in `lib/core/`:

- `core/theme.dart` — shared visual language.
- `core/haptics.dart` — shared platform wrapper.
- `core/notifications.dart` — interface-only, no shared state.
- `core/id.dart` — pure-function id generator.

What drove that decision:

1. **The brief's Phase 3 question** is answered by the layout itself — "how do features share services without coupling?" If feature A imports from feature B, the answer is "they don't, by construction".
2. **No real shared domain.** A task is not a document; their lifecycles differ; an audit entry on a document means something different from an activity entry on a task. Shared types would be either too broad to be useful (a generic `AuditEntry`) or accidentally coupled (a `TimelineEvent` that one feature writes to and the other reads).
3. **Different async shapes.** The task feature's repo is `Future`-based; the document repo is `Stream`-based because of WS/polling updates. Sharing a controller pattern would force one feature to compromise.

**State that is shared by reference but not by mutation:** the `SharedPreferences` instance. Both features could persist to it; today only documents do. Each feature uses its own keyed namespace (`document_verification.docs.v1`) so there's no risk of one feature stomping on another's data even though the storage is the same.

---

## Phase 3 — Dependency Injection

### Q1. Service registration approach

**Constructor injection, composition root in each feature's screen
state.** No global locator, no `get_it`, no `Provider.create` magic at
app startup.

The composition root for each feature is its `initState`:

- **Task feature** at `lib/features/task_board/presentation/task_board_screen.dart:27`:
  ```dart
  _board = TaskBoardController(
    repository: InMemoryTaskRepository(),
    notifications: InAppNotificationService(),
  );
  _drag = DragController(boardController: _board, vsync: this);
  ```
- **Document feature** at `lib/features/document_verification/presentation/document_dashboard_screen.dart:33`:
  ```dart
  final backend = MockDocumentBackend();
  final api = DocumentApiClient(backend);
  final ws = DocumentWebSocketClient(backend);
  final polling = DocumentPollingService(api);
  final repo = DocumentRepositoryImpl(api: api, ws: ws, polling: polling);
  _controller = DocumentDashboardController(
    repository: repo,
    source: PlatformDocumentSource(),
  );
  ```

After construction the controllers are exposed via `MultiProvider`/`ChangeNotifierProvider` for descendant widgets to consume.

#### What is registered, at what scope, and why

| Type | Scope | Lifetime | Reason |
|---|---|---|---|
| `TaskBoardController` | Screen | initState → dispose | Owns task state; no other consumer needs it. |
| `DragController` | Screen | initState → dispose | Tied to task feature; gesture state is screen-local. |
| `InMemoryTaskRepository` | Screen | per `TaskBoardController` | One-to-one with controller. |
| `DocumentDashboardController` | Screen | initState → dispose | Owns dashboard state. |
| `DocumentRepositoryImpl` | Screen | per controller | Owns subscriptions, ws, polling — disposed with controller. |
| `MockDocumentBackend`, `DocumentApiClient`, `DocumentWebSocketClient`, `DocumentPollingService` | Screen | per repo | Wired up at construction; disposed transitively. |
| `PlatformDocumentSource` | Screen | per controller | Stateless wrapper around `image_picker`/`file_picker`. |
| `SharedPreferences` | App | lazy singleton via `getInstance()` | Plugin-imposed singleton; cheap to call repeatedly. |
| `InAppNotificationService` | App-or-screen | currently per controller | Phase-1 stub; would lift to app scope when replaced with `flutter_local_notifications` (which expects one initialised service for the process). |
| `AppTheme` | App | const | Pure data, lives in `core/theme.dart`. |

#### Why this matters more than the choice itself

Constructor injection puts the dependency graph in plain sight. Reading
`document_dashboard_screen.dart:33` tells you exactly what the document
feature needs. There's no "where is this thing coming from?" — the
answer is "the line above this one." For a 4-developer team that's the
cheapest possible onboarding path.

It also keeps tests straightforward. The document repository tests at
`test/document_repository_test.dart:32-50` build the same dependency
chain by hand with shorter timings and a non-random rejection rate.
Same shape, deterministic timings.

### Q2. How do features share common services without coupling?

**Through `core/` and through abstract interfaces — never through
direct imports between features.**

Concretely, `core/` is the only directory both features import from:

```
lib/
├── core/
│   ├── haptics.dart           ← used by task drag, could be by docs
│   ├── id.dart                ← used by both features
│   ├── notifications.dart     ← used by tasks; doc feature could
│   └── theme.dart             ← used by main.dart
└── features/
    ├── task_board/
    └── document_verification/
```

The contract is: anything `core/` exposes must be useful to multiple
features and must not depend on either feature. The `NotificationService`
in `core/notifications.dart` is the canonical example — it's an
abstract interface; the in-app log implementation has zero awareness
of tasks or documents. When we swap in `flutter_local_notifications`,
the swap point is a single line in each feature's screen `initState`,
and neither feature has to know about the other.

For services that genuinely don't fit `core/` because they're partly
shared, partly feature-specific, the right move is a thin shared
interface in `core/` with feature-specific implementations. Example
shape if we needed one for HTTP:

```
core/http/
  http_client.dart           ← interface
  default_http_client.dart   ← package:http impl

features/document_verification/data/
  document_api_client.dart   ← uses HttpClient interface
```

The document API client depends on `HttpClient`, never on
`DefaultHttpClient`. The task feature, if it ever needs HTTP, takes
the same dependency. Neither feature imports the other; both import
the shared abstraction.

---

## Phase 3 — Data Layer

### Q1. Local database choice

**Today: in-memory + `shared_preferences` for documents. Production: I would use Drift (typed SQLite).**

Currently:

- **Tasks** live in `InMemoryTaskRepository` (`lib/features/task_board/data/in_memory_task_repository.dart`). No persistence — tasks vanish on cold start. This is a deliberate Phase 1 trade-off; the repository implements the same `TaskRepository` interface a production impl would.
- **Documents** persist their metadata via `SharedPreferences` keyed by `document_verification.docs.v1`. See `DocumentRepositoryImpl._persist` and `_hydrate` at `lib/features/document_verification/data/document_repository_impl.dart:368, 394`. Bytes are deliberately not persisted (see "Cold-start recovery" below).

#### What I would use in production

**Drift (formerly Moor).** It's a typed, code-generated SQLite layer
with first-class support for migrations, joins, type safety, and
(critically for the task feature) reactive streams of query results.

Why Drift over the alternatives:

| Option | Why I'd skip it |
|---|---|
| **Hive** | NoSQL, no joins, schema migrations are manual. Tasks have a clear relational shape (task ↔ comments ↔ activity), and migrations matter for an app that will keep evolving. |
| **Isar** | Strong contender — fast, reactive, schema-aware. Stagnant maintenance momentum has been a real concern lately; Drift has more conservative adoption risk. |
| **Sembast** | Pure-Dart simplicity is appealing but it doesn't scale beyond hundreds of records before queries get slow. |
| **Floor / sqflite raw** | Both work; Drift offers the same SQLite engine with a much nicer typed API and reactive streams. |
| **ObjectBox** | Performant, but its license model and binary footprint create cross-platform deployment friction not worth it for our shape. |

Concrete migration shape if we move to Drift:

1. Add `drift` and `drift_dev` to `pubspec.yaml`.
2. Define `Tasks`, `Comments`, `Activity` tables in `lib/features/task_board/data/database.dart`.
3. Create `DriftTaskRepository implements TaskRepository` — same interface, different storage.
4. Change one line in `task_board_screen.dart`:
   ```dart
   _board = TaskBoardController(
     repository: DriftTaskRepository(db),  // was InMemoryTaskRepository()
     ...
   );
   ```
5. Equivalent steps for documents — Drift would replace the
   `Map<String, Document>` field in `DocumentRepositoryImpl` and the
   SharedPreferences read/write in `_persist`/`_hydrate`. Bytes would
   move into a separate table keyed by document id, and the
   "uploading → queued + clearBytes" repair on cold start would
   become a query: `UPDATE documents SET status='queued' WHERE status='uploading'`.

The presentation layer changes nothing.

### Q2. Repository pattern and data flow

The repository pattern is implemented per feature, with the interface
in `domain/` and the implementation in `data/`:

- `lib/features/task_board/domain/repositories/task_repository.dart` — interface, 7 methods, all `Future`-returning.
- `lib/features/task_board/data/in_memory_task_repository.dart` — implementation.
- `lib/features/document_verification/domain/repositories/document_repository.dart` — interface; mixes `Future` for one-shot operations and `Stream` for continuous observation.
- `lib/features/document_verification/data/document_repository_impl.dart` — implementation orchestrating three async sources (HTTP, WebSocket, polling).

#### Data flow — task feature (Future-based)

```
User action
   │
   ▼
Widget gestures (TaskCard / TaskColumn / sheets)
   │
   ▼
TaskBoardController method (createTask, editTask, moveTask, addComment, deleteTask)
   │  uses repository
   ▼
TaskRepository (interface) — implementation lives in data/
   │  returns Future<Task>
   ▼
TaskBoardController updates its in-memory grouped lists
   │
   ▼
notifyListeners() — provider rebuilds subscribed widgets
   │
   ▼
Widgets re-render
```

The controller is the *only* place that calls the repository. Widgets
never reach for the repository directly. That single hop makes the
widget tree dumb and the controller authoritative.

#### Data flow — document feature (Stream-based, three sources)

```
User picks file
   │
   ▼
DocumentDashboardController.pickAndUpload
   │
   ▼
DocumentRepositoryImpl.upload  (optimistic insert + try API call)
   │
   ├─ on success: _track(serverId) ─→ WebSocketClient + PollingService
   │                                        │
   │                                        │  (status updates flow back)
   │                                        ▼
   │                              _applyWsUpdate / _applyPollUpdate
   │                                        │
   │                                        ▼
   │                              _applyStatusUpdate (single funnel)
   │                                        │
   │                                        ▼
   │                              _byId[localId] = next  +  _emit()
   │                                        │
   │                                        ▼
   │                              _outDocs.stream ──→ controller
   │                                                       │
   │                                                       ▼
   │                              notifyListeners() ──→ widgets
   │
   └─ on failure: rollback to queued + audit entry, _emit()
```

Two things to call out about this shape:

1. **Single funnel for status changes.** WS and polling both deliver
   different DTOs but they both flow through `_applyStatusUpdate` at
   `document_repository_impl.dart:300`. The two sources literally
   cannot disagree on what "moving to VERIFIED" means because there's
   only one place that interprets it.
2. **Single emission point.** Every public mutation in the repository
   ends with `_emit()` (line 404) which (a) pushes the new list onto
   the broadcast stream and (b) fires off a SharedPreferences write.
   That uniformity is what makes the repository easy to reason about:
   change happens, and exactly two things follow.

---

## Phase 3 — Project Structure

### Q1. How would you structure this for a team of 4+ developers?

The current layout is already that structure:

```
lib/
├── app/                        ← navigation shell, routing
├── core/                       ← cross-feature utilities (no business logic)
├── features/
│   ├── task_board/
│   │   ├── data/
│   │   ├── domain/
│   │   └── presentation/
│   └── document_verification/
│       ├── data/
│       ├── domain/
│       └── presentation/
├── home.dart
└── main.dart
```

#### Why feature-first for a team

- **Ownership maps to folders.** A `CODEOWNERS` rule like `lib/features/task_board/ @swamp/team-tasks` is enough. The tasks team can move within their folder freely; the docs team within theirs.
- **Pull request blast radius is small.** A tasks PR almost never touches `features/document_verification/`. Conflicts cluster around `core/` and `app/`, which are smaller surfaces with explicit owners.
- **New developers ramp on one feature at a time.** "Read `lib/features/document_verification/` and ignore the rest" is a tractable onboarding instruction.
- **Code review can be split.** PRs spanning `core/` get a wider reviewer set; PRs inside one feature don't.

#### Conventions the team would enforce

- `features/X/` may import from `core/`, `domain/` (its own), and Flutter/dart packages. **Never** from `features/Y/`. This is enforceable by lint:
  ```yaml
  # analysis_options.yaml (sketch)
  custom_lint:
    rules:
      no_cross_feature_imports:
        deny:
          - 'package:untitled2/features/(?!task_board)/.*': 'task_board/**'
          - 'package:untitled2/features/(?!document_verification)/.*': 'document_verification/**'
  ```
- `domain/` may import nothing from outside the feature, except `core/` types if absolutely needed.
- `presentation/` may import its own `domain/` interfaces but **not** its own `data/` classes — the screen's `initState` is the only place that constructs `data/` types.
- `data/` may import its own `domain/` interfaces and `core/` utilities. Nothing else.

#### Shared things that don't fit "core" or "feature"

For genuinely cross-cutting concerns that aren't pure utilities — say,
analytics events, feature flags, user session — the right move is a
top-level package layer:

```
lib/
├── platform/                   ← shared services with state (analytics, session)
│   ├── analytics/
│   ├── session/
│   └── feature_flags/
├── core/                       ← pure utilities (no state)
└── features/
```

The split rule: `core/` is pure-function/pure-data; `platform/` is
stateful services that all features may consume. Today we don't have
any so `platform/` doesn't exist; the moment we add the first one
(probably analytics), it goes there, not into `core/`.

### Q2. Where are the seams?

Six seams to know about, ordered by how often a new developer will
hit them:

#### 1. Repository interfaces (`domain/repositories/`)

This is the seam between business logic and storage. The controller
talks to `TaskRepository` / `DocumentRepository` interfaces, never to
implementations. Swapping in a real database changes only the
construction line in the screen `initState`. New developers should
look here first to understand "what can be done with X data."

Files:
- `lib/features/task_board/domain/repositories/task_repository.dart`
- `lib/features/document_verification/domain/repositories/document_repository.dart`

#### 2. The single status-update funnel in the document repo

`DocumentRepositoryImpl._applyStatusUpdate`
(`lib/features/document_verification/data/document_repository_impl.dart:300`) is the *only* place that translates wire-format status updates into local Document changes. WS and polling both feed in here. Anyone touching status logic must touch this method.

#### 3. The drag controller registry

`DragController.registerColumn` and `registerBoardScroll`
(`lib/features/task_board/presentation/drag/drag_controller.dart:79, 87`)
are the seam between columns/board and the gesture engine. New
columns or new scroll surfaces register themselves here so the drag
controller can hit-test against them.

#### 4. Modal sheets and provider scope

Modal bottom sheets are pushed under the *root* `Navigator`, above
any screen-scoped `MultiProvider`. Every `show()` static in the
codebase captures the controller from the calling context and
re-provides it inside the sheet. See:
- `TaskEditorSheet.show` at `lib/features/task_board/presentation/sheets/task_editor_sheet.dart:14`
- `TaskDetailSheet.show` at `lib/features/task_board/presentation/sheets/task_detail_sheet.dart:15`
- `UploadSheet.show` at `lib/features/document_verification/presentation/sheets/upload_sheet.dart:13`
- `DocumentDetailSheet.show` at `lib/features/document_verification/presentation/sheets/document_detail_sheet.dart:15`

A new developer adding a sheet must do the same.

#### 5. The connection-state controller of polling

`DocumentRepositoryImpl._onConnectionChanged`
(`document_repository_impl.dart:250`) is the single place that
decides "should we poll right now?". If the team adds a third real-time
source (e.g. SSE), it slots in here.

#### 6. The `core/` boundary

`lib/core/` contains the contract between features. Anything added
here must be useful to multiple features and must not depend on any
feature. Reviewers should push back on "this is shared by tasks and
docs" claims when only one feature actually uses it.

---

## Phase 4 — Offline Functionality

### Q1. Document upload queue when offline

I would build it on top of the existing optimistic flow, replacing the
in-process `try/catch` in `DocumentRepositoryImpl.upload` with a
durable queue.

#### Queue model

A new `data/document_upload_queue.dart` backed by a Drift table:

```sql
CREATE TABLE upload_queue (
  id              TEXT PRIMARY KEY,           -- local doc id
  document_type   TEXT NOT NULL,              -- PASSPORT|NATIONAL_ID|UTILITY_BILL
  byte_path       TEXT NOT NULL,              -- path to file on disk, NOT bytes
  byte_size       INTEGER NOT NULL,
  checksum        TEXT NOT NULL,
  priority        INTEGER NOT NULL,           -- 0=low, 5=high, 9=urgent
  attempt         INTEGER NOT NULL DEFAULT 0,
  next_attempt_at INTEGER,                    -- unix ms
  last_error      TEXT,
  upload_offset   INTEGER NOT NULL DEFAULT 0, -- bytes already accepted by server
  resume_token    TEXT                        -- if backend supports resumable uploads
);
```

Bytes go to disk (`getApplicationDocumentsDirectory()`), not into the
DB — large blobs in SQLite have well-known performance footguns.

#### Priority model

Three tiers driven by user intent:

1. **Urgent (9)** — user explicitly tapped "Retry" or just picked the file (interactive). Goes to the front of the queue.
2. **Normal (5)** — automatic retries after transient network failure. Honour the queue order.
3. **Background (0)** — re-uploads triggered by app coming back online after a long offline period. Drained slowly to avoid hammering the server when 200 users come back online at the same time after a regional outage.

Priority is also informed by document type — KYC passports/IDs are higher urgency than utility bills, so the picker would pre-set priority based on `DocumentType` (today's `DocumentTypeX` could grow a `priority` extension).

#### Retry logic

Exponential backoff with jitter and a hard cap:

```
attempt 1:  immediate
attempt 2:  2s + jitter
attempt 3:  8s + jitter
attempt 4:  32s + jitter
attempt 5:  120s + jitter
attempt 6+: 600s + jitter (cap)
```

The jitter prevents the thundering-herd on reconnect. After 10 failed
attempts we surface a "Tap to retry manually" state and stop auto-trying
— the user is in a degraded state we can't fix automatically.

The `attempt` and `next_attempt_at` columns are persisted so a kill-relaunch cycle resumes correctly.

#### Partial upload recovery

Two strategies depending on backend support:

**If the backend supports resumable uploads** (S3-style multipart, GCS resumable, or `tus` protocol):
- `upload_offset` tracks bytes already accepted.
- On resume we send a `Content-Range` header from `upload_offset` and continue.
- The `resume_token` column holds whatever opaque handle the backend gave us at start time.

**If it doesn't:**
- Treat upload as atomic. Failure means full re-upload from byte 0.
- Mitigate by chunking client-side: split files >5MB into independently-uploaded chunks and finalise with a "compose" call. This is what the Google Drive client does.

For the SWAMP spec which describes a single `POST` upload, we'd add
chunked-resumable support to the backend at the same time as building
the queue — they're co-designed.

#### Network awareness

The queue should not blindly retry; it should listen to network state.
`connectivity_plus` provides this:

```dart
Connectivity().onConnectivityChanged.listen((result) {
  if (result != ConnectivityResult.none) {
    queue.flushPending();
  }
});
```

Combined with the WebSocket connection state we already track
(`watchConnection()` in the repository), we have a coherent picture
of "what kind of network we have" — fully offline, intermittently
connected, fully online.

#### What the user sees

- An offline banner above the dashboard ("3 uploads queued — will retry when online").
- Per-document status pill: "Queued (waiting for connection)" / "Retrying in 8s" / "Failed — tap to retry".
- The audit trail captures every attempt (already does, via the existing `AuditEntry` model — see `Document.audit`).

### Q2. Task sync conflicts (offline edit vs concurrent online edit)

The hard case: User A edits a task offline. Meanwhile User B edits the
same task online. User A reconnects. Now we have two divergent versions.

I would handle this with **field-level last-write-wins on top of vector
clocks**, not whole-task last-write-wins. Whole-task LWW is the wrong
default because it silently throws away unrelated edits.

#### Mechanism

1. Every task carries a `version` map: `Map<String, Lamport>` where each editable field has a Lamport timestamp.
2. Clients increment their Lamport clock on every local edit.
3. Sync sends the current task + version map to the server.
4. Server merges field by field: for each field, the version with the higher Lamport wins.
5. The merged task is broadcast back to all clients.

Practically, for our `Task` entity:
- `title`, `description`, `priority`, `status`, `dueDate` get their own Lamport timestamps.
- `comments` is append-only — additions from both sides merge by union, sorted by `createdAt`.
- `activity` is append-only the same way.

This keeps comments and activity safe (no losses) while still giving deterministic conflict resolution on the structured fields.

#### When the merge isn't safe

Two cases need user mediation:

1. **Same field, both edited.** If User A and User B both rewrite the
   description, field-level LWW will pick one. We surface a merge
   conflict in the UI: "Your offline edits conflict with another change
   — keep yours, theirs, or merge?".
2. **Status × priority combinations.** If A moves to Done while B
   raises priority to Urgent, the merged result (Done + Urgent) might
   be incoherent. We log the merge and let it stand — the human can
   re-prioritise.

#### Why not CRDTs

CRDTs (e.g. Yjs/Automerge for text, RGA for lists) are the
state-of-the-art for offline-first collaborative apps. For the task
feature, they'd give:
- Lossless concurrent edits to descriptions (text CRDT).
- Lossless concurrent reorderings (RGA).

The cost is significant: every text field becomes a CRDT document
(~10× the bytes), every reorder requires rich position metadata, and
debugging is harder. For SWAMP's expected usage pattern (small teams,
infrequent simultaneous edits on the same task), Lamport + field-level
LWW is the right complexity tier. We'd revisit if we ever shipped real
collaborative editing within a task description.

#### Document feature — sync conflicts

Documents are largely uni-directional: the user uploads, the server
verifies. There are no concurrent multi-user edits on a single
document. The only conflict we'd see is "user deletes a doc locally
while server pushes a verification update for it" — `delete()` already
calls `_untrack(serverId)` (`document_repository_impl.dart:218`), and
incoming updates are dropped if the local id is unknown
(`_applyStatusUpdate` at line 317 returns early for unknown ids). So
the document feature is conflict-free by construction.

### Q3. What degrades gracefully without connectivity?

Per feature, broken down by concrete capability:

#### Tasks

| Capability | Offline behaviour | Notes |
|---|---|---|
| View task board | ✅ Full | All data is local once persisted (Phase 3 plan). |
| Create / edit / delete tasks | ✅ Full | Mutates local DB, queued for sync via the same Lamport mechanism. |
| Drag and drop between columns | ✅ Full | Pure UI state + local model mutation. Sync rides along. |
| Add comments | ✅ Full | Append-only — never conflicts. |
| Activity feed | ✅ Full | Local-only entries written immediately; sync entries arrive later. |
| Cross-device echoes (seeing teammate's edits) | ❌ Requires live | Resumes when reconnected; merge logic above runs on reconnect. |
| Due-date notifications | ⚠️ Partial — local fires from `flutter_local_notifications`; if the due date was set by another user offline-on-their-side, we won't know about it until sync. |

#### Documents

| Capability | Offline behaviour | Notes |
|---|---|---|
| View previously-uploaded documents | ✅ Full | Persisted via `DocumentRepositoryImpl._persist`. |
| View audit trail | ✅ Full | Stored alongside the document. |
| Pick a new document (camera/gallery/file) | ✅ Full | Picker is local. |
| Queue an upload | ✅ Full | The queue lives in local storage; uploads fire when online. |
| Actually verify a document | ❌ Requires live | Verification is server-side. The upload queues; status remains "Queued (offline)" until online. |
| Real-time status updates | ❌ Requires live | WebSocket needs a server. |
| Polling fallback | ❌ Still requires HTTP | But comes back online faster than WS in many real-world failure modes — DNS, captive portals, etc. |

#### What the UI promises

The connection banner at `lib/features/document_verification/presentation/widgets/connection_banner.dart` already surfaces "Reconnecting / Offline" states. We'd extend this with:
- A global app-level offline badge (e.g. on the bottom navigation bar) so the user knows the *whole* app is offline.
- Per-screen messaging that tells the user *why* they can't see fresh data, not just "offline".
- An audit-trail entry on every document that shows it was acted on while offline, so post-hoc anyone can see the order of events.

---

## Phase 4 — Security

### Q1. Document encryption — at rest and in transit

#### In transit

- **TLS 1.3 mandatory.** Refuse fallback to TLS 1.2 unless the device
  doesn't support 1.3 (rare on iOS 12+/Android 10+).
- **Certificate pinning** for the SWAMP API endpoints. Use
  `package:dio` with a `CertificatePinningInterceptor` (or
  `package:http` + `package:http_certificate_pinning`). Pin the
  intermediate CAs, not the leaf certificates — leaf rotation is too
  frequent.
- **No `allowBadCertificates` in any environment**, including local
  development, to avoid the "we forgot to turn it off in prod"
  failure mode.
- **HSTS preload** at the API layer.

#### At rest (on device)

For the encrypted file payload itself:

- **Algorithm: AES-256-GCM.** GCM gives authenticated encryption (no
  separate MAC step) and is hardware-accelerated on every modern
  iOS/Android device.
- **Per-file random IV**, 12 bytes, never reused. Stored prepended to
  the ciphertext.
- **Key derivation:** a per-document encryption key (DEK), wrapped by
  a per-user master key (MK). The MK lives in the platform keystore
  (see Q2). DEKs are random AES-256 keys generated at upload time and
  stored encrypted in the DB next to the file path.

This pattern matches the standard envelope encryption approach used by
KMS systems (AWS KMS, Google Cloud KMS, etc.) on the client side.

#### Library choice

- **`package:cryptography`** (Pure Dart with hardware-accelerated
  builds). Cross-platform, no native config, audited, supports AES-GCM
  with streaming encryption out of the box.
- Avoid `package:encrypt` — wraps OpenSSL with a smaller surface but
  has weaker maintenance.
- Avoid rolling our own — even thin wrappers over platform crypto are
  a footgun.

#### Streaming for large files

A 10 MB document shouldn't be loaded into RAM as plaintext. The
encryption pipeline:

```
File on disk
  → ChunkedReader (1 MB chunks)
  → AES-GCM streaming encrypt
  → ChunkedWriter to encrypted file on disk
```

`package:cryptography`'s `Cipher.newEncryptingSink` supports this. The
existing `DocumentBytes` would gain an alternate "encrypted handle"
mode where bytes are not held in RAM — important for the queue (see
offline section above).

#### Where decryption happens

Two places:

1. **Just before upload** — read encrypted bytes from disk, decrypt
   in chunks, stream into the upload request body. The plaintext
   never touches the heap as a single `Uint8List`.
2. **On viewing a document preview** — same shape but decrypting into
   an `Image.memory` widget, with the decrypted bytes thrown away as
   soon as the widget is disposed.

### Q2. Key management on iOS and Android

I would use `flutter_secure_storage` as the entry point. It abstracts
the right primitive on each platform:

- **iOS: Keychain Services** with the access modifier
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. The "this device
  only" bit prevents iCloud Keychain syncing, which is critical for
  KYC keys — they should never leave the device.
- **Android: EncryptedSharedPreferences** backed by AndroidKeyStore.
  AndroidKeyStore can use the device's Strongbox or TEE
  (Trusted Execution Environment) when available.

The master key (MK) lives in this storage. Per-document encryption
keys (DEKs) are derived using HKDF — they get generated as random,
encrypted with the MK, then stored beside the document metadata.

#### Bootstrap

On first run we generate a 32-byte random MK and write it. The MK is
not derivable from the user's password — it's a device key. Users
authenticate with biometrics to *unlock access* to it, not to derive
it.

#### Biometric gate

`local_auth` package wraps:
- iOS: Face ID / Touch ID
- Android: BiometricPrompt

A failed biometric prompt blocks reads of the keystore. We'd configure
the access constraint at write time:

```dart
await secureStorage.write(
  key: 'mk',
  value: keyBytes,
  iOptions: IOSOptions(
    accessibility: KeychainAccessibility.unlocked_this_device_only,
  ),
  aOptions: AndroidOptions(
    encryptedSharedPreferences: true,
  ),
);
```

For high-sensitivity operations (viewing a verified passport image),
we'd require a fresh biometric within the last 30 seconds. The
audit trail records that biometric was passed.

#### Key rotation

Two scenarios:

1. **DEK rotation** is cheap — re-encrypt one document with a new DEK.
   We would do this on every upload (DEKs are per-document) and never
   reuse them.
2. **MK rotation** is expensive — re-wrap every DEK with the new MK.
   We would do it (a) if there's any indication the device key was
   compromised, (b) on user-initiated "reset secure storage" actions,
   (c) annually as a hygiene measure.

#### What I would not do

- **Store keys in `SharedPreferences` (unencrypted) or in the
  database.** Both are world-readable on rooted/jailbroken devices.
- **Roll a custom keystore.** Even one mistake here is catastrophic.
- **Log keys, even in debug builds.** A `debugPrint` of a key byte
  array in development is a persistent device-log artifact.
- **Pin a single biometric type.** Allow Face ID OR Touch ID OR
  device passcode as fallback, with audit entries marking which was
  used.

### Q3. Audit trail for compliance

The current `AuditEntry` model
(`lib/features/document_verification/domain/entities/document.dart`)
is the in-memory shape. For compliance I would extend it as follows.

#### Required fields per entry

| Field | Why |
|---|---|
| `id` (UUID v7) | Stable identifier, time-ordered. |
| `documentId` (server id) | What was acted on. |
| `kind` | Already an enum — extend with `accessed`, `decryptedForView`, `exported`. |
| `actor.userId` | Who did it. |
| `actor.deviceId` | Which device — needed because compromised devices can be revoked. |
| `actor.appVersion` | For forensic correlation across versions. |
| `at` (ISO 8601 UTC, microsecond precision) | When. |
| `geoip` (country only, if available) | Compliance auditors care about jurisdiction. |
| `result` (`success` / `denied` / `error`) | What happened. |
| `details` | Free-form for auditor context (e.g. rejection reason). |
| `prevHash` (SHA-256 of previous entry's signature) | Tamper-evident chain. |
| `signature` (HMAC-SHA-256 over the entry, using a server-issued audit key) | Per-entry integrity. |

The `prevHash` chain makes the audit trail Merkle-like: removing or
rewriting one entry invalidates every later signature, and any auditor
can verify the chain end-to-end.

#### Storage

- **Local:** append-only Drift table; never updated after insert.
- **Server-mirrored:** every entry is also pushed to a server-side
  audit log within ~minutes (queued the same way as document uploads,
  since this is a write that must survive offline). Server-side
  storage is in a write-once-read-many bucket (S3 with object lock,
  for example).

#### Retention

- **Local:** keep last 90 days for diagnostic UI; older entries
  archived to server.
- **Server:** 7 years for KYC compliance (typical EU/US KYC
  retention). Encrypt at rest with a separate key from document content
  — auditors might be allowed to read the trail without being allowed
  to read documents.

#### What gets logged

- Document upload, retry, deletion (currently logged).
- Document **access** — every time the user (or an admin) views the
  document image, with `kind: accessed` and the biometric proof.
- Document **status changes** from the server (currently logged).
- **Decryption** events — every time we pull plaintext off disk, even
  if the user doesn't see it (e.g. for re-upload).
- **Export** — sharing or exporting outside the app. Would gate
  behind a stronger biometric prompt.
- **Failed access attempts** — biometric failures, expired
  authorisations.

#### Auditor read

A separate "compliance" build of the app, or a server-side admin
console, would render the audit trail with the cryptographic chain
verified visibly. The user-facing app shows only the entries relevant
to that user.

#### What the existing Phase 2 code already gives us

The audit trail in `AuditEntry` and `_applyStatusUpdate` is the bones
of this — every meaningful state change writes one entry, and the
entries travel with the document via the immutable `copyWith` chain.
The compliance hardening (signatures, prev-hash, mirrored storage) is
purely additive on top.

---

## Document end

This file answers Phase 3 in full and the offline + security sections
of Phase 4. Performance is in `PERFORMANCE.md`.

The high-confidence claims here are the ones backed by code in the
repo. The Phase 4 sections are forward-looking — the architecture is
shaped to make them buildable rather than bolted on, but they aren't
implemented today, and I have called that out where relevant.
