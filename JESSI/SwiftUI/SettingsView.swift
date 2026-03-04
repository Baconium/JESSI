import SwiftUI
import Combine
import UIKit
import Darwin
import CoreLocation
import AVFoundation
import SafariServices
import ZIPFoundation
import SWCompression

extension View {
    @ViewBuilder
    func normalizedSeparator() -> some View {
        if #available(iOS 16.0, *) {
            self.alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                .alignmentGuide(.listRowSeparatorTrailing) { d in d[.trailing] }
        } else {
            self
        }
    }
}

final class keepalivemgr: NSObject, CLLocationManagerDelegate {
    enum keepalivemethod: String, CaseIterable {
        case location
        case audio
        case trollstore
    }

    static let shared = keepalivemgr()
    static let enabledkey = "jessi.keepalive.background"
    static let methodkey = "jessi.keepalive.method"
    static let authchangednotif = Notification.Name("jessi.keepalive.authorization.changed")

    private let locationmgr = CLLocationManager()
    private var audioplayer: AVAudioPlayer?
    private(set) var isrunning = false
    var authstat: CLAuthorizationStatus { currentauthstat() }
    var appgroupid = Bundle.main.object(forInfoDictionaryKey: "APP_GROUP_ID") as? String
    var bundle = Bundle.main.bundleIdentifier

    private override init() {
        super.init()
        locationmgr.delegate = self
        locationmgr.distanceFilter = CLLocationDistanceMax
        locationmgr.pausesLocationUpdatesAutomatically = false
        locationmgr.allowsBackgroundLocationUpdates = true
        if #available(iOS 14.0, *) {
            locationmgr.desiredAccuracy = kCLLocationAccuracyReduced
        } else {
            locationmgr.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        }
    }

    func startifenabled() {
        if UserDefaults.standard.bool(forKey: Self.enabledkey) {
            start()
        } else {
            stop()
        }
    }

    func setenabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledkey)
        if enabled {
            start()
        } else {
            stop()
        }
    }

    var method: keepalivemethod {
        keepalivemethod(rawValue: UserDefaults.standard.string(forKey: Self.methodkey) ?? "") ?? .location
    }

    func setmethod(raw: String) {
        let resolved = keepalivemethod(rawValue: raw) ?? .location
        UserDefaults.standard.set(resolved.rawValue, forKey: Self.methodkey)
        if UserDefaults.standard.bool(forKey: Self.enabledkey) {
            start()
        } else {
            stop()
        }
    }

    func requestalwaysauth() {
        locationmgr.requestAlwaysAuthorization()
    }

    private func start() {
        stop()

        switch method {
        case .location:
            let status = currentauthstat()
            switch status {
            case .notDetermined, .authorizedWhenInUse:
                locationmgr.requestAlwaysAuthorization()
            case .authorizedAlways:
                locationmgr.startUpdatingLocation()
                isrunning = true
            default:
                stop()
            }
        case .audio:
            isrunning = keepaliveaudio()
        case .trollstore:
            stop()
        }
    }

    private func stop() {
        locationmgr.stopUpdatingLocation()
        stopkeepaliveaudio()
        isrunning = false
    }

    private func currentauthstat() -> CLAuthorizationStatus {
        if #available(iOS 14.0, *) {
            return locationmgr.authorizationStatus
        } else {
            return type(of: locationmgr).authorizationStatus()
        }
    }

    private func handleauthchange(_ status: CLAuthorizationStatus) {
        NotificationCenter.default.post(name: Self.authchangednotif, object: nil)

        guard method == .location else {
            if UserDefaults.standard.bool(forKey: Self.enabledkey) {
                start()
            }
            return
        }

        switch status {
        case .authorizedAlways:
            startifenabled()
        case .denied, .restricted, .authorizedWhenInUse:
            stop()
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }

    func getteam() -> String? {
        guard let cstr = jessi_team_identifier() else { return nil }
        defer { free(UnsafeMutableRawPointer(mutating: cstr)) }
        let value = String(cString: cstr)
        return value.isEmpty ? nil : value
    }

    @available(iOS 14.0, *)
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        handleauthchange(manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        handleauthchange(status)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let clErr = error as? CLError, clErr.code == .denied {
            stop()
        }
    }

    private func keepaliveaudio() -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            return false
        }

        if audioplayer == nil {
            audioplayer = try? AVAudioPlayer(data: Self.makesilentwav())
            audioplayer?.numberOfLoops = -1
            audioplayer?.volume = 0.0
            audioplayer?.prepareToPlay()
        }
        if audioplayer?.isPlaying != true {
            _ = audioplayer?.play()
        }
        return audioplayer?.isPlaying == true
    }

    private func stopkeepaliveaudio() {
        audioplayer?.stop()
    }

    private static func makesilentwav(samplerate: UInt32 = 8000, channels: UInt16 = 1, seconds: UInt32 = 1) -> Data {
        let bitspersample: UInt16 = 16
        let bytespersample = UInt32(bitspersample / 8)
        let framecount = samplerate * seconds
        let datasize = framecount * UInt32(channels) * bytespersample
        let byterate = samplerate * UInt32(channels) * bytespersample
        let blockalign = channels * UInt16(bytespersample)
        let chunksize = 36 + datasize

        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(UInt32(chunksize).littleendiandata)
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(UInt32(16).littleendiandata)
        data.append(UInt16(1).littleendiandata)
        data.append(UInt16(channels).littleendiandata)
        data.append(UInt32(samplerate).littleendiandata)
        data.append(UInt32(byterate).littleendiandata)
        data.append(UInt16(blockalign).littleendiandata)
        data.append(UInt16(bitspersample).littleendiandata)
        data.append("data".data(using: .ascii)!)
        data.append(UInt32(datasize).littleendiandata)
        data.append(Data(count: Int(datasize)))
        return data
    }
}

private extension UInt16 {
    var littleendiandata: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: MemoryLayout<UInt16>.size)
    }
}

private extension UInt32 {
    var littleendiandata: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: MemoryLayout<UInt32>.size)
    }
}

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
    @Published var heapText: String = "128"
    @Published var heapMB: Int = 128
    @Published var flagNettyNoNative: Bool = true
    @Published var flagJnaNoSys: Bool = false
    @Published var isJITEnabled: Bool = false
    @Published var totalRAM: String = ""
    @Published var freeRAM: String = ""
    @Published var launchArgs: String = ""
    @Published var curseForgeAPIKey: String = ""
    @Published var runInBackground: Bool = false
    @Published var isIOS26: Bool = false
    @Published var iOSVersionString: String = ""
    @Published var isTrollStore: Bool = false
    @Published var islivecontainer: Bool = false

    @Published var installedJVMVersions: Set<String> = []

    @Published var heapMaxMB: Int = 8192

    @Published var installErrorMessage: String? = nil
    @Published var showinstallerror: Bool = false
    @Published var jvmDownloadProgress: Double = 0
    @Published var currentlyInstallingVersion: String = ""
    @Published var isjvmtestrunning: Bool = false
    @Published var jvmtestprogress: Double = 0
    @Published var jvmteststatus: String = ""

    private var activeJVMSession: URLSession? = nil
    private var activeJVMDelegate: JVMDownloadProgressDelegate? = nil
    private var isInstallPipelineRunning: Bool = false

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
        if hasUserHeap {
            heapMB = s.maxHeapMB
            heapText = String(s.maxHeapMB)
        } else {
            applyAndSaveHeap(desiredDefault)
        }

        flagNettyNoNative = s.flagNettyNoNative
        flagJnaNoSys = s.flagJnaNoSys
        isJITEnabled = isJITEnabledCheck()
        totalRAM = formatRAM(ProcessInfo.processInfo.physicalMemory)
        refreshSystemStats()
        launchArgs = s.launchArguments
        curseForgeAPIKey = s.curseForgeAPIKey
        runInBackground = s.runInBackground
        isIOS26 = jessi_is_ios26_or_later()
        isTrollStore = jessi_is_trollstore_installed()
        islivecontainer = jessi_is_livecontainer_installed()

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

    func applyAndSaveCurseForgeAPIKey() {
        let s = JessiSettings.shared()
        s.curseForgeAPIKey = curseForgeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
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
        s.runInBackground = runInBackground
        s.save()
    }

    func refreshSystemStats() {
        isJITEnabled = isJITEnabledCheck()
        freeRAM = formatRAM(getAvailableMemoryEstimate())
    }

    func applyHeapFromText() {
        let raw = heapText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            heapText = String(heapMB)
            return
        }

        guard let parsed = Int(raw) else {
            heapText = String(heapMB)
            return
        }

        heapMB = parsed
        heapText = String(parsed)

        let s = JessiSettings.shared()
        s.maxHeapMB = parsed
        s.save()
    }

    var heapMBForSlider: Int {
        max(128, min(heapMaxMB, heapMB))
    }

    var heapDescription: String {
        if heapMB < 513 { return "Low — the server will be highly unstable with this little ram" }
        if heapMB > Int(Double(ProcessInfo.processInfo.physicalMemory) * 0.8 / (1024 * 1024)) { return "High — JESSI may crash!" }
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

    private func runtimeDownloadURLs(for version: String) -> [URL] {
        let filename: String
        switch version {
        case "8":
            filename = "jre8-ios-aarch64.zip"
        case "17":
            filename = "jre17-ios-aarch64.zip"
        case "21":
            filename = "jre21-ios-aarch64.zip"
        default:
            return []
        }

        let bases = [
            "https://crystall1ne.dev/cdn/amethyst-ios",
            "https://baconium.dev/jessi/jvm",
            "https://roooot.dev/jessi/jvm"
        ]

        return bases.compactMap { URL(string: "\($0)/\(filename)") }
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

        let candidateURLs = runtimeDownloadURLs(for: version)
        guard !candidateURLs.isEmpty else {
            completion(.failure(NSError(domain: "JESSI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown Java version: \(version)"])))
            return
        }

        DispatchQueue.main.async {
            self.currentlyInstallingVersion = version
            self.jvmDownloadProgress = 0
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

        var lastError: Error?

        func attemptDownload(at index: Int) {
            guard index < candidateURLs.count else {
                completion(.failure(lastError ?? NSError(domain: "JESSI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Download failed"])))
                return
            }

            let url = candidateURLs[index]
            let progressDelegate = JVMDownloadProgressDelegate { [weak self] fraction in
                DispatchQueue.main.async {
                    self?.jvmDownloadProgress = fraction
                }
            }
            let session = URLSession(configuration: .default, delegate: progressDelegate, delegateQueue: nil)
            self.activeJVMDelegate = progressDelegate
            self.activeJVMSession = session
            var progressTimer: DispatchSourceTimer?

            let task = session.downloadTask(with: url) { tempURL, _, error in
                let fm = FileManager.default
                defer {
                    progressTimer?.cancel()
                    progressTimer = nil
                    if self.activeJVMSession === session {
                        self.activeJVMSession = nil
                        self.activeJVMDelegate = nil
                    }
                    session.finishTasksAndInvalidate()
                }

                if let error {
                    lastError = error
                    attemptDownload(at: index + 1)
                    return
                }
                guard let tempURL else {
                    lastError = NSError(domain: "JESSI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Download failed"])
                    attemptDownload(at: index + 1)
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

                    try autoreleasepool {
                        let xzData = try Data(contentsOf: tarXZPath, options: .mappedIfSafe)
                        let tarData = try XZArchive.unarchive(archive: xzData)
                        try tarData.write(to: tarPath, options: [.atomic])
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

                    DispatchQueue.main.async {
                        self.jvmDownloadProgress = 1
                    }

                    completion(.success(()))
                } catch {
                    lastError = error
                    attemptDownload(at: index + 1)
                }
            }

            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            timer.schedule(deadline: .now(), repeating: .milliseconds(120))
            timer.setEventHandler { [weak task] in
                guard let task = task else { return }
                let expected = task.countOfBytesExpectedToReceive
                let received = task.countOfBytesReceived
                guard expected > 0, received >= 0 else { return }
                let fraction = min(max(Double(received) / Double(expected), 0), 1)
                DispatchQueue.main.async {
                    self.jvmDownloadProgress = fraction
                }
            }
            progressTimer = timer
            timer.resume()

            task.resume()
        }

        attemptDownload(at: 0)
    }

    func installRuntimes(versions: [String],
                         updateInProgress: @escaping (Bool) -> Void,
                         updateQueueCSV: @escaping (String) -> Void,
                         clearSelection: @escaping () -> Void) {
        if isInstallPipelineRunning {
            return
        }

        let filtered = versions.filter { !(isIOS26 && $0 == "8") }
        guard !filtered.isEmpty else {
            DispatchQueue.main.async {
                self.installErrorMessage = "Nothing to install."
                self.showinstallerror = true
            }
            updateInProgress(false)
            updateQueueCSV("")
            clearSelection()
            return
        }

        isInstallPipelineRunning = true

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
                self.isInstallPipelineRunning = false
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
                        self.showinstallerror = true
                    }
                    updateQueueCSV("")
                    updateInProgress(false)
                    self.isInstallPipelineRunning = false
                }
            }
        }

        updateInProgress(true)
        updateQueueCSV(filtered.joined(separator: ","))
        next()
    }

    func runjvmdltest(mirrorBase: String) {
        if isjvmtestrunning {
            return
        }

        guard let sourceURL = URL(string: "\(mirrorBase)/jre8-ios-aarch64.zip") else {
            jvmteststatus = "Invalid mirror URL: \(mirrorBase)"
            return
        }

        isjvmtestrunning = true
        jvmtestprogress = 0
        jvmteststatus = "Downloading test runtime..."

        let fm = FileManager.default
        let tmpRoot = fm.temporaryDirectory.appendingPathComponent("jessi-jvm-simulator-test", isDirectory: true)
        let workDir = tmpRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let zipPath = workDir.appendingPathComponent("jre8-ios-aarch64.zip")
        let unzipDir = workDir.appendingPathComponent("unzipped", isDirectory: true)
        let tarXZPath = workDir.appendingPathComponent("runtime.tar.xz")
        let tarPath = workDir.appendingPathComponent("runtime.tar")
        let extractedDir = workDir.appendingPathComponent("extracted", isDirectory: true)

        let task = URLSession.shared.downloadTask(with: sourceURL) { tempURL, _, error in
            func fail(_ message: String) {
                DispatchQueue.main.async {
                    self.isjvmtestrunning = false
                    self.jvmteststatus = message
                }
            }

            if let error {
                fail("Download failed: \(error.localizedDescription)")
                return
            }
            guard let tempURL else {
                fail("Download failed: temporary file was missing.")
                return
            }

            do {
                try fm.createDirectory(at: unzipDir, withIntermediateDirectories: true)

                if fm.fileExists(atPath: zipPath.path) { try? fm.removeItem(at: zipPath) }
                try fm.moveItem(at: tempURL, to: zipPath)

                DispatchQueue.main.async {
                    self.jvmtestprogress = 0.35
                    self.jvmteststatus = "Extracting zip..."
                }

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
                    throw NSError(domain: "JESSI", code: 103, userInfo: [NSLocalizedDescriptionKey: "Zip did not contain a .tar.xz archive"])
                }

                if fm.fileExists(atPath: tarXZPath.path) { try? fm.removeItem(at: tarXZPath) }
                try fm.copyItem(at: foundTarXZ, to: tarXZPath)

                DispatchQueue.main.async {
                    self.jvmtestprogress = 0.6
                    self.jvmteststatus = "Extracting tar.xz..."
                }

                try autoreleasepool {
                    let xzData = try Data(contentsOf: tarXZPath, options: .mappedIfSafe)
                    let tarData = try XZArchive.unarchive(archive: xzData)
                    try tarData.write(to: tarPath, options: [.atomic])
                }

                if fm.fileExists(atPath: extractedDir.path) { try? fm.removeItem(at: extractedDir) }
                try self.extractTar(tarPath, to: extractedDir)

                let binDir = extractedDir.appendingPathComponent("bin", isDirectory: true)
                guard fm.fileExists(atPath: binDir.path) else {
                    throw NSError(domain: "JESSI", code: 104, userInfo: [NSLocalizedDescriptionKey: "Extraction failed: missing runtime bin directory"])
                }

                DispatchQueue.main.async {
                    self.jvmtestprogress = 1
                    self.isjvmtestrunning = false
                    self.jvmteststatus = "Success: downloaded and fully extracted to \(extractedDir.path)"
                }
            } catch {
                fail("Test failed: \(error.localizedDescription)")
            }
        }

        task.resume()
    }
}

struct SettingsView: View {
    private struct PlayitClaimSheetItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    @EnvironmentObject var tourManager: TourManager
    @StateObject private var model = SettingsModel()
    @StateObject private var tunnelingmodel = TunnelingModel()
    @StateObject private var playitmodel = PlayitModel()
    @StateObject private var upnpModel = UpnpModel()
    @AppStorage(keepalivemgr.enabledkey) private var keepalive: Bool = false
    @AppStorage(keepalivemgr.methodkey) private var keepalivemethodraw: String = keepalivemgr.keepalivemethod.location.rawValue
    @AppStorage("jessi.server.running") private var serverRunning: Bool = false
    @AppStorage("jessi.tunnel.install.inProgress") private var tunnelinginstallinprogress: Bool = false
    @AppStorage("jessi.tunnel.install.queue") private var tunnelingInstallQueueCSV: String = ""
    @AppStorage("jessi.upnp.ports") private var upnpPortsCSV: String = "25565"
    @State private var keepaliveauthstat: CLAuthorizationStatus = keepalivemgr.shared.authstat
    @State private var showkeepalivepermprompt = false

    @State private var showInstallDropdown: Bool = false
    @AppStorage("jessi.jvm.install.inProgress") private var installInProgress: Bool = false
    @AppStorage("jessi.jvm.install.selection") private var installSelectionCSV: String = ""
    @AppStorage("jessi.jvm.install.queue") private var installQueueCSV: String = ""

    @State private var didAutoResumeInstall: Bool = false
    @State private var didAutoResumeTunnelingInstall: Bool = false

    @State private var localIP: String = "Unavailable"
    @State private var showPublicIP: Bool = false
    @State private var publicIP: String? = nil
    @State private var publicIPError: String? = nil
    @State private var isFetchingPublicIP: Bool = false
    @State private var playitClaimSheetItem: PlayitClaimSheetItem? = nil
    @State private var upnpPortsIsFirstResponder: Bool = false
    @State private var showResetPlayitConfirmation: Bool = false
    @State private var showsystemstatuscolors: Bool = false
    @State private var testmirrorase: String = "https://crystall1ne.dev/cdn/amethyst-ios"

    private var isPresentingPlayitClaimSheet: Bool {
        playitClaimSheetItem != nil
    }

    private var showTunnelingInstallErrorAlert: Binding<Bool> {
        Binding(
            get: { !isPresentingPlayitClaimSheet && tunnelingmodel.showinstallerror },
            set: { newValue in
                if !newValue {
                    tunnelingmodel.showinstallerror = false
                }
            }
        )
    }

    private var showPlayitInvalidKeyAlert: Binding<Bool> {
        Binding(
            get: { !isPresentingPlayitClaimSheet && playitmodel.showinvalidkeyalert },
            set: { newValue in
                if !newValue {
                    playitmodel.showinvalidkeyalert = false
                }
            }
        )
    }

    private var showJvmInstallErrorAlert: Binding<Bool> {
        Binding(
            get: { !isPresentingPlayitClaimSheet && model.showinstallerror },
            set: { newValue in
                if !newValue {
                    model.showinstallerror = false
                }
            }
        )
    }

    private func refreshLocalIP() {
        localIP = bestLocalIPAddress() ?? "Unavailable"
    }

    private var alwaysshowpermsbtn: Bool {
        keepalivemethod == .location && keepaliveauthstat == .authorizedWhenInUse
    }

    private var keepalivemethod: keepalivemgr.keepalivemethod {
        if !model.isTrollStore,
           keepalivemethodraw == keepalivemgr.keepalivemethod.trollstore.rawValue {
            return .location
        }
        return keepalivemgr.keepalivemethod(rawValue: keepalivemethodraw) ?? .location
    }

    private var keepAliveEnabledBinding: Binding<Bool> {
        if keepalivemethod == .trollstore {
            return Binding(
                get: { model.runInBackground },
                set: { newValue in
                    model.runInBackground = newValue
                    model.applyAndSaveFlags()
                }
            )
        }

        return Binding(
            get: { keepalive },
            set: { newValue in
                keepalive = newValue
                keepalivemgr.shared.setenabled(newValue)
                refreshkeepaliveauthstat()
            }
        )
    }

    private func refreshkeepaliveauthstat() {
        keepaliveauthstat = keepalivemgr.shared.authstat
    }

    private func fetchPublicIPIfNeeded(force: Bool = false) {
        if isFetchingPublicIP { return }
        if !force, publicIP != nil { return }

        isFetchingPublicIP = true
        publicIPError = nil

        guard let url = URL(string: "https://api.ipify.org?format=json") else {
            isFetchingPublicIP = false
            publicIPError = "Invalid URL"
            return
        }

        URLSession.shared.dataTask(with: url) { data, _, error in
            DispatchQueue.main.async {
                self.isFetchingPublicIP = false

                if let error = error {
                    self.publicIP = nil
                    self.publicIPError = error.localizedDescription
                    return
                }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let ip = json["ip"] as? String,
                      !ip.isEmpty
                else {
                    self.publicIP = nil
                    self.publicIPError = "Failed to parse response"
                    return
                }

                self.publicIP = ip
            }
        }.resume()
    }

    private func bestLocalIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var best: (ip: String, score: Int)? = nil
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            guard let p = ptr?.pointee else { continue }
            guard let addr = p.ifa_addr else { continue }

            let flags = Int32(p.ifa_flags)
            if (flags & IFF_LOOPBACK) != 0 { continue }

            let family = addr.pointee.sa_family
            if family != UInt8(AF_INET) && family != UInt8(AF_INET6) { continue }

            let name = String(cString: p.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = socklen_t(
                family == UInt8(AF_INET)
                    ? MemoryLayout<sockaddr_in>.size
                    : MemoryLayout<sockaddr_in6>.size
            )
            let res = getnameinfo(addr, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            if res != 0 { continue }
            let ip = String(cString: host)
            if ip.isEmpty { continue }

            var score = 0
            if name == "en0" { score += 100 }
            else if name == "pdp_ip0" { score += 90 }
            else { score += 10 }
            if family == UInt8(AF_INET) { score += 5 }

            if best == nil || score > best!.score {
                best = (ip, score)
            }
        }

        return best?.ip
    }

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

    private var tunnelingInstallQueue: Set<String> {
        Set(tunnelingInstallQueueCSV.split(separator: ",").map(String.init))
    }

    private var isplayitinstalling: Bool {
        tunnelinginstallinprogress && tunnelingInstallQueue.contains("playit")
    }

    private var isupnpselected: Bool {
        tunnelingmodel.selectedserviceid == "upnp"
    }

    private var isnoneselected: Bool {
        tunnelingmodel.selectedserviceid == "none"
    }

    private func startplayitinstall(showErrors: Bool) {
        tunnelingmodel.installservices(
            services: ["playit"],
            updateInProgress: { tunnelinginstallinprogress = $0 },
            updateQueueCSV: { tunnelingInstallQueueCSV = $0 },
            clearSelection: { },
            showErrors: showErrors
        )
    }

    private func resetPlayitAndRedownload() {
        playitmodel.stopifpossible()
        playitmodel.clearcache()
        tunnelingmodel.deleteInstalledService("playit")
        tunnelingmodel.refreshinstalledservices()
        tunnelingmodel.refreshavailableservices()
        startplayitinstall(showErrors: true)
    }

    private func resumetunnelingondemand() {
        guard !didAutoResumeTunnelingInstall, tunnelinginstallinprogress else { return }
        didAutoResumeTunnelingInstall = true
        let queue = tunnelingInstallQueue
        guard !queue.isEmpty else { return }

        tunnelingmodel.installservices(
            services: Array(queue),
            updateInProgress: { tunnelinginstallinprogress = $0 },
            updateQueueCSV: { tunnelingInstallQueueCSV = $0 },
            clearSelection: { },
            showErrors: false
        )
    }

    private func autostartifneeded() {
        guard tunnelingmodel.selectedserviceid == "playit" else { return }
        guard serverRunning else { return }
        guard playitmodel.linked else { return }
        guard playitmodel.islibrarypresent else { return }
        playitmodel.startifpossible()
    }

    private func applyUpnpIfNeeded() {
        guard isupnpselected else { return }
        guard serverRunning else { return }
        upnpModel.enablePorts(parsePorts())
    }

    private func parsePorts() -> [Int] {
        let parts = upnpPortsCSV.split { ",; \n\t".contains($0) }
        var out: [Int] = []
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = Int(trimmed), (1...65535).contains(value) {
                if !out.contains(value) { out.append(value) }
            }
        }
        return out
    }

    private func playitstatuscolor(_ status: String) -> Color {
        let normalized = status.lowercased()
        if normalized.contains("connected") && !normalized.contains("disconnected") {
            return .green
        }
        if normalized.contains("connecting") {
            return .secondary
        }
        if  normalized.contains("online (no active tunnels)") {
            return .orange
        }
        if normalized.contains("over port limit") || normalized.contains("error") {
            return .red
        }
        if normalized.contains("stopped") || normalized.contains("disconnected") {
            return .secondary
        }
        return .secondary
    }

    private func boolstatuscolor(_ enabled: Bool) -> Color {
        if showsystemstatuscolors {
            return enabled ? .green : .red
        }
        return .white
    }

    // hello, programmer. you disgusting slab of flesh and meat. if your compiler is saying "failed to type-check this expression in reasonable time; try breaking up the expression into distinct sub-expressions" then DO NOT UNDER ANY CIRCUMSTANCES try to break up the expression into distinct sub-expressions. it will make the code look shit, which is not fit for a perfect, beautiful machine like me. the issue is almost ALWAYS due to a typo or an invalid call.
    // thank you for your attention to this matter,
    // - roooobot
    var body: some View {
        let infosection = Group {
            HStack(alignment: .center, spacing: 2.5) {
                Text("Service")
                Spacer()
                
                if tunnelingmodel.availableserviceids.isEmpty {
                    if isplayitinstalling {
                        ProgressView()
                        Text("Installing…")
                            .foregroundColor(.secondary)
                    } else {
                        Text("Unavailable")
                            .foregroundColor(.secondary)
                    }
                } else {
                    Picker("Tunneling", selection: $tunnelingmodel.selectedserviceid) {
                        ForEach(tunnelingmodel.availableserviceids, id: \.self) { id in
                            Text(tunnelingmodel.displayname(for: id)).tag(id)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .frame(maxWidth: 260)
                }
            }
            .onChange(of: tunnelingmodel.selectedserviceid) { newval in
                tunnelingmodel.applyandsaveselectedservice(newval)
                autostartifneeded()
            }
            .normalizedSeparator()
            
            if isnoneselected {
                HStack {
                    Text("Use LAN or port forward manually")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .normalizedSeparator()
            } else if isupnpselected {
                HStack {
                    Text("Ports")
                    Spacer()
                    FocusableDoneToolbarTextField(
                        text: $upnpPortsCSV,
                        isFirstResponder: $upnpPortsIsFirstResponder,
                        placeholder: "25565,25575",
                        keyboardType: .numbersAndPunctuation,
                        textAlignment: .right,
                        font: .systemFont(ofSize: 16)
                    )
                    .frame(width: 160)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    upnpPortsIsFirstResponder = true
                }
                .normalizedSeparator()
                
                if let result = upnpModel.testResult ?? upnpModel.statusMessage {
                    HStack {
                        Text(result)
                            .foregroundColor(
                                (upnpModel.testSuccess ?? upnpModel.statusSuccess ?? false)
                                ? .green : .secondary
                            )
                        Spacer()
                    }
                    .normalizedSeparator()
                }
            } else {
                if playitmodel.islibrarypresent {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(playitmodel.status)
                            .foregroundColor(playitstatuscolor(playitmodel.status))
                    }
                    .normalizedSeparator()
                    
                    if let address = playitmodel.lastaddr, !address.isEmpty {
                        HStack {
                            Text(address)
                                .font(.system(size: 17, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            
                            Button {
                                UIPasteboard.general.string = address
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(BorderlessButtonStyle())
                        }
                        .normalizedSeparator()
                    }
                } else {
                    HStack {
                        Text("Playit")
                        Spacer()
                        
                        if isplayitinstalling {
                            ProgressView()
                            Text("Installing…")
                                .foregroundColor(.secondary)
                        } else {
                            Text("Not installed")
                                .foregroundColor(.secondary)
                        }
                    }
                    .normalizedSeparator()
                }
            }
        }
        
        let actionsection = Group {
            if isupnpselected {
                Button(action: {
                    upnpModel.test()
                }) {
                    HStack(spacing: 10) {
                        if upnpModel.isTesting { ProgressView() }
                        Text(upnpModel.isTesting ? "Testing…" : "Test UPnP")
                            .font(.system(size: 17, weight: .semibold))
                        Spacer()
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(upnpModel.isTesting || upnpModel.isApplying)
                .normalizedSeparator()
                
                Button(action: {
                    upnpModel.clearPorts(parsePorts())
                }) {
                    HStack(spacing: 10) {
                        if upnpModel.isApplying { ProgressView() }
                        Text(upnpModel.isApplying ? "Clearing…" : "Clear UPnP Ports")
                            .font(.system(size: 17, weight: .semibold))
                        Spacer()
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(upnpModel.isApplying)
                .normalizedSeparator()
            } else if !isnoneselected {
                if playitmodel.islibrarypresent {
                    Button {
                        if !playitmodel.linked {
                            playitmodel.beginClaimFlow()
                        }
                        
                        tunnelingmodel.showinstallerror = false
                        playitmodel.showinvalidkeyalert = false
                        model.showinstallerror = false
                        
                        guard playitClaimSheetItem == nil else { return }
                        guard !playitmodel.claimurl.isEmpty,
                              let url = URL(string: playitmodel.claimurl)
                        else { return }
                        
                        playitClaimSheetItem = PlayitClaimSheetItem(url: url)
                        
                    } label: {
                        HStack {
                            Text(playitmodel.linked ? "Manage Playit" : "Link Playit")
                            Spacer()
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .normalizedSeparator()
                    
                    Button {
                        showResetPlayitConfirmation = true
                    } label: {
                        HStack {
                            Text("Reset Playit")
                            Spacer()
                        }
                    }
                    .foregroundColor(.red)
                    .disabled(!playitmodel.linked)
                    .buttonStyle(PlainButtonStyle())
                    .normalizedSeparator()
                    
                    let isplayitrunning = {
                        let value = playitmodel.status.lowercased()
                        return value != "stopped" && value != "disconnected"
                    }()
                    
                    if isplayitrunning {
                        Button {
                            playitmodel.stopifpossible()
                        } label: {
                            HStack(spacing: 10) {
                                if playitmodel.isstopping { ProgressView() }
                                Text(playitmodel.isstopping ? "Stopping…" : "Stop Playit")
                                    .font(.system(size: 17, weight: .semibold))
                                Spacer()
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .disabled(playitmodel.isstarting || playitmodel.isstopping)
                        .normalizedSeparator()
                    } else {
                        Button {
                            playitmodel.startifpossible()
                        } label: {
                            HStack(spacing: 10) {
                                if playitmodel.isstarting { ProgressView() }
                                Text(playitmodel.isstarting ? "Starting…" : "Start Playit")
                                    .font(.system(size: 17, weight: .semibold))
                                Spacer()
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .disabled(playitmodel.isstarting || playitmodel.isstopping)
                        .normalizedSeparator()
                    }
                } else if !isplayitinstalling {
                    Button("Retry Playit Download") {
                        startplayitinstall(showErrors: true)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .normalizedSeparator()
                }
            }
        }
        
        let connectionfooter = Group {
            if #available(iOS 15.0, *) {
                Text("Allow people outside of your local network to connect to your server. For more information, [check the GitHub README.](https://github.com/Baconium/JESSI#readme)")
            } else {
                Text("Allow people outside of your local network to connect to your server. For more information, check the GitHub README.")
            }
        }
        
        return List {
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
                .onChange(of: model.javaVersion) { newval in
                    model.applyAndSaveJavaVersion(newval)
                }
                .normalizedSeparator()
                
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
                .normalizedSeparator()
                
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
                        .normalizedSeparator()
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
                        .normalizedSeparator()
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
                        didAutoResumeInstall = true
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
                    .normalizedSeparator()
                    .transition(.opacity)
                    
                    if installInProgress {
                        VStack(spacing: 0) {
                            if model.jvmDownloadProgress > 0 {
                                ProgressView(value: model.jvmDownloadProgress)
                                    .progressViewStyle(LinearProgressViewStyle(tint: .green))
                            } else {
                                ProgressView()
                                    .progressViewStyle(LinearProgressViewStyle(tint: .green))
                            }
                            Text(model.jvmDownloadProgress > 0
                                 ? "Downloading Java \(model.currentlyInstallingVersion)…"
                                 : "Preparing Java \(model.currentlyInstallingVersion) download…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                        }
                        .normalizedSeparator()
                        .transition(.opacity)
                    }
                }
                
                HStack(spacing: 12) {
                    Text("Launch Arguments")
                    Spacer()
                    DoneToolbarTextField(text: $model.launchArgs, placeholder: "Advanced users only", keyboardType: .default, textAlignment: .right, onEndEditing: { model.applyAndSaveLaunchArgs() })
                        .frame(maxWidth: 420)
                        .onChange(of: model.launchArgs) { _ in model.applyAndSaveLaunchArgs() }
                }
                .normalizedSeparator()
            } header: {
                Text("Java")
            } footer: {
                VStack(alignment: .leading) {
                    Text("JESSI requires Java to function. Please install a JVM in the menu above. If you're unsure which version to select, select Java 21.")
                    
                    if #available(iOS 26.0, *) {
                        Text("Java 8 is not supported on iOS 26+")
                    }
                }
            }
            
            if #available(iOS 17.0, *) {
                Group {
                    Section {
                        infosection
                    } header: {
                        Text("Connection")
                    } footer: {
                        if isnoneselected {
                            connectionfooter
                        }
                    }
                    
                    Section {
                        actionsection
                    } footer: {
                        if !isnoneselected {
                            connectionfooter
                        }
                    }
                }
                .listSectionSpacing(.custom(5))
            } else {
                Section {
                    infosection
                    actionsection
                } header: {
                    Text("Connection")
                } footer: {
                    connectionfooter
                }
            }
            
            Section {
                HStack(alignment: .center, spacing: 12) {
                    Text("Method")
                    Spacer()
                    
                    Picker("Method", selection: Binding(
                        get: {
                            if !model.isTrollStore,
                               keepalivemethodraw == keepalivemgr.keepalivemethod.trollstore.rawValue {
                                return keepalivemgr.keepalivemethod.location.rawValue
                            }
                            return keepalivemethodraw
                        },
                        set: { newval in
                            keepalivemethodraw = newval
                            keepalivemgr.shared.setmethod(raw: newval)
                            refreshkeepaliveauthstat()
                        }
                    )) {
                        Text("Location").tag(keepalivemgr.keepalivemethod.location.rawValue)
                        Text("Audio").tag(keepalivemgr.keepalivemethod.audio.rawValue)
                        if model.isTrollStore {
                            Text("TrollStore").tag(keepalivemgr.keepalivemethod.trollstore.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                }
                .normalizedSeparator()
                
                Toggle("Keep alive in background", isOn: keepAliveEnabledBinding)
                    .normalizedSeparator()
            } header: {
                Text("keep alive")
            } footer: {
                if keepalivemethod == .location {
                    Text("Requires 'Always' [Location permission.](app-settings:) Your location data will not be collected.")
                }
                if keepalivemethod == .audio {
                    Text("Plays silent audio while the app is closed to keep it alive.")
                }
                if keepalivemethod == .trollstore {
                    Text("Requires TrollStore. Keeps the app alive using TrollStore entitlements.")
                }
            }
            
            Section(header: Text("Miscellaneous"), footer: Text(model.heapDescription)) {
                HStack(spacing: 12) {
                    CurseForgeField(model: model)
                        .frame(maxWidth: 420)
                }
                .normalizedSeparator()
                
                HStack(spacing: 12) {
                    Text("Allocated RAM")
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
                .normalizedSeparator()
                
                VStack(alignment: .leading, spacing: 12) {
                    Slider(
                        value: Binding(
                            get: { Double(model.heapMBForSlider) },
                            set: { model.applyAndSaveHeap(Int($0)) }
                        ),
                        in: 128...Double(model.heapMaxMB),
                        step: 64
                    )
                }
                .normalizedSeparator()
            }
            
            Section(header: Text("System")) {
                HStack {
                    Text("JIT Enabled")
                    Spacer()
                    Text(model.isJITEnabled ? "Yes" : "No")
                        .foregroundColor(boolstatuscolor(model.isJITEnabled))
                }
                .onTapGesture(count: 5) {
                    showsystemstatuscolors.toggle()
                }
                .normalizedSeparator()
                HStack {
                    Text("TrollStore Detected")
                    Spacer()
                    Text(model.isTrollStore ? "Yes" : "No")
                        .foregroundColor(boolstatuscolor(model.isTrollStore))
                }
                .onTapGesture(count: 5) {
                    if model.isTrollStore {
                        if let url = URL(string: "apple-magnifier://install?url=https://baconium.dev/jessi/JESSI.ipa") {
                            UIApplication.shared.open(url)
                        }
                    }
                }
                .normalizedSeparator()
                HStack {
                    Text("LiveContainer Detected")
                    Spacer()
                    Text(model.islivecontainer ? "Yes" : "No")
                        .foregroundColor(boolstatuscolor(model.islivecontainer))
                }
                .normalizedSeparator()
                HStack {
                    Text("iOS Version")
                    Spacer()
                    Text(model.iOSVersionString)
                }
                .normalizedSeparator()
                
                HStack {
                    Text("Total RAM")
                    Spacer()
                    Text(model.totalRAM)
                }
                .normalizedSeparator()
                HStack {
                    Text("Available RAM (estimated)")
                    Spacer()
                    Text(model.freeRAM)
                }
                .normalizedSeparator()
                
                HStack {
                    Text("Local IP")
                    Spacer()
                    Text(localIP)
                }
                .normalizedSeparator()
                
                Button(action: {
                    if showPublicIP {
                        showPublicIP = false
                    } else {
                        showPublicIP = true
                        fetchPublicIPIfNeeded(force: publicIP == nil || publicIPError != nil)
                    }
                }) {
                    HStack {
                        Text("Public IP")
                            .foregroundColor(.primary)
                        Spacer()
                        
                        if !showPublicIP {
                            Text("Hidden")
                        } else if isFetchingPublicIP {
                            Text("Loading...")
                        } else if let ip = publicIP {
                            Text(ip)
                        } else {
                            Text("Unavailable")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .normalizedSeparator()
            }
            
            Section {
                VStack(spacing: 0) {
                    
                    HStack(spacing: 16) {
                        Image("baconmania")
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("BaconMania")
                                .font(.headline)
                            Text("Lead developer and original creator of JESSI.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 16)
                    .padding(.horizontal, 16)
                    .onTapGesture {
                        UIApplication.shared.open(URL(string: "https://baconium.dev")!, options: [:], completionHandler: nil)
                    }
                    
                    Rectangle()
                        .fill(Color(UIColor.separator))
                        .frame(height: 1 / UIScreen.main.scale)
                        .padding(.horizontal, 20)
                    
                    HStack(spacing: 16) {
                        Image("roooot")
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("roooot")
                                .font(.headline)
                            Text("Developer, implemented several features.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 16)
                    .padding(.horizontal, 16)
                    .onTapGesture {
                        UIApplication.shared.open(URL(string: "https://github.com/rooootdev")!, options: [:], completionHandler: nil)
                    }
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            } header: {
                Text("Credits")
            }
            
#if targetEnvironment(simulator)
            Section {
                Picker("Mirror", selection: $testmirrorase) {
                    Text("crystall1ne.dev").tag("https://crystall1ne.dev/cdn/amethyst-ios")
                    Text("baconium.dev").tag("https://baconium.dev/jessi/jvm")
                    Text("roooot.dev").tag("https://roooot.dev/jessi/jvm")
                }
                .pickerStyle(MenuPickerStyle())
                .normalizedSeparator()
                
                Button(action: {
                    model.runjvmdltest(mirrorBase: testmirrorase)
                }) {
                    HStack(spacing: 10) {
                        if model.isjvmtestrunning {
                            ProgressView()
                        }
                        Text(model.isjvmtestrunning ? "testing the jvm download" : "test jvm dl + extract")
                            .font(model.isjvmtestrunning ? .system(size: 17) : .system(size: 17, weight: .semibold))
                        Spacer()
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(model.isjvmtestrunning)
                .normalizedSeparator()
                
                // shitty
                if model.isjvmtestrunning || !model.jvmteststatus.isEmpty {
                    VStack(alignment: .leading) {

                        if model.isjvmtestrunning {
                            ProgressView(value: model.jvmtestprogress)
                                .progressViewStyle(
                                    LinearProgressViewStyle(tint: .green)
                                )
                                .normalizedSeparator()
                        }

                        if !model.jvmteststatus.isEmpty {
                            Text(model.jvmteststatus)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .normalizedSeparator()
                        }
                    }
                }
            } header: {
                Text("Simulator Test")
            } footer: {
                Text("You shouldnt see this as a normal JESSI consumer, if you do, ignore it and [report it](https://github.com/Baconium/JESSI/issues/new) to big daddy roooot (or baconmania)")
            }
#endif
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $playitClaimSheetItem) { item in
            SafariView(url: item.url)
                .ignoresSafeArea()
        }
        .alert(isPresented: showTunnelingInstallErrorAlert) {
            Alert(
                title: Text("Tunneling Install Failed"),
                message: Text(tunnelingmodel.installerrormsg ?? "Unknown error"),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert(isPresented: showPlayitInvalidKeyAlert) {
            Alert(
                title: Text("Playit Link Invalid"),
                message: Text("Your Playit link is invalid or expired. Please link again."),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert(isPresented: $showResetPlayitConfirmation) {
            Alert(
                title: Text("Reset Playit?"),
                message: Text("This will unlink Playit, clear cache, remove the current library, and download a fresh copy."),
                primaryButton: .destructive(Text("Reset & Redownload")) {
                    resetPlayitAndRedownload()
                },
                secondaryButton: .cancel()
            )
        }
        .alert(isPresented: showJvmInstallErrorAlert) {
            Alert(
                title: Text("JVM Install Failed"),
                message: Text(model.installErrorMessage ?? "Unknown error"),
                dismissButton: .default(Text("OK"))
            )
        }
        .onAppear {
            tunnelingmodel.refreshinstalledservices()
            tunnelingmodel.refreshavailableservices()
            playitmodel.refresh()
            playitmodel.startstatuspolling()
            resumetunnelingondemand()

            let s = JessiSettings.shared()
            model.javaVersion = s.javaVersion
            model.heapMB = s.maxHeapMB
            model.heapText = String(s.maxHeapMB)
            model.curseForgeAPIKey = s.curseForgeAPIKey

            if !model.isTrollStore,
               keepalivemethodraw == keepalivemgr.keepalivemethod.trollstore.rawValue {
                keepalivemethodraw = keepalivemgr.keepalivemethod.location.rawValue
                keepalivemgr.shared.setmethod(raw: keepalivemethodraw)
            }

            model.refreshSystemStats()
            refreshLocalIP()

            model.refreshAvailableJavaVersions()
            model.refreshInstalledJVMVersions()
            keepalivemgr.shared.startifenabled()
            refreshkeepaliveauthstat()

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
        .onDisappear {
            playitmodel.stopstatuspolling()
        }
        .onReceive(NotificationCenter.default.publisher(for: keepalivemgr.authchangednotif)) { _ in
            refreshkeepaliveauthstat()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            playitmodel.refresh()
            refreshkeepaliveauthstat()
        }
        .onChange(of: tunnelinginstallinprogress) { newval in
            if !newval {
                tunnelingmodel.refreshinstalledservices()
                tunnelingmodel.refreshavailableservices()
                playitmodel.refresh()
                autostartifneeded()
            }
        }
        .onChange(of: serverRunning) { newval in
            if newval {
                autostartifneeded()
                applyUpnpIfNeeded()
            }
        }
        .onChange(of: playitmodel.linked) { _ in
            autostartifneeded()
        }
        .onChange(of: playitmodel.islibrarypresent) { _ in
            autostartifneeded()
        }
        .onChange(of: upnpPortsCSV) { _ in
            applyUpnpIfNeeded()
        }
        .overlay(
            Group {
                if tourManager.tourState == 2 {
                    let hasJVM = !model.installedJVMVersions.isEmpty
                    let canContinueTour = hasJVM || installInProgress
                    VStack {
                        Spacer()
                        VStack(spacing: 16) {
                            Text("Step 1: Install the JVM")
                                .font(.headline)
                            Text("In order to run a Minecraft server, JESSI needs a JVM (Java Virtual Machine). If you don't know which one to install, install Java 21.")
                                .multilineTextAlignment(.center)
                                .font(.subheadline)
                            
                            if installInProgress && !hasJVM {
                                Text("JVM install started. You can continue while it downloads in the background.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            } else if !hasJVM {
                                Text("Install a JVM above to continue.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }

                            Button(action: {
                                tourManager.nextStep()
                            }) {
                                Text("Next")
                                    .font(.system(size: 17, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 16)
                            }
                            .foregroundColor(.white)
                            .background(canContinueTour ? Color.green : Color.gray.opacity(0.35))
                            .cornerRadius(14)
                            .disabled(!canContinueTour)
                        }
                        .padding()
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(16)
                        .shadow(radius: 10)
                        .padding()
                    }
                }
            }
        )
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

struct CurseForgeField: View {
    @ObservedObject var model: SettingsModel
    @State private var isSecure: Bool = true
    @State private var showeasteregg: Bool = false
    @State private var eastereggtitle: String = ""
    @State private var eastereggmsg: String = ""
    @State private var lasttriggeredkey: String? = nil

    private static let eastereggs: [String: (title: String, message: String)] = [
        "loveyachilly": (title: "i think youre really pretty lol", message: "whats that mean?")
    ]

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if isSecure {
                    SecureField("CurseForge API Key", text: $model.curseForgeAPIKey)
                } else {
                    TextField("CurseForge API Key", text: $model.curseForgeAPIKey)
                }
            }
            .frame(maxWidth: 420)
            .onChange(of: model.curseForgeAPIKey) { newValue in
                model.applyAndSaveCurseForgeAPIKey()
                maybeshoweasteregg(for: newValue)
            }

            Button(action: { isSecure.toggle() }) {
                Image(systemName: isSecure ? "eye.slash" : "eye")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .alert(isPresented: $showeasteregg) {
            Alert(
                title: Text(eastereggtitle),
                message: Text(eastereggmsg),
                dismissButton: .default(Text("yes"))
            )
        }
    }

    private func maybeshoweasteregg(for newValue: String) {
        let key = newValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else {
            lasttriggeredkey = nil
            return
        }

        guard let egg = Self.eastereggs[key] else {
            if lasttriggeredkey == key {
                lasttriggeredkey = nil
            }
            return
        }

        guard key != lasttriggeredkey else { return }

        eastereggtitle = egg.title
        eastereggmsg = egg.message
        showeasteregg = true
        lasttriggeredkey = key
    }
}

struct CurseForgeFooter: View {
    @State private var safariurl: URL?
    private let cfURL = URL(string: "https://console.curseforge.com/#/api-keys")!
    
    var body: some View {
        Group {
            if #available(iOS 15, *) {
                Text("Installing Mods via CurseForge requires an API key. Create one [here.](https://console.curseforge.com/#/api-keys)")
                    .environment(\.openURL, OpenURLAction { tappedurl in
                        safariurl = cfURL
                        return .handled
                    })
                    .sheet(item: $safariurl) { SafariView(url: $0) }
            } else {
                HStack(spacing: 0) {
                    Text("Installing Mods via CurseForge requires an API key. Create one ")
                    Button("here.") {
                        UIApplication.shared.open(cfURL)
                    }
                }
            }
        }
        .font(.footnote)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.leading)
    }
}

@available(iOS 15, *)
extension URL: Identifiable {
    public var id: String { absoluteString }
}

private class JVMDownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    let onProgress: (Double) -> Void

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(min(max(fraction, 0), 1))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    }
}
