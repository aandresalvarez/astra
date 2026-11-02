import Foundation

/// The host publishes the ticket before the broker returns a launchable ID.
/// Both start and cancel lock the same immutable nonce file. A missing ticket
/// can never be recreated by a delayed launcher or interpreted as a receipt.
enum RemoteWorkspaceJobLaunchTicket {
    static func operation(_ operation: String, jobID: String, nonce: String) -> String {
        // These values become shell arguments before Python can check them.
        guard UUID(uuidString: jobID)?.uuidString.lowercased() == jobID,
              UUID(uuidString: nonce)?.uuidString.lowercased() == nonce,
              ["reserve", "start"].contains(operation) else { return "exit 1" }
        return """
        python3 - '\(jobID)' '\(nonce)' '\(operation)' <<'ASTRA_JOB_TICKET_PY'
        \(source)
        root = job_root(sys.argv[1])
        if sys.argv[3] == 'reserve':
            try: reserve(root, sys.argv[2], 'ready')
            except FileExistsError:
                print('astra_reservation_exists=' + sys.argv[1])
                sys.exit(\(RemoteWorkspaceJobScripts.existingJobExitCode))
        elif decide(root, sys.argv[2], 'start') != 'won':
            sys.exit(\(RemoteWorkspaceJobScripts.existingJobExitCode))
        ASTRA_JOB_TICKET_PY
        """
    }

    static let source = #"""
import datetime, fcntl, json, os, pathlib, stat, sys, uuid

def job_root(job):
    if str(uuid.UUID(job)) != job: raise ValueError('invalid job identity')
    root = pathlib.Path.home() / '.astra' / 'jobs' / job
    for directory in (root.parent.parent, root.parent, root):
        if directory.is_symlink(): raise ValueError('unsafe job directory')
    return root

def flush_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try: os.fsync(fd)
    finally: os.close(fd)

def save_ticket(root, nonce, state):
    value = {'job_id': root.name, 'nonce': nonce, 'state': state,
             'at': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}
    temporary = root / ('ticket-' + str(uuid.uuid4()) + '.tmp')
    with temporary.open('x') as output:
        json.dump(value, output)
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, root / 'launch-ticket.json')
    flush_dir(root)

def reserve(root, nonce, state):
    os.umask(0o077)
    for directory in (root.parent.parent, root.parent):
        try:
            directory.mkdir(mode=0o700)
            flush_dir(directory.parent)
        except FileExistsError: pass
        if directory.is_symlink() or not directory.is_dir(): raise ValueError('unsafe job root')
    # v2 launchers also require this exact mkdir to succeed.
    root.mkdir(mode=0o700)
    with (root / 'nonce').open('x') as output:
        output.write(nonce)
        output.flush()
        os.fsync(output.fileno())
    save_ticket(root, nonce, state)
    flush_dir(root.parent)

def read_ticket(root, nonce):
    path = root / 'launch-ticket.json'
    if not path.exists(): return None
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 1024:
        raise ValueError('unsafe launch ticket')
    value = json.loads(path.read_text())
    if value['job_id'] != root.name or value['nonce'] != nonce:
        raise ValueError('launch ticket identity mismatch')
    return value

def decide(root, nonce, action):
    fd = os.open(root / 'nonce', os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd) as identity:
        fcntl.flock(fd, fcntl.LOCK_EX)
        if not stat.S_ISREG(os.fstat(fd).st_mode) or identity.read(64) != nonce:
            raise ValueError('job identity mismatch')
        ticket = read_ticket(root, nonce)
        if ticket is None or ticket['state'] != 'ready': return 'already_decided'
        save_ticket(root, nonce, action)
        return 'won'
"""#
}
