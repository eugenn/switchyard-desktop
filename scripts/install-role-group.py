#!/usr/bin/env python3
"""Merge a role-group file into the app's role library.

The app has no file import: `~/Library/Application Support/switchyard-desktop/role-library.json`
is written only by the roles screen. A group kept in `configs/role-groups/` is
therefore inert until it is merged in, and this script is that step.

Roles and groups are matched by id: an incoming one replaces the stored one and
anything the file does not mention is left alone, so a library holding the
user's own roles keeps them. The library is backed up before it is rewritten.

The app reads the library once at launch and rewrites the whole file when the
roles screen saves, so a merge while it is open would be overwritten without
warning. Both that and a running route are refused rather than worked around.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import shutil
import socket
import subprocess
import sys
from pathlib import Path

LIBRARY = (
    Path.home() / "Library" / "Application Support" / "switchyard-desktop" / "role-library.json"
)
# Switchyard and LiteLLM, as the app starts them.
ROUTING_PORTS = (4100, 4101)


def port_in_use(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            probe.bind(("127.0.0.1", port))
        except OSError:
            return True
    return False


def blockers(library: Path) -> list[str]:
    """Reasons a merge now would be lost or would fight a running route."""
    found: list[str] = []
    support = library.parent

    try:
        records = json.loads((support / "managed-processes.json").read_text())
    except (OSError, ValueError):
        records = []
    if records:
        names = ", ".join(sorted({str(record.get("name", "?")) for record in records}))
        found.append(f"switchyard-desktop still records managed servers ({names}).")

    if (support / "active-routing.json").exists():
        found.append("Routing is active: stop it in the app before changing roles.")

    for port in ROUTING_PORTS:
        if port_in_use(port):
            found.append(f"Port {port} is in use, so a route is probably running.")

    try:
        running = subprocess.run(
            ["pgrep", "-f", "switchyard-desktop[.]app|SwitchyardDesktopApp"],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        running = None
    if running is not None and running.returncode == 0 and running.stdout.strip():
        found.append(
            "switchyard-desktop is open. It holds the library in memory and would "
            "overwrite this merge on its next save — quit it first."
        )

    return found


def upsert(stored: list[dict], incoming: list[dict], label: str) -> list[str]:
    """Replace by id, append what is new. Returns a line per change."""
    index = {item["id"]: position for position, item in enumerate(stored)}
    changes: list[str] = []
    for item in incoming:
        name = item.get("name", item["id"])
        if item["id"] in index:
            if stored[index[item["id"]]] != item:
                stored[index[item["id"]]] = item
                changes.append(f"replaced {label} {name}")
        else:
            stored.append(item)
            changes.append(f"added {label} {name}")
    return changes


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("group", type=Path, help="role-group JSON to install")
    parser.add_argument("--library", type=Path, default=LIBRARY, help="library to merge into")
    parser.add_argument("--dry-run", action="store_true", help="report the changes, write nothing")
    parser.add_argument(
        "--force", action="store_true",
        help="merge even while the app or a route is running (the app may overwrite it)",
    )
    args = parser.parse_args()

    incoming = json.loads(args.group.read_text())
    if not isinstance(incoming.get("roles"), list) or not isinstance(incoming.get("groups"), list):
        print(f"{args.group} is not a role library: it has no roles and groups.", file=sys.stderr)
        return 1

    reasons = blockers(args.library)
    if reasons and not args.force:
        print("Refusing to merge:", file=sys.stderr)
        for reason in reasons:
            print(f"  - {reason}", file=sys.stderr)
        print("Stop routing and quit switchyard-desktop, or pass --force.", file=sys.stderr)
        return 1
    for reason in reasons:
        print(f"warning: {reason}")

    if args.library.exists():
        library = json.loads(args.library.read_text())
    else:
        # Nothing saved yet: the app writes its shipped roles on the first save,
        # and mergeShippedRoles() adds them to whatever this leaves behind.
        library = {"version": 1, "roles": [], "groups": [], "hiddenBuiltInIDs": []}

    changes = upsert(library.setdefault("roles", []), incoming["roles"], "role")
    changes += upsert(library.setdefault("groups", []), incoming["groups"], "group")

    # A shipped role the user removed must not come back through an import that
    # happens to carry it.
    hidden = set(library.get("hiddenBuiltInIDs", []))
    restored = hidden.intersection(item["id"] for item in incoming["roles"])
    if restored:
        library["hiddenBuiltInIDs"] = sorted(hidden - restored)
        changes.append(f"unhid {len(restored)} built-in role(s) this file provides")

    if not changes:
        print(f"{args.library} already matches {args.group}.")
        return 0

    for change in changes:
        print(f"  {change}")
    if args.dry_run:
        print("Dry run: nothing written.")
        return 0

    library["savedAt"] = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    if args.library.exists():
        stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        backup = args.library.with_name(f"{args.library.name}.bak-{stamp}")
        shutil.copy2(args.library, backup)
        print(f"Backed up {args.library.name} to {backup.name}.")
    args.library.parent.mkdir(parents=True, exist_ok=True)
    args.library.write_text(json.dumps(library, indent=2, sort_keys=True, ensure_ascii=False) + "\n")
    print(f"Merged {args.group} into {args.library}.")
    print("Open switchyard-desktop, select the group in the role library, then Use saved setup.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
