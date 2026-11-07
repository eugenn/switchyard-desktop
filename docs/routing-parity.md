# Routing validation

The app generates configuration in `desktop/core`; algorithms and prompts remain
in the imported Switchyard snapshot. React does not reimplement server routing.

From `desktop/`:

```sh
cargo test --locked -p switchyard-desktop-core
python3 scripts/verify-setup-import.py
python3 scripts/verify-routing-parity.py
npm run test:runtime
```

The setup test uses 29 checked-in synthetic legacy exports and an 18-role catalog.
It verifies import against independently captured TOML, with no old toolchain.
The routing harness uses Rust-generated TOML, a local mock provider and ephemeral
ports to test Chat/Responses behavior, prompts, target identity and Jev decisions.
The runtime smoke also includes the prepared Python/LiteLLM gateway.

These checks do not use real accounts or prove Windows-native execution,
production signing, subscription access or all UI behavior. Consult the command
output for actual results; do not treat historical test counts as current passes.
