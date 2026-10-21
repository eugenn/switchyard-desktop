# Server integration — 2026-09-16

Validated Switchyard `8ba5ea033b9d2417c55710ea482b5bf3c8d577c9` with switchyard-desktop.
Imported 572 tracked files through `scripts/update-switchyard.py`; the snapshot and
manifest match the NVIDIA checkout. The reference executable was the existing
`NVIDIA/target/debug/switchyard-server` built on September 16. The bundled release
helper was built separately from the imported snapshot.

## Compatibility fix

The new server leaves Codex's model catalog and instructions intact by returning
an empty `models` array alongside its standard `data` model inventory. It removed
the route field `reasoning_summaries`.

The initial Swift run reproduced a startup-blocking failure:
`anOptedOutRouteStillPassesTheRealDryRun` failed with
`unknown field reasoning_summaries`.

switchyard-desktop now applies a summary opt-out through Codex's
`model_reasoning_summary = "none"` setting. The default leaves the user's
existing preference alone, and the opt-out is stated only in the generated
profile, so it applies to routed sessions and disappears with the file. This setting
is documented in the [Codex configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference).
Old JSON profiles and generated native routes move the removed field into the
client preference while retaining native prompts and routing options. The UI no
longer advertises or generates the removed server field.

## Results

- 293 Swift tests passed, including real-server validation and process lifecycle,
  summary opt-out, configuration restoration, and legacy preference migration.
- 28 routing scenarios passed against the snapshot release helper and the NVIDIA
  debug helper with identical selected models and judge-call counts. These cover
  Chat Completions, Responses, classifier triggers, fallback, native prompts,
  Stage, Auto, Composite, Escalation, Advisor, subagents, Random and Passthrough.
- 12 Simple preset scenarios passed on each helper, including swapped roles and
  target/reviewer prompts.
- `scripts/build-dev-app.sh` produced `build/switchyard-desktop.app`.
- Bundle validation passed: signatures, standalone dependencies, server dry-run,
  Python runtime, LiteLLM 1.97.0, FastAPI 0.136.3 and deployment targets for 56
  native files.
- The expanded bundle smoke test passed buffered and streaming Responses through
  packaged Switchyard and LiteLLM to a local mock provider. Model discovery,
  selected-model headers, request/error counters and the durable routing log's
  Codex origin were verified with a temporary home and disposable ports.

Logs are in `build/integration-20260916/`. The initial failure is retained in
`swift-tests.log`; the successful run is `swift-tests-fixed.log`. Bundle results
are in `app-bundle.log`.

## Scope

No external model inference or account login was performed. The user's Codex
configuration and independent services on ports 4000/4001 were not changed. This
is a local ad-hoc-signed application build; no DMG, notarization or Git commit was
created. Release compilation reports an existing `String(cString:)` deprecation
warning in `LeftoverProcessReclaimer.swift`.
