//
//  JessiJITBypass.c
//  JESSI
//
//  Created by roooot on 30.01.26.
//

#include "JessiJITBypass.h"
#include "JessiJITCheck.h"
#include <stdlib.h>
#include <unistd.h>

// volatile uint32_t mailbox = 0x50494e47; // PING

// int jessi_ping_stikdebug(void) {
//     mailbox = 0x50494e47; // PING
//     printf("[JESSI] pinging script");
//     usleep(10000);
//     if (mailbox == 0x504f4e47) { // PONG
//         printf("[JESSI] got ping response");
//         return 1;
//     }
//
//     return 0;
// }

void trigger_ios26_jit(void *addr, size_t len) {
    printf("[JESSI] Triggering JIT bypass at address %p (size: %zu)\n", addr, len);
    __asm__ (
        "mov x0, %0 \n"
        "mov x1, %1 \n"
        "mov x16, #1 \n" // JIT26PrepareRegion
        "brk #0xf00d \n"
        : : "r"(addr), "r"(len) : "x0", "x1", "x16"
    );
}
