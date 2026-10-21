"""Importer/release regressions; every checkout and file lives in a temporary directory."""
import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / 'update-switchyard.py'


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='switchyard-import-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        # No inherited Git startup templates, hooks, signing or credential helpers.
        templates = self.root / 'git-templates'
        templates.mkdir()
        self.environment = mock.patch.dict(os.environ, {
            'GIT_CONFIG_GLOBAL': os.devnull,
            'GIT_CONFIG_SYSTEM': os.devnull,
            'GIT_CONFIG_NOSYSTEM': '1',
            'GIT_TEMPLATE_DIR': str(templates),
        })
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.app = self.root / 'desktop'
        (self.app / 'scripts').mkdir(parents=True)
        (self.app / 'vendor').mkdir()
        self.script = self.app / 'scripts/update-switchyard.py'
        shutil.copy2(SCRIPT, self.script)
        spec = importlib.util.spec_from_file_location('snapshot', self.script)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.source = self.root / 'core'
        self.source.mkdir()
        self.git('init', '--quiet', '-b', 'main')
        self.git('config', 'user.name', 'Snapshot Test')
        self.git('config', 'user.email', 'test@example.invalid')
        self.git('config', 'commit.gpgsign', 'false')
        (self.source / 'core.rs').write_text('original\n')
        (self.source / '.github').mkdir()
        (self.source / '.github/workflow.yml').write_text('excluded\n')
        self.git('add', '.')
        self.git('commit', '--quiet', '-m', 'Temporary test fixture')
        self.upstream = self.git('rev-parse', 'HEAD').strip()
        self.git('remote', 'add', 'origin', self.module.UPSTREAM)
        self.git('remote', 'add', 'fork', self.module.FORK)
        self.git('update-ref', 'refs/remotes/origin/main', self.upstream)

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.source), *args], text=True)

    def run_import(self, *args, success=True):
        result = subprocess.run(['python3', str(self.script), '--source', str(self.source), *args],
                                capture_output=True, text=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def manifest(self):
        return json.loads((self.app / 'vendor/switchyard-source.json').read_text())

    def test_fork_and_upstream_are_separate_and_clean_release_passes(self):
        (self.source / 'core.rs').write_text('fork changes\n')
        self.git('commit', '--quiet', '-am', 'Temporary fork fixture')
        self.run_import()
        manifest = self.manifest()
        self.assertEqual(manifest['repository'], self.module.FORK)
        self.assertEqual(manifest['commit'], self.git('rev-parse', 'HEAD').strip())
        self.assertEqual(manifest['upstream_commit'], self.upstream)
        self.assertFalse(manifest['includes_tracked_worktree_changes'])
        self.assertEqual(list(manifest['files']), ['core.rs'])
        self.run_import('--verify', '--release')

    def test_conventional_remote_names_also_work(self):
        self.git('remote', 'rename', 'origin', 'upstream')
        self.git('remote', 'rename', 'fork', 'origin')
        self.run_import()
        self.assertEqual(self.manifest()['repository'], self.module.FORK)
        self.assertEqual(self.manifest()['upstream_commit'], self.upstream)

    def test_dirty_import_is_explicit_and_cannot_be_released(self):
        (self.source / 'core.rs').write_text('uncommitted\n')
        self.run_import(success=False)
        self.run_import('--allow-dirty')
        self.run_import('--verify', '--check-source')
        failure = self.run_import('--verify', '--release', success=False)
        self.assertIn('dirty Switchyard snapshot', failure.stderr)

    def test_untracked_files_are_never_imported(self):
        (self.source / 'private-token.txt').write_text('fixture only\n')
        self.run_import()
        self.assertNotIn('private-token.txt', self.manifest()['files'])

    def test_vendor_edits_are_not_overwritten(self):
        self.run_import()
        target = self.app / 'vendor/switchyard/core.rs'
        target.write_text('local edit\n')
        self.run_import(success=False)
        self.assertEqual(target.read_text(), 'local edit\n')

    def test_legacy_manifest_can_migrate_but_not_release(self):
        self.run_import()
        path = self.app / 'vendor/switchyard-source.json'
        old = self.manifest()
        old.pop('schema_version')
        path.write_text(json.dumps(old))
        self.run_import('--verify')
        self.run_import('--verify', '--release', success=False)
        self.run_import()
        self.run_import('--verify', '--release')

    def test_release_requires_an_explicit_boolean_dirty_flag(self):
        self.run_import()
        for value in (None, 'false', 0):
            manifest = self.manifest()
            manifest['includes_tracked_worktree_changes'] = value
            with self.assertRaises(SystemExit):
                self.module.validate_manifest(manifest, release=True)

    def test_embedded_manifest_must_match_checkout(self):
        self.run_import()
        manifest = self.manifest()
        manifest['commit'] = 'a' * 40
        embedded = self.root / 'embedded.json'
        embedded.write_text(json.dumps(manifest))
        self.run_import('--verify', '--release', '--manifest', str(embedded), success=False)

    def test_symlinks_are_rejected_even_when_broken(self):
        self.source.joinpath('core.rs').unlink()
        self.source.joinpath('core.rs').symlink_to(self.source / 'missing')
        self.run_import('--allow-dirty', success=False)

    def test_git_export_attributes_cannot_change_committed_inventory(self):
        (self.source / '.gitattributes').write_text('core.rs export-ignore\n')
        self.git('add', '.')
        self.git('commit', '--quiet', '-m', 'Temporary archive fixture')
        self.run_import()
        self.assertEqual(self.module.commit_inventory(self.source, 'HEAD'), self.manifest()['files'])

    def test_published_check_rejects_forged_clean_inventory(self):
        self.run_import()
        with mock.patch.object(self.module, 'git'), \
             mock.patch.object(self.module.subprocess, 'run') as fetch, \
             mock.patch.object(self.module, 'commit_inventory', return_value={}):
            with self.assertRaisesRegex(SystemExit, 'does not match'):
                self.module.verify_published(self.manifest())
            self.assertIn(self.module.FORK, fetch.call_args.args[0])

    def test_published_check_fetches_and_matches_committed_bytes(self):
        self.run_import()
        real_run = subprocess.run

        def local_fetch(command, **kwargs):
            # Exercise the real fetch/blob verification with an isolated local remote.
            if 'fetch' in command:
                command = [str(self.source) if part == self.module.FORK else part for part in command]
            return real_run(command, **kwargs)

        with mock.patch.object(self.module.subprocess, 'run', side_effect=local_fetch):
            self.module.verify_published(self.manifest())

    def test_release_entry_points_fail_before_build_or_signing(self):
        self.run_import('--allow-dirty')
        manifest = self.manifest()
        manifest['includes_tracked_worktree_changes'] = True
        (self.app / 'vendor/switchyard-source.json').write_text(json.dumps(manifest))
        bundle = self.root / 'fixture.app'
        resources = bundle / 'Contents/Resources'
        resources.mkdir(parents=True)
        (resources / 'switchyard-source.json').write_text(json.dumps(manifest))
        dmg = self.root / 'fixture.dmg'
        dmg.write_text('fixture only')
        for name, arguments in (
            ('create-release-dmg.sh', []),
            ('package-app.sh', ['--output', str(self.root / 'unused.app'),
                                '--signing-identity', 'Developer ID Application: Fixture',
                                '--hardened-runtime']),
            ('verify-release.sh', ['--app', str(bundle), '--dmg', str(dmg)]),
        ):
            script = self.app / 'scripts' / name
            shutil.copy2(SCRIPT.parent / name, script)
            result = subprocess.run(['sh', str(script), *arguments], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('dirty Switchyard snapshot', result.stderr)
        self.assertFalse((self.root / 'unused.app').exists())


if __name__ == '__main__':
    unittest.main()
