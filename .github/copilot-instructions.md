# JESSI - AI Coding Assistant Instructions

## Project Overview
JESSI is a jailed iOS app that runs Minecraft: Java Edition servers natively on iOS devices (targeting iOS 14+). The app embeds multiple JRE versions (Java 8, 17, 21) and uses JIT compilation to execute Minecraft server JARs. It's built using Objective-C for core services and SwiftUI for the UI layer.

## Architecture

### Core Components
- **JessiJavaRunner** ([JessiJavaRunner.m](JESSI/JessiCore/JessiJavaRunner.m)): Loads and invokes the embedded JVM using `JLI_Launch`. Handles Java home path resolution for different Java versions, stdio redirection to log files, and dynamic JVM library loading.
- **JessiServerService** ([JessiServerService.m](JESSI/JessiCore/JessiServerService.m)): Manages server lifecycle (start/stop), RCON communication, log tailing, and server configuration. Automatically configures `server.properties` with RCON enabled and generates random RCON passwords stored in `.jessi_rcon_password`.
- **SwiftUI Views** ([JESSI/SwiftUI/](JESSI/SwiftUI/)): Tab-based interface with `RootTabView` hosting server manager, launch controls, and settings. Uses `@objc` bridging to expose view controllers to the Objective-C app delegate.
- **Mach Exception Handling** ([mach/mach_excServer.c](JESSI/JessiCore/mach/mach_excServer.c)): Handles JIT-related Mach exceptions for iOS 26+ compatibility via debugger protocol.

### Critical Constraint: In-Process JVM
The JVM **must** run in the same process as the app on jailed devices (no separate processes allowed). This means when the JVM exits (server stop, Forge/NeoForge installer), the entire app terminates. This is by design and **not a crash** - iOS doesn't log it as a crash. Never attempt to run Java in a separate process unless explicitly targeting jailbroken devices.

### Data Flow
1. User selects server → `JessiServerService.startServerNamed:` configures server directory
2. Service auto-generates/updates `server.properties` with RCON credentials
3. `jessi_server_main()` spawns server process with selected Java version and memory settings
4. Server output redirected to `logs/latest.log`, tailed by dispatch timer every 500ms
5. RCON commands sent via TCP socket on port 25575 for console interaction

## Build & Development Workflow

### Building
```bash
# 1. Fetch embedded Java runtimes (Java 8, 17, 21 for iOS ARM64)
./scripts/fetch-runtimes.sh

# 2. Build IPA (uses xcodebuild with CODE_SIGNING_ALLOWED=NO for TrollStore)
./scripts/build-ipa.sh
```

**Critical**: Both Java runtime directories (`Runtimes/java`, `Runtimes/java17`, `Runtimes/java21`) must exist before building. The build script explicitly checks for these.

### Project Structure
- `JESSI/JessiCore/` - Objective-C services and JVM integration
- `JESSI/SwiftUI/` - SwiftUI views with Objective-C bridging header
- `Config/` - Entitlements and Info.plist (note: `dynamic-codesigning` entitlement checked in [JessiJITCheck.m](JESSI/SwiftUI/JessiJITCheck.m))
- `Runtimes/` - Embedded JRE bundles (not committed, fetched via script)

### JIT Enablement
The app requires JIT to function. JIT status is checked via `jessi_check_jit_enabled()` which tests for:
1. `dynamic-codesigning` entitlement (TrollStore apps)
2. `CS_DEBUGGED` flag via `csops()` (debugger-enabled)

For iOS 17.4-18.7.4, users need LocalDevVPN + StikDebug for JIT. iOS 26 uses custom debugger protocol (see [UniversalJIT26Extension.js](JESSI/Resources/UniversalJIT26Extension.js)).

## Code Conventions

### Objective-C Style
- Use modern Objective-C: `@property` with `nonatomic`, explicit nullability (`NS_ASSUME_NONNULL_BEGIN`)
- Naming: `jessi_` prefix for C functions, `Jessi` prefix for classes
- Settings stored via `JessiSettings.shared` (singleton pattern) - see [JessiSettings.h](JESSI/JessiCore/JessiSettings.h)
- Paths via `JessiPaths` class methods (e.g., `[JessiPaths serversRoot]`)

### Swift-ObjC Bridging
- SwiftUI entry points expose static `@objc` methods returning `UIViewController` (see [SwiftUIEntry.swift](JESSI/SwiftUI/SwiftUIEntry.swift))
- Use `Bridging.h` for Objective-C imports into Swift
- Objective-C delegates use protocols (e.g., `JessiServerServiceDelegate`)

### Server Configuration Pattern
When modifying server setup logic, follow the pattern in `configureServerFilesInDir:`:
1. Auto-create `eula.txt` with `eula=true`
2. Parse existing `server.properties` as key-value pairs
3. Forcibly override: `enable-rcon=true`, `rcon.port=25575`, `rcon.password=<generated>`
4. Write properties back sorted alphabetically

### Log Handling
Server logs are tailed from `<server-dir>/logs/latest.log` using a 500ms dispatch timer. RCON-related log lines are filtered out to avoid console spam. When adding log parsing, respect the existing pattern in `startTailingLatestLogInDir:`.

## Common Pitfalls

1. **Don't attempt subprocess spawning** - The JVM must run in-process. Use `jessi_server_main()` directly.
2. **Java version directories** - Must be named exactly `java` (Java 8), `java17`, `java21` in the app bundle root.
3. **RCON password persistence** - Always stored in `.jessi_rcon_password`, never hardcoded.
4. **App crashes after server stop** - This is expected behavior on jailed devices, not a bug to fix.
5. **Bundle ID fallback** - `main.m` uses method swizzling to provide bundle ID fallback for LiveContainer compatibility.

## Key Files for Understanding
- [JessiServerService.m](JESSI/JessiCore/JessiServerService.m) - Server lifecycle management
- [JessiJavaRunner.m](JESSI/JessiCore/JessiJavaRunner.m) - JVM invocation mechanics
- [main.m](JESSI/JessiCore/main.m) - Bundle ID swizzling and app entry point
- [LaunchView.swift](JESSI/SwiftUI/LaunchView.swift) - Console UI and RCON command sending
- [JessiJITCheck.m](JESSI/SwiftUI/JessiJITCheck.m) - JIT enablement detection
