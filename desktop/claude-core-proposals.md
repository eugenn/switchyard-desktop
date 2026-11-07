# Native Claude subscription integration: core follow-ups

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
