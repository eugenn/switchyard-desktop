# Contributing

Contributions are welcome through issues and pull requests. For a substantial
change, open an issue first so we can agree on the behavior and scope.

## Choose the repository

| Change | Repository |
| --- | --- |
| Swift UI, generated configuration, process lifecycle, integration tests, packaging | [switchyard-desktop](https://github.com/eugenn/switchyard-desktop) |
| Server behavior, routing algorithms, API, server tests | [Switchyard fork](https://github.com/eugenn/Switchyard) |

Never edit `vendor/switchyard` directly. A server change is reviewed and merged in
the core fork first; the desktop change imports that commit and updates
`vendor/switchyard-source.json` in the same PR. General improvements can also be
proposed to [NVIDIA upstream](https://github.com/NVIDIA-NeMo/Switchyard).

## Local development

Clone your fork and create a topic branch. Building the app does not require a
separate core checkout: the sources are already in `vendor/switchyard`.
See [README](README.md) for prerequisites and [development](docs/development.md)
for importing core changes and running integration checks.

Run the checks relevant to your change:

```sh
python3 scripts/update-switchyard.py --verify
python3 -m unittest discover -s scripts/tests -v
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
swift build -c release --product SwitchyardDesktopApp
```

For configuration, lifecycle or packaging changes, also build and smoke-test the
complete bundle with `./scripts/build-dev-app.sh release`.
Server changes need the affected crate tests in the core repository as well.

Tests must never resolve real user-owned paths. Use `UserDataLocations` and
injected stores, temporary fixtures and mock providers. Keep
`UserDataLocationsTests` passing. Do not use your real Codex account in automated
tests. Preserve app ports 4100/4101 and the independent manual experiment on
4000/4001. Keep LiteLLM 1.97.0 and FastAPI 0.136.3 pinned.

## Pull requests

Target `main`, keep the change focused, and describe the problem, resulting
behavior and checks actually run. Include screenshots for visible UI changes and
the core PR/commit for snapshot imports. Mention checks you could not run.
Do not include credentials, account files, inference logs or signing material.

External PRs run with a read-only token on GitHub-hosted runners; a maintainer
approves workflow execution for outside contributors. Approval to run CI is not
approval to merge. PRs need maintainer review and passing required checks. New
commits dismiss old approvals. We normally squash merge desktop PRs.

By submitting a contribution, you agree to license it under Apache-2.0, except
where an existing third-party license applies. Preserve copyright and license
notices. Modified upstream files must carry notices of your changes; make those
edits in the core repository before importing. No separate CLA is required.

Be respectful, discuss the code rather than the person, and follow
[our community guidelines](CODE_OF_CONDUCT.md). Report vulnerabilities using
[SECURITY.md](SECURITY.md).
