"""Runtime packaging regressions; no user data or installed runtime is accessed."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
import tempfile

SPEC = importlib.util.spec_from_file_location("prepare_runtime", Path(__file__).with_name("prepare-runtime.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class WindowsRequirementsTests(unittest.TestCase):
    def test_removes_only_uvloop_and_preserves_hashes(self):
        source = "litellm==1.97.0 \\\n    --hash=sha256:abc\nuvloop==0.22.1 \\\n    --hash=sha256:def \\\n    --hash=sha256:ghi\n    # via uvicorn\nfastapi==0.136.3 \\\n    --hash=sha256:jkl\n"
        result = MODULE.windows_requirements(source)
        self.assertNotIn("uvloop==", result)
        self.assertNotIn("sha256:def", result)
        self.assertIn("litellm==1.97.0", result)
        self.assertIn("fastapi==0.136.3", result)
        self.assertIn("--hash=sha256:abc", result)
        self.assertIn("--hash=sha256:jkl", result)

    def test_preserves_lock_without_uvloop(self):
        source = "fastapi==0.136.3\n"
        self.assertEqual(MODULE.windows_requirements(source), source)

    def test_handles_single_line_uvloop_at_end(self):
        self.assertEqual(MODULE.windows_requirements("other==1\nuvloop==0.22.1\n"), "other==1\n")


class ClaudePluginTests(unittest.TestCase):
    def test_windows_is_rejected_before_building_or_writing(self):
        with patch.object(MODULE.sys, "platform", "win32"), patch.object(MODULE, "run") as run:
            with self.assertRaisesRegex(SystemExit, "only for macOS"):
                MODULE.prepare_claude_plugin()
            run.assert_not_called()

    def test_missing_runtime_is_rejected_before_building(self):
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "runtime"
            with patch.object(MODULE.sys, "platform", "darwin"), patch.object(MODULE, "DESTINATION", destination), patch.object(MODULE, "run") as run:
                with self.assertRaisesRegex(SystemExit, "matching bundled runtime"):
                    MODULE.prepare_claude_plugin()
                self.assertEqual(run.call_count, 1)
                self.assertFalse(destination.exists())

    def test_existing_plugin_is_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary)
            (destination / "switchyard-source.json").write_bytes((MODULE.ROOT / "vendor/switchyard-source.json").read_bytes())
            plugin = destination / "claude-plugin"
            plugin.mkdir()
            marker = plugin / "existing"
            marker.write_text("preserve")
            with patch.object(MODULE.sys, "platform", "darwin"), patch.object(MODULE, "DESTINATION", destination), patch.object(MODULE, "run") as run:
                with self.assertRaisesRegex(SystemExit, "already exists"):
                    MODULE.prepare_claude_plugin()
                self.assertEqual(marker.read_text(), "preserve")
                self.assertEqual(run.call_count, 1)


if __name__ == "__main__":
    unittest.main()
