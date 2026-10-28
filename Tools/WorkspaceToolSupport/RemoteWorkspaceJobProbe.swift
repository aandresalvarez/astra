import Foundation

enum RemoteWorkspaceJobProbe {
    static let source = #"""
import json, os, pathlib, stat, subprocess, sys, uuid
job, nonce, operation, stream, count = sys.argv[1:]
if str(uuid.UUID(job)) != job or str(uuid.UUID(nonce)) != nonce:
    raise ValueError('invalid job identity')
root = pathlib.Path.home() / '.astra' / 'jobs' / job
for path in (root.parent.parent, root.parent, root):
    if path.is_symlink(): raise ValueError('unsafe job directory')
present = root.is_dir()
def read(name):
    path = root / name
    if not path.exists(): return None
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 65536:
        raise ValueError('unsafe or oversized job metadata')
    return json.loads(path.read_text())
if present:
    identity = root / 'nonce'
    if identity.is_symlink() or identity.read_text() != nonce:
        raise ValueError('job identity mismatch')
if operation == 'cancel' and present:
    temporary = root / ('cancel-request.tmp-' + str(os.getpid()))
    with temporary.open('x') as output:
        json.dump({'nonce': nonce}, output)
        output.flush(); os.fsync(output.fileno())
    os.replace(temporary, root / 'cancel-request.json')
if operation == 'tail':
    if stream not in ('stdout', 'stderr'): raise ValueError('invalid stream')
    print('astra_tail=' + ('1' if present else 'missing'))
    if present:
        path = root / (stream + '.log')
        if path.exists():
            if path.is_symlink() or not path.is_file(): raise ValueError('unsafe log')
            with path.open('rb') as log:
                log.seek(max(0, path.stat().st_size - 65536))
                data = log.read(65536).decode('utf-8', errors='replace')
            print('\n'.join(data.splitlines()[-min(500, int(count)):]))
    sys.exit(0)
try:
    boot = pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()
except OSError:
    boot = subprocess.check_output(['sysctl', '-n', 'kern.boottime'], text=True).strip()
if not boot: raise ValueError('host identity unavailable')
def alive(pid):
    if not isinstance(pid, int) or pid <= 1: return (False, '')
    probe = subprocess.run(['ps', '-o', 'stat=', '-o', 'lstart=', '-p', str(pid)], capture_output=True, text=True)
    if probe.returncode == 1 and not probe.stdout.strip(): return (False, '')
    if probe.returncode != 0: raise ValueError('process inspection failed')
    parts = probe.stdout.strip().split(None, 1)
    if len(parts) != 2: raise ValueError('incomplete process identity')
    return (not parts[0].startswith('Z'), parts[1])
evidence = read('process.json') if present else None
result = read('result.json') if present else None
for value in (evidence, result):
    if value is not None and (value.get('job_id') != job or value.get('nonce') != nonce):
        raise ValueError('metadata identity mismatch')
pid_live, pid_marker = alive(evidence.get('pid')) if evidence else (False, '')
supervisor_live, supervisor_marker = alive(evidence.get('supervisor_pid')) if evidence else (False, '')
fields = {'astra_probe': 2, 'job_id': job, 'nonce': nonce, 'host_boot_id': boot,
          'state': 'present' if present else 'missing', 'pid_alive': int(pid_live),
          'supervisor_alive': int(supervisor_live), 'pid_start_marker': pid_marker,
          'supervisor_start_marker': supervisor_marker}
if evidence: fields.update({'evidence.' + key: value for key, value in evidence.items()})
if result: fields['result'] = json.dumps(result)
if present:
    for name in ('stdout', 'stderr'):
        path = root / (name + '.log')
        if path.exists():
            if path.is_symlink() or not path.is_file(): raise ValueError('unsafe log')
            info = path.stat(); fields[name + '_bytes'] = info.st_size; fields[name + '_mtime'] = info.st_mtime
for key, value in fields.items(): print(str(key) + '=' + str(value))
print('astra_probe_end=' + job + ':' + nonce)
"""#
}
