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

The current snapshot imports maintained fork commit
`b2ab2ed72f3388fc9946f315e32e934737cc46a1` without tracked working-tree changes.
It includes the fork's routing work, LiteLLM session headers, agent identity in
routing logs, and the latest integrated upstream changes. Use the manifest's
`upstream_commit` and `commit` to inspect committed differences in the core
checkout, and its file hashes to verify the imported sources.

Before the first clean public core release, review the complete upstream diff,
document the supported differences in the fork, and ensure changed upstream
files carry the required change notices. Public desktop releases require a clean
import whose recorded commit is published in the maintained fork.
