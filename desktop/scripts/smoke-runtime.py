"""Exercise the staged runtime offline with the existing desktop integration harness."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, default=ROOT / "desktop/src-tauri/runtime")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("The existing bundle smoke harness is macOS-only. Windows runtime smoke is still required.")
    runtime = args.runtime.resolve()
    with tempfile.TemporaryDirectory(prefix="switchyard-cross-platform-smoke-") as directory:
        app = Path(directory) / "smoke.app"
        resources = app / "Contents/Resources"
        helpers = app / "Contents/Helpers"
        resources.mkdir(parents=True)
        helpers.mkdir()
        os.symlink(runtime / "litellm", resources / "LiteLLM", target_is_directory=True)
        shutil.copy2(runtime / "switchyard-server", helpers / "switchyard-server")
        subprocess.run([sys.executable, ROOT / "scripts/smoke-bundle.py", app], check=True)


if __name__ == "__main__":
    main()
