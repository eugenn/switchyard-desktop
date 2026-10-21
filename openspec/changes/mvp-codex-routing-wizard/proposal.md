## Why

switchyard-desktop is a macOS utility for intelligently routing Codex requests to
different models available through the user's Codex subscription. Without it,
a user must manually determine which subscription models are available, write
a Switchyard route, run `switchyard-server`, and edit Codex's configuration.

The application must make those decisions and lifecycle operations explicit:
on first launch it reads the local Codex setup, discovers the models the
subscription can actually use, lets the user select a Switchyard routing
algorithm and fill its model roles, then starts routing. While a route is
active, the application keeps running in the background and exposes a
status-bar icon so the user can see and control that state.

## What Changes

- Use [NVIDIA-NeMo/Switchyard](https://github.com/NVIDIA-NeMo/Switchyard) as
  the routing engine. switchyard-desktop generates and validates a Switchyard
  configuration, then manages the local `switchyard-server` process.
- Support only models available through the user's active Codex subscription;
  arbitrary model IDs, other providers, API keys, and custom upstream services
  are out of scope.
- On first launch, read `~/.codex/config.toml`, verify that Codex
  is configured, and use its authenticated subscription context to discover
  the available model list. The model list is the source of truth for all
  subsequent assignments.
- Replace the provider/catalog/tier-first wizard with a flow of: inspect
  Codex setup and discover models -> select a routing algorithm -> assign
  discovered models to the roles required by that algorithm -> review and
  press `Start routing`.
- Keep a successfully started route alive when the main window is closed.
  After Start succeeds, hide the main window automatically and show a
  status-bar icon only while routing is active; clicking the icon reopens the
  control window, which exposes status and the stop action.
- Persist the last successfully started non-sensitive routing profile. On a
  later normal launch, show its controls directly instead of repeating the
  first-run setup flow, while retaining an explicit Reconfigure action.
- Before starting, validate the generated Switchyard configuration, launch the
  proxy, back up and patch `~/.codex/config.toml`, and make all
  actions reversible. Normal application termination must restore Codex's
  previous configuration before stopping the proxy.

## Capabilities

### New Capabilities

- `codex-routing-wizard`: discovers a user's Codex-subscription models,
  configures an explicitly selected Switchyard algorithm and its roles, starts
  the local route, and safely manages its background lifecycle.

### Modified Capabilities

- `direct-mvp-distribution`: the packaged application must support active
  background routing and a visible status-bar control, rather than requiring
  the main window to remain open.

## Impact

- Affected code: setup discovery, routing-profile and Switchyard-config
  models, wizard and status-bar UI, process lifecycle, Codex-config handling,
  and tests under `Sources/switchyard-desktopApp/**` and `Tests/switchyard-desktopAppTests/**`.
- Affected user files: `~/.codex/switchyard-desktop.config.toml`, which
  this app generates and deletes in full, and switchyard-desktop's own configuration,
  recovery and diagnostic files under
  `~/Library/Application Support/switchyard-desktop/`.
  `~/.codex/config.toml` is read for discovery and never written.
- Bundled dependencies: Switchyard built from the NVIDIA source snapshot, plus
  Python, LiteLLM 1.97.0 and FastAPI 0.136.3. No separate server installation is required.
- Explicitly out of scope: providers or models outside the Codex subscription,
  manual model-ID entry, API-key management, arbitrary upstream URLs, login
  at macOS startup, and automatic dependency installation.
