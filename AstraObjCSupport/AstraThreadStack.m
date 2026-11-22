#import "AstraObjCSupport.h"

#include <mach/mach.h>
#include <mach/thread_act.h>
#include <mach/vm_map.h>
#include <pthread.h>

// Everything between `thread_suspend` and `thread_resume` below runs while the
// target thread is frozen at an arbitrary instruction. It may be holding the
// allocator lock, the Objective-C runtime lock or a Swift metadata lock, so
// this file is plain C and that region makes Mach calls only: no allocation,
// no Objective-C message, no Swift runtime, no logging. Anything else can wait
// forever on a lock whose owner is the thread this function stopped.

uint32_t AstraCurrentThreadPort(void) {
    return (uint32_t)pthread_mach_thread_np(pthread_self());
}

static int astra_read_frame_record(uintptr_t address, uintptr_t record[2]) {
    vm_size_t read = 0;
    // The kernel copies the bytes, so an unmapped or protected frame pointer
    // comes back as an error here instead of faulting this thread.
    kern_return_t result = vm_read_overwrite(
        mach_task_self(), (vm_address_t)address, sizeof(uintptr_t) * 2, (vm_address_t)record, &read);
    return result == KERN_SUCCESS && read == sizeof(uintptr_t) * 2;
}

// The 47 bits a user-space address uses. What sits above them is not part of
// the address: a pointer-authentication signature on a return address, and on
// a saved frame pointer the bit Swift sets to mark an async function's frame.
// A walk that kept that bit would stop at the first async frame.
static uintptr_t astra_address(uintptr_t value) {
    return value & 0x00007FFFFFFFFFFFULL;
}

int32_t AstraCaptureThreadStack(uint32_t threadPort, uintptr_t *frames, int32_t capacity) {
    thread_t thread = (thread_t)threadPort;
    if (frames == NULL || capacity <= 0 || thread == MACH_PORT_NULL) return 0;
    // A thread cannot be walked by itself this way: it would stop the walker.
    if (thread == pthread_mach_thread_np(pthread_self())) return 0;
    if (thread_suspend(thread) != KERN_SUCCESS) return 0;

    int32_t count = 0;
    uintptr_t programCounter = 0;
    uintptr_t framePointer = 0;
    int haveState = 0;

#if defined(__arm64__)
    arm_thread_state64_t state;
    mach_msg_type_number_t stateCount = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)&state, &stateCount) == KERN_SUCCESS) {
        programCounter = (uintptr_t)arm_thread_state64_get_pc(state);
        framePointer = (uintptr_t)arm_thread_state64_get_fp(state);
        haveState = 1;
    }
#elif defined(__x86_64__)
    x86_thread_state64_t state;
    mach_msg_type_number_t stateCount = x86_THREAD_STATE64_COUNT;
    if (thread_get_state(thread, x86_THREAD_STATE64, (thread_state_t)&state, &stateCount) == KERN_SUCCESS) {
        programCounter = (uintptr_t)state.__rip;
        framePointer = (uintptr_t)state.__rbp;
        haveState = 1;
    }
#endif

    if (haveState) {
        frames[count++] = astra_address(programCounter);
        framePointer = astra_address(framePointer);
        // Both ABIs keep a record of {caller's frame pointer, return address}
        // at the frame pointer. The stack grows down, so each record sits
        // above the one before it; anything else is a frame this walk cannot
        // trust, and it stops there.
        while (count < capacity && framePointer != 0 && (framePointer & (sizeof(uintptr_t) - 1)) == 0) {
            uintptr_t record[2] = {0, 0};
            if (!astra_read_frame_record(framePointer, record)) break;
            uintptr_t returnAddress = astra_address(record[1]);
            if (returnAddress == 0) break;
            frames[count++] = returnAddress;
            uintptr_t callerFrame = astra_address(record[0]);
            if (callerFrame <= framePointer) break;
            framePointer = callerFrame;
        }
    }

    thread_resume(thread);
    return count;
}
