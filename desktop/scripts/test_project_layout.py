"""Guard the single Tauri application layout without accessing user data."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
DESKTOP = ROOT / "desktop"
SPEC = importlib.util.spec_from_file_location("smoke_runtime", Path(__file__).with_name("smoke-runtime.py"))
SMOKE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SMOKE)


class ProjectLayoutTests(unittest.TestCase):
    def test_no_retired_application_entry_points(self):
        for name in ("Package.swift", "Package.resolved", "Sources", "Tests", "Assets", "Resources", ".build", ".swiftpm"):
            with self.subTest(path=name):
                self.assertFalse((ROOT / name).exists())

    def test_runtime_inputs_and_helpers_are_application_owned(self):
        for name in ("runtime/litellm/requirements.lock", "runtime/litellm/launcher.py",
                     "configs/switchyard/smoke.toml", "scripts/build-switchyard.sh",
                     "scripts/build-litellm.sh", "scripts/routing_parity.py"):
            with self.subTest(path=name):
                self.assertTrue((DESKTOP / name).is_file())
        requirements = (DESKTOP / "runtime/litellm/requirements.in").read_text()
        self.assertIn("litellm[proxy]==1.97.0", requirements)
        self.assertIn("fastapi==0.136.3", requirements)

    def test_tauri_resources_exist_and_installers_stay_disabled(self):
        config_path = DESKTOP / "src-tauri/tauri.conf.json"
        config = json.loads(config_path.read_text())
        self.assertFalse(config["bundle"]["active"])
        for source in config["bundle"]["resources"]:
            self.assertTrue((config_path.parent / source).is_dir(), source)
        self.assertEqual(config["bundle"]["resources"]["../resources/"], "notices/")


class RuntimePathsTests(unittest.TestCase):
    def test_native_runtime_paths_do_not_require_an_app_bundle(self):
        for platform, server_name, python_name in (
            ("darwin", "switchyard-server", "litellm/bin/python3.12"),
            ("win32", "switchyard-server.exe", "litellm/python.exe"),
        ):
            with self.subTest(platform=platform), tempfile.TemporaryDirectory(prefix="runtime with spaces ") as temporary:
                runtime = Path(temporary).resolve()
                expected = tuple(runtime / name for name in (server_name, python_name, "litellm/launcher.py"))
                for path in expected:
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.touch()
                with patch.object(SMOKE.sys, "platform", platform):
                    self.assertEqual(SMOKE.runtime_paths(runtime), expected)

    def test_missing_runtime_does_not_fall_back_to_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(FileNotFoundError, "Missing bundled runtime file"):
                SMOKE.runtime_paths(Path(temporary))


if __name__ == "__main__":
    unittest.main()
