# Native Claude subscription integration: core follow-ups

> **Status, November 11:** the desktop app no longer uses the native subscription
> helper, the Claude Code plug-in or Claude Code sign-in. Claude Code now reaches the
> app's own server with an Anthropic API key, so everything below applies only if
> native subscription routing is brought back. The Composite compatibility issue at
> the end affected only that helper; the HTTP route is unaffected.

The desktop integration uses the unchanged `examples/claude` helper and mod from
the checked-in snapshot. Original Claude Code owns authentication, classifier
calls, completions and tools. Switchyard's Runner only selects a native model.
No subscription tokens are imported, proxied or persisted by the desktop app.

This is not a subscription-backed Anthropic transport for arbitrary clients of
the HTTP server on port 4100. Offering that would be a different feature; the
current desktop integration must not claim that it supports it.

Proposed work for the core owner in `../NVIDIA`, not implemented here:

- Port `examples/claude/src/main.rs` away from unconditional Unix process,
  signal and directory APIs and port the mod's Unix-only cleanup for Windows.
- Define a versioned native-client decision bridge if routing through the
  existing HTTP server is required. Claude Code must keep all authenticated
  model calls. Preserve session ordering, native classifiers, cancellation and
  model-only decision constraints; do not turn subscription tokens into an API.
- Expose a supported policy/capability contract for Claude routing. The desktop
  currently deliberately uses only the snapshot's shipped Composite template,
  rather than claiming parity with its thirteen HTTP-proxy strategies.
- Publish platform support and compatibility tests for the helper/mod before
  enabling Windows or claiming tested real-account support on macOS.

Core changes and publication remain with the core owner. Desktop code must not
edit the snapshot to implement these follow-ups.

## November 11 Composite compatibility

Core commit `f3744c82d` makes Composite's capable-first profile inject a planning
system prompt by default. The shipped `examples/claude/switchyard.toml` does not
disable it, so the helper rejects a capable selection with
`Routing must only select a model`. Reproduced against snapshot
`11acea2efba5e91f07208b7bf096e2e593623dc4` by running
`python3 desktop/scripts/smoke-claude.py`. Passthrough succeeds; Composite fails
after the native classifier selects capable. HTTP routing's 52 offline scenarios
still pass.

An explicit empty `routes.claude.stage.capable_system_prompt` does not resolve it:
the core still prepends an empty system instruction, violating the helper's
request-integrity check. That attempted desktop override was removed.

Proposed core follow-up: provide a supported way to disable Composite prompt
injection, apply it in the shipped Claude template, and add a native classifier
roundtrip regression check. Keep the helper's request-integrity check; Claude
must retain ownership of conversation instructions. No core code was changed.
The rebuilt desktop remains a development preview with this known Claude blocker.
