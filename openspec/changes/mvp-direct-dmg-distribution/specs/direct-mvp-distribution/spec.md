## Purpose

Makes switchyard-desktop installable as a safe, directly distributed macOS MVP while
preserving its explicit integration with a user-installed Switchyard server and
the user's Codex configuration.

## ADDED Requirements

### Requirement: Direct DMG release artifact

The system SHALL provide a reproducible, versioned DMG for direct
distribution. The mounted DMG SHALL contain exactly one installable
`switchyard-desktop.app` bundle and an Applications shortcut or equivalent
drag-to-Applications instruction. The distributable app SHALL not depend on
the source checkout, a private developer path, or build tooling at runtime.

#### Scenario: User installs the MVP from a DMG

- **WHEN** a user mounts the published DMG on a machine with the documented
  runtime prerequisites
- **THEN** the user can copy `switchyard-desktop.app` to Applications and launch it
  without cloning this repository or installing Swift/Xcode

#### Scenario: Public build avoids maintainer paths

- **WHEN** the release bundle is inspected or launched on another account
- **THEN** it does not rely on
  `~/Projects/personal/NVIDIA/target/release/switchyard-server` or any other
  maintainer-specific path

### Requirement: Trusted direct-distribution release

Every public DMG SHALL be signed with a Developer ID Application certificate,
notarized, stapled, and validated before publication. Ad-hoc-signed bundles
MAY be produced for local development but SHALL be identified as
non-distributable.

#### Scenario: Public artifact passes local trust validation

- **WHEN** release packaging completes
- **THEN** signature verification, stapling validation, and Gatekeeper
  assessment succeed for the app and the DMG

#### Scenario: Notarization cannot complete

- **WHEN** signing or notarization fails
- **THEN** the release process fails and does not label the resulting artifact
  as a publishable MVP release

### Requirement: Explicit runtime prerequisites

Before `Start routing` can change a user file or launch a proxy, the system
SHALL check and display the resolved Switchyard server path and executability,
the generated configuration's dry-run result, the Codex configuration path
and writability, successful authenticated discovery of the active
subscription's Codex models, complete algorithm-role assignments, and the
selected loopback host/port availability.

The system SHALL bundle Switchyard, Python, LiteLLM 1.97.0 and FastAPI 0.136.3.
Build tools and source checkouts SHALL NOT be required on the installed machine.
The default app SHALL launch its own Switchyard on port 4100 and LiteLLM on port 4101.
It SHALL check runtime availability and port conflicts before Start, complete LiteLLM
sign-in and health checks before changing Codex, and stop both owned processes on Revert.
It SHALL NOT install runtime dependencies or request administrator privileges at startup.

#### Scenario: Required server is missing

- **WHEN** no executable `switchyard-server` can be resolved
- **THEN** the system explains how to reinstall the complete application and
  does not start a proxy or modify Codex's configuration

#### Scenario: Preflight succeeds

- **WHEN** all prerequisite checks, including dry-run validation, succeed
- **THEN** the system enables the user to review and explicitly start routing

### Requirement: Informed and reversible Start

Immediately before `Start routing`, the system SHALL disclose the effective routing
configuration path, Codex configuration path, backup behavior, proxy host and
port, selected Switchyard algorithm and model-role assignments, and that Codex
request content passes through LiteLLM using its own ChatGPT OAuth session.
The session location and browser sign-in flow SHALL be disclosed.

The system SHALL create a backup before changing an existing Codex
configuration and SHALL provide a Revert action that restores the captured
configuration and stops the proxy.

#### Scenario: User reviews side effects

- **WHEN** all readiness checks pass and the user reaches `Start routing`
- **THEN** the user can see every user file that will be changed, the local
  process that will be started, and the selected algorithm and roles before
  consenting

#### Scenario: User reverts an active route

- **WHEN** the user selects Revert after successfully starting routing
- **THEN** the system restores the pre-start Codex configuration exactly and
  stops the proxy it started

### Requirement: Background active routing, safe quit, and recovery

The MVP SHALL hide the main window automatically after routing starts and keep
switchyard-desktop and its proxy running in the background. It SHALL display a
status-bar icon while routing is active. A primary click on the icon SHALL
activate the application and reopen the main controls; the status-bar control
SHALL also expose status, Stop, and Revert actions. The icon SHALL be removed
after routing successfully stops or reverts.

When the user explicitly quits with an active switchyard-desktop route, the system
SHALL offer `Revert and Quit` and `Cancel`. `Revert and Quit` SHALL restore the
captured Codex configuration before the proxy stops.

If recovery fails, the system SHALL remain open, report the failure, and show
the user how to restore the recorded backup. On the next launch after an
unclean termination, the system SHALL detect a known active switchyard-desktop
configuration with an available backup and offer recovery before allowing a
new route start.

#### Scenario: User quits during active routing

- **WHEN** the user requests normal quit after Start
- **THEN** the system does not silently leave Codex pointing to a proxy that
  it is about to stop

#### Scenario: User closes the main window

- **WHEN** routing is active and the user closes the main window without
  explicitly quitting the application
- **THEN** the proxy keeps running and the active-routing status-bar icon
  remains available

#### Scenario: Start enters status-bar-only mode

- **WHEN** routing starts successfully
- **THEN** the main window hides automatically and the active-routing
  status-bar icon remains visible

#### Scenario: Status-bar icon reopens the window

- **WHEN** the routing window is hidden and the user primary-clicks the
  active-routing status-bar icon
- **THEN** the application activates and its main control window reappears

#### Scenario: App was force-quit

- **WHEN** switchyard-desktop is relaunched after a prior unclean exit left its
  provider entry active and a matching backup exists
- **THEN** the system presents recovery before the user can apply another
  routing profile

### Requirement: Sensitive data protection

switchyard-desktop SHALL NOT request, persist, or log an API key. It SHALL not
persist or display authorization headers, bearer tokens, cookies, prompts,
request bodies, source code, or API-key-like values from captured proxy output.
User-visible diagnostics SHALL redact such values before display or storage.

#### Scenario: Proxy diagnostics contain credentials

- **WHEN** a proxy diagnostic contains an authorization header or bearer token
- **THEN** any switchyard-desktop UI or diagnostic output replaces the sensitive
  value with a redacted placeholder

### Requirement: Direct-distribution documentation

The release documentation SHALL state the supported macOS version, all
runtime prerequisites, installation and removal steps, background/status-bar
behavior, the files the app changes, Start/Stop/Revert/recovery behavior, data
flow, and troubleshooting for missing Codex subscription models or a missing
or incompatible Switchyard server.
It SHALL include required third-party notices and state that switchyard-desktop is
not affiliated with OpenAI or NVIDIA.

#### Scenario: User needs to remove the MVP

- **WHEN** a user follows the published removal instructions
- **THEN** the instructions explain how to revert an active route, remove the
  application, and remove only switchyard-desktop-owned support files and backups

### Requirement: Server source ownership

Server development SHALL happen first in `~/Projects/personal/NVIDIA`.
switchyard-desktop SHALL import an explicit source snapshot and manifest, never modify the
server copy directly, and build independently of the NVIDIA checkout. App configuration,
process management, integration tests and packaging belong in switchyard-desktop.

#### Scenario: Server changes are imported into the application

- **WHEN** a reviewed Switchyard server change is ready for switchyard-desktop
- **THEN** the change is implemented first in the NVIDIA checkout and imported
  as an explicit checksummed snapshot before the application bundle is built
