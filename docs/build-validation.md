# Local build validation

## Open-source preparation — 2026-10-21

- Imported schema 2 provenance from the sibling NVIDIA checkout: maintained fork
  commit and integrated NVIDIA upstream commit are separate. All 647 source file
  hashes remain unchanged. The existing dirty flag remains true.
- 13 Python importer/release-gate tests passed using temporary Git fixtures,
  including committed-byte fetching and early rejection at all release entry points.
- `swift test --force-resolved-versions` passed 445 library and 2 application
  tests with Xcode 27.1. User-data tests no longer read real account files; test
  executable discovery does not launch the user's login shell.
- `scripts/build-dev-app.sh release` built and verified the complete app, including
  signatures, native deployment targets, runtime imports and offline server smoke
  tests. Bundled Apache license, notices and source manifest match the checkout.
- The current snapshot is rejected by `--verify --release`, as expected. No public
  DMG or notarization was attempted.
- GitHub YAML parses, local documentation links resolve, shell syntax and
  `git diff --check` pass. The GitHub workflow has not run: its files remain local.
- GitHub visibility, branch protection, outside-contributor workflow approval,
  secret scanning/push protection and private vulnerability reporting were checked
  through the API. See [GitHub maintenance](github.md) for bootstrap details.

Logs: `build/open-source-swift-test.log`, `build/open-source-swift-build.log`,
`build/open-source-package.log`. No commits, pushes or GitHub releases were made.

## Single application — 2026-10-21

`SwitchyardDesktopApp` is the only executable product. It opens Statistics on
launch and includes the full setup wizard, model and role assignments, native
routing options, configuration preview and statistics. The application is named
`switchyard-desktop` throughout its interface and packaging.

The separate lightweight executable, its tests, draft storage implementation and
preset verification script were removed. Shared built-in roles, their IDs, the
saved routing setup, Application Support directory and Codex profile are retained.
Packaging uses `Resources/Info.plist`, bundle ID `dev.switchyard.desktop`, and
`switchyard-desktop.app`; build and DMG scripts have no edition argument.

Validated on Apple Silicon with Xcode 27.1:

- Package inspection reports exactly one executable product and two test targets.
- After cleaning stale SwiftPM artifacts, `swift test` passed 444 library tests
  and 2 application tests.
- `xcodebuild -scheme SwitchyardDesktopApp -configuration Debug ... test` passed
  the same 446 tests, including the user-data sandbox safeguards.
- `xcodebuild -scheme SwitchyardDesktopApp -configuration Release ... build`
  succeeded.
- `scripts/build-dev-app.sh release` built and verified the complete application:
  signatures, resource bundle, 56 native macOS deployment targets, pinned runtime,
  discovery, buffered/streaming Responses, statistics and routing-log smoke checks.
- Build-script syntax, the single app identity and rejection of removed edition
  arguments were checked. The server snapshot is unchanged and verifies correctly.
- `scripts/create-dev-dmg.sh` produced a checksum-verified local DMG. A read-only
  mount confirmed exactly one `switchyard-desktop.app`, its expected executable
  and bundle identity, and the Applications shortcut.

Local logs: `build/single-app-swift-test.log`, `build/single-app-xcode-test.log`,
`build/single-app-xcode-release.log`, `build/single-app-package.log`, and
`build/single-app-dmg.log`.

The dated records below describe earlier builds and retired application variants.

## Server snapshot and portable configuration — 2026-10-21

The snapshot includes the LLM client's `x-litellm-session-id` header: it uses the
agent ID when present and otherwise the session ID, keeping each conversation's
LiteLLM prompt cache stable. Its manifest identifies the source checkout's upstream
`origin`; the base commit and per-file hashes still identify the exact snapshot.

Personal account names were removed from bundle identifiers, source-import defaults,
example project paths, documentation and the routing guide's text and hyperlinks.
The source importer defaults to the sibling `NVIDIA` checkout; example project
bindings start unset. Bundle identifiers are `dev.switchyard.desktop` and
`dev.switchyard.desktop.pro`.

Validation:

- The manifest and the NVIDIA source working tree match all 647 imported files.
- In NVIDIA, `cargo test --locked -p switchyard-llm-client`: 102 tests passed
  (83 unit tests and 19 integration tests), including the new session-header test.
  Stale local Cargo artifacts were cleared before the successful run.
- Xcode Debug package tests: 444 tests passed, including user-data sandbox checks.
- Both release app bundles passed signature, macOS deployment-target, pinned runtime,
  discovery, buffered/streaming Responses, statistics and routing-log smoke checks
  with the new neutral bundle identifiers.
- All tracked files and embedded DOCX parts were scanned for the personal user ID;
  no matches remain. Both plists and the example role-group JSON parse successfully.
- The edited routing guide was rendered and visually reviewed across all 21 pages.

Local logs: `build/snapshot-client-test.log`, `build/snapshot-xcode-test.log`,
`build/snapshot-package-simple.log`, and `build/snapshot-package-pro.log`.

## Project rename — 2026-10-21

The checkout, Swift package, modules, schemes, app identities, user-data paths,
Codex profile, packaging scripts and documentation now use `switchyard-desktop`.
The imported server snapshot was not changed by the rename.

Validated with Xcode 27.1 (27A9275) on Apple Silicon:

- `scripts/prepare-xcode.sh` verified and built the checked-in Switchyard snapshot
  and prepared the pinned Python/LiteLLM runtime.
- `swift test`: 444 tests passed, including the user-data sandbox safeguards.
- Xcode Debug build of `SwitchyardDesktopSimpleApp`: succeeded.
- `xcodebuild -scheme switchyard-desktop-Package -configuration Debug
  -destination 'platform=macOS' -derivedDataPath build/Xcode test`: 444 tests passed.
- `xcodebuild -scheme switchyard-desktop-Package -configuration Release
  -destination 'platform=macOS' -derivedDataPath build/Xcode build`: both editions
  built successfully.
- The opt-in `preparedXcodeRuntimeImportsItsPinnedDependencies` test passed with
  `SWITCHYARD_DESKTOP_CHECK_XCODE_RUNTIME=1`, checking runtime imports and snapshot
  server discovery after the checkout move.
- Both release bundles, `build/switchyard-desktop.app` and
  `build/switchyard-desktop-pro.app`, passed signature verification, resource-bundle
  lookup, macOS 14 checks for 56 native files per bundle, pinned runtime imports,
  discovery, buffered/streaming Responses, statistics and routing-log smoke tests
  using a temporary HOME and a local mock provider.
- Python, shell and plist syntax checks passed.

Detailed local logs are in `build/swift-test.log`, `build/xcode-test.log`,
`build/xcode-simple-debug.log`, `build/xcode-runtime-test.log`,
`build/package-simple.log`, `build/package-pro.log`, and `build/xcode-release.log`.

Historical entries below describe pre-rename builds. Their artifact labels have
been updated to the current naming convention; recorded hashes belong to the
original artifacts and must not be used to verify new builds.

## Switchyard refresh — 2026-10-09

Imported 647 tracked files from NVIDIA at `c6bdef7755bbb8efa63f8b251b7305a38b69344c`,
including its existing tracked routing-log agent-identity changes. The snapshot manifest SHA-256 is
`b54c2f96e3ff66231259576694afc8e80244aff350aec7892f754bc7399e55c4`.
The imported inventory matches both the manifest and the NVIDIA working tree.

Built both release app bundles from this snapshot with Rust 1.99:
`build/switchyard-desktop.app` and `build/switchyard-desktop-pro.app`. Both embedded snapshot manifests match the repository.

Completed:

- 444 Swift tests passed, including all `UserDataLocationsTests` safeguards.
- 38 offline routing scenarios passed against production Swift-generated configurations.
  Added Stage/Auto checks separating retrieved error text from execution failures, and
  Plan/Execute checks for custom mutation tools, planning prompts and execution after compaction.
- 12 Simple preset scenarios passed across Chat Completions and Responses, with swapped
  assignments and role prompts checked on the upstream wire.
- Both bundles passed signature, runtime dependency and macOS 14 deployment-target checks
  (56 native files per bundle), with Python 3.12.10, LiteLLM 1.97.0 and FastAPI 0.136.3.
- Both packaged servers passed discovery, buffered/streaming Responses, stats and routing-log
  checks using a temporary HOME and local mock provider.
- Both DMGs passed checksum verification. Each was mounted read-only, its app copied into
  `build/DMG Install Test 2026-10-09/`, and unmounted. The copied apps passed complete bundle
  verification and retain the exact imported snapshot manifest.

Local Apple Silicon artifacts:

| Artifact | SHA-256 |
| --- | --- |
| `dist/switchyard-desktop-0.1.0-1-arm64-local.dmg` | `e311bb00f0be6c10664655aece8e327b60dc9b55ff2be69dceed45b932c2dc62` |
| `dist/switchyard-desktop-Pro-0.1.0-1-arm64-local.dmg` | `19efd6910f95914568b4baee67805a26385ff468c8304b3e4078c342d9201e14` |

These are ad-hoc-signed local Apple Silicon builds. Authenticated inference, clean-account
installation, Intel builds and public-release notarization were not exercised. No Git commits
were created by this work.

## Switchyard refresh — 2026-10-02

Imported 616 tracked files from NVIDIA at `40d3b6f77aa78c1b9b73ac11a1c20abafe801931`,
including its tracked routing-log agent-identity changes. The snapshot manifest SHA-256 is
`a2d91e041ec7c097b0c23ff19c401f3a645850f2c01cea520f7abc1d39e442cc`.
The imported inventory matches both the manifest and the NVIDIA working tree.

Built both release app bundles from this snapshot with Rust 1.99:
`build/switchyard-desktop.app` and `build/switchyard-desktop-pro.app`. Fixed the resource bundle name to
`switchyard-desktop_SwitchyardDesktopKit.bundle` in packaging, verification and the app's Dock icon lookup.
Packaging now fails if the resource bundle is missing.

Completed:

- 475 Swift tests passed, including all `UserDataLocationsTests` safeguards.
- 30 offline routing scenarios passed against production Swift-generated configurations,
  including the updated escalation verdict and rejection of stale failure evidence.
- 12 Simple preset scenarios passed across Chat Completions and Responses, with swapped
  assignments and role prompts checked on the upstream wire.
- Both bundles passed signature, runtime dependency and macOS 14 deployment-target checks
  (56 native files per bundle), with Python 3.12.10, LiteLLM 1.97.0 and FastAPI 0.136.3.
- Both packaged servers passed discovery, buffered/streaming Responses, stats and routing-log
  checks using a temporary HOME and local mock provider.
- Both DMGs passed checksum verification. Each was mounted, its app copied into
  `build/DMG Install Test/`, and unmounted. The copied apps passed the complete bundle checks;
  their embedded snapshot manifests match the repository manifest.

Local Apple Silicon artifacts:

| Artifact | SHA-256 |
| --- | --- |
| `dist/switchyard-desktop-0.1.0-1-arm64-local.dmg` | `60a5e121138bb4f4249f5691f638c3338807d5722c1e77a1f3d1a6f0d9a41d65` |
| `dist/switchyard-desktop-Pro-0.1.0-1-arm64-local.dmg` | `b3ebd04f143df23d46f2f2248b4ca42447ca2fe8162de4be47ee8bb413d08873` |

These are ad-hoc-signed local builds. Authenticated inference, clean-account installation,
Intel builds and public-release notarization were not exercised.

## Initial local build — 2026-09-11

Artifact: `dist/switchyard-desktop-0.1.0-1-arm64-local.dmg` (Apple Silicon, approximately 226 MiB).
SHA-256: `59e935328814e29bc6a4155bfdc84943d571a0501389e8e9aa403268ec8b5521`.

Completed:

- Switchyard source inventory verified against `vendor/switchyard-source.json`.
- Copied Switchyard built with Cargo.lock and validated with `--dry-run`.
- 162 Swift tests passed, including bundled binary selection, LiteLLM configuration,
  missing-runtime readiness and unexpected server termination.
- Python 3.12.10, LiteLLM 1.97.0 and FastAPI 0.136.3 imported from the packaged runtime.
- orjson 3.11.6 built from source for macOS 14; all 56 packaged native files passed
  deployment-target checks.
- Nested native code and the app received ad-hoc signatures; bundle verification passed.
- DMG checksum verification passed. The image contains the app and Applications shortcut.
- Mounted the image, copied the app to `build/DMG Install Test/switchyard-desktop.app`, unmounted
  the image, and repeated bundle verification from the copied location.
- Both copied servers started using a temporary HOME: LiteLLM health and Switchyard model
  discovery passed without an inference request or the user's OAuth files. The offline proxy
  test uses an OpenAI-compatible placeholder provider to avoid initiating ChatGPT login.
- The copied macOS application launched successfully and displayed its setup window, icon,
  and successful Codex preflight/model discovery. Routing was not started from this UI test.
- The copied app signature remained valid after runtime checks.

Still required before a public release:

- Developer ID signing and Apple notarization/stapling. This machine had no valid signing identity.
- A clean-account installation and the complete browser login / authenticated Codex inference /
  Stop / crash-recovery acceptance flow.
- Separate validation of an Intel build, if one is distributed.

The local DMG is not a notarized public release. No Git commits were created by this work.
