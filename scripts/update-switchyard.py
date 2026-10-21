#!/usr/bin/env python3
"""Import tracked Switchyard sources in one direction; never modify the source repo."""
import argparse
import hashlib
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEST = ROOT / 'vendor/switchyard'
LOCK = ROOT / 'vendor/switchyard-source.json'


def inventory(directory):
    return {str(p.relative_to(directory)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(directory.rglob('*')) if p.is_file()}


def verify():
    expected = json.loads(LOCK.read_text())['files']
    actual = inventory(DEST)
    if expected != actual:
        changed = sorted(k for k in expected.keys() | actual.keys() if expected.get(k) != actual.get(k))
        raise SystemExit('Switchyard snapshot differs from its manifest: ' + ', '.join(changed[:20]))


def verify_source(source):
    expected = json.loads(LOCK.read_text())['files']
    names = subprocess.check_output(['git', '-C', str(source), 'ls-files', '-z']).decode().split('\0')
    actual = {}
    for name in filter(None, names):
        if name.split('/')[0] in {'.agents', '.claude', '.github', '.hooks'}:
            continue
        path = source / name
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
    parser.add_argument('--check-source', action='store_true', help='Also compare the snapshot with the source working tree; requires --verify')
    args = parser.parse_args()
    if args.verify:
        verify()
        print('Switchyard snapshot verified.')
        if args.check_source:
            verify_source(args.source.resolve())
        return
    if args.check_source:
        parser.error('--check-source requires --verify')
    if DEST.exists():
        verify()  # Never overwrite local edits to the imported copy.
    source = args.source.resolve()
    def git(*arguments):
        return subprocess.check_output(['git', '-C', str(source), *arguments])
    dirty = bool(git('status', '--porcelain', '--untracked-files=no').strip())
    if dirty and not args.allow_dirty:
        raise SystemExit('Source has tracked changes. Commit them first, or explicitly use --allow-dirty for a development snapshot.')
    files = git('ls-files', '-z').decode().split('\0')
    with tempfile.TemporaryDirectory(dir=ROOT / 'vendor') as temporary:
        staged = Path(temporary) / 'switchyard'
        staged.mkdir()
        for name in filter(None, files):
            if name.split('/')[0] in {'.agents', '.claude', '.github', '.hooks'}:
                continue
            original = source / name
            if not original.exists():
                continue
            if original.is_symlink() or not original.is_file():
                raise SystemExit(f'Unsupported source entry: {name}')
            target = staged / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(original, target)
        manifest = {
            'repository': git('remote', 'get-url', 'origin').decode().strip(),
            'base_commit': git('rev-parse', 'HEAD').decode().strip(),
            'includes_tracked_worktree_changes': dirty,
            'files': inventory(staged),
        }
        if DEST.exists():
            shutil.rmtree(DEST)
        shutil.move(str(staged), DEST)
        LOCK.write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Imported {len(manifest["files"])} files from {source}; tracked changes: {dirty}.')


if __name__ == '__main__':
    main()
