#!/usr/bin/env python3
"""Bundle license texts from the locked Rust dependency graph (a conservative superset)."""
import json
import shutil
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
metadata = json.loads(subprocess.check_output(
    ['cargo', 'metadata', '--locked', '--format-version', '1'], cwd=root / 'vendor/switchyard'))
output = Path(sys.argv[1])
output.mkdir(parents=True, exist_ok=True)
index = []
for package in sorted(metadata['packages'], key=lambda p: (p['name'], p['version'])):
    if package['source'] is None:
        continue
    source = Path(package['manifest_path']).parent
    name = package['name'] + '-' + package['version']
    texts = [p for p in source.rglob('*') if p.is_file()
             and any(p.name.lower().startswith(prefix) for prefix in ('license', 'licence', 'copying', 'notice', 'copyright'))]
    if package.get('license_file'):
        texts.append(source / package['license_file'])
    for path in set(texts):
        if not path.is_file():
            continue
        target = output / name / path.relative_to(source)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
    index.append({'name': package['name'], 'version': package['version'],
                  'license': package.get('license'), 'repository': package.get('repository'),
                  'license_files': sorted(str(p.relative_to(source)) for p in set(texts))})
(output / 'index.json').write_text(json.dumps(index, indent=2) + '\n')
