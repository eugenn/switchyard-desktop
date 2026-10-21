# Application experience

`switchyard-desktop` opens the Statistics window on launch. **Routing config** opens
its setup wizard. Both windows use the same `WizardModel`, routing profile and
process lifecycle. Opening either window does not start or stop routing.
The app provides one executable, `SwitchyardDesktopApp`, and one packaged app,
`switchyard-desktop.app`.

## Setup wizard

The setup wizard has three steps, because reading the Codex setup and listing the models it
exposes answer one question: **Codex account** shows the setup checks beside the
models they produced, **Routing** chooses the algorithm and fills its targets, and
**Review & start** shows the route, what Start changes on this Mac, and the
generated file. The step rail is navigable: any step the current one has already
cleared is a button, so a finished profile is edited without walking the flow.

The routing step keeps the five routes most setups compare in the left column and
folds the remaining Switchyard routes behind **More algorithms**, expanded
automatically when one of them is selected. Everything Switchyard decides per
request — the classifier target, the fallback target, a separate judge model and
how often classification runs — is grouped into one **Routing decisions** panel,
and native TOML editing stays behind a single disclosure.

The review step leads with the route and its prerequisites, lists the four changes
Start performs as rows with their paths, and keeps `routes.toml` and the connection
fields behind disclosures. The acknowledgement that gates Start sits in the footer
beside the button, and the footer repeats a blocker only when the acknowledgement
is not the thing missing.

## Roles and saved setups

The role library retains the built-in ladder, everyday work, architecture,
execution and review roles, together with custom roles and project groups.
Role IDs and saved routing profiles are preserved. The app uses the shared
Application Support directory and the `switchyard-desktop` Codex profile.

## Verification

`swift test` covers profile generation, saved setup restoration, model discovery,
role editing, user-data sandboxing and process lifecycle. The offline routing
parity harness checks generated configurations against the snapshot server.

Render the setup wizard with fixture models and isolated test data:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
SWITCHYARD_DESKTOP_RENDER_SETUP="$PWD/build/setup.png" \
swift test --filter renderWizardForVisualReview
```

This writes an image for each of the three setup steps. The roles editor can
be rendered with `SWITCHYARD_DESKTOP_RENDER_ROLES` and
`swift test --filter renderRolesEditorForVisualReview`.
