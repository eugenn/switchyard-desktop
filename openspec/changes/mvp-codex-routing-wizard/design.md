## Context

switchyard-desktop configures the local
[NVIDIA-NeMo/Switchyard](https://github.com/NVIDIA-NeMo/Switchyard) server as
an intelligent routing proxy for Codex. Switchyard owns route execution:
`switchyard-server --config <path> --dry-run` validates the generated TOML,
and the long-running server listens on the configured loopback port. Model
Router owns setup, safety checks, profile generation, process lifecycle, and
the Codex configuration change.

The product is Codex-subscription-only. It is not a generic model gateway:
there is no provider chooser, API-key workflow, arbitrary upstream URL, static
model list, or custom-model entry. On first launch it reads
`~/.codex/config.toml`, then discovers models through the
authenticated Codex subscription context. The configuration establishes the
local Codex setup; it is not assumed to be a complete model catalog.

## Goals / Non-Goals

**Goals:**

- Discover and display only models that the current Codex subscription can
  use, without revealing credentials from the Codex configuration.
- Let the user choose a supported Switchyard routing algorithm, then assign
  subscription models to that algorithm's roles.
- Enable `Start routing` only after every required role is assigned and all
  preflight validation passes.
- Keep a running route alive after the main window closes and make active
  routing visible and controllable from the macOS status bar.
- Install routing without writing `~/.codex/config.toml` at all, so
  no failure mode of this app can leave the user's own Codex setup broken.

**Non-Goals:**

- Providers, models, credentials, or upstream endpoints outside the user's
  Codex subscription.
- Static model catalogs, manual model-ID entry, or guessing availability from
  the currently configured Codex model.
- Installing runtime dependencies on the end-user machine. Packaging builds and bundles the complete stack.
- Starting switchyard-desktop at macOS login. Background operation begins only after
  the user starts a route and ends on a safe stop or application quit.
- Switchyard algorithms other than `stage_router` and custom-mode
  `llm_classifier`.

## Decisions

1. **Read a fixed default Codex configuration before setup.**
   `~/.codex/config.toml` is the default configuration location
   for this product. A `CodexSetupReader` parses only the fields needed to
   confirm a usable Codex installation and establish the discovery context. It
   redacts errors and never writes the source content to logs, diagnostics, or
   UI. A missing, unreadable, malformed, or unauthenticated setup blocks the
   wizard rather than causing a new configuration to be created.

2. **The subscription discovery result replaces the static catalog.**
   A `CodexModelDiscovery` service invokes the supported authenticated Codex
   model-list mechanism using the local setup obtained in decision 1. The
   exact transport is an implementation boundary so it can follow the
   supported Codex surface without changing UI or routing models. Its contract
   is strict: return canonical model IDs available to the active subscription,
   report a categorized failure, and never synthesize a fallback list. The
   first successful result populates the setup flow; an explicit refresh
   repeats discovery before routing starts.

3. **Algorithm choice determines roles, not the number of tiers.**
   The user explicitly selects one of two Switchyard algorithms:

   - `stage_router` exposes exactly `efficient` and `capable` target roles.
     It has no judge call.
   - custom-mode `llm_classifier` exposes two to six ordered target roles.
     Each target receives one discovered model and becomes one model group in
     the route's `models` table; the user selects one target as the judge
     (`models.judge`) and one group as `default_target` (fallback).

   This keeps the important cost/behavior choice visible. The previous hidden
   policy of choosing `stage_router` for two tiers and `llm_classifier` for
   three or more tiers is removed. Switching algorithms clears invalid role
   selections and requires the user to confirm the new role set.

4. **Generate only selected roles into Switchyard TOML.**
   `SwitchyardConfigWriter` keeps owning and replacing
   `~/Library/Application Support/switchyard-desktop/routes.toml`. For
   `stage_router`, it emits the `efficient_target` and `capable_target` from
   the roles selected by the user. For `llm_classifier`, it emits one model
   group per target role, `models.any` as the fallback order, `models.judge`
   for the judge's own target, and the selected fallback group as
   `default_target`. A tier never takes the reserved group names `any` or
   `judge`. The generated config uses Codex's existing authenticated request
   flow, not an API key supplied to switchyard-desktop. Before any proxy process
   starts or the Codex profile is written, the writer runs Switchyard's own
   `--dry-run` validation.

5. **Start routing is an ordered transaction that adds a file rather than
   editing one.**
   The final UI exposes `Start routing` only when discovery, algorithm-role
   validation, binary resolution, port availability, Codex-profile writability,
   and generated-TOML dry-run are successful. On click, the app writes the
   owned route config, starts the local proxy, and generates
   `~/.codex/switchyard-desktop.config.toml` — the layer Codex loads on
   top of the user's own configuration for
   `codex --profile switchyard-desktop` (Codex CLI 0.155's `-p/--profile`). Nothing
   the user owns is written, so there is nothing to back up and nothing an
   unclean shutdown can leave broken: the undo is deleting one generated file.
   A failure rolls back completed local work.

   The cost is coverage. Only sessions started with the flag are routed, and
   Codex Desktop, which exposes no way to select a profile, is not. The app
   states the command wherever it reports a route as active.

6. **An active route makes the application a background status item.**
   `SwitchyardProcessManager` remains responsible for the child process, while
   an app-lifecycle coordinator owns its lifetime after the main window closes.
   When a route becomes active, the app installs a status-bar item and
   automatically hides the main window. A primary click on the item activates
   the app and reopens the main window; its controls also offer Stop and Revert.
   Closing the reopened window hides the UI but does not quit the process or
   stop the proxy. The status item is removed only after routing stops or is
   safely reverted. A normal explicit quit still offers `Revert and Quit` or
   `Cancel`, restoring Codex before process termination.

7. **Persist a successful setup separately from active-session recovery.**
   The app stores the last successfully started routing profile without
   credentials. On later normal launches it restores that profile and opens
   the routing controls directly instead of replaying first-run setup. Current
   readiness is still checked before Start. An explicit Reconfigure action
   returns to setup, while an unreadable or incompatible saved profile fails
   back to setup with an explanation. This preference is distinct from the
   active-session record used to recover Codex after an unclean exit.

8. **Use the bundled routing stack.**
   The app resolves an explicit development override or its own Switchyard helper.
   A packaged app never falls through to PATH when the helper is missing. Swift
   command-line development may use PATH. The app also bundles Python and pinned
   LiteLLM/FastAPI dependencies, generates model mappings, and manages ChatGPT
   sign-in plus both server lifetimes. Source changes originate in NVIDIA and are
   imported explicitly; packaging never reads that checkout implicitly.

## Risks / Trade-offs

- **The authenticated Codex model-discovery surface can change.** Isolating it
  behind `CodexModelDiscovery`, with refresh and categorized errors, limits
  the impact; the app still fails closed rather than routing to guessed models.
- **The local Codex configuration can contain sensitive information.** The
  reader and every error path must redact values, and tests must use fixtures
  that prove no tokens or headers reach diagnostic output.
- **Background routing makes state less visible than a foreground-only app.**
  The status-bar icon, plain active/stopped status, and safe quit/recovery
  flow make the active proxy discoverable and controllable.
- **A force quit can still leave Codex configured for a stopped proxy.**
  Persisting active-session metadata and offering recovery on the next launch
  remains mandatory.
- **Switchyard is a bundled pre-1.0 dependency.** Dry-run validation is the
  compatibility gate; a schema mismatch fails before configuration changes.

## Open Questions

- Which supported Codex command or endpoint is the durable implementation of
  `CodexModelDiscovery` for subscription accounts, and what minimum Codex
  version is required?
- Codex Desktop cannot select a configuration profile, so it is not routed.
  Is a supported way to route it worth a separate change, given it would mean
  editing `~/.codex/config.toml` again?
