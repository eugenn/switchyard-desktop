# switchyard-desktop

Native macOS app for routing Codex requests between models with NVIDIA Switchyard.
Configure models and routing, then review request statistics. Switchyard and the
Python/LiteLLM runtime are bundled with the app.

This is an independent community project using a
[maintained Switchyard fork](https://github.com/eugenn/Switchyard), based on
[NVIDIA Switchyard](https://github.com/NVIDIA-NeMo/Switchyard). It is not affiliated
with or endorsed by NVIDIA or OpenAI.

![Statistics screen](images/ui.png)

## Quick start

Requires macOS 14 or later and the Codex CLI installed and signed in with access
to the models you want to use.

1. Open the DMG for your Mac (`arm64` or `x86_64`), drag **switchyard-desktop.app**
   to **Applications**, and launch it.
2. Open **Routing config**. In **Codex account**, discover your available models.
3. In **Routing**, choose an algorithm and assign models and roles.
4. In **Review & start**, review the configuration and start routing. Follow the
   ChatGPT sign-in instructions if prompted.
5. Run Codex through the route:

   ```sh
   codex --profile switchyard-desktop
   ```

Keep the app running while using the route. Use **Stop routing** when finished.

## Run from source

Requires Xcode, Python 3, `uv`, and the Rust toolchain specified in
`vendor/switchyard/rust-toolchain.toml`. From the repository root:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
./scripts/build-dev-app.sh release
open build/switchyard-desktop.app
```

Then follow the setup steps above. The build downloads and bundles the required
runtimes; nothing is installed at app startup.

## Development and contributions

The app builds from the checked-in core snapshot; a separate core checkout is
only needed to develop server changes. Start with [CONTRIBUTING.md](CONTRIBUTING.md)
and the [development workflow](docs/development.md). See also
[core fork maintenance](docs/core-fork.md), [releases and provenance](docs/releases.md),
and [GitHub maintainer settings](docs/github.md).

## License

Original application code and project assets are licensed under
[Apache-2.0](LICENSE). Third-party components retain their own licenses; see
[NOTICE](NOTICE) and [third-party notices](Resources/THIRD-PARTY-NOTICES.txt).
Report vulnerabilities using [SECURITY.md](SECURITY.md).
