# SWAMP_ — Architecture

Two features, one app. Tasks (Trello-style board) and Documents (KYC verification dashboard) live side by side under `lib/features/`, share nothing but a small `core/` folder, and answer to the same architectural rules.

This document covers Phase 3 in full — state management, dependency injection, data layer, project structure — plus the offline and security parts of Phase 4. Performance lives in `PERFORMANCE.md`.

I've tried to keep the claims here checkable. Most "I did X" statements are paired with a file path, sometimes a line number, so anyone reading can confirm the code matches.

---

## State management

### What I picked, and why

`provider` with per-feature `ChangeNotifier`s. Each feature owns its own controller; the screen creates it in `initState`, exposes it through a `MultiProvider`, and lets the widget tree below subscribe to whatever slice it needs.

There are four notifiers in total:

- **`TaskBoardController`** — the task feature's source of truth for the board's grouped lists, CRUD, and activity log.
- **`DragController`** — drag-gesture state. Lives next to `TaskBoardController` but is deliberately separate. If pointer-move events lived on the board controller, every move would mark the whole task list dirty. Splitting them means only the drag overlay and the active slot indicator rebuild while the user is dragging.
- **`DocumentDashboardController`** — owns the document list and connection state for the document feature.
- **`DocumentRepositoryImpl`** — not a `ChangeNotifier`, but exposes broadcast streams that the controller subscribes to.

The thing I considered most carefully was whether the friction of `provider` was worth saving by going to Riverpod or Bloc. For one screen per feature with no cross-screen subscriptions, I couldn't justify either. Bloc would push me to write event classes for every CRUD operation and the boilerplate would dwarf the logic. Riverpod's compile-time DI is a nice-to-have I didn't need yet — the dependency graph is small enough to read directly in each screen's `initState`. `provider` gave me what I wanted with less ceremony.

If the document feature later grew a second screen — verification history, admin review — that needed access to the same controller across routes, I'd lift the controller above `MaterialApp.builder` so modal routes could read it without the re-provide trick. For now, screen-scoped is correct.

### How the two features handle state — together or apart?

Apart, by construction. `lib/features/task_board/` and `lib/features/document_verification/` are siblings that don't import from each other. They both import from `lib/core/` (theme, haptics, id, notifications interface) but never from each other.

That isolation is what answers the brief's question about coupling. By construction, you can't accidentally couple these features because they literally cannot see each other.

Why not have shared types between them? Because a task isn't a document, and forcing them through a shared shape would either flatten the differences or invent a fake commonality. The closest thing to shared state is `SharedPreferences`, but each feature uses its own keyed namespace (`document_verification.docs.v1`), so neither feature can stomp on the other's data even though they share the storage primitive.

---

## Dependency injection

### The registration approach

Constructor injection, with each feature's screen `initState` as the composition root. There's no global locator, no `get_it`, no service registry.

When the document dashboard mounts, `_DocumentDashboardScreenState.initState` reads:

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

Six lines. That's the entire dependency graph the document feature needs. A new dev grepping for "where does the document repo come from" finds the answer in one screen file — no plumbing to follow.

The cost is a bit of repeat construction. For two features that's fine; if we grew to five-plus features I'd consider lifting common dependencies (a single `Database`, a single `HttpClient`) above the screen layer.

What's registered, and at what scope:

| Type | Scope | Why |
|---|---|---|
| Controllers | Screen | Lifecycle matches the screen; nothing else needs them. |
| Repositories | Screen | One per controller. |
| Mock backend, API client, WS client, polling | Screen | Wired up at construction; disposed transitively. |
| `SharedPreferences` | App | Plugin gives a singleton. |
| `AppTheme` | App | Pure data. |
| Platform plugins (`image_picker`, `file_picker`) | Screen | Stateless wrappers. |

There's nothing exotic in that table. Most of these you'd guess.

### Sharing services without coupling

Through `core/`, and through interfaces.

`core/notifications.dart` is the canonical example. It exposes `NotificationService` as an abstract interface; the in-app log implementation sits next to it. Neither file knows tasks or documents exist. When we want real notifications, a `flutter_local_notifications`-backed implementation drops in behind the same interface, and one line per feature changes.

The rule: anything in `core/` must be useful to multiple features and must not depend on any feature. The moment something in `core/` reaches into a feature folder, it's no longer core — it's a misfiled feature concern.

If we ever need something heavier — say, an HTTP client both features want to talk to — the right shape is a thin interface in `core/`, with a default implementation, both consumed by feature data layers. Each feature depends on the abstraction, never on the other feature.

---

## Data layer

### Local database choice

Today, tasks live in memory and documents persist their metadata to `SharedPreferences`. Both are deliberate Phase 1/Phase 2 trade-offs — implementing real persistence wasn't where the rubric weighted attention.

In production I'd use Drift (formerly Moor). It's a typed, code-generated SQLite layer with first-class reactive query streams, which matters because both features want a "tell me when this list changes" subscription rather than a "fetch me a snapshot" call.

The alternatives I weighed:

- **Hive** is fast and dead simple, but it's NoSQL with no relational model. Comments belong to tasks; activity entries belong to documents; audit entries belong to documents. Forcing those through a key-value store would mean denormalising everything.
- **Isar** would actually be a strong choice — fast, reactive, schema-aware. The catch is its maintenance momentum has wobbled lately. For a long-lived KYC product I'd rather pick the conservative bet.
- **Sembast** is fine for hundreds of records but slows past that.
- **Floor / sqflite raw** both work. Drift is the same SQLite engine but with a much nicer typed API.

The migration to Drift wouldn't change anything in the UI. The repository interfaces (`TaskRepository`, `DocumentRepository`) live in `domain/`; the concrete implementations live in `data/`. When we move to Drift, we add `data/drift_task_repository.dart`, change one line in the screen `initState`, and the controllers don't notice.

### How data flows from network to UI

Two shapes, one principle.

**Tasks (Future-based)** is straightforward. A user gesture calls a controller method, the controller calls a repository method, the repository returns a future, the controller updates its grouped lists, calls `notifyListeners`, the widget tree rebuilds. The controller is the only thing that talks to the repository. Widgets never reach for storage directly. That single hop makes the widget tree dumb and the controller authoritative.

**Documents (Stream-based)** is where it gets interesting. The repository wires three async sources:

1. The HTTP API for uploads and status fetches.
2. The WebSocket for live status updates while connected.
3. The polling service for fallback while the WebSocket is reconnecting or offline.

All three feed updates into a single funnel — `_applyStatusUpdate` in `DocumentRepositoryImpl`. That's the only place wire-format updates become local Document changes. The WS client and the polling service can never disagree on what "moving to VERIFIED" means because there's only one place that interprets it.

Every public mutation in the repository ends in `_emit()`, which does two things — pushes the updated list onto a broadcast stream and writes the change to `SharedPreferences`. The controller listens to the stream; the UI listens to the controller; everything stays in lock-step.

Both features use the repository pattern even though their async shapes differ. The point isn't the shape — it's that the rest of the app gets one consistent story: there's an interface, the data comes from there, and here's how it gets to the UI.

---

## Project structure

### Structuring for a team of 4+

The layout you see now — feature-first, with `core/` shared and `app/` for navigation — is exactly the structure I'd recommend.

```
lib/
├── app/                ← navigation shell, routing
├── core/               ← cross-feature utilities (no business logic)
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

It works for teams because ownership maps to folders. A `CODEOWNERS` rule per feature folder is enough for review routing. PR conflicts cluster around `core/` and `app/`, both of which are small surfaces; feature PRs don't cross paths. A new dev can ramp on one feature at a time — "read `lib/features/document_verification/`, ignore everything else" is a tractable instruction.

The dependency arrow inside each feature still points inward toward `domain/`. So `data/` knows about `domain/`, `presentation/` knows about `domain/`, but neither feature knows the other exists.

The conventions a team would enforce, ideally with custom lints:

- A feature may import from `core/` and from its own `domain/`. Never from a sibling feature.
- `domain/` may import almost nothing — pure Dart, optionally a Flutter type for things like `Color` on enum extensions.
- `presentation/` may import its own `domain/` interfaces but not its own `data/` classes. The screen's `initState` is the only place that constructs `data/` types.

If we grew past two features I'd add a `platform/` layer for stateful cross-cutting services (analytics, session, feature flags) to keep `core/` strictly pure-utility. We don't have any today, so the layer doesn't exist yet.

### Where the seams are

Six places. A new dev needs to know all of them.

The **repository interfaces** in each feature's `domain/repositories/` are the seam between business logic and storage. Swapping in a real database changes only the construction line in the screen `initState`.

**`_applyStatusUpdate` in `DocumentRepositoryImpl`** (line 300) is the single place that translates wire-format updates into Document mutations. Anyone touching status logic touches this method.

The **drag controller's registry** — `registerColumn` and `registerBoardScroll` (lines 79 and 87 in `drag_controller.dart`) — is the seam between columns/board and the gesture engine. New columns or scroll surfaces register themselves here.

**Modal sheets and provider scope.** Modals are pushed under the root Navigator, above any screen-scoped provider. Every `show()` static in the codebase captures the controller from the calling context and re-provides it inside the sheet. Adding a new sheet means doing the same.

**`_onConnectionChanged` in `DocumentRepositoryImpl`** (line 250) is the single place that decides whether to poll. Adding a third real-time source slots in here.

**The `core/` boundary.** Anything added must be useful to multiple features and must not depend on any feature. Reviewers should push back when "this is shared by tasks and documents" turns out to mean "tasks uses it and the doc team might one day."

---

## Phase 4 — Offline

### Document upload queue when offline

I'd build it on top of the existing optimistic-upload flow, replacing the in-process `try/catch` in `DocumentRepositoryImpl.upload` with a durable queue.

The queue itself is a Drift table:

```sql
CREATE TABLE upload_queue (
  id              TEXT PRIMARY KEY,
  document_type   TEXT NOT NULL,
  byte_path       TEXT NOT NULL,    -- file on disk, NOT bytes inline
  byte_size       INTEGER NOT NULL,
  checksum        TEXT NOT NULL,
  priority        INTEGER NOT NULL,
  attempt         INTEGER NOT NULL DEFAULT 0,
  next_attempt_at INTEGER,
  last_error      TEXT,
  upload_offset   INTEGER NOT NULL DEFAULT 0,
  resume_token    TEXT
);
```

Bytes go to disk, not into the database. Large blobs in SQLite have well-known performance footguns — you really don't want a 10 MB file in a row.

Three priority tiers, driven by user intent. **Urgent (9)** is for uploads the user just initiated or just retried — front of the queue. **Normal (5)** is automatic retry after transient failure; honours queue order. **Background (0)** is bulk re-upload after extended offline; drained slowly so we don't hammer the server when a regional outage clears and 200 users come back at the same moment. Priority can also vary by document type — a passport ID is more urgent than a utility bill.

Retry uses exponential backoff with jitter, capped at 10 minutes:

```
attempt 1:  immediate
attempt 2:  2s + jitter
attempt 3:  8s + jitter
attempt 4:  32s + jitter
attempt 5:  120s + jitter
attempt 6+: 600s + jitter (cap)
```

After 10 failures the queue surfaces a "Tap to retry manually" state and stops auto-retrying. We're in a degraded state we can't fix automatically; better to ask for help than fail in a loop.

Partial recovery comes in two flavours depending on backend support. If the backend supports resumable uploads (S3 multipart, GCS resumable, `tus`), we track an `upload_offset` and resume with a `Content-Range` header from where the failure left off. If it doesn't, treat upload as atomic and consider chunking client-side — split files larger than 5 MB into independently-uploaded chunks and finalise with a compose call. This is what the Google Drive client does.

The queue listens to `connectivity_plus`. When connectivity returns, it flushes pending uploads. Combined with the WebSocket connection state already exposed by the repo (`watchConnection()`), we have a coherent picture of "what kind of network we have right now."

The user sees an offline banner above the dashboard ("3 uploads queued"), per-document status pills ("Queued — waiting for connection" / "Retrying in 8s" / "Failed — tap to retry"), and audit entries for every attempt.

### Task sync conflicts

The hard case: User A edits a task offline. User B edits the same task online at the same time. User A reconnects.

I'd handle this with field-level last-write-wins on top of vector clocks, not whole-task last-write-wins. Whole-task LWW is the wrong default because it silently throws away unrelated edits — User A renames the title, User B raises the priority, and one of those edits disappears.

Every task carries a version map: `Map<String, Lamport>` where each editable field has a Lamport timestamp. Local edits increment the clock. On sync, the server merges field by field — for each field, the higher Lamport wins. For our `Task`:

- `title`, `description`, `priority`, `status`, `dueDate` get their own Lamport timestamps.
- `comments` is append-only — additions from both sides merge by union, sorted by `createdAt`. Same for `activity`.

That keeps comments and activity safe (no losses) while still giving deterministic resolution on the structured fields.

Where it falls short: same field, both edited. If A and B both rewrite the description, LWW picks one. We surface the merge conflict in the UI: "Your offline edits conflict — keep yours, theirs, or merge?". Status × priority combos are similar — if A moves to Done while B raises priority to Urgent, the merged result might be incoherent. We log the merge and let it stand. A human can re-prioritise.

I considered CRDTs (Yjs, Automerge for text, RGA for lists). They'd give lossless concurrent edits. But every text field becomes a CRDT document (~10× the bytes), every reorder becomes rich position metadata, and debugging becomes harder. For SWAMP's expected usage pattern — small teams, infrequent simultaneous edits — Lamport plus field-level LWW is the right complexity tier.

The document feature is conflict-free by construction. Documents are uni-directional (user uploads, server verifies); there are no concurrent multi-user edits. The only conflict shape — "user deletes locally while server pushes a verification update" — is already handled: `delete()` calls `_untrack(serverId)`, and incoming updates for unknown ids drop on the floor.

### What degrades gracefully

For tasks, almost everything works offline. Read, create, edit, delete, drag, comment, activity feed — all of these mutate local state and queue for sync. The sync path is the same Lamport mechanism above. What requires a live connection: cross-device echoes (seeing teammate's edits) and notifications about events that happened on someone else's device.

For documents, less. Viewing existing documents and their audit trails works offline because everything's persisted. Picking a new file works offline. Queueing an upload works offline. But actually verifying a document requires the server — verification is a backend pipeline; we can't run it on the device. Real-time status updates obviously need a live connection. The polling fallback also needs the network — it's just polling instead of WebSocket.

The connection banner already exists for the document feature and tells the user when real-time updates are degraded. I'd extend this to a global app-level offline indicator (probably on the bottom navigation bar) and per-screen messaging that explains *why* the user can't see fresh data, not just that they can't.

---

## Phase 4 — Security

### Document encryption — at rest and in transit

In transit: TLS 1.3 mandatory, refusing fallback to TLS 1.2 unless the device truly doesn't support it (rare on iOS 12+ / Android 10+). Certificate pinning at the API client layer — pin the intermediate CAs, not leaf certificates, because leaf rotation is too frequent and we'd brick clients on every renewal. No `allowBadCertificates` in any environment, including dev. That's the failure mode where someone forgets to flip it off in prod.

At rest: AES-256-GCM with a per-file random IV (12 bytes, never reused). GCM gives authenticated encryption — no separate MAC step needed — and is hardware-accelerated on every modern phone. Per-document encryption keys (DEKs), wrapped by a per-user master key (MK) that lives in the platform keystore. This is the standard envelope-encryption pattern.

For the library, `package:cryptography`. Pure Dart with hardware-accelerated builds, audited, supports AES-GCM with streaming encryption. I'd avoid `package:encrypt` (weaker maintenance) and definitely avoid rolling our own anything.

For files larger than ~1 MB I'd use streaming encryption. A 10 MB document shouldn't be loaded into RAM as plaintext. The cryptography library's `Cipher.newEncryptingSink` supports this — the `DocumentBytes` model would gain an "encrypted handle" mode where bytes never live in memory.

Decryption happens in two places. Just before upload: read encrypted bytes from disk, decrypt streaming, send chunks straight to the upload request body. Plaintext never touches the heap as a single allocation. On viewing a preview: decrypt into an `Image.memory` widget, throw away decrypted bytes when the widget disposes.

### Key management on iOS and Android

`flutter_secure_storage` as the entry point — it abstracts the right primitive on each platform.

On iOS, Keychain Services with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. The "this device only" bit prevents iCloud Keychain syncing, which matters for KYC keys — they should never leave the device.

On Android, EncryptedSharedPreferences backed by AndroidKeyStore. The Keystore can use the device's StrongBox or TEE (Trusted Execution Environment) when available, putting the key in hardware-backed isolation.

The master key is generated once on first run (32 random bytes), written to secure storage, and never derived from a user password. It's a device key. Users authenticate with biometrics to unlock access to it, not to derive it.

Biometric gating goes through `local_auth` (Face ID, Touch ID, BiometricPrompt). Failed prompts block reads. For high-sensitivity operations — viewing a verified passport image, exporting a document — I'd require a fresh biometric within the last 30 seconds, and the audit trail records that a biometric was passed.

Key rotation. DEK rotation is cheap (re-encrypt one document) and happens on every upload; DEKs are per-document and never reused. MK rotation is expensive (re-wrap every DEK) and would happen on suspected compromise, on explicit "reset secure storage" actions, or annually as hygiene.

What I'd never do: store keys in unencrypted SharedPreferences, log keys in any environment including debug, pin to a single biometric type without a device-passcode fallback, or roll a custom keystore.

### Audit trail

The current `AuditEntry` model is the in-memory shape. For compliance I'd extend it.

Required fields per entry:

- `id` (UUID v7 — time-ordered, stable)
- `documentId`
- `kind` (already an enum — extend with `accessed`, `decryptedForView`, `exported`)
- `actor.userId`, `actor.deviceId`, `actor.appVersion`
- `at` (ISO 8601 UTC, microsecond precision)
- `geoip` (country only)
- `result` (`success` / `denied` / `error`)
- `details` (free-form auditor context)
- `prevHash` (SHA-256 of the previous entry's signature)
- `signature` (HMAC-SHA-256 over the entry, using a server-issued audit key)

The `prevHash` chain makes the trail Merkle-like. Removing or rewriting one entry invalidates every later signature, and an auditor can verify the whole chain end-to-end in one pass.

Storage is append-only Drift locally, server-mirrored within minutes. Server-side, write-once-read-many (S3 with object lock works). Retention: 90 days locally for diagnostic UI, 7 years on the server for KYC compliance (typical EU/US retention). The server-side trail is encrypted at rest with a key separate from document content — auditors might be allowed to read the trail without being allowed to read documents.

What gets logged:

- Document upload, retry, deletion (already logged today).
- Document **access** — every preview view, with biometric proof.
- Status changes from the server (already logged).
- **Decryption** events, even if the user doesn't see the result (e.g. for re-upload).
- **Export** — sharing or saving outside the app. Gated behind a stronger biometric prompt.
- **Failed access attempts** — biometric failures, expired authorisations.

Auditor read happens through a separate compliance build of the app or a server-side admin console, with the cryptographic chain verified visibly. Users see only the entries relevant to their own activity.

The Phase 2 code already has the bones of this. Every meaningful state change writes an entry, and entries travel with the document via the `copyWith` chain. The compliance hardening — signatures, prev-hash, mirrored storage — is purely additive on top.

---

That's the architecture story. The high-confidence claims are the ones backed by code in the repo — those reference file paths and lines. The Phase 4 sections are forward-looking: the architecture is shaped to make them buildable rather than bolted on, but I haven't built them yet, and I've called that out where it's relevant.
