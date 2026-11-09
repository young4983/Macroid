#!/bin/bash
set -euo pipefail
MACROID_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MACROID_ROOT="$MACROID_ROOT" python3 - <<'PY'
import os
from pathlib import Path
import subprocess
import zipfile
import hashlib
import tempfile
root = Path(os.environ['MACROID_ROOT'])
artifacts = root / 'artifacts'
app = artifacts / 'Macroid.app'
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
if (app / 'Contents/Resources/Macroid.apk').read_bytes() != (artifacts / 'Macroid.apk').read_bytes():
    raise SystemExit('The bundled Android helper is stale; run scripts/build.sh before packaging.')
app_zip = artifacts / 'Macroid-macOS-universal.zip'
if app_zip.exists(): app_zip.unlink()
subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(app_zip)], check=True)
dmg = artifacts / 'Macroid-macOS-universal.dmg'
with tempfile.TemporaryDirectory(prefix='macroid-dmg-') as directory:
    stage = Path(directory)
    subprocess.run(['ditto', str(app), str(stage / 'Macroid.app')], check=True)
    (stage / 'Applications').symlink_to('/Applications', target_is_directory=True)
    subprocess.run(['hdiutil', 'create', '-volname', 'Macroid', '-fs', 'HFS+', '-srcfolder', str(stage),
                    '-format', 'UDZO', '-ov', str(dmg)], check=True)
source_zip = artifacts / 'Macroid-source.zip'
# Include source files rather than ignored runtimes, local test captures or build output.
source_files = subprocess.check_output(['git', '-C', str(root), 'ls-files', '--cached', '--others', '--exclude-standard', '-z']).split(b'\0')
with zipfile.ZipFile(source_zip, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
    for name in sorted(set(source_files)):
        if not name: continue
        relative = Path(os.fsdecode(name))
        path = root / relative
        if any(part in {'.git', '.gradle', '.build', 'build', 'xcuserdata', '__pycache__'} for part in relative.parts): continue
        if relative.parts[0] == 'artifacts': continue
        if path.name in {'.DS_Store', 'local.properties'} or not path.is_file(): continue
        archive.write(path, str(Path('Macroid') / relative))
files = [artifacts / 'Macroid.apk', app_zip, dmg]
(artifacts / 'SHA256SUMS').write_text(''.join(hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + path.name + '\n' for path in files))
for path in [*files, source_zip]: print(path)
PY
