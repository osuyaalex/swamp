# SWAMP_ — Senior Flutter Assessment

Two features in one Flutter app for the Polymarq PolyOps assessment:

1. **Task board** — Trello-style CRUD with custom drag-and-drop, priorities, due dates, comments, and an activity log.
2. **Document verification** — KYC dashboard with multi-document upload, in-app camera + edge detection, on-device OCR, and real-time status via WebSocket with a polling fallback.

The architecture, the offline/security thinking, and the performance strategy live in their own files — this README is just enough to clone, run, and find your way around.

---

## Run it

```bash
flutter pub get
flutter run                         # device or simulator
flutter test                        # both test suites
flutter build apk --release         # Android
flutter build ios --release         # iOS (requires signing)
```

Tested with Flutter `3.x` / Dart SDK `^3.11.1` (see `pubspec.yaml`). No env vars, no backend to point at — the document feature uses an in-process `MockDocumentBackend` so the WebSocket / polling / upload flows are exercised end-to-end without a network.

A pre-built debug APK is in `deliveries/` if you'd rather sideload than build.

---

## Where things live

```
lib/
├── app/                          # HomeShell + bottom nav
├── core/                         # Cross-feature primitives
│   ├── audit_signing.dart        # HMAC chain for tamper-evident audit log
│   ├── biometrics.dart           # local_auth gate
│   ├── connectivity_state.dart   # connectivity_plus stream + offline banner
│   ├── edge_detection.dart       # custom RenderObject for live doc edges
│   ├── haptics.dart              # platform-aware feedback
│   ├── image_processor.dart      # compute()-based compression on isolate
│   ├── notifications.dart        # NotificationService interface + in-app impl
│   ├── screen_capture_guard.dart # prevents screenshots on KYC screens
│   └── secure_storage.dart       # flutter_secure_storage wrapper
├── features/
│   ├── task_board/{domain,data,presentation}/
│   └── document_verification/{domain,data,presentation}/
│       └── data/ocr_service.dart # ML Kit text recognition wrapper
└── main.dart

test/                             # Repository + controller tests (see docs/TESTING.md)
docs/                             # Supporting docs (testing strategy, etc.)
deliveries/                       # Demo video, prebuilt APK, the assessment PDF
ARCHITECTURE.md                   # Phase 3 + Phase 4 (offline & security)
PERFORMANCE.md                    # Phase 4 — performance strategy
README.md                         # this file
```

The structure is feature-first rather than layer-first — `lib/features/<x>/{domain,data,presentation}/` instead of `lib/{domain,data,presentation}/<x>/`. Each feature owns its own clean-architecture layers; `core/` is the only shared surface. ARCHITECTURE.md explains why.

---

## What's implemented

**Phase 1 — Task Management (BUILD)** — full CRUD, custom drag-and-drop with shadows, ghost preview, edge auto-scroll, cross-column centre auto-scroll, haptics, priorities (low/medium/high/urgent), due dates with notification scheduling, comments, and an activity log.

**Phase 2 — Document Verification (BUILD)** — uploads for Passport / National ID / Utility Bill (image_picker, file_picker, in-app camera), basic image quality validation, JPG/PNG/PDF handling, real-time status via mock WebSocket with auto-reconnect, polling fallback, optimistic uploads with rollback, retry on rejection, persisted state across restarts.

**Phase 3 — Architecture & DI (DESIGN)** — `ARCHITECTURE.md`.

**Phase 4 — Offline / Security / Performance (DESIGN)** — offline + security in `ARCHITECTURE.md`, performance in `PERFORMANCE.md`.

### Could-Have / Bonus actually shipped

- **Custom camera with real-time edge detection** — `lib/core/edge_detection.dart` uses a custom `RenderObject` over the camera preview.
- **OCR** — Google ML Kit text recognition wired into the upload flow.
- **Biometric gate** — KYC screens require `local_auth` before content renders.
- **Encryption-ready storage** — `flutter_secure_storage` for tokens; document bytes are addressable by checksum.
- **Signed audit chain** — each audit entry HMAC-chained to its predecessor (`lib/core/audit_signing.dart`), tamper-evident even without a server.
- **Screen-capture guard** — `screen_protector` blocks screenshots and screen recording on document screens.
- **Background image processing** — compression and EXIF-strip run on a background isolate via `compute()`.
- **Offline banner + connection-aware UI** — `connectivity_plus` stream feeds a banner; the document repo queues failed uploads with retry.

---

## Tests

Two suites covering the parts most likely to regress:

- `test/widget_test.dart` — `TaskBoardController` CRUD, cross-column move, off-by-one inside a column, comment + activity logging, notification scheduling.
- `test/document_repository_test.dart` — optimistic upload, rollback on API failure, retry from queued, status transitions through the WebSocket, persistence round-trip.

The full strategy — what's covered, what's deliberately not, and why — is in [`docs/TESTING.md`](docs/TESTING.md).

---

## Documentation map

| File | What's in it |
|---|---|
| `README.md` | This file — setup + map |
| `ARCHITECTURE.md` | State management, DI, data layer, project structure, offline, security |
| `PERFORMANCE.md` | 1,000-task rendering, image memory, profiling tools, target benchmarks |
| `docs/TESTING.md` | Testing approach, what's covered, trade-offs |

---

## Commit history

The branch is `feature-apk`. Commits are grouped by phase so the history reads as the project was built — Phase 1 first, then Phase 2, then the security/camera/OCR additions, then docs. `git log --oneline main..feature-apk` is the short version.

---

## Demo video

`deliveries/` holds the 8–10 minute walkthrough covering both features, real-time status updates, and at least one error / edge case scenario.