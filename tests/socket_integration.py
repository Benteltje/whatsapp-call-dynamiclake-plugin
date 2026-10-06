#!/usr/bin/env python3
"""Exercise the real executable with synthetic sessions; no WhatsApp or audio access."""
import base64
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import time
import zipfile

binary = Path(sys.argv[1]).resolve()
root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / 'plugin.json').read_text())
package = binary.parent
assert manifest['executable'] == binary.name
assert (package / manifest['icon']).is_file()
architectures = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split()
assert set(architectures) == {'arm64', 'x86_64'}
archive = root / 'dist' / f"WhatsAppCall-{manifest['version']}.dynamiclakeplugin.zip"
# Root downloads must be byte-for-byte copies of this build, with correct checksum names.
import hashlib
root_package = root / 'WhatsAppCall.dynamiclakeplugin'
package_files = {p.relative_to(package) for p in package.rglob('*') if p.is_file()}
root_files = {p.relative_to(root_package) for p in root_package.rglob('*') if p.is_file()}
assert root_files == package_files
for relative in package_files:
    assert (root_package / relative).read_bytes() == (package / relative).read_bytes()
root_archive = root / 'WhatsAppCall.dynamiclakeplugin.zip'
assert root_archive.read_bytes() == archive.read_bytes()
checksum = (root / 'WhatsAppCall.dynamiclakeplugin.zip.sha256').read_text().split()
assert checksum == [hashlib.sha256(root_archive.read_bytes()).hexdigest(), root_archive.name]
assert (root_package / binary.name).stat().st_mode & 0o111
with zipfile.ZipFile(archive) as z:
    assert f'{package.name}/plugin.json' in z.namelist()
    assert not any('/Sources/' in n for n in z.namelist())
    executable = z.getinfo(f'{package.name}/{binary.name}')
    assert (executable.external_attr >> 16) & 0o111
payload = subprocess.check_output([str(binary), '--demo-json'])
assert len(payload) < 65536
sample = json.loads(payload)
left = sample['surfaces']['compactLiveActivity']['leftSlot']
assert left['source'] == 'sfSymbol' and left['systemImage'] == 'phone.fill' and left['tint'] == 'green'
assert sample['size'] == 'small'
right = sample['surfaces']['compactLiveActivity']['rightSlot']
assert right['type'] == 'text' and right['text'] == '0:44'
assert (package / 'Assets/WhatsAppLightIcon.png').is_file()

with tempfile.TemporaryDirectory(prefix='wa-test-', dir='/tmp') as directory:
    directory = Path(directory)
    settings = directory / 'settings.json'
    def save(**changes):
        values = dict(detectNativeCalls=False, detectWebCalls=False, diagnosticActivity=True, showWaveform=True, pollSeconds=0.5)
        values.update(changes)
        temporary = settings.with_suffix('.tmp')
        temporary.write_text(json.dumps({'values': values}))
        temporary.replace(settings)
    save()
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(str(directory / 'socket'))
    listener.listen(1)
    listener.settimeout(5)
    env = {k:v for k,v in os.environ.items() if not k.startswith('DYNAMICLAKE_')}
    env.update(DYNAMICLAKE_JSON_SOCKET=str(directory / 'socket'), DYNAMICLAKE_PLUGIN_SETTINGS_PATH=str(settings), DYNAMICLAKE_PLUGIN_PACKAGE=str(package))
    process = subprocess.Popen([str(binary)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    conn = None
    try:
        conn, _ = listener.accept()
        conn.settimeout(8)
        def exact(length):
            data = b''
            while len(data) < length:
                part = conn.recv(length - len(data))
                assert part, 'unexpected disconnect'
                data += part
            return data
        def receive():
            length = struct.unpack('!I', exact(4))[0]
            assert 0 < length <= 65536
            return json.loads(exact(length))
        def until(predicate, seconds=8):
            end = time.monotonic() + seconds
            while time.monotonic() < end:
                frame = receive()
                if predicate(frame): return frame
            raise AssertionError('expected frame not received')
        def send(message, fragmented=False):
            body = json.dumps(message).encode()
            frame = struct.pack('!I', len(body)) + body
            if fragmented:
                conn.sendall(frame[:2]); time.sleep(0.1); conn.sendall(frame[2:])
            else: conn.sendall(frame)
        initial = receive()
        assert initial['type'] == 'create'
        assert initial['size'] == 'small'
        first_time = initial['surfaces']['compactLiveActivity']['rightSlot']['text']
        until(lambda f: f.get('surfaces', {}).get('compactLiveActivity', {}).get('rightSlot', {}).get('text') not in [None, first_time])
        send({'type':'response', 'ok':True})
        save(compactPresentation='Phone + waveform')
        wave = until(lambda f: 'sneakPeek' in f.get('surfaces', {}) and f['type'] == 'update')
        image = wave['surfaces']['compactLiveActivity']['rightSlot']
        assert image['source'] == 'inlineData' and image['mimeType'] == 'image/png'
        assert base64.b64decode(image['base64Data']).startswith(b'\x89PNG\r\n\x1a\n')
        assert len(base64.b64decode(image['base64Data'])) < 49152
        first_image = image['base64Data']
        until(lambda f: f.get('surfaces', {}).get('compactLiveActivity', {}).get('rightSlot', {}).get('base64Data') not in [None, first_image])
        save(showWaveform=False)
        frame = until(lambda f: 'sneakPeek' in f.get('surfaces', {}) and f['type'] == 'update')
        assert frame['surfaces']['compactLiveActivity']['rightSlot']['type'] == 'text'
        assert frame['size'] == 'small'
        send({'type':'action', 'actionID':'dismiss'}, fragmented=True)
        until(lambda f: f['type'] == 'dismiss')
        conn.settimeout(2)
        try:
            unexpected = receive()
            raise AssertionError(f'reappeared after dismissal: {unexpected["type"]}')
        except socket.timeout: pass
        save(diagnosticActivity=False, showWaveform=False)
        time.sleep(6)
        save(showWaveform=False)
        conn.settimeout(8)
        until(lambda f: f['type'] == 'create')
        send({'type':'action', 'actionID':'end-call'})
        until(lambda f: f['type'] == 'dismiss')
        conn.close(); conn = None
        assert process.wait(timeout=3) == 65, 'disconnected monitor must exit'
        assert b'host disconnected' in process.stderr.read()
    finally:
        if conn: conn.close()
        listener.close()
        if process.poll() is None:
            process.terminate(); process.wait(timeout=3)

# Hostile frame lengths must terminate promptly instead of allocating indefinitely.
with tempfile.TemporaryDirectory(prefix='wa-bad-', dir='/tmp') as directory:
    listener = socket.socket(socket.AF_UNIX)
    path = directory + '/socket'
    listener.bind(path); listener.listen(1); listener.settimeout(5)
    settings = directory + '/settings.json'
    Path(settings).write_text(json.dumps({'detectNativeCalls':False,'detectWebCalls':False}))
    env.update(DYNAMICLAKE_JSON_SOCKET=path, DYNAMICLAKE_PLUGIN_SETTINGS_PATH=settings)
    process = subprocess.Popen([str(binary)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        conn, _ = listener.accept()
        conn.sendall(struct.pack('!I', 65537))
        assert process.wait(timeout=3) == 65
        assert b'too large' in process.stderr.read()
        conn.close()
    finally:
        listener.close()
        if process.poll() is None: process.kill(); process.wait()
print('Package, payload, fragmented socket actions, settings reload, dismissal, preview restart, hangup, disconnect and oversized-frame tests passed.')
