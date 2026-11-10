#!/usr/bin/env python3
"""Start the production UI in a temporary app with enforcement disabled.

Run while Harmony is off. No user app is launched/minimized/closed, and
preferences use a separate bundle ID. --minute-timer exercises a temporary
one-minute deadline without enforcement or a recovery helper. An external
deadline also catches a blocked main event loop.
"""
import platform
import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
if any(arg not in ('--minute-timer', '--playlist-smoke') for arg in sys.argv[1:]):
    raise SystemExit('Usage: python3 tests/run-ui-smoke.py [--minute-timer] [--playlist-smoke]')
os.chdir(ROOT)
installed = pathlib.Path.home() / 'Applications/Harmony.app/Contents/MacOS/HarmonyFocus'
if installed.exists():
    state = subprocess.run([str(installed), '--is-running'], timeout=5).returncode
    if state != 1:
        raise SystemExit('Exit Harmony normally before running the live UI smoke test.')

bundle_id = 'local.harmony.focus.ui-smoke'
try:
    with tempfile.TemporaryDirectory(prefix='harmony-ui-smoke-') as directory:
        app = pathlib.Path(directory) / 'Harmony UI Test.app'
        executable = app / 'Contents/MacOS/HarmonyUITest'
        resources = app / 'Contents/Resources'
        executable.parent.mkdir(parents=True)
        resources.mkdir()
        info = plistlib.loads((ROOT / 'Info.plist').read_bytes())
        info.update(CFBundleIdentifier=bundle_id, CFBundleExecutable='HarmonyUITest',
                    CFBundleName='Harmony UI Test', CFBundleDisplayName='Harmony UI Test')
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        subprocess.run([sys.executable, str(ROOT / 'tools/copy-player-resources.py'), str(resources)], check=True)
        sources = ['main.swift', 'Setup.swift', 'PhoneBridge.swift', 'PhonePrompt.swift', 'WindowPreparation.swift',
                   'WindowRedraw.swift', 'NativeInterface.swift', 'LifecycleCore.swift', 'tests/AppIntegrationTests.swift']
        command = ['swiftc', '-O', '-whole-module-optimization', '-D', 'HARMONY_TESTING',
                   '-target', f'{platform.machine()}-apple-macosx13.0', *sources, '-o', str(executable)]
        for framework in ('Cocoa', 'WebKit', 'Vision', 'ScreenCaptureKit', 'ApplicationServices'):
            command += ['-framework', framework]
        subprocess.run(command, check=True)
        subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
        try:
            subprocess.run([str(executable), '--ui-smoke', '--supervised', *sys.argv[1:]], check=True, timeout=30 if '--playlist-smoke' in sys.argv else 12)
        except subprocess.TimeoutExpired:
            raise SystemExit('FAIL: UI event loop stalled; the isolated test process was stopped.')
finally:
    subprocess.run(['defaults', 'delete', bundle_id], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
