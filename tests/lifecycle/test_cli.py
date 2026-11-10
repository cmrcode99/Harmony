#!/usr/bin/env python3
"""Exercise the real launcher against fake OS/app endpoints; never touches the desktop."""
import json, os, pathlib, subprocess, tempfile, unittest

SOURCE = pathlib.Path(__file__).resolve().parents[2] / 'bin/harmony'

class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='harmony-cli-test-')
        self.root = pathlib.Path(self.tmp.name)
        self.log = self.root / 'calls.jsonl'
        self.env = {**os.environ, 'HOME': str(self.root), 'TEST_LOG': str(self.log), 'TEST_RUNNING': '1'}
        self.binary = self.root / 'Applications/Harmony.app/Contents/MacOS/HarmonyFocus'
        self.binary.parent.mkdir(parents=True)
        recorder = '#!/usr/bin/env python3\nimport json,os,sys\nwith open(os.environ["TEST_LOG"],"a") as f:f.write(json.dumps(sys.argv[1:])+"\\n")\n'
        self.binary.write_text(recorder.replace('import json,os,sys\n', 'import json,os,sys\nif sys.argv[1:]==["--is-running"]: sys.exit(2 if os.environ["TEST_RUNNING"]=="error" else (0 if os.environ["TEST_RUNNING"]=="1" else 1))\n')); self.binary.chmod(0o755)
        self.open = self.root / 'mock-open'; self.open.write_text(recorder); self.open.chmod(0o755)
        self.pgrep = self.root / 'mock-pgrep'
        self.pgrep.write_text('#!/bin/sh\n[ "$TEST_RUNNING" = 1 ]\n'); self.pgrep.chmod(0o755)
        self.launcher = self.root / 'harmony'
        self.launcher.write_text(SOURCE.read_text().replace('/usr/bin/open', str(self.open)).replace('/usr/bin/pgrep', str(self.pgrep)))
        self.launcher.chmod(0o755)
    def tearDown(self): self.tmp.cleanup()
    def run_cli(self, *args):
        self.log.unlink(missing_ok=True)
        result = subprocess.run([str(self.launcher), *args], env=self.env, capture_output=True, text=True)
        calls = [json.loads(x) for x in self.log.read_text().splitlines()] if self.log.exists() else []
        return result, calls
    def test_invalid_inputs_do_not_touch_app(self):
        for args in [('0',),('6',),('-1',),('1.5',),('01',),('+1',),('NaN',),('wat',),('1','2','3'),('',)]:
            with self.subTest(args=args):
                result,calls=self.run_cli(*args); self.assertEqual(result.returncode,2); self.assertEqual(calls,[])
    def test_setup_opens_only_configuration_when_off(self):
        self.env['TEST_RUNNING'] = '0'
        result, calls = self.run_cli('setup')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [[str(self.root / 'Applications/Harmony.app'), '--args', '--configure-only']])
        self.env['TEST_RUNNING'] = '1'
        result, calls = self.run_cli('setup')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(calls, [])

    def test_phone_setup_opens_configuration_only_when_off(self):
        self.env['TEST_RUNNING'] = '0'
        result, calls = self.run_cli('setup', 'phone')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [[str(self.root / 'Applications/Harmony.app'), '--args', '--configure-phone']])
        for state in ['1', 'error']:
            self.env['TEST_RUNNING'] = state
            result, calls = self.run_cli('setup', 'phone')
            self.assertEqual(result.returncode, 1)
            self.assertEqual(calls, [])
        for args in [('setup', 'unknown'), ('setup', 'phone', 'extra')]:
            result, calls = self.run_cli(*args)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(calls, [])

    def test_packaged_phone_shortcut_uses_the_same_command(self):
        shortcut = SOURCE.parents[1] / 'sharing/Setup iPhone.command'
        result = subprocess.run(['zsh', str(shortcut)], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('Install Harmony first', result.stderr)
        installed_cli = self.root / '.local/bin/harmony'
        installed_cli.parent.mkdir(parents=True)
        installed_cli.write_text(self.launcher.read_text())
        installed_cli.chmod(0o755)
        self.env['TEST_RUNNING'] = '0'
        result = subprocess.run(['zsh', str(shortcut)], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertEqual(calls, [[str(self.root / 'Applications/Harmony.app'), '--args', '--configure-phone']])

    def test_uninstall_uses_helper_without_opening_the_app(self):
        helper = self.root / '.local/lib/harmony/manage-install.sh'
        helper.parent.mkdir(parents=True)
        helper.write_text('#!/bin/zsh\nprint -r -- "$*" > "$TEST_LOG"\n')
        self.log.unlink(missing_ok=True)
        result = subprocess.run([str(self.launcher), 'uninstall', '--remove-data'], env=self.env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.log.read_text().strip(), 'uninstall --remove-data')
        helper.unlink()
        result = subprocess.run([str(self.launcher), 'uninstall'], env=self.env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('uninstall helper is missing', result.stderr)

    def test_running_actions(self):
        for args,action in [(('hide',),'hide'),(('unhide',),'unhide'),(('exit',),'exit'),(('phone',),'phone')]:
            with self.subTest(action=action):
                result,calls=self.run_cli(*args);self.assertEqual(result.returncode,0)
                self.assertEqual(calls[0],['--command',action])
                self.assertEqual(len(calls),1) # Phone must not reopen/activate Harmony.
    def test_running_start_commands_never_touch_app(self):
        for args in [(), *[(str(hours),) for hours in range(1,6)], ('0','30'), ('2','30'), ('5','0')]:
            with self.subTest(args=args):
                result,calls=self.run_cli(*args)
                self.assertEqual(result.returncode,1)
                self.assertEqual(calls,[])
                self.assertIn('Another instance of Harmony is already running.',result.stderr)
    def test_extend_routes_hours_without_reopening(self):
        for hours in range(1,6):
            result,calls=self.run_cli('extend',str(hours))
            self.assertEqual(result.returncode,0)
            self.assertEqual(calls,[['--command','extend',str(hours)]])
    def test_invalid_extend_arguments_never_touch_app(self):
        for args in [('extend',),('extend','0'),('extend','6'),('extend','-1'),('extend','1.5'),
                     ('extend','01'),('extend','+1'),('extend','NaN'),('extend',' 1'),('extend','1','2','3'),('hide','1')]:
            with self.subTest(args=args):
                result,calls=self.run_cli(*args)
                self.assertEqual(result.returncode,2)
                self.assertEqual(calls,[])
    def test_hours_minutes_start_and_extend(self):
        cases=[('0','1','1'),('0','30','30'),('2','30','30'),('4','59','59'),('5','0','0'),('2','05','5'),('5','00','0')]
        for hours,raw_minutes,minutes in cases:
            with self.subTest(hours=hours,minutes=raw_minutes):
                self.env['TEST_RUNNING']='0'
                result,calls=self.run_cli(hours,raw_minutes)
                self.assertEqual(result.returncode,0)
                self.assertEqual(calls,[['-g',str(self.root/'Applications/Harmony.app'),'--args','--launch-action','lock',hours,minutes]])
                result,calls=self.run_cli('extend',hours,raw_minutes)
                self.assertEqual(result.returncode,1)
                self.assertEqual(calls,[])
                self.env['TEST_RUNNING']='1'
                result,calls=self.run_cli('extend',hours,raw_minutes)
                self.assertEqual(result.returncode,0)
                self.assertEqual(calls,[['--command','extend',hours,minutes]])
    def test_invalid_minute_durations_do_not_touch_app(self):
        for duration in [('0','0'),('0','00'),('5','1'),('5','59'),('1','60'),('2','-1'),('2','1.5'),
                         ('2','059'),('2','000'),('2','+5'),('2',' 5'),('2','5 '),('02','30'),('6','0')]:
            for prefix in [(),('extend',)]:
                with self.subTest(args=prefix+duration):
                    result,calls=self.run_cli(*(prefix+duration))
                    self.assertEqual(result.returncode,2)
                    self.assertEqual(calls,[])
    def test_off_extend_never_starts_app(self):
        self.env['TEST_RUNNING']='0'
        for hours in range(1,6):
            result,calls=self.run_cli('extend',str(hours))
            self.assertEqual(result.returncode,1)
            self.assertEqual(calls,[])
    def test_off_control_commands_are_rejected(self):
        self.env['TEST_RUNNING']='0'
        for action in ['hide','unhide','exit','phone']:
            result,calls=self.run_cli(action);self.assertEqual(result.returncode,1);self.assertEqual(calls,[])
    def test_cold_start_and_lock(self):
        self.env['TEST_RUNNING']='0'
        result,calls=self.run_cli();self.assertEqual(result.returncode,0)
        self.assertEqual(calls,[['-g',str(self.root/'Applications/Harmony.app'),'--args','--launch-action','show']])
        for hours in range(1,6):
            result,calls=self.run_cli(str(hours));self.assertEqual(result.returncode,0)
            self.assertEqual(calls,[['-g',str(self.root/'Applications/Harmony.app'),'--args','--launch-action','lock',str(hours)]])
    def test_state_inspection_error_does_not_start(self):
        self.env['TEST_RUNNING']='error'
        result,calls=self.run_cli()
        self.assertEqual(result.returncode,1)
        self.assertEqual(calls,[])
        self.assertIn('Could not inspect',result.stderr)
    def test_help_does_not_launch(self):
        for running in ['0','1']:
            self.env['TEST_RUNNING']=running
            outputs=[]
            for alias in ['help','--help','-h']:
                result,calls=self.run_cli(alias);self.assertEqual(result.returncode,0);self.assertEqual(calls,[])
                outputs.append(result.stdout)
                for command in ['harmony 1..5','harmony extend N','harmony hide','harmony unhide','harmony phone','harmony setup phone','harmony exit','harmony help']:
                    self.assertIn(command,result.stdout)
            self.assertEqual(outputs[0],outputs[1]);self.assertEqual(outputs[1],outputs[2])
    def test_missing_install_is_clear(self):
        self.binary.unlink()
        result,calls=self.run_cli();self.assertEqual(result.returncode,1);self.assertIn('not installed',result.stderr);self.assertEqual(calls,[])

if __name__ == '__main__': unittest.main()
