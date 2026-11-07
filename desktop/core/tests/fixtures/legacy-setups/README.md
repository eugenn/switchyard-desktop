# Legacy setup fixtures

Synthetic exports captured on November 7, 2026, before removing the macOS-only
implementation. No account, credential, user path or real conversation was used.

There are 29 setup JSON/TOML pairs: 13 presets, 13 native policies, and three
Jev configurations. `roles.json` captures the 18 built-in roles. The TOML files
are independent expected outputs; do not regenerate them from the importer.

`cargo test -p switchyard-desktop-core --test legacy_setup_import` checks these
fixtures without requiring the removed application or its toolchain.
