## Purpose

Lets a Codex subscriber configure intelligent request routing among the models
available to that subscription through a locally managed
[NVIDIA-NeMo/Switchyard](https://github.com/NVIDIA-NeMo/Switchyard) proxy.
The app remains available in the background, with a visible status-bar icon,
while routing is active.

## ADDED Requirements

### Requirement: Codex-only subscription setup

The system SHALL support only the models available through the user's active
Codex subscription. It SHALL NOT offer another provider, an arbitrary custom
model ID, API-key setup, or an arbitrary upstream endpoint.

On first launch, before model or routing choices are shown, the system SHALL
read `~/.codex/config.toml` as the default Codex configuration
file. It SHALL use that configuration only to establish the local Codex setup
and authenticated subscription context; it SHALL NOT expose or persist
credentials or other sensitive values from the file.

#### Scenario: First launch finds the Codex configuration

- **WHEN** switchyard-desktop is opened for the first time and
  `~/.codex/config.toml` is readable and represents a configured
  Codex subscription
- **THEN** the system reads the configuration before continuing to subscription
  model discovery

#### Scenario: Codex configuration is unavailable

- **WHEN** the default Codex configuration is missing, unreadable, malformed,
  or does not identify a usable Codex subscription
- **THEN** the system explains that Codex must be configured first and does
  not allow routing setup or start

### Requirement: Subscription model discovery

The system SHALL discover the models that the authenticated Codex subscription
can use during first-run setup. It SHALL use Codex's configured authenticated
context and a supported Codex discovery mechanism; it SHALL NOT infer a list
only from a static catalog or accept unverified user-entered IDs.

The discovered set SHALL be shown to the user and SHALL be the only set from
which a model can be assigned to a routing role. The system SHALL let the user
refresh the discovery result before starting routing.

#### Scenario: Models are discovered successfully

- **WHEN** Codex setup and subscription discovery succeed
- **THEN** the user sees only models available to that subscription and can
  choose them for eligible routing roles

#### Scenario: Model discovery fails

- **WHEN** the configured Codex subscription cannot return an available-model
  list
- **THEN** the system shows a safe remediation and retry action, and does not
  substitute a static list or enable routing start

### Requirement: Successful routing setup is reused

After routing has been configured and started successfully, the system SHALL
persist the non-sensitive routing profile needed to reuse that setup, including
the selected algorithm, role assignments, route identifier, and local endpoint.
It SHALL NOT persist credentials, authentication headers, or OAuth session data
as part of that profile.

On a subsequent normal application launch, when a saved profile is compatible
and no recovery is required, the system SHALL bypass first-run setup and show
the saved routing controls directly. Restarting the application alone SHALL NOT
require the user to repeat model discovery, algorithm selection, or role
assignment. The system SHALL still perform current readiness validation before
starting the route and SHALL expose an explicit Reconfigure action.

#### Scenario: Previously configured router is opened again

- **WHEN** the user launches switchyard-desktop after a routing profile was previously
  configured and started successfully
- **THEN** the system restores the saved profile and opens its routing controls
  without presenting the first-run setup flow

#### Scenario: User chooses to reconfigure

- **WHEN** the user invokes Reconfigure from the saved routing controls
- **THEN** the system opens setup with the saved choices available for review
  and editing

#### Scenario: Saved setup is no longer usable

- **WHEN** the saved profile cannot be decoded, is incompatible, or references
  models that are no longer available
- **THEN** the system explains why reconfiguration is required and enters setup
  without silently starting an invalid route

### Requirement: User selects a routing algorithm

The system SHALL present the supported Switchyard algorithms and require the
user to select one before role assignment. For this MVP, it SHALL support:

- `stage_router`, which requires `efficient` and `capable` roles; and
- custom-mode `llm_classifier`, which routes among two to six target roles and
  requires the user to select one target role as the classifier and one target
  role as the fallback.

The UI SHALL state the routing behavior and additional classifier-call cost of
each option. Changing the algorithm SHALL remove or revalidate assignments
that are not valid for the newly selected algorithm.

#### Scenario: User selects stage routing

- **WHEN** the user selects `stage_router`
- **THEN** the system presents exactly the `efficient` and `capable` model
  roles and does not require a classifier or fallback role

#### Scenario: User selects classifier routing

- **WHEN** the user selects custom-mode `llm_classifier`
- **THEN** the system presents two to six ordered target roles plus controls
  to choose the classifier and fallback roles from those targets

### Requirement: Models are assigned to algorithm roles

The system SHALL display only the model roles required by the selected
algorithm and SHALL require the user to assign one discovered subscription
model to every target role before routing can start.

For `llm_classifier`, the chosen classifier and fallback SHALL each refer to
an assigned target role. The resulting configuration's selectable targets
SHALL be exactly the assigned target roles.

#### Scenario: Required role is unassigned

- **WHEN** one or more required roles have no assigned discovered model
- **THEN** the system disables `Start routing` and identifies the incomplete
  roles

#### Scenario: All roles are assigned

- **WHEN** every target role has an assigned discovered model and all
  algorithm-specific selections are valid
- **THEN** the system enables `Start routing`

### Requirement: Start routing validates the Switchyard configuration

After all required roles are assigned, the system SHALL expose `Start routing`.
It SHALL generate a Switchyard configuration for the selected algorithm and
validate it with `switchyard-server --config <path> --dry-run` before starting
a proxy process or modifying another user file.

For `stage_router`, the generated configuration SHALL use the assigned
`efficient` and `capable` targets. For `llm_classifier`, it SHALL use the
user-selected target, classifier, and fallback roles.

#### Scenario: Valid configuration starts routing

- **WHEN** the user presses `Start routing` and dry-run validation succeeds
- **THEN** the system starts the proxy and applies the Codex configuration
  change

#### Scenario: Invalid configuration blocks start

- **WHEN** validation fails after the user presses `Start routing`
- **THEN** the system displays the validation error and does not start a proxy
  or modify Codex's configuration

### Requirement: Managed Switchyard process lifecycle

The system SHALL start and stop the
NVIDIA-NeMo/Switchyard `switchyard-server` process itself as a managed child
process bound to `127.0.0.1` on a configurable local port. It SHALL report
whether the route is running and SHALL not modify Codex's configuration when
the required Switchyard binary cannot be located or started.

The system SHALL record the managed children it starts, and before checking
prerequisites it SHALL stop any it left behind when an earlier run ended
without shutting them down. It SHALL stop only a process it recorded starting,
or one holding a required local port and running one of its own bundled
executables; any other holder of that port SHALL be reported by name instead.

#### Scenario: Required Switchyard binary is missing

- **WHEN** the system cannot locate an executable `switchyard-server`
- **THEN** it explains how to reinstall the complete switchyard-desktop application
  and does not start routing or modify Codex's configuration

#### Scenario: A previous run was force quit and left its servers running

- **WHEN** the user starts routing again and port 4100 or 4101 is still held by
  a managed server from that run
- **THEN** the system stops it, reports what it stopped, and starts routing
  without asking the user to find and stop the process themselves

#### Scenario: A required port belongs to another program

- **WHEN** a required local port is held by a process this application did not
  start
- **THEN** that process is left running and the prerequisite names it, so the
  user can quit it or choose another port

### Requirement: Active routing continues in the background

Immediately after `Start routing` succeeds, the system SHALL hide the main
window without stopping the managed proxy or removing the generated Codex
profile.
The system SHALL remain running in the background and show a status-bar icon
that visibly indicates active routing. A primary click on the status-bar icon
SHALL activate switchyard-desktop and reopen the main control window. The status-bar
control SHALL also expose the running state and offer a Stop action.

Closing the reopened main window while routing remains active SHALL return the
application to the same status-bar-only state without stopping routing.

The status-bar icon SHALL be removed when routing is stopped.

#### Scenario: User closes the window while routing

- **WHEN** the user closes the main window after `Start routing` succeeds
- **THEN** the proxy remains running and an active-routing status-bar icon
  remains available

#### Scenario: Successful start hides the setup window

- **WHEN** `Start routing` completes successfully
- **THEN** the main window hides automatically, routing continues, and only the
  active-routing status-bar icon remains visible

#### Scenario: User clicks the active-routing icon

- **WHEN** the main window is hidden and the user primary-clicks the
  active-routing status-bar icon
- **THEN** switchyard-desktop becomes active and the main control window reappears

#### Scenario: User stops routing from the status bar

- **WHEN** the user chooses Stop from the active-routing status-bar menu
- **THEN** the system performs the documented safe stop behavior and removes
  the active-routing icon after the route stops

### Requirement: Routing is installed as a generated Codex profile

The system SHALL NOT write `~/.codex/config.toml`. It SHALL install
a route by generating `~/.codex/switchyard-desktop.config.toml` in full —
the configuration layer Codex loads on top of the user's own for sessions
started as `codex --profile switchyard-desktop` — and SHALL state that command
wherever it reports a route as active.

Stopping SHALL delete that generated file before stopping the managed proxy. A
normal application quit while routing is active SHALL offer `Stop and Quit` or
`Cancel`, and a termination the application cannot turn into a prompt SHALL
delete the file as well.

Because the file belongs to the application alone, a run that ends without
deleting it SHALL leave every Codex session that does not name the profile
unaffected. A subsequent launch SHALL delete a generated file left behind and
report that it did; it SHALL NOT block a new route either way, since starting
one replaces the file. A generated path whose contents no longer select this
application's provider SHALL be left in place and reported rather than deleted.

A record written by an earlier version that patched `config.toml` in place
SHALL be honoured once, at the first launch that finds it: the system SHALL
restore that file from the backup the earlier version recorded and remove the
record.

#### Scenario: Stop removes the generated profile and nothing else

- **WHEN** the user stops an active route
- **THEN** `~/.codex/switchyard-desktop.config.toml` is deleted,
  `~/.codex/config.toml` is byte-for-byte what it was before the
  route started, and the managed proxy is stopped

#### Scenario: An unclean shutdown leaves the user's configuration intact

- **WHEN** the application is force quit while a route is active
- **THEN** `~/.codex/config.toml` is unchanged, Codex sessions
  started without the profile behave exactly as before, and the next launch
  deletes the generated profile and reports it

#### Scenario: An upgrade finds a configuration an earlier version patched

- **WHEN** a launch finds a record from a version that patched
  `~/.codex/config.toml` and that file still selects the managed
  provider
- **THEN** the system restores it from the recorded backup, removes the record,
  and never writes that file again

### Requirement: The generated profile is watched while a route is active

Only this application writes the generated profile, but it can still be edited
or deleted outside the app. While a route is active the system SHALL re-read
that file and SHALL report a file that is missing, no longer names the running
route, or no longer points at the managed provider, naming what it found. It
SHALL offer an action that generates the file again, which replaces it whole.

Cleanup of a route left by an earlier run SHALL be decided by the managed
provider alone, not by the route id, so a generated file whose `model` was
edited is still removed.

#### Scenario: The generated profile no longer names the running route

- **WHEN** the generated profile is edited to name a model the running route
  does not serve
- **THEN** the system reports the drift with the selected model and offers to
  generate the file again, and the status-bar item warns while the window is
  closed

#### Scenario: The generated profile is deleted under a running route

- **WHEN** the generated profile is deleted while a route is active
- **THEN** the system reports that a routed session has no route to resolve and
  offers to generate the file again

#### Scenario: A drifted profile is still cleaned up on the next launch

- **WHEN** the app launches with a recorded session whose generated profile
  still selects the managed provider but names another model
- **THEN** the system deletes that file instead of discarding the record

### Requirement: Bundled LiteLLM upstream

The default Switchyard upstream SHALL be the app-managed LiteLLM instance on
127.0.0.1:4101. LiteLLM SHALL use its ChatGPT OAuth session and the discovered,
assigned model IDs. Start SHALL wait for authentication and health before
writing the Codex profile. Stop SHALL stop both managed servers after deleting
it. Manual experiments on ports 4000/4001 SHALL remain independent.

#### Scenario: Default route starts the managed LiteLLM upstream

- **WHEN** the user starts a valid profile without selecting an external
  development upstream
- **THEN** the system starts its bundled LiteLLM on port 4101 before writing
  the Codex profile

### Requirement: Durable diagnostics for an unattended stop

Routing runs while the user is working in Codex, so a server that dies or stops
answering is noticed somewhere else, long after the fact. The system SHALL keep
a durable, redacted record under `~/Library/Application Support/switchyard-desktop/`
that survives the session that wrote it: its own lifecycle events in
`diagnostics.log`, and each managed server's own output in
`switchyard-server.log` and `litellm.log`.

The system SHALL record starting and stopping a managed server, an unexpected
exit with its exit status and the server's last output, a running proxy that
stops answering on loopback, writing and deleting the Codex profile, and
cleanup of a route left by an earlier run. It SHALL drain a managed server's
output continuously, so that output can never block the server that produced
it. Every recorded value SHALL pass the same redaction as UI diagnostics, and
each file SHALL be bounded in size, keeping one previous generation. The system
SHALL offer a way to open that folder from the status-bar menu.

#### Scenario: A managed server stops while the user is in Codex

- **WHEN** `switchyard-server` or the managed LiteLLM exits while a route is
  active
- **THEN** the system records the event, the exit status and the server's last
  output in `diagnostics.log`, and names that file in the recovery message it
  shows

#### Scenario: The proxy is running but no longer answering

- **WHEN** a periodic loopback probe of the running proxy fails
- **THEN** the system records the missed probe without stopping the route, and
  records the recovery when the proxy answers again

#### Scenario: Diagnostics never retain credentials or request content

- **WHEN** a managed server prints a credential, a token, or request content
- **THEN** the recorded line is redacted before it reaches any file the app
  keeps
