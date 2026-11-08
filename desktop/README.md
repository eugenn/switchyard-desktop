# Switchyard Desktop

The sole application: Tauri 2 / React / Rust for macOS 14+ and Windows x64.
This directory owns the frontend, Rust core, Tauri shell, runtime inputs and build tools.
This remains a development preview with incomplete release acceptance, not a
release-ready installer. See [current status](../docs/cross-platform.md).

## Run on macOS

Prerequisites: Node.js 22+, Rust stable, Xcode Command Line Tools, Python 3 and uv.

```sh
cd desktop
npm ci
npm run runtime
npm run desktop
```

If `build/litellm-runtime` within `desktop/` is already prepared, avoid rebuilding
Python with:

```sh
python3 scripts/prepare-runtime.py --reuse-python
```

Preparation verifies the checked-in snapshot, builds the server from it, and
copies Python/LiteLLM into `src-tauri/runtime`. It does not use a server from PATH
or `../NVIDIA`. The preparation step refuses to overwrite an existing runtime;
move the previous runtime aside before rebuilding. No packages are installed at
application startup. The generated runtime is ignored by Git.

`npm run dev` opens the UI in a browser without native capabilities. The browser
explicitly labels this mode, disables native actions and never invents metrics.

## Claude Code subscription routing

**Development preview, macOS only.** This feature is in the source app in
this folder. Previously published DMGs contain the retired application. Real-account testing is
still needed; the automated checks do not verify a live Claude conversation.

### What this does

**Claude Code** is Anthropic's program for working with code in Terminal. It is
separate from the Claude website and the Claude desktop app. Switchyard adds a
small plug-in to Claude Code that chooses between two Claude models as you work:
one for routine tasks and one for more demanding tasks.

**You do not enter an API key.** You sign in with your Claude account through
Claude Code. Claude Code handles sign-in and sends the requests itself;
Switchyard does not read or copy your sign-in tokens. Your account must include
Claude Code access and access to both models you choose. Account usage limits
still apply, and the routing decisions can also use Claude requests. This is
not a promise of unlimited usage or lower cost.

Unlike the Codex integration, this does **not** turn the app's server into a
Claude API endpoint. Other programs cannot send Claude subscription requests
through the Codex proxy. Claude activity also does not appear in the app's
HTTP proxy statistics.

### One-time preparation

1. Install Claude Code **2.1.301 or newer** separately and enable its **mods**
   feature. Mods allow Claude Code to load the Switchyard add-on.
2. Prepare the development app and its runtime using **Run on macOS** above.
3. Stop the development app before adding the Claude plug-in. From the
   repository root, run:

   ```sh
   cd desktop
   python3 scripts/prepare-runtime.py --claude-plugin
   npm run desktop
   ```

   If your Terminal is already in `desktop`, skip `cd desktop`. This builds the
   add-on from the Switchyard source included in this repository. The script
   refuses to overwrite an existing `desktop/src-tauri/runtime/claude-plugin`
   folder. If you need to rebuild it, move that folder aside first.

Use the native development app (`npm run desktop`), not the browser-only preview
(`npm run dev`): the browser cannot sign in or prepare Claude routing.

### Connect your account and start working

1. In the development app, open **Routing**, then **Set up Claude**.
2. Click **Check Claude account**. If Claude Code cannot be found, enter the
   full path to its executable in **Claude Code executable** and check again.
   Otherwise, leave that field empty.
3. If you are not signed in, click **Sign in with Claude Code** and complete
   sign-in in the browser. Return to the app and check the account again.
   This flow requires a Claude subscription sign-in, not an API-key sign-in.
4. Enter two exact model IDs that your account can use. A model ID is the
   machine-readable name starting with `claude-`, not a friendly display name:
   - **Efficient Claude model ID**: the model for routine tasks.
   - **Capable Claude model ID**: the model for more demanding tasks.

   The app does not discover these models automatically or grant access to
   them. Use IDs supported by your installed Claude Code and your account.
5. Click **Prepare Claude routing**, then **Copy command**. Preparing creates
   a launch command; it does not start Claude Code yet.
6. Open Terminal and go to the project folder you want Claude Code to work in.
   Paste the copied command and press Return. Approve the plug-in if prompted.
   Continue working in that Claude Code session.

You do not need to start the Codex route for this to work. Claude Code runs
separately: closing the desktop app does not end your Claude Code session.

### Pause routing or change models

Type these commands **inside Claude Code**, not in the desktop app:

| Command | What it does |
| --- | --- |
| `/switchyard` | Shows the current routing status. |
| `/switchyard off` | Pauses automatic model switching. |
| `/switchyard on` | Enables automatic switching for the next request. |

Choosing a model manually in Claude Code also pauses automatic switching.
To change your two model IDs, update them in the app, prepare routing again,
and start a new Claude Code session with the new command. Existing sessions
keep their previous settings.

This integration uses the bundled **Composite** routing policy: the rules that
choose between Efficient and Capable. The Codex algorithm editor does not change
these rules. Windows support is not available yet.

### Developer checks

From `desktop`, run these checks without Claude sign-in or subscription requests:

```sh
cargo test -p switchyard-desktop-core
npm test
python3 scripts/smoke-claude.py
```

The smoke check runs the actual prepared helper with test data, checks model
selection and the Composite classifier exchange, and verifies test storage and
shutdown cleanup. It does not contact Claude. Real subscription sign-in, mods,
model access and a full Claude Code conversation still need testing with an
actual account. Proposed core follow-ups are in `claude-core-proposals.md`.

## Windows development

Run the same preparation script **on Windows** with Python 3.12, uv, Node.js,
Rust's MSVC toolchain and the native build tools needed by the server dependencies:

```powershell
cd desktop
npm ci
py -3 scripts/prepare-runtime.py
npm run desktop
```

The preparation script builds `switchyard-server.exe` from the snapshot and
stages Windows Python 3.12.10. It uses the pinned hash-checked lock, removing only
`uvloop`, which is not supported on Windows. LiteLLM remains 1.97.0 and FastAPI
remains 0.136.3. This path is implemented but has not been run on Windows.

The Rust desktop library passes cross-target checking for
`x86_64-pc-windows-gnu`; that is **not** a linked Windows application, native
runtime validation, or a substitute for testing on Windows. Windows process
ownership uses Job Objects; Unix uses process groups. Neither path reclaims
foreign processes or kills an arbitrary listener to free a port.

## Routing and role workflows

Routing and role workflows are implemented in this client. Remaining activity,
lifecycle and release gaps are tracked in [the status ledger](../docs/cross-platform.md).

- All 13 strategies: Auto, Stage, Capability, Custom, Escalation, Composite,
  Advisor, Random, Passthrough, No-op, Prefill, Plan -> execute, and VGR.
  Prefill remains optional: the default server snapshot has no Prefill feature.
  A checkpoint field does not make the packaged server support that feature.
- All 18 original role definitions, including their exact prompts and efforts.
  Create, edit, duplicate, delete, reset, search, tag and group roles. Save the
  library independently of incomplete routing models. Groups can hold routing
  drafts; loading one changes the editor, not a running route.
- Two to six Custom targets, described roles, fallback, classifier templates,
  classification cadence, separate/shared judges and per-target native options.
  Additional native targets support subagent policies. Native route TOML replaces
  the entire policy, with scope and target-reference validation.
- Jev / TypeSafe decisions for Capability, Custom and Composite. Enter the key
  explicitly in the decision-provider panel. It is stored in macOS Keychain or
  Windows Credential Manager, never in JSON, generated TOML, exports or the
  renderer's persistent storage. Only the managed server receives it in its
  environment. Jev sends classification data to api.typesafe.ai; tests use only
  loopback mocks. Real vault integration still requires platform acceptance.
- Explicit Codex CLI account-model discovery, executable override, persisted model
  catalog, supported-effort checks, context/image limits, long-context cap and
  Codex reasoning-summary preference. No discovery starts automatically.
- ChatGPT device sign-in through the pinned bundled LiteLLM authenticator.
  LiteLLM OAuth tokens remain in the isolated app-data directory, not the vault.
- Request-log history with time/search filtering and raw record inspection,
  plus live server counters. Outcomes are not counted as model usage. Charts,
  cost/context/session aggregates and richer flow views remain incomplete.
- Explicit JSON import/export. Legacy saved setups preserve native policy,
  target identities/prompts, role membership IDs and context metadata. A saved
  setup does not contain its library's group names/paths: imports retain those
  memberships under placeholder group names. Credentials are never imported.
  Nonstandard providers/listeners/upstreams are rejected rather than changed.

## Codex connection

Review configuration never writes files. Every Start creates
CODEX_HOME/switch.config.toml once both services are ready, and Stop removes it.
Start a client with codex --profile switch. The user's config.toml is never
written.

A foreign switch.config.toml is never replaced. A regular file selecting the
`switchyard-desktop` provider is treated as a stale app profile and may be
replaced on Start. A file containing only Codex's `[tui]` state can also be
replaced. Stop removes this session's profile, including added Codex UI state;
other external edits and links are preserved with an explanation. A failed
installation rolls back the new services. Full crash-recovery ownership
reconciliation is not implemented yet.
Stop any old installation before using ports 4100/4101. The app never reclaims
foreign listeners; the independent manual 4000/4001 setup is untouched.

## Validation

Run from desktop/ unless the command starts with ../:

```sh
npm run build
npm test
cargo test -p switchyard-desktop-core --locked
cargo check -p switchyard-desktop-shell --locked
cargo check -p switchyard-desktop-core --locked --target x86_64-pc-windows-gnu
python3 -m unittest discover -s scripts -p 'test_*.py' -v
python3 scripts/verify-setup-import.py
python3 scripts/verify-routing-parity.py
npm run test:runtime
cargo test -p switchyard-desktop-core --locked noop_session_profile_and_rollback_use_only_injected_paths -- --ignored
```

The setup check reads 29 checked-in synthetic legacy exports: all 13 presets,
all 13 native bodies and three Jev variants, plus the exact 18-role catalog.
It runs entirely in Rust and does not require the removed app or its toolchain.
The routing check runs 52 real-server scenarios through Chat and Responses,
including Custom cadence/fallback, stage transitions, native prompts, subagents,
shared-model roles, random weights and eight Jev mock cases.

The runtime smoke uses an offline provider and ephemeral ports, exercising
streaming, non-streaming, stats and routing-log provenance directly through
`src-tauri/runtime`, without creating a legacy app bundle. The explicit ignored No-op integration test exercises real
session startup/stop/profile rollback without auth on ephemeral ports. All test
user locations and vaults are isolated. No check uses the real user account.

## Remaining release blockers

- Full activity aggregation/flow views, account/setup polish and visual acceptance.
- Forced-quit recovery, cancel during startup, guarded close, single-instance
  ownership and bounded redacted diagnostics; menu/tray/window preferences.
- LiteLLM OAuth token vault protection and real Keychain/Credential Manager
  acceptance. Current Unix auth-directory mode is 0700; Windows inherits the
  app-data ACL. The TypeSafe key uses the OS vault, not that token directory.
- Native Windows build/run, clean-machine acceptance, installer/signing/update
  integration, accessibility acceptance and complete third-party license output.

Normal exit stops owned services. Service stderr is not persisted to avoid
accidental secret capture. Windows process-tree containment is implemented with
Job Objects, but a GNU cross-target check is not a Windows application test.

Installer generation is disabled in `src-tauri/tauri.conf.json` (`bundle.active = false`). The snapshot is dirty/development-only:
never publish it. Releases must preserve --verify --release --check-published,
trusted signing and dependency-license gates. Core changes belong in ../NVIDIA
and must be imported with the snapshot tool; never edit vendor files here.
