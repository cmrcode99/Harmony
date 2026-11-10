#!/usr/bin/env python3
"""Exercise installation transactions in a temporary home, without OS services."""
import fcntl
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='harmony-install-test-')
        self.root = Path(self.temp.name)
        self.home = self.root / 'Home with spaces'
        self.home.mkdir()
        self.log = self.root / 'commands.jsonl'
        self.loaded = self.root / 'loaded'
        self.failed = self.root / 'failed-once'
        self.env = {**os.environ, 'HOME': str(self.home), 'TEST_LOG': str(self.log),
                    'TEST_LOADED': str(self.loaded), 'TEST_FAILED': str(self.failed)}
        self.mock = self.root / 'service-tool'
        self.mock.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ['TEST_LOG'], 'a') as file: file.write(json.dumps(args) + '\\n')
loaded = pathlib.Path(os.environ['TEST_LOADED'])
failed = pathlib.Path(os.environ['TEST_FAILED'])
if args[0] == 'print': sys.exit(0 if loaded.exists() else 1)
if args[0] == 'bootout': loaded.unlink(missing_ok=True)
if args[0] == 'bootstrap':
    if os.environ.get('TEST_FAIL_BOOTSTRAP') == '1' and not failed.exists():
        failed.touch(); sys.exit(1)
    loaded.touch()
if args[0] == '--verify' and os.environ.get('TEST_FAIL_SIGNATURE') == '1': sys.exit(1)
''')
        self.mock.chmod(0o755)
        self.helper = self.root / 'manage-install.sh'
        self.helper.write_text((ROOT / 'sharing/manage-install.sh').read_text()
                               .replace('launchctl ', f'"{self.mock}" ')
                               .replace('/usr/bin/codesign ', f'"{self.mock}" '))
        self.source = self.root / 'New Harmony.app'
        self.binary = self.source / 'Contents/MacOS/HarmonyFocus'
        self.binary.parent.mkdir(parents=True)
        self.binary.write_text('#!/bin/sh\nexit 0\n')
        self.binary.chmod(0o755)
        (self.source / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'local.harmony.focus'}))
        (self.source / 'version').write_text('one')
        self.launcher = self.root / 'launcher'
        self.launcher.write_text('#!/bin/zsh\napp="$HOME/Applications/Harmony.app"\n')
        self.app = self.home / 'Applications/Harmony.app'
        self.cli = self.home / '.local/bin/harmony'
        self.manager = self.home / '.local/lib/harmony/manage-install.sh'
        self.agent = self.home / 'Library/LaunchAgents/local.harmony.focus.supervisor.plist'
        self.state = self.home / 'Library/Application Support/Harmony Focus'
        self.prefs = self.home / 'Library/Preferences/local.harmony.focus.plist'

    def tearDown(self):
        self.temp.cleanup()

    def run_helper(self, *arguments):
        return subprocess.run(['zsh', str(self.helper), *map(str, arguments)],
                              env=self.env, capture_output=True, text=True)

    def install(self):
        result = self.run_helper('install', self.source, self.launcher)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def commands(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_install_and_update_reload_service_without_starting_focus(self):
        self.install()
        self.assertEqual((self.app / 'version').read_text(), 'one')
        self.assertTrue(self.cli.is_file() and self.manager.is_file())
        record = plistlib.loads(self.agent.read_bytes())
        self.assertEqual(record['ProgramArguments'], [str(self.app / 'Contents/MacOS/HarmonyFocus'), '--supervised'])
        self.assertTrue(self.loaded.exists())
        (self.source / 'version').write_text('two')
        self.install()
        self.assertEqual((self.app / 'version').read_text(), 'two')
        self.assertTrue(any(command[0] == 'bootout' for command in self.commands()))
        self.assertFalse(any(command[0] == 'open' for command in self.commands()))

    def test_bootstrap_failure_restores_all_previous_artifacts_and_service(self):
        self.install()
        original_cli = self.cli.read_bytes()
        original_agent = self.agent.read_bytes()
        (self.source / 'version').write_text('two')
        self.launcher.write_text('#!/bin/zsh\n# updated\napp="$HOME/Applications/Harmony.app"\n')
        self.env['TEST_FAIL_BOOTSTRAP'] = '1'
        result = self.run_helper('install', self.source, self.launcher)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.app / 'version').read_text(), 'one')
        self.assertEqual(self.cli.read_bytes(), original_cli)
        self.assertEqual(self.agent.read_bytes(), original_agent)
        self.assertTrue(self.loaded.exists())

    def test_same_instance_lock_blocks_install_and_uninstall(self):
        self.state.mkdir(parents=True)
        with (self.state / 'instance.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            for arguments in [('install', self.source, self.launcher), ('uninstall',)]:
                result = self.run_helper(*arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Harmony is running', result.stderr)
        self.assertEqual(self.commands(), [])
        self.assertFalse(self.app.exists())

    def test_unfinished_or_corrupt_session_refuses_changes(self):
        self.prefs.parent.mkdir(parents=True)
        for value in [time.time() + 600, 'not-a-timestamp']:
            self.prefs.write_bytes(plistlib.dumps({'lockEnd': value}))
            result = self.run_helper('install', self.source, self.launcher)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(self.app.exists())
        self.assertEqual(self.commands(), [])

    def test_uninstall_preserves_data_by_default_and_erases_only_explicitly(self):
        self.install()
        config = self.state / 'configuration.json'
        config.write_text('{"private": "local-only"}')
        result = self.run_helper('uninstall')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(config.exists())
        for target in [self.app, self.cli, self.manager, self.agent]:
            self.assertFalse(target.exists(), target)
        self.assertFalse(self.loaded.exists())
        result = self.run_helper('uninstall')
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.run_helper('uninstall', '--remove-data')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.state.exists())

    def test_bad_signature_and_unowned_paths_are_not_replaced(self):
        self.env['TEST_FAIL_SIGNATURE'] = '1'
        result = self.run_helper('install', self.source, self.launcher)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.app.exists())
        self.env.pop('TEST_FAIL_SIGNATURE')
        self.cli.parent.mkdir(parents=True)
        self.cli.write_text('someone else owns this command')
        result = self.run_helper('install', self.source, self.launcher)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.cli.read_text(), 'someone else owns this command')
        self.cli.unlink()
        target = self.root / 'do-not-change'
        target.write_text('protected')
        self.cli.symlink_to(target)
        result = self.run_helper('install', self.source, self.launcher)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.cli.is_symlink())
        self.assertEqual(target.read_text(), 'protected')


if __name__ == '__main__':
    unittest.main()
