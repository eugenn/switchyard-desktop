# Development workflow

## One application

`desktop/` contains the only UI and application shell: React/TypeScript, a Rust
library, and Tauri. The previous Swift package, application, tests and packaging
entry points are removed. Do not restore a parallel implementation.

Start with [the application guide](../desktop/README.md). Native development uses
`npm run desktop`; `npm run dev` is only a browser preview. Build Switchyard from
`vendor/switchyard`, never from PATH or the sibling core checkout implicitly.

## Core ownership and imports

All server work starts in `../NVIDIA`. Desktop tasks may propose core changes in
Markdown, but must not implement, commit or push them there. The maintainer
reviews and publishes core changes, then imports them explicitly:

```sh
python3 scripts/update-switchyard.py --source ../NVIDIA
python3 scripts/update-switchyard.py --verify
```

Use `--allow-dirty` only for intentional development snapshots. Public releases
must pass `--verify --release --check-published`. Keep the manifest together with
the snapshot: fork commit and integrated NVIDIA commit are separate identities.
No reverse synchronization exists. Never edit vendor sources directly.

## Prepare the runtime

From the repository root:

```sh
cd desktop
npm ci
npm run runtime
npm run desktop
```

On macOS, preparation calls the retained `scripts/build-switchyard.sh` and
`scripts/build-litellm.sh` helpers. Those helpers are runtime builders, not
application packagers. On Windows the preparation script builds the snapshot
and stages native Python. The prepared runtime is ignored build output.
Preparation refuses to overwrite an existing runtime. Move an obsolete runtime
aside deliberately before rebuilding; never remove account directories.

LiteLLM 1.97.0, FastAPI 0.136.3 and Python 3.12.10 remain pinned in
`runtime/litellm/requirements.lock`. `uv` and compiler tools are build-time
requirements; nothing is installed at application startup.

## Test without accounts

See [validation commands](../desktop/README.md#validation). Tests inject temporary
user locations and mock providers. The checked-in legacy setup fixtures were
exported before removing the previous app and are tested entirely in Rust.
The routing harness generates configurations using production Rust code.

The app uses ports 4100/4101. Integration tests use ephemeral loopback ports.
Do not stop unrelated processes to free ports. The independent manual experiment
on 4000/4001 is outside the app's lifecycle and must remain untouched.

## User data and migration

Keep existing preview data under the `switchyard-desktop/cross-platform` support
directory. Resolve user-owned paths only through `UserDataLocations`; tests must
use injected stores and vaults as well. Setup import is explicit and creates a
draft, not an automatic account or file migration. Do not delete old app data,
credentials or Codex files as part of source cleanup.

## Packaging

Installer generation is disabled in the Tauri configuration while release
acceptance is incomplete. Old DMGs are not builds of this code. See
[release requirements](releases.md); removing the retired implementation does
not waive provenance, licensing, platform validation or signing gates.
