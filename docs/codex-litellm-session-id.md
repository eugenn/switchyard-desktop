# Forward the Codex session ID to LiteLLM

Codex CLI 0.167.0 sends `session-id` and `thread-id`. An offline request through
the installed Codex, Switchyard build 4, and LiteLLM 1.97.0 reached LiteLLM
without `x-litellm-session-id`. PR #1001 forwards that header when the caller
supplies it. The runner's `extra_headers` configuration only sets fixed values.

## Configuration

`forward_codex_session_id` is an opt-in setting on the Switchyard HTTP backend.
The desktop enables it for clients that use the bundled LiteLLM gateway when
the selected server accepts the setting. The server default is `false`.

The Switchyard LLM client preserves a caller-supplied `x-litellm-session-id`.
When that header is absent and the option is enabled, it copies the nonempty
inbound `session-id` into `x-litellm-session-id`. Credential forwarding remains
controlled separately by `forward_auth`.

## Verification

1. Test the core with the option off and on. Cover an existing LiteLLM header,
   a missing or empty source ID, and `forward_auth = false`.
2. Import the updated core snapshot and rebuild the desktop bundle. Verify that
   the generated configuration enables the setting for the managed gateway.
3. Run Codex against the built Switchyard and bundled LiteLLM with an offline
   mock provider, temporary configuration, and disposable loopback ports.
   Observe the original `session-id` on ingress to Switchyard and the resulting
   `x-litellm-session-id` on ingress to LiteLLM. Assert that they match.
4. Send two turns in one Codex conversation and a turn in a new conversation.
   Assert stable IDs within a conversation and distinct IDs across conversations.
   Exercise a buffered request separately and verify that an explicit
   `x-litellm-session-id` takes priority.
