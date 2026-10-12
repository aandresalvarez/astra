import Darwin

/// Whether `pid` is still a live process. `kill(pid, 0)` can't tell: on macOS
/// it succeeds for a process that exited but nobody has reaped yet, and a
/// killed grandchild waits on launchd for that.
func processIsRunning(_ pid: pid_t) -> Bool {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
    return info.pbi_status != UInt32(SZOMB) && info.pbi_flags & UInt32(PROC_FLAG_INEXIT) == 0
}
