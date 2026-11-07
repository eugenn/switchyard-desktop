# Contributing

Use issues and pull requests for focused changes. Discuss substantial changes first.
The only application is the Tauri / React / Rust client in `desktop/`.

## Ownership

- This repository owns the UI, generated configuration, credentials, process
  lifecycle, integration checks and packaging.
- Server behavior, algorithms, API and server tests belong in the core checkout
  `../NVIDIA`. For desktop tasks, record proposed core changes in Markdown;
  the maintainer manages core development and publication.
- Never edit `vendor/switchyard` directly. Import reviewed changes with
  `scripts/update-switchyard.py` and retain `vendor/switchyard-source.json`.
- Do not commit or publish without the user's approval.

## Checks

From the repository root:

```sh
python3 scripts/update-switchyard.py --verify
python3 -m unittest discover -s scripts/tests -v
python3 -m unittest discover -s desktop/scripts -p 'test_*.py' -v
cd desktop
npm ci
npm test
npm run build
cargo test --locked -p switchyard-desktop-core
cargo check --locked -p switchyard-desktop-shell
```

For configuration or lifecycle changes, also run the offline runtime/routing
checks in [the application guide](desktop/README.md#validation). No Swift or Xcode
application target is involved; macOS still requires native developer tools.

Never let automated tests resolve real user paths. Use `UserDataLocations`,
injected stores/vaults, temporary files and mock providers. Keep the Rust
`user_data_locations` integration test passing. Never use a real account in tests.
Keep app ports 4100/4101 and the independent experiment on 4000/4001 separate.
Keep LiteLLM 1.97.0 and FastAPI 0.136.3 pinned.

## Pull requests

Target `main`. Describe the behavior, tests actually run and remaining gaps.
Include screenshots with synthetic data for UI changes and provenance for core
imports. Do not include credentials, private prompts, logs or signing material.

External PR checks use `pull_request`, read-only permissions and GitHub-hosted
runners. Never give PR code signing credentials or account access. CI is not
proof of a signed installer or real-account acceptance.

Contributions are licensed under Apache-2.0 unless an existing third-party
license applies. Preserve notices. Follow [the code of conduct](CODE_OF_CONDUCT.md)
and report vulnerabilities using [SECURITY.md](SECURITY.md).
