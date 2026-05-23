// Bridges the POSIX fork(2) function — which Swift marks `unavailable`
// in modern macOS toolchains because the runtime can't safely survive
// it in a multithreaded process. We use it in test code only, where the
// child immediately raises a fatal signal and dies before touching any
// of the Swift runtime's per-thread state.
//
// Returning `pid_t` (typically int32_t on macOS) keeps the Swift call
// site portable.

#ifndef HARK_FORK_BRIDGE_H
#define HARK_FORK_BRIDGE_H

#include <sys/types.h>

pid_t hark_fork(void);

#endif
