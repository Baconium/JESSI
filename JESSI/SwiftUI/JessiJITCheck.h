#ifndef JessiJITCheck_h
#define JessiJITCheck_h

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

bool jessi_check_jit_enabled(void);
bool jessi_is_ios26_or_later(void);
bool jessi_is_txm_device(void);

#ifdef __cplusplus
}
#endif

#endif
