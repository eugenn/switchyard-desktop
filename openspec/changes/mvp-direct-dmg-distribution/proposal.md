## Why

The routing wizard now works as a developer-built Swift package, but that is not
an installable MVP for other Codex users. Its current bundle is ad-hoc signed,
the runtime dependency on `switchyard-server` is implicit, and quitting after
starting a route can leave Codex configured to use a proxy that is no longer
running.

The MVP will be distributed directly as a DMG, not through the Mac App Store.
It must therefore make its prerequisites, security boundaries, install path,
and recovery behavior explicit while retaining the current non-sandboxed
integration with the user's Codex configuration.

## What Changes

- Produce a reproducible direct-distribution release: a versioned
  `switchyard-desktop.app` in a drag-to-Applications DMG.
- Sign release artifacts with Developer ID, notarize them, staple the
  notarization ticket, and validate the resulting app and DMG before release.
- Add a startup/pre-Start readiness check that explains every external
  prerequisite: the bundled Switchyard and LiteLLM runtimes, a writable Codex
  configuration at `~/.codex/config.toml`, successful discovery of
  subscription models, valid algorithm-role assignments, and the chosen
  loopback port.
- Make `Start routing` an informed action: disclose that the app writes its
  routing configuration, starts a local proxy, edits the Codex configuration,
  and sends Codex requests through Switchyard and LiteLLM using the LiteLLM
  ChatGPT OAuth session.
- Keep active routing alive when the main window is closed and display a
  status-bar icon while it is active. Explicit application quit must offer to
  revert the Codex configuration before stopping the proxy; the next launch
  must offer recovery after an unclean exit.
- Document installation, removal, data handling, third-party notices, and the
  fact that switchyard-desktop is an independent utility rather than OpenAI or NVIDIA
  software.

## Capabilities

### New Capabilities

- `direct-mvp-distribution`: direct DMG packaging, prerequisite checks,
  safety/recovery behavior, and user-facing release documentation for the
  switchyard-desktop MVP.

### Modified Capabilities

- `codex-routing-wizard`: subscription discovery, `Start routing`, background
  status-bar operation, quit behavior, and recovery gain explicit distribution
  requirements.

## Impact

- Affected code: packaging scripts and release metadata; app lifecycle,
  readiness, and error-display code; tests for recovery and redaction.
- Affected user files: `~/Library/Application Support/switchyard-desktop/routes.toml`
  and `~/.codex/config.toml`, including switchyard-desktop's timestamped
  backups.
- Runtime dependencies Switchyard, Python, LiteLLM 1.97.0 and FastAPI 0.136.3 are bundled.
  Codex and the upstream subscription remain user-provided.
- All Switchyard changes originate in `~/Projects/personal/NVIDIA`; switchyard-desktop
  imports a checksummed source snapshot and owns only app integration/configuration.
- Distribution is direct DMG. Mac App Store, launch agents and login-at-startup are out of scope.
