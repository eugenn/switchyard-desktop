# Switchyard routing parity

The app uses the same Rust algorithms, prompt assets, request translation and session state as
`~/Projects/personal/NVIDIA`. There is no Swift routing implementation. The server is
built only from `vendor/switchyard`, imported by `scripts/update-switchyard.py`.

## Findings, 2026-09-13

The 562 imported files already matched the source working tree. The differences were in application
configuration and configuration restoration:

| Previous application behavior | Current behavior |
| --- | --- |
| Only Stage and Custom classifier were selectable | Every native route type is represented; the optional prefill build requirement is explicit |
| Classifier forced `user_turn` | Defaults to native `every_request`; all three triggers are selectable |
| Judge budget forced to 512 tokens | Uses the native 4096-token default |
| Judge context window forced to 6 messages | Uses the native unset default; configurable in native options |
| Custom prompt told the judge to prefer the least powerful role and bias uncertainty toward the fallback | Uses the source custom-mode example instructions with the user's role descriptions; fallback remains deterministic server policy |
| No built-in capability, escalation or advisor prompt path | Omitting prompt overrides uses the packaged server prompts verbatim |
| No target system prompt or request options | Native target fields are preserved |
| Judge had to be one of the serving targets | Separate discovered judge model and request options are supported |
| Restoring generated TOML reconstructed routing from model labels | Modern generated configurations retain prompts, thresholds, schemas, groups, triggers and nested policies |

The observed saved route used `llm_classifier`, `mode = "custom"`, and `classify_trigger = "user_turn"`.
That holds a selected model through tool continuations until a new user message. It is not the same
as selecting a model for each request. A verdict the route cannot parse or resolve selects the
configured fallback; since the 0.3.0 snapshot an HTTP failure of the judge call itself stops the
request after its retries instead. Actual provider verdicts are model-dependent; changing the
trigger does not guarantee a model change on every request.

`targets.*.system_prompt` is an instruction for the serving model, not a classifier description.
The custom role descriptions are incorporated into the custom judge prompt. The native capability
prompt instead forecasts `p_solve` and a capability boundary; the Rust threshold policy selects the
tier. Stage routing reads tool history, so it does not use role descriptions to estimate task difficulty.

Native options replace the entire algorithm body rather than merging hidden app defaults into it.
Use target keys shown in the editor, and qualify nested tables as `[routes.main.classifier]`,
`[routes.main.stage]`, `[routes.main.subagents]`, etc. Target options can use native inline tables
such as `extra_body = { chat_template_kwargs = { enable_thinking = false } }`.
Additional native targets can supply independent subagent workers or model-group fallback candidates.
They are included in discovery validation, the bundled gateway inventory, persistence and restoration.

Older JSON profiles with no stored trigger adopt `every_request` when loaded. Explicit native TOML
triggers are preserved. Existing configuration on disk takes effect only after starting/applying
routing with the updated application. This change does not rewrite Codex settings or the independent
4000/4001 experiment during development.

## Verification

```sh
python3 scripts/update-switchyard.py --verify --check-source
scripts/build-switchyard.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
python3 scripts/verify-routing-parity.py \
  --reference-server ~/Projects/personal/NVIDIA/target/release/switchyard-server
```

The final application suite passed 218 tests. The parity harness uses production Swift configuration generation, the real bundled server, a
local mock Responses upstream, and disposable ports. It checks 28 scenarios: Chat Completions and
Responses ingress, all classifier triggers, missing session identity, invalid verdict fallback,
Stage/Auto escalation and de-escalation, capability thresholds, Composite signal overrides,
Escalation latching, Advisor approval, optional Stage classifier, subagent passthrough, target system
prompts, weighted Random and Passthrough. All standard presets also pass the real server dry-run,
including No-op. It checks the complete packaged judge prompts on the actual upstream requests.
With `--reference-server`, it compares the selected models and judge-call counts against NVIDIA.

The core source test run passed 289 libsy tests, 53 runner unit tests and 3 runner integration tests.
The broader server run has one pre-existing failure:
`responses_stream_error_does_not_emit_success_terminal_events`. It expects `response.failed` while
the source emits a generic `error` event. This is outside routing configuration and was not changed;
both snapshots have the same implementation.

The optional prefill route requires a matching feature-enabled server and model assets. The standard
build has no prefill runtime; its native configuration rejection is preserved. No fake substitute or
silent fallback is provided.

The local app bundle is built with `scripts/build-dev-app.sh`. Bundle verification checks the
bundled helper, Python runtime, LiteLLM 1.97.0, FastAPI 0.136.3, macOS deployment targets, signature
integrity and an isolated gateway/server startup smoke test.

## Findings, 2026-09-19 (Switchyard 0.3.0 snapshot)

Imported `53a68031` over `8ba5ea03`: 64 server commits, workspace version 0.2.0 to 0.3.0. Two
generated-configuration rules changed how this app has to write `routes.toml`, and both are now
covered by the offline harnesses.

| Server change | Effect on switchyard-desktop |
| --- | --- |
| A route refuses one model id reached through two `[llm_clients]` entries | The judge on its own LiteLLM entry — every direct ChatGPT classifier profile — asks for the same model under a published name of its own (`judge-<model>`), which the bundled LiteLLM maps back to the real model |
| One target per model id on a client; two that disagree on `reasoning_effort` or `extra_body` are refused | A judge repeating a target's model keeps its own settings where the bundled LiteLLM serves it, and otherwise runs as that target, which the generated file states above `models.judge` |
| Route capabilities are enforced, not only advertised: `tool_calling`, `reasoning` or `vision` set to `false` reject the matching input with HTTP 400 before dispatch | Generated routes declare `true` or leave the key unset, so nothing is restricted. A native route body that sets one to `false` now rejects those requests |
| New `timeout_ms` on an `[llm_clients]` entry bounds attempts, retries and the whole response | Not generated; judge and answer calls keep waiting as before. Available in native options, and the judge can take its own entry |
| An HTTP client failure stops routing after retries, and a deadline returns `504` | A judge that fails now surfaces an error rather than silently serving the fallback |
| Responses continuations are pinned by id when a route's answer targets use different `[llm_clients]` entries: a stored `previous_response_id` or `conversation` returns to the model that served it, without a judge call | Generated routes serve every answer target through one client — a judge-only client does not count — so routing is unaffected. A native body with answer targets on separate clients takes the pinning, and with it `503 response_state_limit_exceeded` at capacity and `409 response_state_conflict` on a reused id, both counted in `/v1/stats` `total_errors` |
| Streamed calls are recorded by their final outcome, and a fallback call is attributed to each candidate | Statistics show more errors and more per-model requests for the same traffic than the 0.2.0 snapshot did |
| Codex spawned threads count as sub-agent work (`thread_spawn` with `thread_source = subagent`) | A native `[routes.main.subagents]` policy now also catches Codex's spawned threads |
| The default classifier input excludes tool calls, tool results and reasoning | Classifier routes judge on user content, so verdicts are steadier through tool continuations |

`/v1/stats`, the routing log and the `--config`/`--dry-run` interfaces are unchanged, so the
statistics window, log reader and validation step needed no changes.

## Findings, 2026-10-09 (Switchyard refresh)

Imported 647 tracked files from NVIDIA at `c6bdef7755bbb8efa63f8b251b7305a38b69344c`,
including the existing tracked routing-log agent-identity changes. The manifest records
the complete working-tree snapshot; the bundled server is built from that inventory.

| Server change | Effect on switchyard-desktop |
| --- | --- |
| Stage/Auto recognizes inspection shell commands and ignores failure-like text retrieved successfully from files | Reading a log containing a fatal error no longer escalates the route; an executed command with the same error still does |
| Plan/Execute accepts `tool_semantics` and retains execution state after history compaction | Native route options can name custom mutation tools; execution stays on Efficient after the mutation disappears from the request history |
| Capability routing supports System One decision clients and targets | Included in the server snapshot; switchyard-desktop's generated presets continue to use LLM judges, and the UI does not configure decision clients |
| Decision calls participate in server observations and stats; request translation and streaming instrumentation are updated | The existing stats API, routing-log reader and process launch flags remain compatible |

The expanded offline harness passes 38 scenarios across Chat Completions and Responses.
New checks use production Swift-generated Stage/Auto and Plan/Execute configurations, verify
the planning prompt on the upstream wire, and cover custom mutation tools and execution after
history compaction. All provider traffic
in these checks goes to disposable loopback mock servers.
