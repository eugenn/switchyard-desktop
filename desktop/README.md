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

## Claude Code routing with an Anthropic API key

**Development preview.** Real-account testing is still needed: the automated checks
use a fake key and do not contact Anthropic. Claude Code routing uses an
**Anthropic API key**, billed to your Anthropic API account. It does not use a
Claude subscription: the app has no Claude Code sign-in, plug-in or "mods" step.

### What this does

**Claude Code** is Anthropic's program for working with code in Terminal. This
feature points it at the app's local Switchyard server (`127.0.0.1:4100`), the
same server Codex uses. The server selects between two Claude models you choose
(one for routine tasks, one for more demanding tasks) and calls Anthropic itself
with your key, including the classifier calls that make the choice.

- The key is saved in macOS Keychain or Windows Credential Manager, never in JSON,
  generated TOML or the launch command. Only the managed server receives it, in its
  environment. Claude Code never sees it; it sends a placeholder token that the
  server ignores.
- Requests appear in **Activity** and **Requests** with origin `claude-code`.
- Routing uses the bundled Composite policy. The Codex strategy editor does not
  change it.
- Anthropic usage and rate limits apply to your key. Classifier calls are extra
  requests on that key.

### Set up and start working

1. Open **Routing**, then **Set up Claude**.
2. Enter your Anthropic API key and click **Save API key**. The field clears and
   shows only whether a key is saved. **Remove API key** deletes it from the vault.
3. Enter two exact model IDs your account can use (machine-readable names starting
   with `claude-`): **Efficient** for routine tasks and **Capable** for demanding
   ones. The app does not look models up or guess them. Click **Save Claude setup**.
   Clearing both fields turns the Claude Code route off.
4. Start routing (**Save and start**). The Claude Code route is added to the server
   only while both models and a key are saved, and only for that run: change the
   setup, then stop and start again.
5. Copy the launch command from **Set up Claude**, open Terminal in your project
   folder and run it. It looks like this (POSIX shell):

   ```sh
   ANTHROPIC_BASE_URL='http://127.0.0.1:4100' ANTHROPIC_AUTH_TOKEN='switchyard-local' \
   ANTHROPIC_MODEL='switchyard-claude' ANTHROPIC_DEFAULT_OPUS_MODEL='switchyard-claude' \
   ANTHROPIC_DEFAULT_SONNET_MODEL='switchyard-claude' ANTHROPIC_DEFAULT_HAIKU_MODEL='switchyard-claude' \
   ANTHROPIC_CUSTOM_HEADERS='x-switchyard-origin: claude-code' claude
   ```

   `switchyard-claude` is the route name, not a model. It is how Claude Code asks the
   server to choose. Claude Code may log `unrecognized_model` for that name.
   The variables apply to that one Claude Code session only; your own Claude
   Code configuration and sign-in are not changed.

Starting routing still needs the ChatGPT sign-in unless the Codex algorithm is
**Noop**, because the server and LiteLLM gateway start together. For a
Claude-only setup, choose the Noop algorithm.

### Not verified yet

- A full Claude Code conversation with a real key: tool use, streaming, extended
  thinking and context limits through the route.
- Whether Claude Code limits any features for the unrecognized route name.
- That a Claude Code that is already signed in with a subscription uses the
  placeholder token instead of that sign-in for the launched session. The smoke
  run used an empty, isolated Claude Code configuration.
- Windows: the launch command above is POSIX shell only.

### Developer checks

From `desktop`, run these without any account, key or network:

```sh
cargo test -p switchyard-desktop-core
npm test
```

`cargo test -p switchyard-desktop-core -- --include-ignored claude_route` also starts
the prepared bundled server with a fake key, on an ephemeral port, and checks that
both routes are served and that the key never reaches a file.

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
