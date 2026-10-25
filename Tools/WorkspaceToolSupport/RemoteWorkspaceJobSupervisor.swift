import Foundation

/// Runs on the SSH host with its existing Python 3. The scope process signals
/// its own group, never a PID read from a mutable record. This is cancellation
/// of a managed group, NOT containment of arbitrary detached/remote tools.
enum RemoteWorkspaceJobSupervisor {
    static let source = #"""
import base64, datetime, json, os, pathlib, signal, subprocess, sys, time
"""# + "\n" + RemoteWorkspaceJobClock.pythonSource + "\n" + #"""

root = pathlib.Path(sys.argv[1])
nonce = sys.argv[2]
timeout = int(sys.argv[3])
shell = sys.argv[4]
clock = json.loads(base64.b64decode(sys.argv[5]))

def stamp():
    return datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

def write(name, value):
    temporary = root / (name + '.tmp-' + str(os.getpid()))
    with temporary.open('x') as output:
        json.dump(value, output)
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, root / name)

def read(name):
    try:
        with (root / name).open() as source:
            return json.load(source)
    except (OSError, ValueError):
        return None

def boot_id():
    try:
        return pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()
    except OSError:
        return subprocess.check_output(['sysctl', '-n', 'kern.boottime'], text=True).strip()

def marker(pid):
    return subprocess.check_output(['ps', '-o', 'lstart=', '-p', str(pid)], text=True).strip()

def requested():
    value = read('cancel-request.json')
    return isinstance(value, dict) and value.get('nonce') == nonce

def members():
    # The ps process itself temporarily belongs to this group. Exclude its
    # exact PID, not command names; a job can name itself anything it likes.
    probe = subprocess.Popen(['ps', '-axo', 'pid=,pgid=,stat='], stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True)
    output, _ = probe.communicate()
    if probe.returncode != 0:
        return None
    remaining = []
    for row in output.splitlines():
        parts = row.split()
        if len(parts) < 3:
            return None
        try:
            pid, group = int(parts[0]), int(parts[1])
        except ValueError:
            return None
        if group == os.getpgrp() and pid not in (os.getpid(), probe.pid) and not parts[2].startswith('Z'):
            remaining.append(pid)
    return remaining

def scope():
    os.setsid()
    # Caught handlers reset to defaults when the command execs; the scope
    # remains alive through TERM so KILL still happens if a child ignores it.
    signal.signal(signal.SIGTERM, lambda *_: None)
    process = {
        'pid': os.getpid(), 'start_marker': marker(os.getpid()),
        'supervisor_pid': os.getppid(), 'supervisor_start_marker': marker(os.getppid()),
        'boot_id': boot_id(), 'started_at': stamp(), 'isolation': 'managed_process_group',
        'shell': shell, 'nonce': nonce, 'job_id': root.name,
    }
    write('process.json', process)
    # Cancellation may have arrived after registration but before launch.
    if requested():
        write('scope-result.json', {'status': 'cancelled', 'exit_code': 130, 'command_started': False})
        return
    if clock.get('clockDomain') != '\#(RemoteWorkspaceJobClock.domain)' or clock.get('bootID') != boot_id():
        write('scope-result.json', {'status': 'failed', 'exit_code': 125, 'command_started': False})
        return
    deadline = min(clock['deadline'], monotonic_now() + timeout) if timeout else clock['deadline']
    remaining = deadline - monotonic_now()
    if remaining <= 0:
        write('scope-result.json', {'status': 'timed_out', 'exit_code': 124, 'command_started': False})
        return
    with (root / 'stdout.log').open('ab') as out, (root / 'stderr.log').open('ab') as err:
        command = subprocess.Popen([shell, str(root / 'command.sh')], stdin=subprocess.DEVNULL,
                                   stdout=out, stderr=err, cwd=os.path.expanduser('~'))
        stopping_at = None
        stopping_reason = None
        while True:
            code = command.poll()
            active = members()
            if stopping_at is None and (requested() or (deadline is not None and monotonic_now() >= deadline)):
                stopping_reason = 'cancelled' if requested() else 'timed_out'
                write('stop-request.json', {'status': stopping_reason, 'nonce': nonce})
                stopping_at = monotonic_now()
                # This process is a live member/leader of this exact group.
                # No stale PID lookup can redirect the signal elsewhere.
                os.killpg(os.getpgrp(), signal.SIGTERM)
            if code is not None and active == []:
                status = stopping_reason or ('succeeded' if code == 0 else 'failed')
                write('scope-result.json', {'status': status, 'exit_code': code, 'command_started': True})
                return
            if stopping_at is not None and monotonic_now() - stopping_at >= 3:
                # Includes this anchor. The outer supervisor reaps it and
                # records the outcome. Escaped work remains unverified.
                os.killpg(os.getpgrp(), signal.SIGKILL)
            time.sleep(0.1)

os.umask(0o077)
os.setsid()
child = os.fork()
if child == 0:
    try:
        scope()
        os._exit(0)
    except BaseException:
        os._exit(125)
_, wait_status = os.waitpid(child, 0)
outcome = read('scope-result.json')
stop = read('stop-request.json')
if not isinstance(outcome, dict):
    reason = stop.get('status') if isinstance(stop, dict) and stop.get('nonce') == nonce else None
    outcome = {'status': reason if reason in ('cancelled', 'timed_out') else 'failed',
               'exit_code': os.waitstatus_to_exitcode(wait_status)}
outcome.update({'job_id': root.name, 'nonce': nonce, 'completed_at': stamp(),
                'cleanup_verified': False})
write('result.json', outcome)
"""#
}
