#import "JessiServerSoftware.h"

NSString *JessiServerSoftwareDisplayName(JessiServerSoftware software) {
    switch (software) {
        case JessiServerSoftwareVanilla: return @"Vanilla";
        case JessiServerSoftwareFabric: return @"Fabric";
        case JessiServerSoftwareQuilt: return @"Quilt";
        case JessiServerSoftwareForge: return @"Forge";
        case JessiServerSoftwareNeoForge: return @"NeoForge";
        case JessiServerSoftwarePaper: return @"Paper";
        case JessiServerSoftwareCustomJar: return @"Import Custom Jar";
    }
    return @"Unknown";
}

BOOL JessiServerSoftwareIsCustomJar(JessiServerSoftware software) {
    return software == JessiServerSoftwareCustomJar;
}

BOOL JessiServerSoftwareIsSupported(JessiServerSoftware software) {
    switch (software) {
        case JessiServerSoftwareVanilla:
        case JessiServerSoftwareFabric:
        case JessiServerSoftwareQuilt:
        case JessiServerSoftwareForge:
        case JessiServerSoftwareNeoForge:
        case JessiServerSoftwarePaper:
        case JessiServerSoftwareCustomJar:
            return YES;
    }
    return NO;
}
