## Context

`mvp-codex-routing-wizard` provides a native macOS UI for generating a
Switchyard route configuration, starting `switchyard-server`, and patching the
user's Codex configuration. It currently builds an `.app` by copying a Swift
Package executable into a bundle and applying an ad-hoc signature.

The MVP is distributed directly as a DMG rather than through the Mac App
Store. Direct distribution permits the existing integration with
`~/.codex/config.toml` and bundled Switchyard/LiteLLM servers; it does not remove the need for safe lifecycle handling,
clear user consent, or a trusted Gatekeeper-compatible release artifact.

## Goals / Non-Goals

**Goals:**

- Let a user install one DMG artifact by dragging `switchyard-desktop.app` to
  Applications.
- Make a release artifact accepted by Gatekeeper without asking users to
  bypass its security prompts.
- Fail before `Start routing` when Codex setup or subscription-model discovery
  fails, a routing role is incomplete, or an external dependency is absent,
  inaccessible, incompatible, or would collide with the selected local port.
- Never leave the user unintentionally pointing Codex at a proxy that the app
  has stopped.
- Keep a user-started route alive after the main window closes and make that
  state visible and controllable through a status-bar icon.
- Avoid persisting or displaying credentials, authorization headers, prompts,
  source code, or other sensitive request content in switchyard-desktop logs.

**Non-Goals:**

- Mac App Store distribution, App Sandbox, security-scoped bookmarks, or
  App Store review support.
- Installing dependencies on the end-user machine at runtime. All server runtimes ship in the app.
- Login-item or `launchd` startup, or proxy persistence after the application
  process explicitly quits.
- Owning an OpenAI API key, signing a user into Codex, or supporting models
  outside the active Codex subscription.
- Promising production-grade Switchyard support while Switchyard remains
  pre-1.0.

## Decisions

1. **Keep Swift Package Manager for source builds; add a direct-release
   packaging pipeline.** Source development continues to use `swift build` and
   `swift test`. A release script creates a deterministic `.app` bundle with a
   checked-in `Info.plist`, version metadata, app icon, and all runtime
   resources. It then creates a DMG containing the app and an Applications
   alias. The release pipeline, rather than a developer's local Finder state,
   is the source of release artifacts.

2. **Differentiate local developer bundles from distributable releases.**
   Ad-hoc signing remains acceptable only for a local build. A public DMG must
   be signed with a Developer ID Application certificate, use the hardened
   runtime required by the notarization workflow, be submitted to Apple's
   notarization service, have the resulting ticket stapled, and pass local
   signature/Gatekeeper validation before it is published. Secrets and signing
   identities stay outside the repository.

3. **Bundle the complete routing stack.** Switchyard sources are imported from NVIDIA
   into `vendor/switchyard` with per-file checksums and a base commit. Build with `--locked`.
   Embed the native server in `Contents/Helpers` and a relocatable Python/LiteLLM runtime
   in `Contents/Resources/LiteLLM`. Pin LiteLLM 1.97.0 and FastAPI 0.136.3 with a hashed
   dependency lock. Sign all native extensions/libraries before sealing the app.
   The default chain is Switchyard :4100 -> LiteLLM :4101 -> ChatGPT. LiteLLM owns OAuth
   in its standard user directory. Show device-login instructions in the app, wait for
   readiness before changing Codex, and stop both processes on Revert. Never use an
   arbitrary PATH binary when a packaged helper is missing.

4. **Treat Start as an informed, reversible change across four boundaries.**
   Immediately before `Start routing`, the UI states the effective paths,
   host/port, selected algorithm and roles, and all side effects: it writes
   `routes.toml`, launches the local server, creates a timestamped backup, and
   changes the active Codex provider/model. The model assignments must come
   from authenticated Codex-subscription discovery. The existing
   backup-before-write ordering remains the rollback mechanism.

5. **Route in the background while switchyard-desktop remains alive.** Closing the
   main window does not terminate the application or proxy while routing is
   active. A status-bar icon remains visible and exposes status, reopen, Stop,
   and Revert controls. If the user explicitly quits while the app owns an
   active routing configuration, the app presents `Revert and Quit` and
   `Cancel`. `Revert and Quit` restores the captured Codex configuration before
   terminating the proxy. If restoration fails, the app remains alive and
   shows recovery instructions instead of silently leaving a dead proxy
   endpoint in the config. A force quit cannot be intercepted, so a later
   launch detects an active switchyard-desktop config plus backup and offers recovery
   before another Start.

6. **switchyard-desktop owns no user credential.** It does not ask for, persist, or
   log an API key. The default Switchyard configuration disables credential forwarding to LiteLLM.
   LiteLLM manages its own ChatGPT OAuth session; direct upstream overrides can forward credentials. Any captured
   subprocess output shown in the UI or written to a diagnostic file must
   redact authorization headers, bearer tokens, cookies, API-key-like values,
   prompts, and request bodies.

7. **The release includes user and legal documentation.** The DMG and project
   documentation state the macOS/Codex/Switchyard prerequisites, install and
   removal steps, supported lifetime of the proxy, the exact files changed,
   privacy/data-flow behavior, recovery steps, third-party notices, and an
   unaffiliated-brand disclaimer.

## Risks / Trade-offs

- **Bundled Python increases artifact size.** Package locked dependencies and validate
  relocation, native signatures and supported architecture before release.
- **Subscription model discovery can fail or change across Codex versions.**
  The release must fail closed, show refresh/remediation, and never fall back
  to model IDs that were not verified for the active subscription.
- **A forced termination can leave Codex configured for a stopped proxy.**
  Startup recovery reduces the damage but cannot make force quit atomic.
- **Forwarded request data is sensitive.** Even though switchyard-desktop does not
  own the credentials, the proxy handles them; misleading privacy messaging or
  unredacted diagnostics would be unacceptable.
- **Notarization needs Apple credentials and network access.** The packaging
  script must provide a clear failure rather than falling back to an
  unsigned/not-notarized public artifact.

## Open Questions

- What is the minimum supported `switchyard-server` version and the most
  reliable machine-readable compatibility check beyond `--dry-run`?
- What is the minimum supported Codex version and authenticated model-discovery
  interface for subscription accounts?
- Should the public MVP support only Codex CLI until Codex Desktop behavior is
  confirmed by the existing end-to-end verification tasks?
