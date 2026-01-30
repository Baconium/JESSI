//
//  JessiJITBypass.h
//  JESSI
//
//  Created by roooot on 30.01.26.
//

#ifndef JessiJITBypass_h
#define JessiJITBypass_h

#include <stdio.h>
#include <stdint.h>

extern volatile uint32_t mailbox;

// int jessi_ping_stikdebug(void);

void trigger_ios26_jit(void *addr, size_t len);

#endif
