#include "include/HarkForkBridge.h"
#include <unistd.h>

pid_t hark_fork(void) {
    return fork();
}
