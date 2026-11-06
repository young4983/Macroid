#!/usr/bin/env python3
"""Build an isolated test dex and inject codec failures around real VirtualDisplay/encoder operations."""
import argparse
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--serial', required=True)
parser.add_argument('--allow-device', action='store_true')
args = parser.parse_args()
if not args.serial.startswith('emulator-') and not args.allow_device: parser.error('Physical devices require --allow-device')
sdk = Path(os.environ.get('ANDROID_HOME', Path.home() / 'Library/Android/sdk'))
adb = [str(sdk/'platform-tools/adb'), '-s', args.serial]
android = sdk/'platforms/android-36/android.jar'
classes = root/'android/app/build/intermediates/javac/debug/compileDebugJavaWithJavac/classes'
d8 = sorted((sdk/'build-tools').glob('*/d8'))[-1]
with tempfile.TemporaryDirectory(prefix='macroid-resize-test-') as temporary:
    folder = Path(temporary)
    subprocess.run(['javac', '-source', '17', '-target', '17', '-cp', str(android)+os.pathsep+str(classes), '-d', temporary,
                    str(root/'android/tests/ResizeFailureProbe.java')], check=True)
    subprocess.run([str(d8), '--lib', str(android), '--classpath', str(classes), '--min-api', '31', '--output', temporary,
                    *map(str, folder.rglob('*.class'))], check=True)
    remote = '/data/local/tmp/macroid-resize-failure.dex'
    try:
        subprocess.run([*adb, 'push', str(folder/'classes.dex'), remote], check=True)
        apk = subprocess.check_output([*adb,'shell','pm','path','io.macroid.bridge']).decode().splitlines()[0].removeprefix('package:')
        subprocess.run([*adb,'shell','CLASSPATH='+shlex.quote(apk+':'+remote)+' app_process / io.macroid.bridge.ResizeFailureProbe'], check=True, timeout=60)
    finally:
        subprocess.run([*adb,'shell','rm','-f',remote], check=True)
