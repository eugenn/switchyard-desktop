# Application status and acceptance

## Single implementation

As of November 7, 2026, `desktop/` is the only application implementation.
The Swift sources, tests, package manifest and app/DMG scripts have been removed.
This is a source transition, not a claim that all former features are complete.
Previously published installers remain historical. New installer generation is
explicitly disabled until release acceptance is complete.

## Status ledger

| Area | Current implementation | Remaining acceptance |
| --- | --- | --- |
| Routing | 13 strategies, native policy editing, 2-6 Custom targets, per-target options and subagents | Optional Prefill requires a different server feature build. |
| Roles | 18 built-in roles, CRUD/reset/search/tags/groups and group drafts | Native UX and accessibility acceptance. |
| Jev / TypeSafe | Capability, Custom and Composite decisions; OS key vault | Real vault/account acceptance. |
| Codex models | Explicit CLI discovery, executable override, cached metadata and effort/context checks | Real-account/platform acceptance. |
| Saved setups | Explicit draft import/export, legacy JSON compatibility | No automatic account/history migration; missing legacy group names use placeholders. |
| Codex profile | Temporary switch.config.toml on Start, unchanged-profile removal on Stop, rollback | Forced-quit reconciliation and startup cancellation. |
| Runtime | Bundled snapshot/Python, sign-in, readiness and owned children | Native Windows runtime and clean-machine acceptance. |
| Claude Code | Anthropic API key in the system vault, a Claude route on the local server, copyable launch command | Windows launch command; real-key conversation (tools, streaming, thinking) pending. |
| Activity | Live counters and bounded searchable request records | Full charts, cost/context/session and flow aggregation. |
| Host integration | Tauri window and normal-exit cleanup | Tray/menu/preferences, guarded exit and single-instance/crash recovery. |
| Distribution | Tauri is the only packaging path; installer generation disabled | Licensing, signing, updates and native installer acceptance. |

## Safety boundaries

- Preserve preview data paths under `switchyard-desktop/cross-platform`.
- All user paths go through `UserDataLocations`; tests inject stores and vaults.
- Use app ports 4100/4101 and ephemeral test ports. Never reclaim foreign listeners
  or touch the independent 4000/4001 experiment.
- Preserve foreign Codex profiles and symlinks. A regular file selecting the
  Switchyard provider is treated as stale on Start; Stop preserves unrelated edits.
- TypeSafe keys use Keychain/Credential Manager. LiteLLM OAuth tokens still use
  app-private files and need further release security work.
- Keep core changes out of this repository's UI work and never edit vendor.
- External PRs receive no signing credentials or account data.

See [application checks](../desktop/README.md#validation) and
[release gates](releases.md). Offline tests do not prove real-account, Windows,
visual, accessibility or installer acceptance.
