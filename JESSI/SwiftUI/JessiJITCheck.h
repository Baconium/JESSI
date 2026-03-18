#ifndef JessiJITCheck_h
#define JessiJITCheck_h

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

bool jessi_check_jit_enabled(void);
bool jessi_is_running_on_macos(void);
bool jessi_is_ios26_or_later(void);
bool jessi_is_txm_device(void);
bool jessi_is_debugger_attached(void);

bool jessi_is_trollstore_installed(void);
bool jessi_is_livecontainer_installed(void);
const char * _Nullable jessi_team_identifier(void);

#ifdef __cplusplus
}
#endif

#endif
