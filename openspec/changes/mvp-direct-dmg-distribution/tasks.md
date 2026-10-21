## 1. Release bundle and DMG

- [x] 1.1 Move release metadata out of the generated bundle script into
  version-controlled resources: `Info.plist`, icon assets, copyright notice,
  and a single version/build source of truth.
- [x] 1.2 Replace the ad-hoc public-bundle path with a reproducible release
  script that builds the Release executable, assembles `switchyard-desktop.app`, and
  emits a versioned DMG containing the app and an Applications alias.
- [x] 1.3 Keep a documented developer-only build path for local testing, but
  label ad-hoc-signed artifacts as non-distributable.
- [ ] 1.4 Verify on a clean macOS user account that mounting the DMG and
  dragging the app to Applications produces a launchable app without source
  checkout paths or build tools present.

## 2. Signing and notarization

- [x] 2.1 Add release-script inputs for the Developer ID Application identity
  and notarization profile without storing credentials, certificate exports, or
  Apple IDs in the repository.
- [x] 2.2 Sign every executable and nested code object in the `.app` with
  hardened runtime enabled; fail the release when signing does not verify.
- [ ] 2.3 Submit the final DMG for notarization, wait for acceptance, staple
  the ticket to the distributable artifact, and fail rather than producing an
  unsigned or unstapled public DMG.
- [x] 2.4 Add a release verification command that checks the code signature,
  stapled ticket, and Gatekeeper assessment of both the app and DMG.

## 3. Prerequisite and consent flow

- [x] 3.1 Add a readiness model that reports: resolved
  `switchyard-server` path, executable status, dry-run result, writable Codex
  config path, selected loopback host/port availability, and the resolved
  Codex-subscription connection validity.
- [x] 3.2 Remove the maintainer-specific NVIDIA checkout fallback from public
  release behavior; retain it only in an explicitly documented development
  mode, if retained at all.
- [x] 3.3 Prevent routing start until required readiness checks pass. On failure,
  explain the missing dependency and safe remediation without executing an
  installer, downloading software, or requesting administrator privileges.
- [x] 3.4 Add a start disclosure that identifies the effective files,
  proxy endpoint, selected algorithm and roles, backup, local process,
  forwarded authorization, and Revert action.
- [x] 3.5 Add unit tests for the readiness state and an integration test
  confirming failed readiness never changes the Codex configuration.
- [ ] 3.6 Replace the old routing-start prerequisites with `Start routing`
  prerequisites that also require successful reads of
  `~/.codex/config.toml`, authenticated subscription-model
  discovery, and complete algorithm-role assignments.
- [ ] 3.7 Update the final disclosure to show the selected Switchyard
  algorithm and roles and to describe use of the existing Codex subscription,
  without presenting an arbitrary upstream URL or API-key workflow.

## 4. Active-routing lifecycle and recovery

- [x] 4.1 Track whether the current Codex configuration was successfully
  changed by this app and which backup must restore it.
- [x] 4.2 Intercept normal quit while routing is active and offer only
  `Revert and Quit` or `Cancel`; test that `Revert and Quit` restores the
  exact backup before stopping the proxy.
- [x] 4.3 Keep the app open and display actionable recovery instructions when
  restoring the Codex configuration fails during quit.
- [x] 4.4 On launch, detect a switchyard-desktop provider entry with a matching
  backup but no healthy managed proxy, surface a recovery state, and prevent a
  second route start until the user recovers or explicitly resolves the state.
- [x] 4.5 Add tests for normal quit, failed restoration, and unclean-exit
  recovery detection.
- [x] 4.6 Keep the application and proxy alive when the main window closes
  during active routing; add a status-bar icon with status, reopen, Stop, and
  Revert actions.
- [x] 4.7 Test that the status-bar icon is visible only for an active or
  recovery-required route and is removed after a successful stop or revert.

## 5. Sensitive data and release documentation

- [x] 5.1 Add a redaction layer for displayed/persisted subprocess diagnostics
  and test bearer tokens, authorization headers, cookies, API-key-like
  strings, request bodies, and prompts are not retained.
- [x] 5.2 Add an in-app or bundled privacy/data-flow notice explaining that
  Codex requests and credentials are forwarded by the local proxy to the
  selected upstream endpoint and are not stored by switchyard-desktop.
- [x] 5.3 Add installation, prerequisites, supported/unsupported behavior,
  apply/revert/recovery, removal, and troubleshooting documentation.
- [x] 5.4 Inventory all third-party dependencies and bundled assets, add their
  required notices, and add a statement that switchyard-desktop is not affiliated
  with OpenAI or NVIDIA.

## 6. MVP release verification

- [ ] 6.1 On a clean macOS account, install the notarized DMG; confirm
  Gatekeeper accepts the application and the app has no build-time or private
  path dependency.
- [ ] 6.2 With the bundled Switchyard/LiteLLM stack and a signed-in Codex setup,
  apply a routing profile, route one Codex CLI request through the proxy, and
  verify the expected files are the only changed user files.
- [ ] 6.3 Quit through `Revert and Quit`; verify the proxy stops and
  `~/.codex/config.toml` matches its pre-start backup byte-for-byte.
- [ ] 6.4 Simulate an unclean termination after Start, relaunch the app, and
  verify recovery restores a usable Codex configuration without exposing
  credentials in diagnostics.
- [ ] 6.5 Close the main window during an active route and verify the proxy
  continues serving until Stop, Revert, or explicit application quit is used
  from the status-bar control.

## 7. Standalone server packaging

- [x] 7.1 Import checksummed Switchyard sources from NVIDIA without creating commits.
- [x] 7.2 Build the copied server with Cargo.lock and embed it in the application.
- [x] 7.3 Bundle a relocatable Python runtime with pinned LiteLLM/FastAPI dependencies.
- [x] 7.4 Generate LiteLLM model mappings and coordinate login/start/stop with Switchyard.
- [x] 7.5 Document server builds, source updates, manual LiteLLM and DMG packaging.
- [x] 7.6 Verify the final app after copying from a mounted DMG and ejecting it.
- [ ] 7.7 Complete clean-account acceptance and authenticated inference before public release.
