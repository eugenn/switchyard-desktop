"""Build a development-only runtime from the checked-in snapshot and pinned Python lock."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
DESKTOP = ROOT / "desktop"
BUILD = DESKTOP / "build"
DESTINATION = DESKTOP / "src-tauri/runtime"


def run(arguments, **kwargs):
    subprocess.run([str(argument) for argument in arguments], check=True, **kwargs)


def windows_requirements(source):
    lines = source.splitlines(keepends=True)
    result = []
    index = 0
    while index < len(lines):
        if lines[index].startswith("uvloop=="):
            while lines[index].rstrip().endswith("\\"):
                index += 1
            index += 1
        else:
            result.append(lines[index])
            index += 1
    return "".join(result)


def prepare_claude_plugin():
    if sys.platform != "darwin":
        raise SystemExit("The native Claude plugin helper is currently packaged only for macOS.")
    run([sys.executable, ROOT / "scripts/update-switchyard.py", "--verify"])
    snapshot = ROOT / "vendor/switchyard-source.json"
    if not (DESTINATION / "switchyard-source.json").is_file() or (DESTINATION / "switchyard-source.json").read_bytes() != snapshot.read_bytes():
        raise SystemExit("Prepare a matching bundled runtime before adding the Claude plugin.")
    destination = DESTINATION / "claude-plugin"
    if destination.exists():
        raise SystemExit(f"Claude plugin already exists at {destination}; move it aside before rebuilding.")
    target = subprocess.check_output(["rustc", "-vV"], text=True)
    target = next(line.split(": ", 1)[1] for line in target.splitlines() if line.startswith("host: "))
    target_name = target.replace("-", "_")
    target_dir = BUILD / "switchyard-target"
    environment = dict(os.environ, CARGO_TARGET_DIR=str(target_dir))
    environment[f"CARGO_TARGET_{target_name.upper()}_RUSTFLAGS"] = "-C link-arg=-mmacosx-version-min=14.0"
    environment[f"CFLAGS_{target_name}"] = "-mmacosx-version-min=14.0"
    environment[f"CXXFLAGS_{target_name}"] = "-mmacosx-version-min=14.0"
    run(["cargo", "build", "--locked", "--release", "--target", target, "-p", "switchyard-claude"], cwd=ROOT / "vendor/switchyard", env=environment)
    source = ROOT / "vendor/switchyard/examples/claude"
    with tempfile.TemporaryDirectory(prefix="claude-plugin-", dir=DESTINATION) as temporary:
        staged = Path(temporary) / "plugin"
        for relative in [".claude-plugin/plugin.json", "hooks/hooks.json", "hooks/register.mjs"]:
            target_file = staged / relative
            target_file.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source / relative, target_file)
        (staged / "bin").mkdir()
        helper = staged / "bin/switchyard-claude"
        shutil.copy2(target_dir / target / "release/switchyard-claude", helper)
        run(["codesign", "--sign", "-", "--force", helper])
        for name in ["LICENSE", "NOTICE"]:
            shutil.copy2(ROOT / "vendor/switchyard" / name, staged / name)
        if destination.exists():
            raise SystemExit(f"Claude plugin appeared at {destination}; it was not overwritten.")
        staged.rename(destination)
    print(f"Claude Code plugin staged at {destination}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reuse-python", action="store_true", help="macOS development only: copy the existing repo-local prepared Python runtime")
    parser.add_argument("--claude-plugin", action="store_true", help="Add the snapshot's native Claude Code plugin to an existing macOS runtime")
    args = parser.parse_args()
    if args.claude_plugin:
        if args.reuse_python:
            parser.error("--claude-plugin cannot be combined with --reuse-python")
        prepare_claude_plugin()
        return
    if sys.platform not in ("darwin", "win32"):
        parser.error("Build this runtime on macOS or Windows, not by cross-compiling.")
    DESTINATION.parent.mkdir(parents=True, exist_ok=True)
    if DESTINATION.exists() and any(item.name != ".gitkeep" for item in DESTINATION.iterdir()):
        raise SystemExit(f"Runtime already exists at {DESTINATION}. Move it aside before rebuilding; existing data is never deleted automatically.")
    run([sys.executable, ROOT / "scripts/update-switchyard.py", "--verify"])
    target_output = subprocess.check_output(["rustc", "-vV"], text=True)
    target = next(line.split(": ", 1)[1] for line in target_output.splitlines() if line.startswith("host: "))
    snapshot_path = ROOT / "vendor/switchyard-source.json"
    snapshot = json.loads(snapshot_path.read_text())
    if sys.platform == "darwin":
        run(["sh", DESKTOP / "scripts/build-switchyard.sh"])
        if not args.reuse_python:
            run(["sh", DESKTOP / "scripts/build-litellm.sh"])
        server = BUILD / "switchyard-target/release/switchyard-server"
        python_source = BUILD / "litellm-runtime"
    else:
        if args.reuse_python:
            parser.error("--reuse-python is only supported for the macOS development runtime.")
        server_target = BUILD / "switchyard-target"
        environment = dict(os.environ, CARGO_TARGET_DIR=str(server_target))
        run(["cargo", "build", "--locked", "--release", "-p", "switchyard-server"], cwd=ROOT / "vendor/switchyard", env=environment)
        server = server_target / "release/switchyard-server.exe"
        python_source = None
    with tempfile.TemporaryDirectory(prefix="switchyard-runtime-") as temporary:
        staged = Path(temporary) / "runtime"
        staged.mkdir()
        shutil.copy2(server, staged / server.name)
        if python_source:
            shutil.copytree(python_source, staged / "litellm", symlinks=True)
            python = staged / "litellm/bin/python3.12"
        else:
            downloads = Path(temporary) / "python-download"
            run(["uv", "python", "install", "3.12.10", "--install-dir", downloads])
            candidates = list(downloads.glob("cpython-3.12.10-windows-*-none"))
            if len(candidates) != 1:
                raise SystemExit("Could not uniquely locate the downloaded Windows Python runtime.")
            shutil.copytree(candidates[0], staged / "litellm", symlinks=True)
            python = staged / "litellm/python.exe"
            requirements = Path(temporary) / "requirements-windows.lock"
            requirements.write_text(windows_requirements((DESKTOP / "runtime/litellm/requirements.lock").read_text()))
            run(["uv", "pip", "install", "--python", python, "--target", staged / "litellm/Lib/site-packages", "--require-hashes", "-r", requirements])
        shutil.copy2(DESKTOP / "runtime/litellm/launcher.py", staged / "litellm/launcher.py")
        sandbox = Path(temporary) / "check-user"
        sandbox.mkdir()
        environment = dict(os.environ, HOME=str(sandbox), USERPROFILE=str(sandbox),
                           APPDATA=str(sandbox), LOCALAPPDATA=str(sandbox), XDG_CONFIG_HOME=str(sandbox),
                           CODEX_HOME=str(sandbox / "codex"), CHATGPT_TOKEN_DIR=str(sandbox / "chatgpt"),
                           PYTHONDONTWRITEBYTECODE="1")
        run([python, "-I", staged / "litellm/launcher.py", "--check"], env=environment)
        shutil.copy2(snapshot_path, staged / "switchyard-source.json")
        (staged / "runtime-manifest.json").write_text(json.dumps({
            "target": target,
            "litellm": "1.97.0",
            "fastapi": "0.136.3",
            "python": "3.12.10",
            "snapshotCommit": snapshot["commit"],
            "snapshotManifestSha256": hashlib.sha256(snapshot_path.read_bytes()).hexdigest(),
            "developmentOnly": True,
            "dirtySnapshot": snapshot["includes_tracked_worktree_changes"],
        }, indent=2) + "\n")
        shutil.copytree(staged, DESTINATION, symlinks=True, dirs_exist_ok=True)
    print(f"Prepared development runtime for {target}: {DESTINATION}")
    print("Not a release artifact: signing, license collection and release snapshot gates are still required.")


if __name__ == "__main__":
    main()
