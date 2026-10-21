# switchyard-desktop

Native macOS app built on NVIDIA Switchyard. Configure models and routing, then
review request statistics. The DMG bundles the required runtimes; install by
dragging `switchyard-desktop.app` to **Applications**.

![Statistics screen](images/ui.png)

switchyard-desktop is an independent utility, not affiliated with OpenAI or NVIDIA.

## Requirements and installation

- macOS 14 or later, with the architecture indicated in the DMG filename (`arm64` or `x86_64`).
- The Codex CLI installed and signed in with a subscription that exposes the selected models.
- A ChatGPT sign-in for LiteLLM. An existing session in `~/.config/litellm/chatgpt/auth.json` is reused.
- Internet access to the upstream service, and available local ports 4100 and 4101.
  Servers left behind by a run that was force quit or crashed are stopped automatically at the
  next start; a port held by any other program is reported by name instead.

1. Mount the DMG and drag **switchyard-desktop.app** to **Applications**.
2. Eject the image and open the app. It opens **Statistics**; choose **Routing config** to configure a route.
3. In **Codex account**, check the existing Codex setup and discover the models your account can use.
4. In **Routing**, choose an algorithm, assign models and roles, and adjust routing decisions or native options.
5. In **Review & start**, inspect the generated configuration, acknowledge the changes, and start routing.
   If LiteLLM needs sign-in, follow the ChatGPT device-login instructions shown in the app.
6. Start Codex as `codex --profile switchyard-desktop`. The app provides the command for copying.
   Sessions started without the flag keep your own settings and are not routed.
   **Also use this route in Codex Desktop** provides a block to paste into `config.toml` yourself,
   making the route your Codex default until you remove those lines.

Discovery reads `$CODEX_HOME/config.toml`, or `~/.codex/config.toml`, without modifying it.
Start writes `switchyard-desktop.config.toml` beside it, the layer Codex loads for
`codex --profile switchyard-desktop`. Stop deletes that generated profile before shutting down
the managed servers. Opening the app alone never starts routing or writes a profile.

The Statistics window shows recorded request flow, model usage, conversation history,
classifier calls and errors. Routing checks and reviews have separate counts and do not
inflate served-request counts. The role library includes implementation, architecture,
execution and review prompts that can be edited and assigned to routing targets.

See [Application experience](docs/app-experience.md) for the setup flow and isolated UI previews.

Public releases must be Developer ID signed, notarized and stapled. A filename ending in
`-local.dmg` is an ad-hoc-signed development artifact, not a public release.

## Request flow

Selecting a conversation in statistics shows a context gauge beside each model.
It compares the last served request's input tokens (including cached input and server-added
instructions) with that model's maximum window (`max_context_window`) from the current local Codex
catalog, falling back to `context_window` when no maximum is provided. The default client window
can be smaller than the model's maximum. It updates after usage is
logged; output tokens and cumulative session totals are not included. Missing data displays `—`.
A configured Switchyard `context_window` appears separately on the router node: this is a route
declaration, not an enforced per-model limit. While routing runs, it comes from the managed
server's `/v1/models`; when stopped, it comes from the app's saved server configuration.

```text
Codex → Switchyard (127.0.0.1:4100) → LiteLLM (127.0.0.1:4101) → ChatGPT
```

Both servers belong to the app. The existing manual experiment on ports 4000/4001 is independent.
Switchyard selects a model; LiteLLM maps its ID to `chatgpt/<model-id>` and manages ChatGPT OAuth.
The default configuration does not forward Codex credentials to LiteLLM. An explicit direct-upstream
configuration can forward the caller credential instead.

The app generates LiteLLM's model list from the selected, discovered models. The sample under
`configs/litellm/development.yaml` is for manual development, not the production model inventory.

- **Auto / Stage router:** native tool-history routing, including escalation and de-escalation
  within one session. The Stage preset matches Switchyard's `efficient_first`, threshold `0.5`,
  and three-result window.
- **Capability classifier:** Switchyard's packaged capability prompt, verdict schema and probability
  policy. **Custom classifier** uses the user's role descriptions and native `target_selector` policy.
- **Escalation / Composite / Advisor:** the original trajectory judge, classifier-plus-stage router,
  and review gate, with Switchyard's packaged prompts and default budgets.
  Escalation requires fresh, consistent evidence in the same failure category before switching
  to Capable. Optional native `escalation.deescalation` settings can return the session to Efficient.
- **Random / Passthrough / No-op:** native weighted routing, a fixed target, and a local OK response.
- **Prefill router:** configuration is available for an explicit server build with the optional
  `prefill-router` feature and its Python runtime, encoder and trained checkpoint. The standard
  bundled server, like the standard NVIDIA build, rejects this route during dry-run validation.
- Classification defaults to `every_request`, including tool continuations. The UI also exposes
  `user_turn` and `new_session`; Composite permits those two triggers, starts with `user_turn`, and still scores stage signals
  every request. Without session identity, the native affinity behavior applies.
- **Native Switchyard options** edits the complete algorithm body under `[routes.main]`. This
  includes thresholds, picker, context windows, custom prompts and schemas, model-group fallbacks,
  tool semantics, handoff notes, review budgets and nested subagent policies. Additional native targets
  can supply separate subagent workers and fallback candidates. The server validates
  these options; Swift does not reimplement any routing algorithm.
- **Roles** open the role library: the roles every setup on this Mac shares. A role carries the
  description the judge reads, the prompt its model is sent as target `system_prompt`, a reasoning
  level and tags to filter by. The library ships the four-step ladder, common workflow roles,
  and further roles for debugging, tests, refactoring, review, planning, docs and
  short answers. Roles are searched by name, wording, prompt or tag; they can be duplicated, edited,
  reset to what they shipped as, and removed. A target picks one from the library, and editing a role
  reaches every target holding it. Custom roles and prompts can be saved in the same library.
- **Role groups** collect roles by project or purpose. A role can belong to several groups;
  removing a group keeps its roles. Each group has an optional project-folder label and can
  save the current routing setup, including model assignments, judge and fallback. **Use saved
  setup** loads that draft while routing is stopped; it does not start a server or automatically
  select a route by project directory. Current library prompts take precedence over saved copies.
  Group settings are beside the group selector in the role library, with membership under **Groups**
  on each role. The app imports no files, so a role-group JSON file kept in `configs/role-groups/` is
  merged into the role library by `scripts/install-role-group.py <file>` with switchyard-desktop quit and
  routing stopped: it backs the library up, replaces roles and groups by id and leaves the rest
  alone. Because current library prompts win over a saved copy, keep a group's own copies and the
  library in step — the script is what does that.
- **Routing decisions** asks two questions rather than naming server fields: which model decides the
  routing — a target's model to reuse, or one of its own, in one menu — and which target serves a turn
  the judge cannot place. A judge on its own model is a complete answer by itself; the target it would
  otherwise share is then not needed. The target making the call is chipped `judge` in the list above.
- The routing step reads its prompts without opening anything: **Judge prompt** under the roles bar
  shows what the judge is sent on every classification, with the group list already built from the
  targets below it, and each target's **Role prompt** shows the description the judge reads and the
  prompt its model gets. Both are read-only and selectable; **Edit in the library** opens the role.
- Target settings preserve native `system_prompt`, `reasoning_effort` and `extra_body`. A role's
  prompt is written onto its target, and a `system_prompt` in native target options wins over it. A separate
  discovered model can serve as judge. Optional judge budgets and context windows use server defaults
  (including the classifier's 4096 output tokens), rather than app-specific limits.
- Image support is advertised only when all assigned models support images and the bundled server
  accepts the corresponding configuration field.
- Each classifier target becomes one model group in the route's `models` table; the judge's verdict
  names a group, and `models.any` is the route's fallback order. `any` and `judge` are reserved, so
  a target role never takes those names.
- Preset configurations carry an `Advertise reasoning summaries to Codex` toggle. It is on by default,
  which leaves the key out of the generated route so Switchyard follows the route's reasoning
  support. Turning it off writes `reasoning_summaries = false` for a model that takes a reasoning
  effort but returns no summary. When native route options are enabled, capability fields are
  edited there as part of the complete route body.

See [the routing parity audit](docs/routing-parity.md) for the original discrepancies and validation.

The app points Codex at the proxy with `http_headers = { "x-switchyard-origin" = "codex-cli" }`, so
every routed turn is labelled in the routing log and the Statistics window can tell Codex's turns
apart from anything else aimed at the same port.

## Files, lifetime and recovery

Start writes files under `~/Library/Application Support/switchyard-desktop/`:

- `routes.toml`: generated Switchyard configuration.
- `litellm.yaml`: generated LiteLLM model mappings, with no credentials.
- `active-routing.json`: recovery metadata for the Codex configuration change.
- `saved-routing-setup.json`: the last successfully started profile and discovered model metadata,
  without credentials; used to open the routing controls directly on later launches.
- `role-library.json`: the role library — every role this Mac knows, with its description, model
  prompt, reasoning level and tags. Written whenever a role is edited, added or removed, and read at
  launch; a later version adds the roles it ships without touching a word of an edited one or
  putting back one that was removed.
- `routing-log.jsonl`: routing decisions used by the Statistics window, without request bodies.
- `diagnostics.log`: what the app did — start, stop, an unexpected exit, a proxy that stops
  answering, recovery at launch. Kept across launches, rotated into `diagnostics.previous.log`.
- `switchyard-server.log` and `litellm.log`: what each server itself printed, one banner per run.

All three logs are redacted as they are written: credentials, tokens and anything that looks like
request content never reach them. **Reveal logs in Finder** in the menu-bar menu opens the folder.

Codex configuration is resolved using `$CODEX_HOME/config.toml`, or `~/.codex/config.toml`. That
file is read and never written. The generated layer is `switchyard-desktop.config.toml` in the same
directory; deleting it is the whole of an undo, and nothing outside `codex --profile switchyard-desktop`
reads it. LiteLLM separately manages its OAuth session under `~/.config/litellm/chatgpt/`.

Closing the main window keeps active routing alive, with controls in the menu bar. **Stop routing**
deletes the generated profile before stopping both servers. Normal quit offers **Stop and Quit** or
**Cancel**. If the file cannot be deleted, the app stays open, keeps the proxy running and says so.

While routing is active, clicking the menu-bar or Dock icon reopens that app's own main window.
The app opens **Statistics** by default: a 15-minute request-flow map, model shares and errors,
and latency with per-model filters. The current server provides session p50/p99; a history chart is
shown when the request log contains per-request timings. Idle models remain visible as dashed paths.
Active flow paths softly pulse without token particles. Flow animations and window polling pause
while the window is minimized, hidden or fully occluded, then resume when it becomes visible.
**Routing config** opens setup explicitly; a route that needs recovery opens the Review controls instead.

After a successful Start, the app remembers the non-sensitive routing setup. Opening
**Routing config** on a later launch shows its saved Review controls. Choose
**Reconfigure** to return to setup.

A crash or force quit leaves your own Codex configuration untouched; the only leftover is the
generated profile, which affects nothing until a session asks for it by name. The next launch
deletes it and says so. If that ever fails, delete `switchyard-desktop.config.toml` yourself, or just
press Start again — it replaces the file. A crashed process can leave child servers behind; resolve
a port conflict before restarting, without stopping an unrelated server.

For removal: Stop routing, quit, delete the app, then remove its Application Support directory if
desired. The shared LiteLLM OAuth session is not removed automatically.

Upgrading from a version that edited `config.toml` directly, while a route from it was active, is
handled once: the first launch of this version restores that file from the backup the old version
recorded and then never writes it again.

## Build the application and local DMG

Build prerequisites: Xcode, the Rust toolchain specified by `vendor/switchyard/rust-toolchain.toml`,
Python 3 for build scripts, and `uv`. Build dependencies are downloaded during packaging, never at
application startup. Current scripts build for the host architecture, not a universal binary.

```sh
cd ~/Projects/personal/switchyard-desktop
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# Build the complete local app, including both servers.
./scripts/build-dev-app.sh release
open build/switchyard-desktop.app

# Build the local drag-to-Applications installer.
./scripts/create-dev-dmg.sh
```

The local DMG is written to `dist/switchyard-desktop-<version>-<build>-<arch>-local.dmg`.
Packaging verifies the source snapshot, builds Switchyard, assembles the Python runtime from locked
requirements, collects notices, signs nested native code, and verifies the bundle.
`swift run` alone does not assemble the Python runtime or the app bundle.

For Xcode development, run `./scripts/prepare-xcode.sh` once (and after runtime or
server snapshot updates), open `Package.swift`, select **SwitchyardDesktopApp / My Mac**, and press **⌘R**. Unbundled debug builds find the
prepared Python/LiteLLM runtime and snapshot server in this checkout's `build/` directory.
They use app ports 4100/4101, without relying on the manual experiment. No dependencies are
installed at app startup. Complete `.app` bundles always use their own embedded runtime.
`SwitchyardDesktopApp` is the only executable target. It uses `SwitchyardDesktopKit` for
configuration generation, process management and statistics.

To build the app and run all tests with Xcode's build system:

```sh
xcodebuild -scheme SwitchyardDesktopApp -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/Xcode test
xcodebuild -scheme SwitchyardDesktopApp -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build/Xcode build
```

## Build Switchyard separately

```sh
cd ~/Projects/personal/switchyard-desktop
./scripts/build-switchyard.sh
```

This checks `vendor/switchyard-source.json`, then runs
`cargo build --locked --release --target <host triple> -p switchyard-server` inside
`vendor/switchyard`, with build output outside the source snapshot. The macOS 14 floor is passed to
that target only — as a link argument and as `CFLAGS`/`CXXFLAGS` for the compiled C in `ring` and
`aws-lc-sys` — because exporting `MACOSX_DEPLOYMENT_TARGET` also reaches the host proc-macro crates,
which rustc 1.96 then refuses to load. The built binary is copied to the one path the rest of the
repository reads:

```text
build/switchyard-target/release/switchyard-server
```

The script also validates `configs/switchyard/smoke.toml` using `--dry-run`.
See [Development workflow](docs/development.md) for source updates, server testing and manual LiteLLM startup.

## Public release

Set version/build metadata in `Resources/AppVersion.env`. Configure a Developer ID Application
identity and a `notarytool` keychain profile outside this repository, then run:

```sh
SWITCHYARD_DESKTOP_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
SWITCHYARD_DESKTOP_NOTARY_PROFILE='switchyard-desktop-notary' \
./scripts/create-release-dmg.sh
```

The script signs native executables, libraries and Python extensions with hardened runtime, notarizes
and staples the app, creates and signs the DMG, notarizes and staples it, then verifies both artifacts.
A failure stops release; it never silently falls back to ad-hoc signing.
Output: `dist/switchyard-desktop-<version>-<build>-<arch>.dmg`.

A local build is not evidence of Apple notarization. Before publishing, verify installation and the
complete sign-in/routing/recovery flow on a clean macOS account, using the intended release architecture.

## Troubleshooting

- **Bundled server/runtime missing:** reinstall the complete app or rebuild with `build-dev-app.sh`.
  Installing another `switchyard-server` on PATH will not replace a missing bundled server.
- **Port 4101 in use:** stop the conflicting app-owned process before starting. switchyard-desktop does not
  silently attach to or terminate another LiteLLM server.
- **ChatGPT sign-in pending:** follow the device sign-in instructions in the window. The LiteLLM
  session is separate from Codex model discovery; both must work.
- **Unsupported configuration:** update the server snapshot from NVIDIA, rebuild, and run tests.
- **Codex discovery failed:** resolve the Codex sign-in/configuration issue shown by the setup step.
- **Routing stopped on its own, or Codex lost the route:** read `diagnostics.log` under
  `~/Library/Application Support/switchyard-desktop/`. An unexpected exit is recorded there with the exit
  code and the server's last output; a proxy that is alive but no longer answering is recorded as a
  missed health probe. `switchyard-server.log` holds the server's own account of the same moment.

Local verification results and remaining release checks: [Build validation](docs/build-validation.md).

## Notices

Bundled notices are under `Contents/Resources/`, including Switchyard's Apache-2.0 license and NOTICE,
and Rust dependency license texts. Python package licenses remain in their distribution metadata inside
the bundled LiteLLM runtime. See `Resources/PRIVACY.txt` and `Resources/THIRD-PARTY-NOTICES.txt`.
