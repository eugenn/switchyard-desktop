#!/usr/bin/env python3
"""Import tracked Switchyard sources in one direction; never modify the source repo."""
import argparse
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEST = ROOT / 'vendor/switchyard'
LOCK = ROOT / 'vendor/switchyard-source.json'
EXCLUDED = {'.agents', '.claude', '.github', '.hooks'}
FORK = 'https://github.com/eugenn/Switchyard.git'
UPSTREAM = 'https://github.com/NVIDIA-NeMo/Switchyard.git'


def git(source, *arguments):
    return subprocess.check_output(['git', '-C', str(source), *arguments])


def repository_url(value):
    """Store a public, credential-free URL regardless of local transport."""
    match = re.fullmatch(r'(?:https://github\.com/|git@github\.com:)([\w.-]+/[\w.-]+?)(?:\.git)?/?', value)
    if not match:
        raise SystemExit('Source remote must be a credential-free GitHub HTTPS or SSH URL.')
    return f'https://github.com/{match[1]}.git'


def remote_for(source, expected):
    for name in git(source, 'remote').decode().splitlines():
        url = git(source, 'remote', 'get-url', name).decode().strip()
        # Ignore unrelated remotes, including private/local URLs.
        if url in (expected, expected.removesuffix('.git'),
                   expected.replace('https://github.com/', 'git@github.com:')):
            return name
    raise SystemExit(f'Add a remote for {expected} in the source checkout first.')


def commit_inventory(source, commit):
    """Read committed bytes without checking out files or applying local filters."""
    result = {}
    # Read Git blobs, not git archive: export-ignore/export-subst must not alter sources.
    entries = git(source, 'ls-tree', '-r', '-z', commit).split(b'\0')
    blobs = []
    for entry in filter(None, entries):
        metadata, name = entry.split(b'\t', 1)
        name = name.decode()
        if name.split('/')[0] in EXCLUDED:
            continue
        mode, kind, oid = metadata.decode().split()
        if kind != 'blob' or mode not in {'100644', '100755'}:
            raise SystemExit(f'Unsupported committed source entry: {name}')
        blobs.append((name, oid))
    batch = subprocess.run(['git', '-C', str(source), 'cat-file', '--batch'],
                           input=''.join(oid + '\n' for _, oid in blobs).encode(),
                           stdout=subprocess.PIPE, check=True)
    data = io.BytesIO(batch.stdout)
    for name, oid in blobs:
        header = data.readline().decode().split()
        if len(header) != 3 or header[:2] != [oid, 'blob']:
            raise SystemExit(f'Cannot read committed source: {name}')
        result[name] = hashlib.sha256(data.read(int(header[2]))).hexdigest()
        if data.read(1) != b'\n':
            raise SystemExit('Invalid Git blob stream.')
    return result


def validate_manifest(manifest, release=False):
    if manifest.get('schema_version') != 2:
        if release:
            raise SystemExit('Release requires a version 2 source manifest; re-import the core.')
        return  # Allow the old snapshot to be verified before migrating it.
    for field in ('repository', 'upstream_repository'):
        value = manifest.get(field, '')
        if repository_url(value) != value:
            raise SystemExit(f'Manifest {field} must be a canonical HTTPS URL.')
    for field in ('commit', 'upstream_commit'):
        if not re.fullmatch(r'[0-9a-f]{40}', manifest.get(field, '')):
            raise SystemExit(f'Manifest {field} must be a full Git commit SHA.')
    if type(manifest.get('includes_tracked_worktree_changes')) is not bool:
        raise SystemExit('Manifest must explicitly record whether tracked changes were imported.')
    if release and manifest['includes_tracked_worktree_changes']:
        raise SystemExit('Release blocked: dirty Switchyard snapshot. Commit and publish the core changes, then re-import without --allow-dirty.')


def verify_published(manifest):
    """Check the public commit bytes, without trusting a dirty flag alone."""
    with tempfile.TemporaryDirectory(prefix='switchyard-provenance-') as directory:
        git(directory, 'init', '--quiet')
        subprocess.run(['git', '-C', directory, '-c', 'credential.helper=',
                        '-c', 'core.askPass=', 'fetch', '--quiet', '--depth=1',
                        manifest['repository'], manifest['commit']],
                       env={**os.environ, 'GIT_TERMINAL_PROMPT': '0'},
                       check=True, timeout=120)
        if commit_inventory(directory, 'FETCH_HEAD') != manifest['files']:
            raise SystemExit('Published core commit does not match the imported snapshot.')
    print('Published core commit matches the snapshot.')


def inventory(directory):
    result = {}
    for path in sorted(directory.rglob('*')):
        if path.is_symlink():
            raise SystemExit(f'Unsupported snapshot symlink: {path.relative_to(directory)}')
        if path.is_file():
            result[str(path.relative_to(directory))] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def verify(manifest_path=LOCK, release=False, check_published=False):
    manifest = json.loads(manifest_path.read_text())
    validate_manifest(manifest, release)
    if manifest_path != LOCK and manifest != json.loads(LOCK.read_text()):
        raise SystemExit('Bundled source manifest differs from this checkout; verify with the matching app sources.')
    expected = manifest['files']
    actual = inventory(DEST)
    if expected != actual:
        changed = sorted(k for k in expected.keys() | actual.keys() if expected.get(k) != actual.get(k))
        raise SystemExit('Switchyard snapshot differs from its manifest: ' + ', '.join(changed[:20]))
    if check_published:
        verify_published(manifest)


def verify_source(source):
    expected = json.loads(LOCK.read_text())['files']
    names = subprocess.check_output(['git', '-C', str(source), 'ls-files', '-z']).decode().split('\0')
    actual = {}
    for name in filter(None, names):
        if name.split('/')[0] in EXCLUDED:
            continue
        path = source / name
        if path.is_symlink():
            raise SystemExit(f'Unsupported source entry: {name}')
        if path.is_file():
            actual[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    changed = sorted(k for k in expected.keys() | actual.keys() if expected.get(k) != actual.get(k))
    if changed:
        raise SystemExit('Switchyard source differs from the snapshot: ' + ', '.join(changed))
    print(f'Switchyard source matches the snapshot ({len(actual)} files).')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=ROOT.parent / 'NVIDIA',
                        help='Switchyard source checkout (default: sibling NVIDIA directory)')
    parser.add_argument('--allow-dirty', action='store_true', help='Explicitly import tracked working-tree changes')
    parser.add_argument('--verify', action='store_true')
    parser.add_argument('--release', action='store_true', help='With --verify, reject legacy or dirty snapshots')
    parser.add_argument('--check-published', action='store_true', help='With --verify --release, fetch the recorded public core commit and verify its bytes')
    parser.add_argument('--manifest', type=Path, default=LOCK, help='With --verify, also check a bundled manifest against this checkout')
    parser.add_argument('--upstream-ref', help='Upstream ref already fetched into the source checkout (default: NVIDIA remote/main)')
    parser.add_argument('--check-source', action='store_true', help='Also compare the snapshot with the source working tree; requires --verify')
    args = parser.parse_args()
    if (args.release or args.check_published or args.manifest != LOCK) and not args.verify:
        parser.error('--release, --check-published and --manifest require --verify')
    if args.check_published and not args.release:
        parser.error('--check-published requires --release')
    if args.verify:
        verify(args.manifest, args.release, args.check_published)
        print('Switchyard snapshot verified.')
        if args.check_source:
            verify_source(args.source.resolve())
        return
    if args.check_source:
        parser.error('--check-source requires --verify')
    if DEST.exists():
        verify()  # Never overwrite local edits to the imported copy.
    source = args.source.resolve()
    fork_remote = remote_for(source, FORK)
    upstream_remote = remote_for(source, UPSTREAM)
    commit = git(source, 'rev-parse', 'HEAD').decode().strip()
    upstream_ref = args.upstream_ref or f'{upstream_remote}/main'
    upstream_commit = git(source, 'merge-base', commit, upstream_ref).decode().strip()
    dirty = bool(git(source, 'status', '--porcelain', '--untracked-files=no').strip())
    if dirty and not args.allow_dirty:
        raise SystemExit('Source has tracked changes. Commit them first, or explicitly use --allow-dirty for a development snapshot.')
    files = git(source, 'ls-files', '-z').decode().split('\0')
    with tempfile.TemporaryDirectory(dir=ROOT / 'vendor') as temporary:
        staged = Path(temporary) / 'switchyard'
        staged.mkdir()
        for name in filter(None, files):
            if name.split('/')[0] in EXCLUDED:
                continue
            original = source / name
            if original.is_symlink():
                raise SystemExit(f'Unsupported source entry: {name}')
            if not original.exists():
                continue
            if not original.is_file():
                raise SystemExit(f'Unsupported source entry: {name}')
            target = staged / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(original, target)
        manifest = {
            'schema_version': 2,
            'repository': repository_url(git(source, 'remote', 'get-url', fork_remote).decode().strip()),
            'commit': commit,
            'upstream_repository': UPSTREAM,
            'upstream_commit': upstream_commit,
            'includes_tracked_worktree_changes': dirty,
            'files': inventory(staged),
        }
        if not dirty and commit_inventory(source, commit) != manifest['files']:
            raise SystemExit('Clean import differs from committed bytes; check Git filters and concurrent edits.')
        validate_manifest(manifest)
        if DEST.exists():
            shutil.rmtree(DEST)
        shutil.move(str(staged), DEST)
        LOCK.write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Imported {len(manifest["files"])} files from {source}; tracked changes: {dirty}.')


if __name__ == '__main__':
    main()
