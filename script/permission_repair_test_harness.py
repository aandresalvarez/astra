#!/usr/bin/env python3
"""Run Swift tests with permission-command execution outside their executor.

The private, synchronous Unix-socket server owns and reaps each command. It is
started before SwiftPM, uses no worker threads, and exists only for this run.
"""
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

SOCKET_ENV = 'ASTRA_PERMISSION_TEST_SOCKET'
ALLOWED_EXECUTABLES = {'/bin/sh', '/bin/chmod', '/usr/bin/chflags'}
MAX_REQUEST_BYTES = 65536
COMMAND_TIMEOUT = 15


def terminate_group(process):
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()



def stop_test_process(process):
    # SwiftPM starts its testing helper in a separate process group. Snapshot
    # descendants before signalling the driver, while parentage is still known.
    groups = {process.pid}
    if process.poll() is None:
        rows = subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid='], text=True)
        parents = {int(row.split()[0]): int(row.split()[1]) for row in rows.splitlines() if row.strip()}
        descendants = {process.pid}
        while True:
            found = {pid for pid, parent in parents.items() if parent in descendants}
            expanded = descendants | found
            if expanded == descendants:
                break
            descendants = expanded
        for pid in descendants:
            try:
                groups.add(os.getpgid(pid))
            except ProcessLookupError:
                pass
        try:
            process.send_signal(signal.SIGINT)
            process.wait(timeout=3)
        except (ProcessLookupError, subprocess.TimeoutExpired):
            pass
    for group in groups - {os.getpgrp()}:
        try:
            os.killpg(group, signal.SIGKILL)
        except ProcessLookupError:
            pass
    process.wait()


def execute(request):
    if not isinstance(request, dict):
        raise ValueError('Invalid permission-test request')
    executable = request.get('executable')
    arguments = request.get('arguments')
    if not isinstance(executable, str) or executable not in ALLOWED_EXECUTABLES or not isinstance(arguments, list) or not all(isinstance(a, str) for a in arguments):
        raise ValueError('Invalid permission-test command')
    # File-backed output cannot hang pipe draining if a command leaves a child.
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        child = subprocess.Popen([executable, *arguments], stdin=subprocess.DEVNULL,
                                 stdout=out, stderr=err, start_new_session=True)
        try:
            code = child.wait(timeout=COMMAND_TIMEOUT)
        except subprocess.TimeoutExpired:
            terminate_group(child)
            return {'exitCode': 124, 'stderr': 'Permission command timed out'}
        except BaseException:
            terminate_group(child)
            raise
        # Reap descendants too: a successful shell must not leave test work alive.
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        out.seek(0)
        err.seek(0)
        return {'exitCode': code, 'stdout': out.read(8192).decode(errors='replace'),
                'stderr': err.read(8192).decode(errors='replace')}


def serve_request(connection):
    connection.settimeout(COMMAND_TIMEOUT + 2)
    data = bytearray()
    while b'\n' not in data:
        chunk = connection.recv(4096)
        if not chunk:
            raise ValueError('Incomplete permission-test request')
        data.extend(chunk)
        if len(data) > MAX_REQUEST_BYTES:
            raise ValueError('Permission-test request exceeds limit')
    return execute(json.loads(data.split(b'\n', 1)[0]))


def run(command):
    if not command:
        raise ValueError('Missing test command')
    with tempfile.TemporaryDirectory(prefix='astra-permission-', dir='/tmp') as directory:
        path = str(Path(directory) / 'commands.sock')
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
            server.bind(path)
            os.chmod(path, 0o600)
            server.listen(128)
            server.settimeout(0.1)
            child = subprocess.Popen(command, env=dict(os.environ, **{SOCKET_ENV: path}), start_new_session=True)
            previous = {}

            def interrupted(number, _frame):
                raise KeyboardInterrupt

            try:
                for number in (signal.SIGINT, signal.SIGTERM):
                    previous[number] = signal.signal(number, interrupted)
                while child.poll() is None:
                    try:
                        connection, _ = server.accept()
                    except socket.timeout:
                        continue
                    with connection:
                        try:
                            response = serve_request(connection)
                            response['executorPID'] = os.getpid()
                        except (ValueError, OSError) as error:
                            response = {'exitCode': 125, 'stderr': str(error)}
                        try:
                            connection.sendall(json.dumps(response).encode() + b'\n')
                        except OSError:
                            pass  # A cancelled test no longer consumes the result.
                return child.returncode
            except KeyboardInterrupt:
                return 130
            finally:
                # Also clean descendants after normal SwiftPM termination.
                stop_test_process(child)
                for number, handler in previous.items():
                    signal.signal(number, handler)


if __name__ == '__main__':
    try:
        sys.exit(run(sys.argv[1:]))
    except (ValueError, OSError) as error:
        print('Permission-test harness: ' + str(error), file=sys.stderr)
        sys.exit(125)
