# GitHub maintenance

Repository: https://github.com/eugenn/switchyard-desktop

## Repository settings

The repository is public and accepts issues and pull requests from forks.
Desktop PRs use squash merge with the PR title/body as the commit message.
Merged topic branches are deleted automatically, and the update-branch button is
enabled. The core fork keeps its own upstream-merge history.

Secret scanning and push protection are enabled. Private vulnerability reporting
is enabled through the repository's Security tab; `SECURITY.md` links to it.

`main` requires:

- One approving review, including the code owner when applicable.
- Fresh approval after new commits and resolved review conversations.
- Up-to-date `Snapshot checks` and `macOS tests`, provided by GitHub Actions.
- Linear history, with force pushes and branch deletion disabled.

Administrator bypass is intentionally available for the sole maintainer,
including bootstrapping CI and handling the maintainer's own PRs, which cannot
self-approve. Use the normal review/check path for external contributions.

## CI and outside contributors

`.github/workflows/ci.yml` runs on PRs targeting `main`, pushes to `main`, and manual
dispatch. Required check names are stable and have no path filters. The snapshot
job runs integrity checks, importer/release-gate regressions and shell syntax
checks. The macOS job selects Xcode 26.3 on `macos-15`, runs Swift tests (including
`UserDataLocationsTests`) and builds the single application product. It does not
notarize or publish binaries.

GitHub Actions has read-only default workflow permissions and cannot approve PRs.
All outside contributors require maintainer approval before fork workflows run.
Review code and workflow changes before approving execution. Checkout uses a
pinned action commit and does not persist credentials. Use GitHub-hosted runners;
never run external PR code on the maintainer's Mac or expose signing/account
secrets through `pull_request_target`. Dependabot proposes GitHub Actions updates.

Complete app-bundle smoke tests remain a maintainer validation step for relevant
changes; the basic PR workflow is not evidence of signing, notarization or a
tested DMG. See [release validation](releases.md).

## Maintaining required checks

Keep branch-protection check names synchronized with the workflow's job names.
After changing CI, verify both jobs on the exact pushed commit. Pending or skipped
checks are not evidence that the code passed. Do not disable required checks to
work around a failing workflow; fix the failure and verify the next run.

The initial community/CI setup is bootstrapped with the maintainer's administrator
bypass because its required workflow does not exist on the default branch until
the first push. Subsequent external contributions use the normal PR process.
