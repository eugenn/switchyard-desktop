"""Verify legacy setup import using checked-in synthetic fixtures; no user data."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def main():
    subprocess.run(
        ["cargo", "test", "--locked", "-p", "switchyard-desktop-core", "--test", "legacy_setup_import"],
        cwd=ROOT / "desktop", check=True,
    )


if __name__ == "__main__":
    main()
