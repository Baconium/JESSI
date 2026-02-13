import SwiftUI
import Combine
import UIKit
import Darwin
import ZIPFoundation
import SWCompression

private struct InstallJVMRow: View {
    let version: String
    let isInstalled: Bool
    let isUnsupported: Bool
    let isSelected: Bool
    let isInstalling: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                Image(systemName: isInstalled ? "checkmark.circle.fill" : (isSelected ? "checkmark.circle.fill" : "circle"))
                    .foregroundColor(isInstalled ? .green : (isSelected ? Color.accentColor : .secondary))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Java \(version)")
                        .foregroundColor(.primary)

                    if isUnsupported {
                        Text("Not supported on iOS 26+")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if isInstalling {
                        Text("Installing…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if isInstalled {
                        Text("Installed")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isUnsupported || isInstalled)
    }
}

final class SettingsModel: ObservableObject {
    @Published var availableJavaVersions: [String] = []
    @Published var javaVersion: String = "8"
    @Published var heapText: String = "768"
    @Published var heapMB: Int = 768
    @Published var flagNettyNoNative: Bool = true
    @Published var flagJnaNoSys: Bool = false
    @Published var txmSupport: Bool = true
    @Published var isJITEnabled: Bool = false
    @Published var totalRAM: String = ""
    @Published var freeRAM: String = ""
    @Published var launchArgs: String = ""
    @Published var isIOS26: Bool = false
    @Published var iOSVersionString: String = ""

    @Published var installedJVMVersions: Set<String> = []

    @Published var heapMaxMB: Int = 8192

    @Published var installErrorMessage: String? = nil
    @Published var showInstallError: Bool = false
    
    @Published var showClearCacheAlert: Bool = false
    @Published var showClearCacheSuccess: Bool = false
    @Published var showClearCacheError: Bool = false
    @Published var clearCacheErrorMessage: String? = nil

    let allJVMVersions: [String] = ["8", "17", "21"]

    init() {
        let s = JessiSettings.shared()

        let os = ProcessInfo.processInfo.operatingSystemVersion
        
        let totalMB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024))
        heapMaxMB = max(128, totalMB)
        
        if os.patchVersion>0 {
            iOSVersionString = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        } else {
            iOSVersionString = "\(os.majorVersion).\(os.minorVersion)"
        }

        availableJavaVersions = JessiSettings.availableJavaVersions()
        javaVersion = s.javaVersion

        let d = UserDefaults.standard
        let hasUserHeap = d.object(forKey: "jessi.maxHeapMB") != nil
        let desiredDefault = max(128, (heapMaxMB / 2 / 64) * 64)
        let configured = hasUserHeap ? s.maxHeapMB : desiredDefault
        applyAndSaveHeap(configured)

        flagNettyNoNative = s.flagNettyNoNative
        flagJnaNoSys = s.flagJnaNoSys
        isJITEnabled = isJITEnabledCheck()
        totalRAM = formatRAM(ProcessInfo.processInfo.physicalMemory)
        refreshSystemStats()
        launchArgs = s.launchArguments
        isIOS26 = jessi_is_ios26_or_later()
        txmSupport = s.txmSupport

        refreshInstalledJVMVersions()
    }

    func applyAndSaveJavaVersion(_ ver: String) {
        let s = JessiSettings.shared()
        s.javaVersion = ver
        s.save()
    }

    func applyAndSaveLaunchArgs() {
        let s = JessiSettings.shared()
        s.launchArguments = launchArgs
        s.save()
    }

    func applyAndSaveTxmSupport() {
        let s = JessiSettings.shared()
        s.txmSupport = txmSupport
        s.save()
    }

    func applyAndSaveHeap(_ mb: Int) {
        let clamped = max(128, min(heapMaxMB, mb))
        let snapped = (clamped / 64) * 64

        heapMB = snapped
        heapText = String(snapped)

        let s = JessiSettings.shared()
        s.maxHeapMB = snapped
        s.save()
    }

    
    func applyAndSaveFlags() {
        let s = JessiSettings.shared()
        s.flagNettyNoNative = flagNettyNoNative
        s.flagJnaNoSys = flagJnaNoSys
        s.save()
    }

    func refreshSystemStats() {
        freeRAM = formatRAM(getAvailableMemoryEstimate())
    }

    func applyHeapFromText() {
        let raw = heapText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            heapText = String(heapMB)
            return
        }
        applyAndSaveHeap(Int(raw) ?? heapMB)
    }

    var heapDescription: String {
        if heapMB < 513 { return "Low — the server will be highly unstable with this little ram" }
        if heapMB > 4095 { return "High — JESSI may crash!" }
        return "Recommended: approximately half of your device's total ram. if you exceed the amount of ram your device has available, JESSI will crash!"
    }

    private func isJITEnabledCheck() -> Bool {
        return jessi_check_jit_enabled()
    }

    private func formatRAM(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        return String(format: "%.0f MB", mb)
    }

    private struct SystemMemoryEstimate {
        let pageSize: UInt64
        let strictFreeBytes: UInt64
        let availableBytes: UInt64
        let wiredBytes: UInt64
        let compressedBytes: UInt64
    }

    private func estimateSystemMemory() -> SystemMemoryEstimate? {
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
        let p = UInt64(pageSize)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: stats) / MemoryLayout<integer_t>.size)

        let kerr: kern_return_t = withUnsafeMutablePointer(to: &stats) { statsPtr in
            statsPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return nil }

        let freePages = UInt64(stats.free_count)
        let speculativePages = UInt64(stats.speculative_count)
        let inactivePages = UInt64(stats.inactive_count)
        let purgeablePages = UInt64(stats.purgeable_count)
        let wiredPages = UInt64(stats.wire_count)
        let compressedPages = UInt64(stats.compressor_page_count)

        let strictFree = (freePages + speculativePages) * p
        let available = (freePages + speculativePages + inactivePages + purgeablePages) * p

        return SystemMemoryEstimate(
            pageSize: p,
            strictFreeBytes: strictFree,
            availableBytes: available,
            wiredBytes: wiredPages * p,
            compressedBytes: compressedPages * p
        )
    }

    private func getAvailableMemoryEstimate() -> UInt64 {
        estimateSystemMemory()?.availableBytes ?? 0
    }

    private func getAppMemoryFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }
    
    func refreshAvailableJavaVersions() {
        availableJavaVersions = JessiSettings.availableJavaVersions()
    }

    private var runtimesDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Runtimes", isDirectory: true)
    }

    func runtimeDir(for version: String) -> URL {
        runtimesDir.appendingPathComponent("jre\(version)", isDirectory: true)
    }

    func refreshInstalledJVMVersions() {
        var installed: Set<String> = []
        for ver in allJVMVersions {
            let dir = runtimeDir(for: ver)
            if FileManager.default.fileExists(atPath: dir.path) {
                installed.insert(ver)
            }
        }
        installedJVMVersions = installed
    }

    func deleteInstalledJVMVersions(at offsets: IndexSet) {
        for index in offsets {
            guard index >= 0 && index < allJVMVersions.count else { continue }
            let ver = allJVMVersions[index]
            guard installedJVMVersions.contains(ver) else { continue }

            let dir = runtimeDir(for: ver)
            try? FileManager.default.removeItem(at: dir)
        }

        refreshInstalledJVMVersions()
        refreshAvailableJavaVersions()
    }

    func deleteInstalledJVMVersion(_ ver: String) {
        guard installedJVMVersions.contains(ver) else { return }
        let dir = runtimeDir(for: ver)
        try? FileManager.default.removeItem(at: dir)
        refreshInstalledJVMVersions()
        refreshAvailableJavaVersions()
    }

    private func runtimeDownloadURL(for version: String) -> URL? {
        switch version {
        case "8":
            return URL(string: "https://crystall1ne.dev/cdn/amethyst-ios/jre8-ios-aarch64.zip")
        case "17":
            return URL(string: "https://crystall1ne.dev/cdn/amethyst-ios/jre17-ios-aarch64.zip")
        case "21":
            return URL(string: "https://crystall1ne.dev/cdn/amethyst-ios/jre21-ios-aarch64.zip")
        default:
            return nil
        }
    }

    private func postInstallFixPermissions(runtimeRoot: URL) {
        let fm = FileManager.default
        let bin = runtimeRoot.appendingPathComponent("bin", isDirectory: true)

        if fm.fileExists(atPath: bin.path) {
            if let en = fm.enumerator(at: bin, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for case let url as URL in en {
                    _ = chmod(url.path, 0o755)
                }
            }
        }

        let helper1 = runtimeRoot.appendingPathComponent("jspawnhelper", isDirectory: false)
        let helper2 = runtimeRoot.appendingPathComponent("lib/jspawnhelper", isDirectory: false)
        if fm.fileExists(atPath: helper1.path) { _ = chmod(helper1.path, 0o755) }
        if fm.fileExists(atPath: helper2.path) { _ = chmod(helper2.path, 0o755) }
    }

    private func readFileMagic(_ url: URL) throws -> UInt32 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 4) ?? Data()
        if data.count < 4 {
            return 0
        }
        return data.withUnsafeBytes { raw in
            raw.load(as: UInt32.self)
        }
    }

    private func isMachOMagic(_ magicLE: UInt32) -> Bool {
        // Little-endian constants for common Mach-O magics.
        // 0xfeedfacf -> 64-bit Mach-O
        // 0xcafebabe -> FAT (universal) Mach-O
        // Note: when reading little-endian UInt32 directly from bytes, these appear as below.
        return magicLE == 0xFEEDFACF || magicLE == 0xCAFEBABE || magicLE == 0xBEBAFECA
    }

    private func validateInstalledRuntime(at runtimeRoot: URL, version: String) throws {
        let fm = FileManager.default
        let releaseFile = runtimeRoot.appendingPathComponent("release", isDirectory: false)
        guard fm.fileExists(atPath: releaseFile.path) else {
            throw NSError(domain: "JESSI", code: 40, userInfo: [NSLocalizedDescriptionKey: "JRE\(version) install looks incomplete (missing release file). Try reinstalling."])
        }

        let candidate1 = runtimeRoot.appendingPathComponent("lib/jli/libjli.dylib", isDirectory: false)
        let candidate2 = runtimeRoot.appendingPathComponent("lib/libjli.dylib", isDirectory: false)
        let libjli = fm.fileExists(atPath: candidate1.path) ? candidate1 : candidate2
        guard fm.fileExists(atPath: libjli.path) else {
            throw NSError(domain: "JESSI", code: 41, userInfo: [NSLocalizedDescriptionKey: "JRE\(version) install looks incomplete (missing libjli.dylib). Try reinstalling."])
        }

        let magic = try readFileMagic(libjli)
        guard isMachOMagic(magic) else {
            throw NSError(domain: "JESSI", code: 42, userInfo: [NSLocalizedDescriptionKey: String(format: "JRE%@ install appears corrupted (libjli magic=0x%08x). Delete and reinstall the JVM.", version, magic)])
        }
    }

    private func extractTar(_ tarPath: URL, to destDir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        let handle = try FileHandle(forReadingFrom: tarPath)
        defer { try? handle.close() }

        var reader = TarReader(fileHandle: handle)
        var finished = false

        while !finished {
            finished = try reader.process { (entry: TarEntry?) -> Bool in
                guard let entry else { return true }

                var name = entry.info.name
                if name.hasPrefix("./") { name.removeFirst(2) }
                if name.hasPrefix("/") { name.removeFirst() }
                if name.isEmpty || name == "." { return false }

                let outURL = destDir.appendingPathComponent(name)

                switch entry.info.type {
                case .directory:
                    try fm.createDirectory(at: outURL, withIntermediateDirectories: true)

                case .symbolicLink:
                    let parent = outURL.deletingLastPathComponent()
                    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                    if fm.fileExists(atPath: outURL.path) {
                        try? fm.removeItem(at: outURL)
                    }
                    if !entry.info.linkName.isEmpty {
                        try fm.createSymbolicLink(atPath: outURL.path, withDestinationPath: entry.info.linkName)
                    }

                default:
                    let parent = outURL.deletingLastPathComponent()
                    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                    if fm.fileExists(atPath: outURL.path) {
                        try? fm.removeItem(at: outURL)
                    }
                    if let data = entry.data {
                        try data.write(to: outURL, options: [.atomic])
                    } else {
                        try Data().write(to: outURL, options: [.atomic])
                    }

                    if let perms = entry.info.permissions {
                        try? fm.setAttributes([.posixPermissions: perms.rawValue], ofItemAtPath: outURL.path)
                    }
                }

                return false
            }
        }
    }

    private func installOneRuntime(version: String, completion: @escaping (Result<Void, Error>) -> Void) {
        if isIOS26 && version == "8" {
            completion(.failure(NSError(domain: "JESSI", code: 26, userInfo: [NSLocalizedDescriptionKey: "Java 8 is not supported on iOS 26+"])))
            return
        }

        guard let url = runtimeDownloadURL(for: version) else {
            completion(.failure(NSError(domain: "JESSI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown Java version: \(version)"])))
            return
        }

        let outerFM = FileManager.default
        let tmpRoot = outerFM.temporaryDirectory.appendingPathComponent("jessi-jvm-install", isDirectory: true)
        let workDir = tmpRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let zipPath = workDir.appendingPathComponent("jre\(version).zip")
        let unzipDir = workDir.appendingPathComponent("unzipped", isDirectory: true)
        let tarXZPath = workDir.appendingPathComponent("runtime.tar.xz")
        let tarPath = workDir.appendingPathComponent("runtime.tar")

        do {
            try outerFM.createDirectory(at: unzipDir, withIntermediateDirectories: true)
        } catch {
            completion(.failure(error))
            return
        }

        let task = URLSession.shared.downloadTask(with: url) { tempURL, _, error in
            let fm = FileManager.default
            if let error {
                completion(.failure(error))
                return
            }
            guard let tempURL else {
                completion(.failure(NSError(domain: "JESSI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Download failed"])))
                return
            }

            do {
                try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: workDir) }
                if fm.fileExists(atPath: zipPath.path) { try? fm.removeItem(at: zipPath) }
                try fm.moveItem(at: tempURL, to: zipPath)

                let archive = try Archive(url: zipPath, accessMode: .read)
                for entry in archive {
                    let outURL = unzipDir.appendingPathComponent(entry.path)
                    let parent = outURL.deletingLastPathComponent()
                    try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
                    if fm.fileExists(atPath: outURL.path) {
                        try? fm.removeItem(at: outURL)
                    }
                    _ = try archive.extract(entry, to: outURL)
                }

                let enumerator = fm.enumerator(at: unzipDir, includingPropertiesForKeys: nil)
                var foundTarXZ: URL? = nil
                while let u = enumerator?.nextObject() as? URL {
                    if u.pathExtension == "xz" && u.lastPathComponent.hasSuffix(".tar.xz") {
                        foundTarXZ = u
                        break
                    }
                }
                guard let foundTarXZ else {
                    throw NSError(domain: "JESSI", code: 3, userInfo: [NSLocalizedDescriptionKey: "Runtime archive did not contain a .tar.xz"])
                }
                if fm.fileExists(atPath: tarXZPath.path) { try? fm.removeItem(at: tarXZPath) }
                try fm.copyItem(at: foundTarXZ, to: tarXZPath)

                do {
                    try autoreleasepool {
                        let xzData = try Data(contentsOf: tarXZPath, options: .mappedIfSafe)
                        let tarData = try XZArchive.unarchive(archive: xzData)
                        try tarData.write(to: tarPath, options: [.atomic])
                    }
                } catch {
                    completion(.failure(error))
                    return
                }

                let finalDir = self.runtimeDir(for: version)
                let staging = self.runtimesDir.appendingPathComponent("jre\(version).staging-\(UUID().uuidString)", isDirectory: true)
                if fm.fileExists(atPath: staging.path) { try? fm.removeItem(at: staging) }

                try self.extractTar(tarPath, to: staging)
                self.postInstallFixPermissions(runtimeRoot: staging)

                if fm.fileExists(atPath: finalDir.path) {
                    let backup = self.runtimesDir.appendingPathComponent("jre\(version).backup-\(UUID().uuidString)", isDirectory: true)
                    try? fm.removeItem(at: backup)
                    try fm.moveItem(at: finalDir, to: backup)
                    try? fm.removeItem(at: backup)
                }
                try fm.moveItem(at: staging, to: finalDir)

                do {
                    try self.validateInstalledRuntime(at: finalDir, version: version)
                } catch {
                    try? fm.removeItem(at: finalDir)
                    throw error
                }

                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }

        task.resume()
    }

    func installRuntimes(versions: [String],
                         updateInProgress: @escaping (Bool) -> Void,
                         updateQueueCSV: @escaping (String) -> Void,
                         clearSelection: @escaping () -> Void) {
        let filtered = versions.filter { !(isIOS26 && $0 == "8") }
        guard !filtered.isEmpty else {
            DispatchQueue.main.async {
                self.installErrorMessage = "Nothing to install."
                self.showInstallError = true
            }
            updateInProgress(false)
            updateQueueCSV("")
            clearSelection()
            return
        }

        var remaining = filtered
        func next() {
            if remaining.isEmpty {
                DispatchQueue.main.async {
                    self.refreshInstalledJVMVersions()
                    self.refreshAvailableJavaVersions()
                }
                updateQueueCSV("")
                updateInProgress(false)
                clearSelection()
                return
            }

            let current = remaining.removeFirst()
            updateQueueCSV(([current] + remaining).joined(separator: ","))

            self.installOneRuntime(version: current) { result in
                switch result {
                case .success:
                    DispatchQueue.main.async {
                        self.refreshInstalledJVMVersions()
                        self.refreshAvailableJavaVersions()
                    }
                    next()
                case .failure(let error):
                    DispatchQueue.main.async {
                        self.installErrorMessage = error.localizedDescription
                        self.showInstallError = true
                    }
                    updateQueueCSV("")
                    updateInProgress(false)
                }
            }
        }

        updateInProgress(true)
        updateQueueCSV(filtered.joined(separator: ","))
        next()
    }
    
    func clearCache() {
        clearCacheErrorMessage = nil
        
        let fm = FileManager.default
        let defaults = UserDefaults.standard
        
        // Clear Playit-related UserDefaults keys
        let playitKeys = [
            "jessi.playit.claimurl",
            "jessi.playit.secretkey",
            "jessi.playit.lastaddress",
            "jessi.playit.status",
            "jessi.playit.lasterror"
        ]
        
        for key in playitKeys {
            defaults.removeObject(forKey: key)
        }
        
        // Clear caches directory
        if let cachesDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let contents = try? fm.contentsOfDirectory(at: cachesDir, includingPropertiesForKeys: nil)
            if let contents = contents {
                for itemURL in contents {
                    try? fm.removeItem(at: itemURL)
                }
            }
        }
        
        // Clear temporary installation directories
        let tmpDir = fm.temporaryDirectory
        let jessiTunnelingDir = tmpDir.appendingPathComponent("jessi-tunneling-install", isDirectory: true)
        let jessiJVMDir = tmpDir.appendingPathComponent("jessi-jvm-install", isDirectory: true)
        
        try? fm.removeItem(at: jessiTunnelingDir)
        try? fm.removeItem(at: jessiJVMDir)
        
        // Synchronize UserDefaults
        defaults.synchronize()
        
        showClearCacheSuccess = true
    }
}

struct SettingsView: View {
    @StateObject private var model = SettingsModel()

    @State private var showInstallDropdown: Bool = false
    @AppStorage("jessi.jvm.install.inProgress") private var installInProgress: Bool = false
    @AppStorage("jessi.jvm.install.selection") private var installSelectionCSV: String = ""
    @AppStorage("jessi.jvm.install.queue") private var installQueueCSV: String = ""

    @State private var didAutoResumeInstall: Bool = false

    private var installSelection: Set<String> {
        Set(installSelectionCSV.split(separator: ",").map(String.init))
    }

    private func setInstallSelection(_ selection: Set<String>) {
        installSelectionCSV = selection.sorted(by: { Int($0) ?? 0 < Int($1) ?? 0 }).joined(separator: ",")
    }

    private var installQueue: Set<String> {
        Set(installQueueCSV.split(separator: ",").map(String.init))
    }

    private func toggleSelection(_ version: String) {
        if model.installedJVMVersions.contains(version) { return }
        if model.isIOS26 && version == "8" { return }
        if installInProgress { return }
        var next = installSelection
        if next.contains(version) {
            next.remove(version)
        } else {
            next.insert(version)
        }
        setInstallSelection(next)
    }

    var body: some View {
        List {
            Section {
                HStack(alignment: .center, spacing: 12) {
                    Text("Version")
                    Spacer()
                    if model.availableJavaVersions.isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(Color.yellow)
                        Text("No runtimes found")
                            .foregroundColor(Color.secondary)
                    } else {
                        Picker("Java", selection: $model.javaVersion) {
                            ForEach(model.availableJavaVersions, id: \.self) { ver in
                                Text("Java \(ver)").tag(ver)
                            }
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .frame(maxWidth: 260)
                    }
                }
                .onChange(of: model.javaVersion) { newValue in
                    model.applyAndSaveJavaVersion(newValue)
                }

                Button(action: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                        showInstallDropdown.toggle()
                    }
                }) {
                    HStack(alignment: .center, spacing: 12) {
                        Text("Install JVM")
                            .foregroundColor(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(showInstallDropdown ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())

                if showInstallDropdown {
                    let nonInstalled = model.allJVMVersions.filter { !model.installedJVMVersions.contains($0) }
                    let installed = model.allJVMVersions.filter { model.installedJVMVersions.contains($0) }

                    ForEach(nonInstalled, id: \.self) { ver in
                        InstallJVMRow(
                            version: ver,
                            isInstalled: false,
                            isUnsupported: model.isIOS26 && ver == "8",
                            isSelected: installSelection.contains(ver),
                            isInstalling: installInProgress && installQueue.contains(ver),
                            onToggle: { toggleSelection(ver) }
                        )
                        .disabled(installInProgress || (model.isIOS26 && ver == "8"))
                    }

                    ForEach(installed, id: \.self) { ver in
                        InstallJVMRow(
                            version: ver,
                            isInstalled: true,
                            isUnsupported: false,
                            isSelected: false,
                            isInstalling: false,
                            onToggle: { }
                        )
                        .disabled(true)
                    }
                    .onDelete { offsets in
                        for i in offsets {
                            guard i >= 0 && i < installed.count else { continue }
                            let ver = installed[i]
                            model.deleteInstalledJVMVersion(ver)
                            setInstallSelection(installSelection.subtracting([ver]))
                        }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))

                    Button(action: {
                        let selected = installSelection.subtracting(model.installedJVMVersions)
                        guard !selected.isEmpty else { return }

                        let ordered = selected.sorted(by: { Int($0) ?? 0 < Int($1) ?? 0 })
                        model.installRuntimes(
                            versions: ordered,
                            updateInProgress: { installInProgress = $0 },
                            updateQueueCSV: { installQueueCSV = $0 },
                            clearSelection: { setInstallSelection([]) }
                        )
                    }) {
                        HStack(spacing: 10) {
                            if installInProgress {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                                    .accentColor(.white)
                            }
                            Text(installInProgress ? "Installing…" : "Install")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background((installSelection.isEmpty || installInProgress) ? Color.gray.opacity(0.35) : Color.green)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(installSelection.isEmpty || installInProgress)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowBackground(Color(UIColor.secondarySystemBackground))
                    .transition(.opacity)
                }

                HStack(alignment: .center, spacing: 12) {
                    Text("Launch Arguments")
                    Spacer()
                    DoneToolbarTextField(text: $model.launchArgs, placeholder: "Advanced users only", keyboardType: .default, textAlignment: .right, onEndEditing: { model.applyAndSaveLaunchArgs() })
                        .frame(maxWidth: 420)
                        .onChange(of: model.launchArgs) { _ in model.applyAndSaveLaunchArgs() }
                }
            } header: {
                Text("Java")
            } footer: {
                VStack(alignment: .leading) {
                    Text("JESSI requires Java to function. Please install a JVM in the menu above. If you're unsure which version to select, select Java 21.")
                    
                    if #available(iOS 26.0, *) {
                        Text("Java 8 is not supported on iOS 26 or later.")
                    }
                }
            }

            Section(header: Text("Memory"), footer: Text(model.heapDescription)) {
                HStack(spacing: 12) {
                    Text("RAM")
                    Spacer()
                    DoneToolbarTextField(
                        text: $model.heapText,
                        placeholder: "128-\(model.heapMaxMB)",
                        keyboardType: .numberPad,
                        textAlignment: .right,
                        font: UIFont.systemFont(ofSize: 16, weight: .semibold),
                        onEndEditing: { model.applyHeapFromText() }
                    )
                    .frame(width: 92)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Slider(
                        value: Binding(
                            get: { Double(model.heapMB) },
                            set: { model.applyAndSaveHeap(Int($0)) }
                        ),
                        in: 128...Double(model.heapMaxMB),
                        step: 64
                    )
                }
            }            

            ConnectionSectionView()

            Section(header: Text("System")) {
                HStack {
                    Text("JIT Enabled")
                    Spacer()
                    Text(model.isJITEnabled ? "Yes" : "No")
                        .foregroundColor(model.isJITEnabled ? .green : .red)
                }

                if model.isIOS26 {
                    Toggle("TXM Support (A15+/M2+)", isOn: $model.txmSupport)
                        .onChange(of: model.txmSupport) { _ in model.applyAndSaveTxmSupport() }
                }

                HStack {
                    Text("iOS Version")
                    Spacer()
                    Text(model.iOSVersionString)
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Total RAM")
                    Spacer()
                    Text(model.totalRAM)
                }
                HStack {
                    Text("Available RAM (estimated)")
                    Spacer()
                    Text(model.freeRAM)
                }
                
                Button(action: {
                    model.showClearCacheAlert = true
                }) {
                    HStack {
                        Text("Clear Cache")
                        Spacer()
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                }
                .foregroundColor(.primary)

            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .alert(isPresented: $model.showInstallError) {
            Alert(
                title: Text("JVM Install Failed"),
                message: Text(model.installErrorMessage ?? "Unknown error"),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert(isPresented: $model.showClearCacheAlert) {
            Alert(
                title: Text("Clear Cache"),
                message: Text("This will clear all cached data, including Playit connection settings and temporary files. This action cannot be undone."),
                primaryButton: .destructive(Text("Clear")) {
                    model.clearCache()
                },
                secondaryButton: .cancel()
            )
        }
        .alert(isPresented: $model.showClearCacheSuccess) {
            Alert(
                title: Text("Cache Cleared"),
                message: Text("Cache has been cleared successfully."),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert(isPresented: $model.showClearCacheError) {
            Alert(
                title: Text("Error"),
                message: Text(model.clearCacheErrorMessage ?? "Failed to clear cache."),
                dismissButton: .default(Text("OK"))
            )
        }
        .onAppear {
            let s = JessiSettings.shared()
            model.javaVersion = s.javaVersion
            model.heapMB = s.maxHeapMB
            model.heapText = String(s.maxHeapMB)

            model.txmSupport = s.txmSupport

            model.refreshSystemStats()

            model.refreshAvailableJavaVersions()
            model.refreshInstalledJVMVersions()

            setInstallSelection(installSelection.subtracting(model.installedJVMVersions))

            if !didAutoResumeInstall, installInProgress {
                didAutoResumeInstall = true
                let queue = installQueue
                if !queue.isEmpty {
                    let ordered = queue.sorted(by: { Int($0) ?? 0 < Int($1) ?? 0 })
                    model.installRuntimes(
                        versions: ordered,
                        updateInProgress: { installInProgress = $0 },
                        updateQueueCSV: { installQueueCSV = $0 },
                        clearSelection: { setInstallSelection([]) }
                    )
                }
            }
        }
    }
}
