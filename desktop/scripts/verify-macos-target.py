#!/usr/bin/env python3
"""Reject native dependencies that would break the advertised macOS 14 minimum."""
import re
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
magic = {bytes.fromhex(s) for s in ('feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}
checked = 0
for path in root.rglob('*'):
    if path.is_symlink() or not path.is_file():
        continue
    with path.open('rb') as stream:
        if stream.read(4) not in magic:
            continue
    checked += 1
    result = subprocess.run(['/usr/bin/vtool', '-show-build', str(path)], capture_output=True, text=True, check=True)
    versions = re.findall(r'^\s*minos\s+([\d.]+)', result.stdout, re.M)
    versions += re.findall(r'cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version ([\d.]+)', result.stdout)
    for version in versions:
        if tuple(map(int, version.split('.')[:2])) > (14, 0):
            raise SystemExit(f'{path} requires macOS {version}, newer than the app minimum 14.0')
print(f'Checked macOS deployment targets for {checked} native files.')
