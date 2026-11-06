#!/bin/bash
set -euo pipefail
MACROID_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MACROID_ROOT="$MACROID_ROOT" python3 - <<'PY'
import os
from pathlib import Path
import subprocess
import zipfile
import hashlib
root = Path(os.environ['MACROID_ROOT'])
artifacts = root / 'artifacts'
app_zip = artifacts / 'Macroid-macOS-universal.zip'
if app_zip.exists(): app_zip.unlink()
subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(artifacts / 'Macroid.app'), str(app_zip)], check=True)
source_zip = artifacts / 'Macroid-source.zip'
with zipfile.ZipFile(source_zip, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
    for path in sorted(root.rglob('*')):
        relative = path.relative_to(root)
        if any(part in {'.git', '.gradle', '.build', 'build', 'xcuserdata', '__pycache__'} for part in relative.parts): continue
        if relative.parts[0] == 'artifacts' and not (path.suffix in {'.json', '.txt'} and 'testing' in relative.parts): continue
        if path.name in {'.DS_Store', 'local.properties'} or not path.is_file(): continue
        archive.write(path, str(Path('Macroid') / relative))
files = [artifacts / 'Macroid.apk', app_zip]
(artifacts / 'SHA256SUMS').write_text(''.join(hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + path.name + '\n' for path in files))
for path in files: print(path)
PY
