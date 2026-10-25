#include <sys/resource.h>
#include <sys/mman.h>
#include <mach/mach.h>
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>

// Child-only limits: never lower ASTRA's own limits. Existing dyld shared
// mappings are enormous on macOS, so cap growth above the measured baseline.
static int constrain(void) {
    const uint64_t budget = 512ULL * 1024 * 1024;
    struct mach_task_basic_info info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return -1;
    if (info.virtual_size > UINT64_MAX - budget) return -1;
    struct rlimit address = {info.virtual_size + budget, info.virtual_size + budget};
    struct rlimit cpu = {120, 120};
    struct rlimit file = {64ULL * 1024 * 1024, 64ULL * 1024 * 1024};
    if (setrlimit(RLIMIT_AS, &address) || setrlimit(RLIMIT_CPU, &cpu) || setrlimit(RLIMIT_FSIZE, &file)) return -1;
    // Reserve only, never touch pages. Refuse to fetch if this OS accepts a
    // limit without enforcing it. No unbounded Git fallback is permitted.
    void *probe = mmap(NULL, budget + 4096, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (probe != MAP_FAILED) { munmap(probe, budget + 4096); return -1; }
    return 0;
}
int main(int argc, char **argv) {
    if (argc < 2 || argv[1][0] != '/') return 64;
    if (constrain()) { fputs("Plugin fetch resource limits unavailable.\n", stderr); return 77; }
    if (setenv("GIT_ALLOC_LIMIT", "67108864", 1)) return 77;
    execv(argv[1], argv + 1);
    perror("Plugin fetch executable");
    return 69;
}
