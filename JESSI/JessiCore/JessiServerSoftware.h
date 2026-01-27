#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, JessiServerSoftware) {
    JessiServerSoftwareVanilla = 0,
    JessiServerSoftwareFabric,
    JessiServerSoftwareQuilt,
    JessiServerSoftwareForge,
    JessiServerSoftwareNeoForge,
    JessiServerSoftwarePaper,
    JessiServerSoftwareCustomJar,
};

FOUNDATION_EXPORT NSString *JessiServerSoftwareDisplayName(JessiServerSoftware software);
FOUNDATION_EXPORT BOOL JessiServerSoftwareIsSupported(JessiServerSoftware software);
FOUNDATION_EXPORT BOOL JessiServerSoftwareIsCustomJar(JessiServerSoftware software);
