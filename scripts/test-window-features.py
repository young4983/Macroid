#!/usr/bin/env python3
"""Resize, stream-boundary and panel-power integration tests. Physical devices require opt-in."""
import argparse
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
parser.add_argument('--allow-device', action='store_true')
parser.add_argument('--screen-power', action='store_true', help='Temporarily turn off physical panels and test cleanup')
args = parser.parse_args()
if not args.serial.startswith('emulator-') and not args.allow_device:
    parser.error('Physical tests require --allow-device')
args.output.mkdir(parents=True, exist_ok=True)
adb = str(Path(os.environ.get('ANDROID_HOME', Path.home() / 'Library/Android/sdk')) / 'platform-tools/adb')
report = {'serial': args.serial, 'checks': [], 'configurations': []}
def run(*command, timeout=30):
    return subprocess.check_output([adb, '-s', args.serial, *command], stderr=subprocess.STDOUT, timeout=timeout).decode().strip()
def wait(check, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = check()
        if value: return value
        time.sleep(.1)
    raise AssertionError('Timed out waiting for condition')
def passed(name):
    report['checks'].append(name)
    print('PASS', name, flush=True)
def state():
    output = run('shell', 'content', 'query', '--uri', 'content://io.macroid.fixture/state')
    pairs = re.findall(r'(\w+)=(.*?)(?=, \w+=|$)', output.partition(': ')[2])
    return {k: v if k == 'text' else int(v) for k, v in pairs}
def panel_modes():
    text = run('shell', 'dumpsys', 'SurfaceFlinger')
    modes = []
    physical = False
    for line in text.splitlines():
        if 'DisplayDevice{' in line:
            physical = 'virtual' not in line.lower()
        if re.match(r'^(?:Virtual )?Display \d+\s*$', line): physical = False
        if 'connectionType=Internal' in line: physical = True
        match = re.search(r'powerMode=(\w+)', line)
        if match and physical: modes.append(match.group(1))
    return modes
def panel_is(on):
    modes = panel_modes()
    return bool(modes) and all(value.lower() == ('on' if on else 'off') for value in modes)

class Client:
    def __init__(self, port):
        self.socket = socket.create_connection(('127.0.0.1', int(port)), timeout=25)
        self.counter = 0
        self.config = {}
        self.pictures = {}
        self.key = {}
        self.parameters = {}
        self.events = []
    def exact(self, n):
        result = bytearray()
        while len(result) < n:
            part = self.socket.recv(n-len(result))
            if not part: raise EOFError()
            result.extend(part)
        return bytes(result)
    def read(self):
        magic, version, kind, flags, stream, length = struct.unpack('>4sBBHII', self.exact(16))
        assert magic == b'MCRD' and version == 1 and length <= 16*1024*1024
        payload = self.exact(length)
        if kind == 2:
            assert stream in self.config, 'video arrived before stream.config'
            if flags & 1: self.parameters[stream] = True
            elif flags & 2:
                assert self.parameters.get(stream), 'keyframe arrived before codec config'
                self.key[stream] = True
            if not flags & 1:
                assert self.key.get(stream), 'new configuration did not start at a keyframe'
                self.pictures[stream] = self.pictures.get(stream, 0) + 1
            return None
        value = json.loads(payload)
        if value.get('event') == 'stream.config':
            stream = value['stream']; self.config[stream] = value
            self.key[stream] = False; self.parameters[stream] = False; self.pictures[stream] = 0
        if 'event' in value: self.events.append(value)
        return value
    def send(self, op, **values):
        self.counter += 1
        payload = json.dumps(dict(id=self.counter, op=op, **values)).encode()
        self.socket.sendall(struct.pack('>4sBBHII', b'MCRD', 1, 1, 0, 0, len(payload)) + payload)
        return self.counter
    def response(self, request):
        while True:
            value = self.read()
            if value and value.get('id') == request:
                if not value.get('ok'): raise RuntimeError(value.get('error'))
                return value.get('result', {})
    def request(self, op, **values): return self.response(self.send(op, **values))
    def frames(self, stream, count=3):
        deadline = time.monotonic() + 20
        while self.pictures.get(stream, 0) < count and time.monotonic() < deadline: self.read()
        assert self.pictures.get(stream, 0) >= count
    def reject(self, op, **values):
        try: self.request(op, **values)
        except RuntimeError: return
        raise AssertionError('Expected rejection: ' + op)
    def tap(self, stream):
        fixture = state(); before = fixture['clicks']
        metadata = self.config[stream]
        for action in [0, 1]:
            self.request('input.pointer', stream=stream, generation=metadata['generation'], action=action,
                         x=fixture['buttonX'] * metadata['width']/fixture['width'],
                         y=fixture['buttonY'] * metadata['height']/fixture['height'])
        wait(lambda: state()['clicks'] == before + 1)

agents = []
def start(label):
    name, token = 'macroid_test_' + uuid.uuid4().hex, secrets.token_hex(32)
    apk = run('shell', 'pm', 'path', 'io.macroid.bridge').splitlines()[0].removeprefix('package:')
    port = run('forward', 'tcp:0', 'localabstract:' + name)
    path = args.output / (label + '.log'); log = path.open('wb')
    process = subprocess.Popen([adb, '-s', args.serial, 'shell', 'CLASSPATH=' + shlex.quote(apk) + ' app_process / io.macroid.bridge.AgentMain ' + name + ' ' + token], stdout=log, stderr=subprocess.STDOUT)
    agents.append((process, port, log))
    wait(lambda: 'MACROID_READY' in path.read_text(errors='replace'))
    client = Client(port)
    return client, client.request('hello', token=token)

client = None
try:
    run('install', '-r', str(ROOT / 'android/app/build/outputs/apk/debug/app-debug.apk'))
    run('install', '-r', str(ROOT / 'android/fixture/build/outputs/apk/debug/fixture-debug.apk'))
    run('shell', 'input', 'keyevent', 'KEYCODE_WAKEUP')
    run('shell', 'wm', 'dismiss-keyguard')
    client, info = start('features')
    report['device'] = info
    assert info['capabilities']['resize'] and info['capabilities']['streamConfig']
    client.reject('device.screenPower', screenOff=True)
    initial = client.request('stream.open', stream=1, mode='fusion', package='io.macroid.fixture',
                             width=630, height=1080, density=240, configEvents=True)
    client.frames(1)
    wait(lambda: state().get('display') == initial['display'])
    client.tap(1)
    original = state()
    for w, h in [(1440, 960), (630, 1080), (3200, 1800), (720, 1280), (1400, 900), (630, 1080)]:
        updated = client.request('stream.resize', stream=1, width=w, height=h, density=240)
        assert updated['display'] == initial['display']
        client.frames(1)
        wait(lambda: state().get('width') == updated['width'] and state().get('height') == updated['height'])
        fixture = state()
        assert fixture['task'] == original['task'] and fixture['clicks'] == original['clicks']
        assert abs(fixture['widthDp'] - w/1.5) < max(5, w/1.5*.02), fixture
        assert fixture['insetTop'] == 0 and fixture['insetBottom'] == 0, fixture
        assert fixture['statusVisible'] == 0 and fixture['navigationVisible'] == 0, fixture
        report['configurations'].append(dict(request=[w,h,240], result=updated, fixture=fixture))
    passed('narrow/wide/narrow and encoder downscale preserve dp, display, task and state; system bars absent')
    client.tap(1)
    client.reject('input.key', stream=1, generation=1, code=4)
    client.reject('stream.resize', stream=1, width=0, height=720, density=240)
    client.request('stream.sync', stream=1); client.frames(1)
    client.tap(1)
    passed('input uses current geometry; stale generations and invalid sizes rejected without losing stream')
    second = client.request('stream.open', stream=2, mode='fusion', package='com.android.settings', configEvents=True)
    client.frames(2)
    assert second['display'] != initial['display']
    client.request('stream.resize', stream=1, width=1200, height=900, density=240); client.frames(1)
    client.request('stream.close', stream=2)
    passed('resize with a second independent encoder')
    if args.screen_power:
        assert info['capabilities']['screenPower'], info
        client.request('device.screenPower', screenOff=True)
        wait(lambda: panel_is(False)); client.tap(1)
        before = client.pictures[1]; client.frames(1, before+5)
        client.request('device.screenPower', screenOff=False)
        wait(lambda: panel_is(True))
        passed('fusion remains interactive and produces video while physical panel is off')
    resize_id = client.send('stream.resize', stream=1, width=630, height=1080, density=240)
    close_id = client.send('stream.close', stream=1)
    client.response(resize_id); client.response(close_id)
    passed('close queued during resize releases the stream')
    client.request('apps.launch', package='io.macroid.fixture')
    mirror = client.request('stream.open', stream=3, mode='mirror', configEvents=True)
    client.frames(3); wait(lambda: state().get('display') == 0)
    client.reject('stream.resize', stream=3, width=1200, height=900, density=240)
    if args.screen_power:
        client.request('device.screenPower', screenOff=True)
        wait(lambda: panel_is(False)); client.tap(3)
        before = client.pictures[3]; client.frames(3, before+5)
        passed('mirror remains interactive and produces video while physical panel is off')
        client.request('stream.close', stream=3); wait(lambda: panel_is(True))
        passed('closing the final window restores the physical panel')
        client.request('stream.open', stream=4, mode='mirror', configEvents=True); client.frames(4)
        client.request('device.screenPower', screenOff=True); wait(lambda: panel_is(False))
        client.socket.close(); client = None; wait(lambda: panel_is(True))
        passed('transport EOF restores panel')
        client, info = start('guard-crash')
        client.request('stream.open', stream=1, mode='mirror', configEvents=True); client.frames(1)
        client.request('device.screenPower', screenOff=True); wait(lambda: panel_is(False))
        run('shell', 'kill', '-9', str(info['agentPid']))
        wait(lambda: panel_is(True))
        passed('independent guard restores panel after AgentMain SIGKILL')
    report['passed'] = True
except Exception as e:
    report['passed'] = False; report['error'] = repr(e)
    raise
finally:
    if client:
        try: client.socket.close()
        except Exception: pass
    for process, port, log in agents:
        try: process.wait(timeout=12)
        except subprocess.TimeoutExpired: process.terminate()
        log.close()
        run('forward', '--remove', 'tcp:' + port)
    report['finalPanelModes'] = panel_modes() if args.screen_power else []
    (args.output / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
