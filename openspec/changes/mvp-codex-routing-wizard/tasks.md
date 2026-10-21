## 1. Existing foundation

- [x] 1.1 Create the Swift Package macOS application and its test target.
- [x] 1.2 Generate, write, and dry-run validate a switchyard-desktop-owned
  Switchyard configuration.
- [x] 1.3 Start and stop a managed `switchyard-server` process on a loopback
  port, generating and deleting the Codex profile layer that points at it.

## 2. Codex subscription discovery

- [x] 2.1 Add a `CodexSetupReader` that reads
  `~/.codex/config.toml` on first launch, validates its relevant
  non-sensitive setup fields, and reports clear errors without logging
  credential values.
- [x] 2.2 Define and implement the supported authenticated Codex model
  discovery mechanism. It must return only models available through the
  current subscription and must not use the old static or user-editable model
  catalog as a fallback.
- [x] 2.3 Add first-run and refresh UI states for loading, successful
  discovery, malformed or missing configuration, unauthenticated Codex, empty
  results, and discovery failure.
- [x] 2.4 Add tests with redacted configuration fixtures and discovery
  doubles covering successful discovery, refresh, and every blocked state.

## 3. Algorithm and role model

- [x] 3.1 Replace tier-count-selected routing with an explicit
  `RoutingAlgorithm` selection: `stage_router` and custom-mode
  `llm_classifier`.
- [x] 3.2 Model `stage_router` roles as exactly `efficient` and `capable`;
  allow only discovered subscription models to populate them.
- [x] 3.3 Model classifier routing as two to six ordered target roles, each
  assigned a discovered model, with the classifier and fallback selected from
  the assigned targets.
- [x] 3.4 Ensure changing algorithms clears or revalidates incompatible role
  assignments and blocks start until all required roles are complete.
- [x] 3.5 Add unit tests for valid and invalid role assignments, algorithm
  switches, classifier/fallback selection, and the exclusion of unverified
  model IDs.

## 4. Switchyard rendering and start

- [x] 4.1 Update `SwitchyardConfigWriter` to render the exact
  `stage_router` roles selected by the user rather than inferring an algorithm
  from tier count.
- [x] 4.2 Update custom-mode `llm_classifier` rendering to use the
  user-selected target, classifier, and fallback roles and to keep all free
  text TOML-safe.
- [x] 4.3 Rename the final action to `Start routing`; enable it only after
  discovery, role validation, readiness checks, and generated-config dry-run
  succeed.
- [ ] 4.4 Add golden-output and dry-run tests for both algorithms and failure
  tests proving an invalid configuration never starts a proxy or writes Codex
  configuration.

## 5. Background active-routing UI

- [x] 5.1 Add an application lifecycle coordinator that keeps the app and
  managed proxy alive after the routing window is closed.
- [x] 5.2 Add a status-bar item visible only while routing is active. Its
  menu must show status, reopen the control window, and provide a Stop action.
- [x] 5.3 Remove the status-bar item only after a successful stop; retain it
  and explain what is left on disk when deleting the profile fails.
- [x] 5.4 Update normal-quit handling so `Stop and Quit` deletes the generated
  profile before the status item disappears and the proxy terminates.
- [x] 5.5 Add lifecycle tests for close-window/background operation,
  status-item visibility, status-menu actions, normal quit, and unclean-exit
  recovery.
- [x] 5.6 Persist the last successfully started non-sensitive routing profile
  and bypass first-run setup on later launches when that profile is still
  compatible; add an explicit Reconfigure action.
- [x] 5.7 Hide the main window automatically after `Start routing` succeeds,
  leaving only the active-routing status-bar icon visible; make a primary click
  on that icon activate the app and reopen the main controls.
- [ ] 5.8 Add lifecycle tests for saved-profile relaunch, invalid saved-profile
  fallback, automatic post-Start hiding, and direct status-icon reopening.

## 6. Durable diagnostics

- [x] 6.1 Keep an append-only, redacted `diagnostics.log` for app and server
  lifecycle events, rotated with one previous generation.
- [x] 6.2 Drain each managed server's stdout/stderr continuously into its own
  redacted file, so a full pipe can never block the server.
- [x] 6.3 Record an unexpected exit with its exit status and last output, and
  probe the running proxy on loopback so an unresponsive server is recorded too.
- [x] 6.4 Name the log in the recovery message and offer `Reveal logs in Finder`
  from the status-bar menu.
- [x] 6.5 Add tests for line format, redaction, rotation, drain-without-blocking,
  and the recorded start/stop/unexpected-exit events.

- [x] 6.6 Watch the generated profile while a route is active, report a file
  that was edited or deleted, and repair it by generating it again; key
  cleanup on the managed provider rather than the route id.

- [x] 6.7 Resolve every user-owned location through one seam that redirects a
  test process into a per-process sandbox, and assert it: a default-constructed
  model must not read or write the live Codex config, the live Codex profile,
  the active-route record or the saved setup.

## 7. End-to-end verification

- [ ] 7.1 On a Codex-subscribed account, verify first launch reads
  `~/.codex/config.toml` and displays only discovered subscription
  models without exposing credentials.
- [ ] 7.2 Configure and start one `stage_router` route and one
  `llm_classifier` route; verify the generated configurations pass
  `switchyard-server --dry-run` and that `codex --profile switchyard-desktop` sends a
  request through each proxy.
- [ ] 7.3 Verify successful Start automatically hides the main window; relaunch
  without repeating setup, then use a direct status-bar icon click to reopen
  the controls and verify Stop remains available.
- [ ] 7.4 Verify normal quit and an unclean exit leave
  `~/.codex/config.toml` byte-for-byte unchanged, that the next
  launch deletes the generated profile, and that diagnostics never expose
  subscription credentials.
- [ ] 7.5 With routing active, edit and then delete
  `~/.codex/switchyard-desktop.config.toml` and verify the app reports
  each case and generates the file again on request.
- [ ] 7.6 Verify a session started without `--profile switchyard-desktop` uses the
  account's own settings and is not routed, and that starting one with the flag
  is.
