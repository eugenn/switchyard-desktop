#!/usr/bin/env python3
"""Sign nested Rust/Python native code before sealing the macOS app."""
import subprocess
import sys
from pathlib import Path

app = Path(sys.argv[1]).resolve()
identity = sys.argv[2]
magic = {bytes.fromhex(s) for s in ('feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}
options = ['--force', '--sign', identity]
if identity != '-':
    options += ['--options', 'runtime', '--timestamp']
for path in sorted(app.rglob('*')):
    if path.is_symlink() or not path.is_file():
        continue
    with path.open('rb') as stream:
        is_native = stream.read(4) in magic
    if is_native:
        subprocess.run(['/usr/bin/codesign', *options, str(path)], check=True)
subprocess.run(['/usr/bin/codesign', *options, str(app)], check=True)
