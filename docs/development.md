# Development workflow

## Ownership

The maintainer uses the sibling `../NVIDIA` as the Switchyard development checkout.
Implement server behavior, API, routing algorithms, metrics and server tests there first.

`switchyard-desktop` owns the Swift application, configuration generation, process management, integration
checks and packaging. `vendor/switchyard/` is an imported source snapshot, not a second development
branch. Do not edit it directly. Builds never copy sources implicitly from NVIDIA.

The current import includes tracked working-tree changes from NVIDIA because that checkout was not
clean. `vendor/switchyard-source.json` records the maintained fork URL and commit, integrated NVIDIA
upstream URL and commit, whether tracked changes were included, and SHA-256 hashes for every imported
file. The core commit alone is not the identity of a dirty snapshot. See [release provenance](releases.md).
Untracked files, local credentials, scratch profiles and build output are not imported.

The import is a regular source snapshot, not a Git subtree merge: it does not create commits or alter
existing history. Commit the snapshot and its manifest together when the change is reviewed.

## Change and test Switchyard

```sh
cd ~/Projects/personal/NVIDIA
cargo build --locked --release -p switchyard-server
cargo test --locked -p switchyard-server
```

Run the tests for any other affected crates too. Commit reviewed server changes in NVIDIA first
and publish the commit to `eugenn/Switchyard` before using it in a public app release.
Then update the application copy explicitly:

```sh
cd ~/Projects/personal/switchyard-desktop
python3 scripts/update-switchyard.py
python3 scripts/update-switchyard.py --verify
./scripts/build-switchyard.sh
```

The default source is NVIDIA. `--source /path/to/checkout` supports another machine's checkout.
An explicit `--allow-dirty` imports tracked working-tree changes for development. Public releases
require a clean published core commit and reject dirty snapshots. The importer refuses to overwrite modifications to the
existing vendor snapshot; resolve them in NVIDIA and restore the imported copy before retrying.

The importer identifies remotes by URL, so both `origin` = NVIDIA / `fork` = your fork
and `upstream` = NVIDIA / `origin` = your fork work. It does not change remotes or
fetch. Fetch upstream intentionally before merging updates. `--upstream-ref`
overrides the default NVIDIA remote's `main` when importing another upstream line.

Run `python3 -m unittest discover -s scripts/tests -v` for importer and release-gate
regressions. These tests use disposable local Git repositories, never the real core checkout.

No reverse synchronization exists. If an app feature needs a server change, implement and test the
server change first in NVIDIA, import it, then implement the app integration.

## Build and run the copied server

```sh
cd ~/Projects/personal/switchyard-desktop
./scripts/build-switchyard.sh
build/switchyard-target/release/switchyard-server \
  --config configs/switchyard/smoke.toml --dry-run
```

The smoke profile validates configuration only; its upstream deliberately does not perform inference.
To run manually, supply an actual development profile and an unused loopback port:

```sh
build/switchyard-target/release/switchyard-server \
  --config "$HOME/Library/Application Support/switchyard-desktop/routes.toml" \
  --host 127.0.0.1 --port 4100
```

Stop app-owned routing first. A default generated profile needs LiteLLM on port 4101.
The app's Advanced executable override can test `NVIDIA/target/release/switchyard-server` explicitly.
Normal installed-app operation always chooses the bundled helper, independently of PATH.

## LiteLLM: original manual experiment

The existing NVIDIA workflow is preserved:

```sh
cd ~/Projects/personal/NVIDIA
uv run --project examples/litellm \
  --with 'litellm[proxy]==1.97.0' \
  --with 'fastapi==0.136.3' \
  litellm \
  --config scratch/codex-claude-router/litellm.yaml \
  --host 127.0.0.1 \
  --port 4001
```

This experiment's Switchyard profile must point to `http://127.0.0.1:4001/v1`.
The app uses 4101 instead, so the manual experiment can remain independent.
Before the first Xcode run, use `./scripts/prepare-xcode.sh` to build the snapshot
server and pinned Python/LiteLLM runtime. Unbundled debug builds resolve these
components from this checkout's `build/` directory and default to app ports
4100/4101. This also works when Xcode puts the executable in DerivedData.
The app never installs dependencies on launch or automatically selects the manual
4001 experiment. An explicitly saved external upstream remains editable under
**Advanced**. Complete `.app` bundles use only their own embedded runtime.
The supplied YAML uses LiteLLM's `chatgpt/` provider; it does not register the example's Switchyard
Python plugin. Therefore the application needs the standalone LiteLLM proxy dependencies, not an
editable Python installation of the NVIDIA checkout.

## Build the bundled LiteLLM runtime

```sh
cd ~/Projects/personal/switchyard-desktop
./scripts/build-litellm.sh
build/litellm-runtime/bin/python3.12 -I build/litellm-runtime/launcher.py --check

# Manual app-equivalent development proxy; complete ChatGPT device login first.
build/litellm-runtime/bin/python3.12 -I -u build/litellm-runtime/launcher.py --login
build/litellm-runtime/bin/python3.12 -I build/litellm-runtime/launcher.py \
  --config configs/litellm/development.yaml --host 127.0.0.1 --port 4101
```

The runtime contains a relocatable managed Python 3.12.10 distribution and pinned packages from
`runtime/litellm/requirements.lock`. `uv` is needed only while building. No home-directory virtualenv,
Homebrew Python, absolute pip entry-point shebang or checkout symlink is required at runtime.

To intentionally update dependency resolution, edit `requirements.in` and regenerate the lock:

```sh
uv pip compile runtime/litellm/requirements.in --python-version 3.12 \
  --generate-hashes --output-file runtime/litellm/requirements.lock
```

The lock pins orjson 3.11.6, satisfying LiteLLM's dependency floor. Its extension
is built from source with `MACOSX_DEPLOYMENT_TARGET=14.0`, because prebuilt wheels
can require macOS 15. This uses the build machine's Rust toolchain.
Packaging checks every native deployment target against macOS 14.

Keep LiteLLM and FastAPI at the requested versions unless compatibility is deliberately revalidated.
Generated runtime files are ignored build output. Rebuild the DMG after dependency changes.

## Verify integration

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export PATH="$PWD/build/switchyard-target/release:$PATH"
swift test
./scripts/build-dev-app.sh
./scripts/verify-bundle.sh build/switchyard-desktop.app
./scripts/create-dev-dmg.sh
```

Tests use temporary Codex files and mocks. Real-server checks use the copied binary on PATH.
A bundle check validates signatures, runtime dependencies, Switchyard dry-run and Python imports in a
minimal environment, then starts both packaged servers with a temporary HOME and checks health/model discovery without inference. Also mount the DMG, copy the app to a path containing spaces and verify it there.
Do not claim clean-account installation, authenticated inference or notarization based on unit tests.

Before publishing, test browser sign-in, Start, a real request from `codex --profile switch`,
closing/reopening the window, Stop, quit and crash recovery. Production signing credentials stay outside the repository.
