# switchyard-desktop

A desktop app that chooses which AI model handles a request. Use a lighter model
for routine work and a more capable model when needed, without switching by hand.
The app uses [NVIDIA Switchyard](https://github.com/NVIDIA-NeMo/Switchyard) through
an independently maintained [core fork](https://github.com/eugenn/Switchyard).
It is not affiliated with NVIDIA, OpenAI or Anthropic.

The only application is now in [`desktop/`](desktop/README.md), built with Tauri,
React and Rust. Its source, runtime inputs, resources and build tools all live there.
**This is a development preview, not a release-ready installer.** Old DMGs from
GitHub Releases contain the retired application, not the current code. Build and
run from source using the instructions below.

## What you can connect

| Integration | How it works | What you need |
| --- | --- | --- |
| Codex / ChatGPT | Codex sends requests to the local Switchyard server, which selects a model and calls the bundled LiteLLM gateway. | Codex CLI, account access to the chosen models, and a separate ChatGPT sign-in through the app. |
| Claude Code | A Switchyard add-on selects between two models inside Claude Code. Claude Code handles sign-in and requests directly. | Claude Code 2.1.301+, mods enabled, a subscription sign-in and access to both models. macOS only; live-account testing still needed. |
| Jev / TypeSafe | Optional service that helps choose the model; it does not write the final answer. | A TypeSafe API key. Classification requests are separate from your model usage. |

Claude does **not** use the local Codex proxy: this does not provide a general
Claude API endpoint backed by a subscription. Gemini has no account setup flow
in this app yet. Supported models and usage limits depend on your provider.

## Run on macOS

You need macOS 14+, Node.js 22+, Rust stable, Xcode Command Line Tools, Python 3
and `uv`. The bundled Switchyard source also needs the toolchain specified in
`vendor/switchyard/rust-toolchain.toml`.

From the repository root, open Terminal and run:

```sh
cd desktop
npm ci
npm run runtime
npm run desktop
```

The first preparation builds Switchyard and bundles Python/LiteLLM. It can take
some time and requires dependency downloads. The app does not install packages
when it starts. If a prepared runtime already exists, the preparation command
refuses to replace it; see [runtime preparation](desktop/README.md#run-on-macos).

`npm run dev` only opens a browser preview. Account sign-in, routing and other
native actions are disabled there. Use `npm run desktop` for a working app.

Windows setup is documented in [the application guide](desktop/README.md#windows-development).
It still needs native build and runtime acceptance on Windows.

## Start routing Codex

1. Install Codex CLI separately and sign in to the account you want to use.
2. In the app's **Routing** page, discover the models available to your account.
3. Choose a routing strategy and assign models. Review the generated configuration.
4. Complete the ChatGPT sign-in when needed, save your settings and start routing.
5. In your project folder, run:

   ```sh
   codex --profile switch
   ```

Keep the app running while using this route. Stop routing in the app when done.
The app temporarily creates `CODEX_HOME/switch.config.toml`; it does not rewrite
`config.toml` or overwrite an unrelated profile. A stale Switchyard profile or
a file containing only Codex UI state can be replaced on Start. An occupied port is
reported rather than freed by stopping someone else's process.

## Use Claude without an API key

Claude Code is Anthropic's program for working with code in Terminal, separate
from the Claude website and desktop app. Sign in through Claude Code, choose two
models in **Routing > Set up Claude**, then prepare and run the launch command
shown by the app. Preparing the command does not start Claude Code automatically.

Follow the [step-by-step Claude guide](desktop/README.md#claude-code-subscription-routing)
for the one-time add-on build, account connection, model selection and pause commands.
Your subscription's limits still apply; routing can also make classifier requests.
Claude activity is not included in the app's HTTP proxy statistics.

## Existing installations

Quit the retired app and stop its route before starting this one: both use ports
4100/4101. Do not delete account files or app data to upgrade. This app keeps its
settings under `switchyard-desktop/cross-platform` in the platform's application
data folder. That directory name is retained to preserve existing preview data.

To bring over an old routing setup, use **Import / export routing setup** and
paste your exported JSON or legacy `saved-routing-setup.json`. Import creates a
draft: review it and save explicitly. Accounts, tokens and request history are
not transferred. Old setup imports are tested with 29 synthetic fixtures.

## Development and limitations

The routing editor supports 13 strategies and 18 built-in roles. Some server
features, including Prefill, require an optional core build. Activity views,
forced-quit recovery, OS integration, credential protection and installer
acceptance still have open work. Removing the old app does not mean these gaps
are complete. See [current status](docs/cross-platform.md).

- [Application setup and checks](desktop/README.md)
- [Development workflow](docs/development.md)
- [Contributing](CONTRIBUTING.md)
- [Release requirements](docs/releases.md)
- [Core snapshot ownership](docs/core-fork.md)

## License

Original application code and assets are licensed under [Apache-2.0](LICENSE).
Third-party components retain their own licenses; see [NOTICE](NOTICE),
[dependency notices](desktop/resources/THIRD-PARTY-NOTICES.txt) and `desktop/licenses/`.
Report vulnerabilities using [SECURITY.md](SECURITY.md).
