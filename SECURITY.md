# Security reports

Report vulnerabilities privately through
[GitHub private vulnerability reporting](https://github.com/eugenn/switchyard-desktop/security/advisories/new).
Do not include credentials, account files, private prompts or inference logs.
Provide the app version or source commit, operating system, reproduction steps
using synthetic data, and expected/actual behavior.

The active implementation is the Tauri client on `main`. Old Swift installers
are retired and are not builds of the current source. This is a community
project with no guaranteed response time; installer and credential-security
acceptance remains incomplete. See [release gates](docs/releases.md).

For a bundled-core issue, include the commit and provenance from
`vendor/switchyard-source.json` or the prepared runtime's copy. We will coordinate
with the maintained core fork or NVIDIA upstream as appropriate. Do not disclose
a vulnerability in a public issue or PR before coordination.
