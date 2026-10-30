#!/usr/bin/env python3
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch
import permission_repair_test_harness as harness


class PermissionHarnessTests(unittest.TestCase):
    def test_rejects_invalid_requests_before_launch(self):
        for request in [None, [], {'executable': []}, {'executable': '/bin/echo', 'arguments': []},
                        {'executable': '/bin/sh', 'arguments': 'bad'}, {'executable': '/bin/sh', 'arguments': [1]}]:
            with self.subTest(request=request), patch.object(subprocess, 'Popen') as launch:
                with self.assertRaises(ValueError):
                    harness.execute(request)
                launch.assert_not_called()

    def test_real_repair_preserves_failure_status_and_output(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / 'config with spaces.json'
            file.write_text('{}')
            file.chmod(0)
            result = harness.execute({'executable': '/bin/chmod', 'arguments': ['u+r', str(file)]})
            self.assertEqual(result['exitCode'], 0)
            self.assertEqual(file.stat().st_mode & 0o777, 0o400)
            result = harness.execute({'executable': '/bin/sh', 'arguments': ['-c', 'printf failed >&2; exit 7']})
            self.assertEqual(result['exitCode'], 7)
            self.assertEqual(result['stderr'], 'failed')

    def test_timeout_reaps_command(self):
        with patch.object(harness, 'COMMAND_TIMEOUT', 0.05):
            result = harness.execute({'executable': '/bin/sh', 'arguments': ['-c', 'sleep 60']})
        self.assertEqual(result['exitCode'], 124)

    def test_partial_request_cannot_execute(self):
        reader, writer = socket.socketpair()
        with reader, writer, patch.object(harness, 'execute') as execute:
            writer.sendall(b'{')
            writer.shutdown(socket.SHUT_WR)
            with self.assertRaises(ValueError):
                harness.serve_request(reader)
            execute.assert_not_called()

    def test_oversized_request_cannot_execute(self):
        reader, writer = socket.socketpair()
        with reader, writer, patch.object(harness, 'execute') as execute, patch.object(harness, 'MAX_REQUEST_BYTES', 8):
            writer.sendall(b'{"tooLong":true}\n')
            with self.assertRaises(ValueError):
                harness.serve_request(reader)
            execute.assert_not_called()

    def test_wrapper_endpoint_lifecycle_and_exit_code(self):
        code = '''import json,os,socket,sys
from pathlib import Path
path=os.environ['ASTRA_PERMISSION_TEST_SOCKET']
Path(sys.argv[1]).write_text(path)
assert Path(path).stat().st_mode & 0o777 == 0o600
assert Path(path).parent.stat().st_mode & 0o777 == 0o700
with socket.socket(socket.AF_UNIX) as client:
 client.connect(path)
 client.sendall(json.dumps({'executable':'/bin/sh','arguments':['-c','printf "%s" "$PPID"; exit 7']}).encode()+b'\\n')
 data=b''
 while b'\\n' not in data: data+=client.recv(4096)
 result=json.loads(data)
 assert result['executorPID']!=os.getpid()
 assert str(result['executorPID'])==result['stdout']
 assert result['exitCode']==7
sys.exit(23)
'''
        with tempfile.TemporaryDirectory() as directory:
            record = Path(directory) / 'endpoint'
            self.assertEqual(harness.run([sys.executable, '-c', code, str(record)]), 23)
            self.assertFalse(Path(record.read_text()).parent.exists())

    def test_renamed_helpers_inherit_a_fresh_provider_namespace_even_on_failure(self):
        code = '''import json,os,subprocess,sys,uuid
from pathlib import Path
key='ASTRA_TEST_PROVIDER_NAMESPACE_ID'
identifier=str(uuid.UUID(os.environ[key]))
child=subprocess.check_output(['/bin/sh','-c','printf "%s" "$ASTRA_TEST_PROVIDER_NAMESPACE_ID"','renamed-provider-helper'],text=True)
assert str(uuid.UUID(child))==identifier
Path(sys.argv[1]).write_text(identifier)
sys.exit(19)
'''
        with tempfile.TemporaryDirectory() as directory:
            seen = []
            for index in range(2):
                record = Path(directory) / str(index)
                with patch.dict(os.environ, {'ASTRA_TEST_PROVIDER_NAMESPACE_ID': 'invalid-parent-marker'}):
                    self.assertEqual(harness.run([sys.executable, '-c', code, str(record)]), 19)
                seen.append(uuid.UUID(record.read_text()))
            self.assertNotEqual(seen[0], seen[1])

    def test_cancellation_reaps_active_command_and_test_process(self):
        code = """import json,os,socket,sys
from pathlib import Path
Path(sys.argv[1]).write_text(str(os.getpid()))
with socket.socket(socket.AF_UNIX) as client:
 client.connect(os.environ['ASTRA_PERMISSION_TEST_SOCKET'])
 assert os.environ['ASTRA_TEST_PROVIDER_NAMESPACE_ID']
 command='echo $$ > "'+sys.argv[2]+'"; sleep 60'
 client.sendall(json.dumps({'executable':'/bin/sh','arguments':['-c',command]}).encode()+b'\\n')
 client.recv(4096)
"""
        with tempfile.TemporaryDirectory() as directory:
            test_pid = Path(directory) / 'test.pid'
            command_pid = Path(directory) / 'command.pid'
            wrapper = subprocess.Popen([sys.executable, str(Path(harness.__file__)), sys.executable,
                                        '-c', code, str(test_pid), str(command_pid)])
            try:
                deadline = time.monotonic() + 15
                while not command_pid.exists() and wrapper.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(command_pid.exists())
                wrapper.send_signal(signal.SIGTERM)
                self.assertEqual(wrapper.wait(timeout=15), 130)
                for path in [test_pid, command_pid]:
                    with self.assertRaises(ProcessLookupError):
                        os.kill(int(path.read_text()), 0)
            finally:
                if wrapper.poll() is None:
                    wrapper.kill()
                    wrapper.wait()

    def test_cancellation_cleans_a_separate_helper_process_group(self):
        code = """import os,signal,subprocess,sys,time
from pathlib import Path
subprocess.Popen([sys.executable,'-c',
 'import os,signal,sys,time; from pathlib import Path; signal.signal(signal.SIGINT,signal.SIG_IGN); Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(60)',
 sys.argv[1]],start_new_session=True)
while True: time.sleep(1)
"""
        with tempfile.TemporaryDirectory() as directory:
            helper_pid = Path(directory) / 'helper.pid'
            wrapper = subprocess.Popen([sys.executable, str(Path(harness.__file__)), sys.executable,
                                        '-c', code, str(helper_pid)], stderr=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 15
                while not helper_pid.exists() and wrapper.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(helper_pid.exists())
                pid = int(helper_pid.read_text())
                wrapper.send_signal(signal.SIGTERM)
                self.assertEqual(wrapper.wait(timeout=15), 130)
                # Reparented helpers are reaped by the OS, which can be asynchronous.
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    try: os.kill(pid, 0)
                    except ProcessLookupError: break
                    time.sleep(0.01)
                else: self.fail('Separate helper survived cancellation')
            finally:
                if wrapper.poll() is None:
                    wrapper.kill()
                    wrapper.wait()
                if helper_pid.exists():
                    try: os.killpg(int(helper_pid.read_text()), signal.SIGKILL)
                    except ProcessLookupError: pass

    def test_test_executor_contains_no_process_launch(self):
        root = Path(__file__).resolve().parents[1]
        source = (root / 'Tests/CopilotHomeAccessCheckTests.swift').read_text()
        self.assertNotIn('Process()', source)
        self.assertIn('PermissionRepairCommandClient.run(executable, arguments)', source)
        for path in ['script/precommit.sh', 'script/prepush.sh']:
            text = (root / path).read_text()
            self.assertNotIn('run swift test --filter', text)
            self.assertIn('script/swift_test.sh --filter', text)
        self.assertIn('script/swift_test.sh --no-parallel', (root / '.github/workflows/ci.yml').read_text())


if __name__ == '__main__':
    unittest.main()
