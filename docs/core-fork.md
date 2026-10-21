# Maintained Switchyard core

Upstream: https://github.com/NVIDIA-NeMo/Switchyard

Maintained fork: https://github.com/eugenn/Switchyard

Develop server behavior, algorithms, APIs and server tests in the core repository.
The maintainer's checkout is the sibling `../NVIDIA`; contributors may use another
location with `scripts/update-switchyard.py --source /path/to/core`.

Keep topic branches focused so generally useful fixes can be proposed upstream.
Periodically merge upstream into the maintained core branch, resolve conflicts
there and run the affected crate tests. Preserve published commits and release
tags; do not rebase history already referenced by desktop releases.

The current snapshot includes custom routing work and local changes in
`crates/libsy-llm-client/README.md`, `crates/libsy-llm-client/src/client.rs` and
`crates/switchyard-server/src/routing_log.rs`. The uncommitted client work includes
LiteLLM session headers; the routing-log work includes agent identity. This list
describes the remaining working-tree changes, not the full fork/upstream diff.
Use the manifest's `upstream_commit` and `commit` to inspect committed differences
in the core checkout, and its file hashes to identify the imported working tree.

Before the first clean public core release, review the complete upstream diff,
document the supported differences in the fork, and ensure changed upstream
files carry the required change notices. Desktop development can continue while
the snapshot is dirty; public desktop releases are blocked until a clean import.
