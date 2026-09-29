#ifndef JessiPrebootRedirect_h
#define JessiPrebootRedirect_h

#ifdef __cplusplus
extern "C" {
#endif

// apple decided to make /private/preboot unreadable by a sandboxed app on iOS 27
// specifically because they hate fun. fuck you tim apple

void jessi_install_preboot_redirect(void);

#ifdef __cplusplus
}
#endif

#endif
