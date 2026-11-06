#!/usr/bin/env python3
"""Real integration test. Requires an explicitly selected emulator; never selects a phone."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import socket
import struct
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--serial', required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--allow-device', action='store_true', help='Explicitly allow installation and input tests on a physical device')
args = parser.parse_args()
if not args.serial.startswith('emulator-') and not args.allow_device:
    parser.error('Use an emulator serial; physical devices require explicit --allow-device')
args.output.mkdir(parents=True, exist_ok=True)
sdk = Path(os.environ.get('ANDROID_HOME', Path.home() / 'Library/Android/sdk'))
adb = str(sdk / 'platform-tools/adb')
def run(*command, timeout=40):
    return subprocess.check_output([adb, '-s', args.serial, *command], stderr=subprocess.STDOUT, timeout=timeout).decode().strip()
def wait_for(check, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = check()
        if value: return value
        time.sleep(.15)
    raise AssertionError('Timed out waiting for condition')

class Client:
    def __init__(self, port, output):
        self.socket = socket.create_connection(('127.0.0.1', int(port)), timeout=15)
        self.counter = 0
        self.frames = {}
        self.output = output
    def exact(self, count):
        result = bytearray()
        while len(result) < count:
            part = self.socket.recv(count - len(result))
            if not part: raise EOFError()
            result.extend(part)
        return bytes(result)
    def read(self):
        magic, version, kind, flags, stream, count = struct.unpack('>4sBBHII', self.exact(16))
        assert magic == b'MCRD' and version == 1 and count <= 16*1024*1024
        payload = self.exact(count)
        if kind == 2:
            assert len(payload) > 8
            self.frames[stream] = self.frames.get(stream, 0) + 1
            if stream == 1 and self.frames[stream] <= 120: self.output.write(payload[8:])
            return None
        assert kind == 1
        return json.loads(payload)
    def request(self, op, **values):
        self.counter += 1
        payload = json.dumps(dict(id=self.counter, op=op, **values), ensure_ascii=False).encode()
        self.socket.sendall(struct.pack('>4sBBHII', b'MCRD', 1, 1, 0, 0, len(payload)) + payload)
        while True:
            response = self.read()
            if response and response.get('id') == self.counter:
                if not response.get('ok'): raise RuntimeError(response.get('error'))
                return response.get('result', {})
    def rejects(self, op, **values):
        try: self.request(op, **values)
        except RuntimeError: return
        raise AssertionError('Operation should have been rejected: ' + op)

def state():
    output = run('shell', 'content', 'query', '--uri', 'content://io.macroid.fixture/state')
    result = dict(re.findall(r'(\w+)=(.*?)(?=, \w+=|$)', output.partition(': ')[2]))
    return {k: (v if k == 'text' else int(v)) for k, v in result.items()}

report = {'serial': args.serial, 'checks': [], 'videoFrames': {}}
def passed(name):
    report['checks'].append(name)
    print('PASS', name, flush=True)

run('install', '-r', str(ROOT / 'android/app/build/outputs/apk/debug/app-debug.apk'))
run('install', '-r', str(ROOT / 'android/fixture/build/outputs/apk/debug/fixture-debug.apk'))
run('shell', 'input', 'keyevent', 'KEYCODE_WAKEUP')
run('shell', 'wm', 'dismiss-keyguard')
name, token = 'macroid_test_' + uuid.uuid4().hex, secrets.token_hex(32)
apk = run('shell', 'pm', 'path', 'io.macroid.bridge').splitlines()[0].removeprefix('package:')
port = run('forward', 'tcp:0', 'localabstract:' + name)
log = (args.output / 'agent.log').open('wb')
process = subprocess.Popen([adb, '-s', args.serial, 'shell', 'CLASSPATH=' + shlex.quote(apk) + ' app_process / io.macroid.bridge.AgentMain ' + name + ' ' + token], stdout=log, stderr=subprocess.STDOUT)
client = None
test_file = '/sdcard/Download/macroid-test-' + uuid.uuid4().hex + '.bin'
previous_ime = run('shell', 'settings', 'get', 'secure', 'default_input_method')
try:
    wait_for(lambda: 'MACROID_READY' in (args.output / 'agent.log').read_text(errors='replace'))
    with (args.output / 'fixture.h264').open('wb') as video:
        client = Client(port, video)
        info = client.request('hello', token=token)
        report['device'] = info
        assert info['product'] == 'Macroid' and info['protocol'] == 1 and info['sdk'] >= 31
        passed('authenticated independent Macroid protocol')
        apps = client.request('apps.list')['apps']
        assert any(app['package'] == 'io.macroid.fixture' for app in apps)
        icon = base64.b64decode(client.request('apps.icon', package='io.macroid.fixture')['png'])
        assert icon.startswith(b'\x89PNG')
        passed('app discovery and icons')
        display = client.request('stream.open', stream=1, mode='fusion', package='io.macroid.fixture', width=720, height=1280)
        assert display['display'] > 0
        wait_for(lambda: state().get('buttonX', 0) > 0)
        fixture = state(); assert fixture['display'] == display['display']
        passed('app runs on an independent display')
        for action in [0, 1]: client.request('input.pointer', stream=1, action=action, x=fixture['buttonX'], y=fixture['buttonY'])
        wait_for(lambda: state().get('clicks') == 1)
        passed('targeted touch injection changes application state')
        client.request('ime.enable')
        for action in [0, 1]: client.request('input.pointer', stream=1, action=action, x=fixture['editorX'], y=fixture['editorY'])
        time.sleep(.8)
        text = '你好 Macroid 🙂'
        client.request('input.text', stream=1, text=text)
        wait_for(lambda: state().get('text') == text)
        client.request('input.key', stream=1, code=67)
        wait_for(lambda: state().get('text') != text)
        passed('Unicode IME and targeted keyboard injection')
        client.request('clipboard.set', text='Macroid 剪贴板')
        assert client.request('clipboard.get')['text'] == 'Macroid 剪贴板'
        passed('bidirectional Unicode clipboard')
        content = secrets.token_bytes(420000)
        transfer = client.request('files.upload.begin', path=test_file, size=len(content))['transfer']
        for offset in range(0, len(content), 196608):
            client.request('files.upload.chunk', transfer=transfer, offset=offset, data=base64.b64encode(content[offset:offset+196608]).decode())
        client.request('files.upload.finish', transfer=transfer)
        result = bytearray()
        while len(result) < len(content):
            result.extend(base64.b64decode(client.request('files.read', path=test_file, offset=len(result))['data']))
        assert hashlib.sha256(result).digest() == hashlib.sha256(content).digest()
        client.rejects('files.upload.begin', path=test_file, size=0)
        client.rejects('files.list', path='/data/local/tmp')
        client.rejects('files.read', path='/sdcard/../../data/local/tmp', offset=0)
        passed('chunked binary file round trip, no overwrite, shared-storage boundary')
        second = client.request('stream.open', stream=2, mode='fusion', package='com.android.settings', width=720, height=1280)
        assert second['display'] > 0 and second['display'] != display['display']
        deadline = time.monotonic() + 15
        while min(client.frames.get(1, 0), client.frames.get(2, 0)) < 10 and time.monotonic() < deadline: client.read()
        assert client.frames.get(1, 0) >= 10 and client.frames.get(2, 0) >= 10
        passed('two concurrent independent H.264 streams')
        client.request('stream.close', stream=2)
        client.request('stream.close', stream=1)
        mirror = client.request('stream.open', stream=3, mode='mirror')
        assert mirror['display'] == 0
        deadline = time.monotonic() + 15
        while client.frames.get(3, 0) < 5 and time.monotonic() < deadline: client.read()
        assert client.frames.get(3, 0) >= 5
        client.request('stream.close', stream=3)
        passed('main-screen mirroring')
        # Disconnect with the custom IME enabled: shutdown must restore the original keyboard.
        report['videoFrames'] = client.frames
        client.socket.close(); client = None
    process.wait(timeout=12)
    assert run('shell', 'settings', 'get', 'secure', 'default_input_method') == previous_ime
    dumpsys = run('shell', 'dumpsys', 'display')
    assert not re.search(r'\bname="Macroid [123]"', dumpsys)
    passed('disconnect restores IME and releases virtual displays')
    for scenario in ['invalid-token', 'oversized-frame']:
        negative_name = 'macroid_negative_' + uuid.uuid4().hex
        negative_port = run('forward', 'tcp:0', 'localabstract:' + negative_name)
        negative_path = args.output / (scenario + '.log')
        with negative_path.open('wb') as negative_log:
            negative = subprocess.Popen([adb, '-s', args.serial, 'shell', 'CLASSPATH=' + shlex.quote(apk) + ' app_process / io.macroid.bridge.AgentMain ' + negative_name + ' ' + secrets.token_hex(32)], stdout=negative_log, stderr=subprocess.STDOUT)
            try:
                wait_for(lambda: 'MACROID_READY' in negative_path.read_text(errors='replace'))
                with socket.create_connection(('127.0.0.1', int(negative_port)), timeout=10) as rejected:
                    if scenario == 'invalid-token':
                        body = json.dumps({'id': 1, 'op': 'hello', 'token': 'incorrect'}).encode()
                        rejected.sendall(struct.pack('>4sBBHII', b'MCRD', 1, 1, 0, 0, len(body)) + body)
                    else:
                        rejected.sendall(struct.pack('>4sBBHII', b'MCRD', 1, 1, 0, 0, 16*1024*1024+1))
                    try: assert rejected.recv(1) == b''
                    except ConnectionResetError: pass
                negative.wait(timeout=10)
            finally:
                if negative.poll() is None: negative.terminate()
                run('forward', '--remove', 'tcp:' + negative_port)
    passed('rejects invalid authentication and oversized frames')
    report['passed'] = True
finally:
    if client: client.socket.close()
    if process.poll() is None:
        try: process.wait(timeout=8)
        except subprocess.TimeoutExpired: process.terminate()
    log.close()
    run('forward', '--remove', 'tcp:' + port)
    run('shell', 'rm', '-f', test_file)
    (args.output / 'report.json').write_text(json.dumps(report, indent=2, ensure_ascii=False))
print('Macroid integration checks completed')
