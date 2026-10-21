# Development ownership

- switchyard-desktop is a standalone macOS app distributed as a DMG, with its own bundled Switchyard server.
- Ship one application target, `SwitchyardDesktopApp`, with one `switchyard-desktop.app` bundle and no edition selector.
- All server development happens first in `../NVIDIA` (relative to this checkout).
- Never edit `vendor/switchyard` directly. Import changes with `scripts/update-switchyard.py` and keep `vendor/switchyard-source.json` with the snapshot.
- switchyard-desktop owns Swift UI, generated server configuration, process lifecycle, integration tests, and app/DMG packaging. Server behavior, algorithms, API and server tests belong in NVIDIA.
- Build the bundled server only from the checked-in snapshot. Do not implicitly use PATH binaries or the NVIDIA checkout in an app bundle.
- Do not create commits without the user's approval. Snapshot imports do not require commits.
- Bundle Python/LiteLLM as well as Switchyard. Pin LiteLLM 1.97.0 and FastAPI 0.136.3; do not install dependencies on app startup. Use ports 4100/4101 for the app and preserve the independent manual experiment on 4000/4001.
- Never let a test resolve a real user path. Every user-owned location goes through `UserDataLocations`, which redirects a test process into a per-process sandbox; inject stores in tests as well, and keep `UserDataLocationsTests` passing.
