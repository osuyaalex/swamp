# Testing strategy

The brief asks for "a testing approach that is thoughtful — prioritise meaningful coverage over hitting a number." This document explains where I drew the line and why.

---

## Where I tested, where I didn't

I wrote tests for the two places where regressions are silent and expensive: the **task board state machine** and the **document repository's async lifecycle**. Both are pure-Dart layers — no widgets, no plugins — so they run fast, deterministically, and tell me if business logic broke.

I did **not** write widget tests for the drag-and-drop or the camera screen. Both are dominated by gesture, render, and platform-channel behaviour that widget tests don't reproduce faithfully. Asserting "the ghost preview's shadow has the right opacity" through a `WidgetTester` is the kind of test that passes while the real interaction is broken. That's a regression net you trust until it lies to you.

The trade-off: a real regression in the drag overlay would only be caught by the demo video or a manual run. I judged that acceptable for an assessment-scope project — at team scale I'd add Maestro / Patrol flow tests for those interactions instead of widget tests.

---

## What's covered

### `test/widget_test.dart` — `TaskBoardController`

| Test | What it pins down |
|---|---|
| `createTask lands in To Do at index 0` | Insert position invariant; new tasks always appear at the top of the column |
| `moveTask across columns updates status and clamps the index` | Cross-column move logs status change, target index is clamped to column length, "moved" activity entry appended |
| `moveTask within a column adjusts for the source index shift` | The classic ReorderableListView off-by-one — moving from index 0 to "index 2" must land at index 1 because the source was removed first |
| `addComment appends comment + activity entry` | Comment write also writes an activity entry with kind `commented` |
| `editTask logs priority + due-date changes as separate activity` | Edit emits one activity per *kind* of change, not one bundled entry |
| `deleteTask removes from board` | Hard-delete sweeps from every column |
| `createTask with due date schedules a notification` | Notification side-effect happens at creation, not later |

### `test/document_repository_test.dart` — `DocumentRepositoryImpl`

The async surface is the part most likely to break under pressure (network drops, app restarts, simultaneous status updates), so every test covers a concrete async invariant against a deterministic `MockDocumentBackend`:

| Test | What it pins down |
|---|---|
| Upload immediately surfaces an optimistic entry, then transitions through verified | Optimistic update is visible *before* the network round-trip; status transitions arrive in order |
| Upload rolls back to `queued` when the API throws | Failure path doesn't leave the UI in `uploading` forever; rollback emits a queued entry with an audit-trail message |
| Retry on a queued doc re-uploads and reaches uploaded state | Retry uses the same path as initial upload, not a special branch |
| Status transitions via WebSocket | `STATUS_UPDATE` messages drive the same state path as polling — the UI doesn't need to know which source delivered the update |
| Persistence round-trip | Writing and re-reading from `SharedPreferences` preserves the document list and audit chain |

---

## What I deliberately skipped

- **Drag overlay rendering, ghost preview, edge auto-scroll** — not faithfully reproducible in widget tests. Verified manually + on video.
- **Camera + edge detection** — needs the real platform channel. Verified on-device.
- **OCR result accuracy** — that's a model-quality test, not a code-correctness test. The wrapper is thin enough that "the ML Kit call returned a string" isn't worth a test.
- **Notification delivery** — the in-app `InAppNotificationService` exposes `debugScheduled` so I assert scheduling intent (covered above), not OS delivery.
- **WebSocket reconnect policy under random drops** — the `simulateDrops` flag is on by default at runtime but disabled in tests so they stay deterministic. The reconnect logic is small enough to read.

---

## How I'd extend this for a team

1. **Golden tests** for the priority badges, status pills, and audit timeline — these are pure-paint widgets where a visual regression is exactly what you want to catch.
2. **Patrol or Maestro** flow tests for the two critical user journeys: "create task, drag it across columns, comment on it" and "upload a passport, watch it verify". These actually exercise the gesture and platform layers that widget tests punt on.
3. **Contract tests** against the real KYC backend once it exists — the current `MockDocumentBackend` is the contract, and I'd want a fixture-based test that the real server's responses still satisfy `DocumentApiClient`'s expectations.
4. **Property-based tests** for `moveTask` — its index arithmetic is the kind of thing where fuzzing would catch the edge case I missed.

---

## Running the tests

```bash
flutter test                                    # everything
flutter test test/widget_test.dart              # task board only
flutter test test/document_repository_test.dart # document repo only
flutter test --coverage                         # with lcov output
```

The suites run in single-digit seconds. Both use deterministic fakes (no `Future.delayed` race conditions), so flakes haven't been a problem.