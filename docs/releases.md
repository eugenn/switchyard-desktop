# Releases and source provenance

## Current status

The sole application is the Tauri / React / Rust client in `desktop/`. The Swift
application and its DMG scripts were removed on November 7, 2026. Previously
published DMGs are historical artifacts, not installers for the current client.
No new installer is claimed to be tested or ready for publication.

Tauri installer generation is disabled (`bundle.active = false`). Keep it disabled
until the gates below are implemented and accepted. `npm run build` builds web
assets only; it does not create an application or signed installer.

## Source provenance

`vendor/switchyard-source.json` records the maintained fork URL/commit, NVIDIA
upstream URL/integrated commit, dirty-import flag and imported file hashes.
Only `scripts/update-switchyard.py` may update vendor sources.

Before publishing any artifact, from the repository root run:

```sh
sh scripts/verify-release-source.sh
```

This invokes `--verify --release --check-published`. It rejects dirty imports,
checks imported bytes, and verifies the fork commit is published. It does **not**
verify an installer, signatures, notarization or Windows trust. The importer
regression tests exercise this gate using disposable repositories.

## Installer acceptance gates

1. Verify source provenance, exact dependency locks and the intended app version.
2. Bundle the checked-in server snapshot and pinned Python/LiteLLM, with no PATH
   fallback or startup dependency download. Verify runtime manifests and hashes.
3. Collect licenses for the application, frontend, Rust shell/core/server, Python
   packages and assets. Preserve NOTICE and dependency copyright texts.
4. Build and test natively on macOS and Windows, including clean-machine install,
   paths containing spaces, readiness, streaming, occupied ports, graceful exit,
   crash recovery and isolated test data. Run real-account/vault acceptance
   manually; automated tests must not use accounts.
5. Implement a trusted installer pipeline: nested macOS signing, hardened runtime,
   notarization/stapling and Gatekeeper checks; equivalent Windows signing and
   installation checks. Do not expose secrets to external PRs.
6. Add installer/update validation and checksums, then enable packaging only after
   all blockers in [the status ledger](cross-platform.md) are accepted.

The signing/runtime helper scripts in `desktop/scripts/` are building blocks, not a complete
Tauri release pipeline. Do not bypass missing gates by distributing an ad-hoc
build as a verified release. Historical reports in `docs/archive/swift/` describe only
the retired application's artifacts.
