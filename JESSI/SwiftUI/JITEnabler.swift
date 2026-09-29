import Foundation
import Combine
import os
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

final class JITEnabler: ObservableObject {
    static let shared = JITEnabler()
    private static let osLog = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "JESSI", category: "JIT")

    static let localDevVPNURL = URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!

    enum Phase: Equatable {
        case idle
        case connecting
        case mountingDDI
        case attaching
        case enabled
        case attached
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .connecting, .mountingDDI, .attaching: return true
            default: return false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var logLines: [String] = []
    @Published private(set) var hasPairingFile = PairingFileStore.exists
    @Published private(set) var jitEnabled = JITEnabler.isJITUsable

    var usesJITScript: Bool { Self.deviceNeedsJITScript }

    private var helperExtension: NSExtension?
    private var helperRequest: UUID?
    private var eventListener: HelperEventListener?
    private var statusTimer: Timer?
    private var portFinder: RemotePairingDiscovery?

    private init() {}

    func importPairingFile(from url: URL) {
        do {
            try PairingFileStore.importFile(from: url)
            hasPairingFile = true
            appendLog("Imported pairing file \(url.lastPathComponent)")
            if case .failed = phase { phase = .idle }
        } catch {
            phase = .failed("Couldn't import the pairing file: \(error.localizedDescription)")
        }
    }

    func removePairingFile() {
        PairingFileStore.remove()
        hasPairingFile = PairingFileStore.exists
    }

    func refreshStatus() {
        hasPairingFile = PairingFileStore.exists
        jitEnabled = Self.isJITUsable
    }

    static var isLocalDevVPNConnected: Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.pointee.ifa_name).hasPrefix("utun"),
                  (entry.pointee.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if ip >> 16 == 0x0A07 { return true }
        }
        return false
    }

    var canAutoEnable: Bool {
        #if targetEnvironment(macCatalyst)
        return false
        #else
        guard #available(iOS 17.4, *), !jessi_is_running_on_macos() else { return false }
        return PairingFileStore.exists && Self.isLocalDevVPNConnected
        #endif
    }

    static var isJITUsable: Bool {
        guard jessi_check_jit_enabled() else { return false }
        guard deviceNeedsJITScript else { return true }
        return isBeingDebugged && !helperLostWhileAttached
    }

    private static var helperLostWhileAttached = false
    private static let restartMessage = "The JIT helper stopped while it was attached. Close JESSI from the app switcher, reopen it, and enable JIT again."

    private static var isBeingDebugged: Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    func enableJIT() {
        guard !phase.isBusy else { return }
        refreshStatus()

        #if targetEnvironment(macCatalyst)
        phase = .enabled
        #else
        if Self.helperLostWhileAttached {
            phase = .failed(Self.restartMessage)
            return
        }
        if jitEnabled {
            phase = usesJITScript ? .attached : .enabled
            return
        }
        guard let pairingData = PairingFileStore.load() else {
            phase = .failed("Import a pairing file first.")
            return
        }

        logLines.removeAll()
        phase = .connecting

        do {
            let listener = try HelperEventListener { [weak self] event in
                DispatchQueue.main.async { self?.handle(event) }
            }
            eventListener = listener
            startStatusTimer()

            let finder = RemotePairingDiscovery()
            portFinder = finder
            appendLog("Looking for this device's RemotePairing service…")
            finder.findOwnPort(timeout: 5) { [weak self] port in
                guard let self, case .connecting = self.phase else { return }
                self.portFinder = nil
                let override = UserDefaults.standard.integer(forKey: "jessi.jit.tunnelPort")
                let chosen: UInt16
                if override > 0 && override <= Int(UInt16.max) {
                    chosen = UInt16(override)
                    self.appendLog("Using RemotePairing port \(chosen) from settings")
                } else if let port {
                    chosen = port
                    self.appendLog("RemotePairing service is on port \(port)")
                } else {
                    chosen = RemotePairingDiscovery.fallbackPort
                    self.appendLog("Couldn't find the RemotePairing port over Bonjour; trying \(chosen)")
                }
                do {
                    try self.launchHelper(pairingData: pairingData, eventPort: listener.port, tunnelPort: chosen)
                } catch {
                    self.finish(.failed(error.localizedDescription))
                }
            }
        } catch {
            finish(.failed(error.localizedDescription))
        }
        #endif
    }

    func cancel() {
        guard phase.isBusy else { return }
        portFinder?.cancel()
        portFinder = nil
        if let helperRequest {
            helperExtension?.cancelRequest(withIdentifier: helperRequest)
        }
        helperRequest = nil
        appendLog("Cancelled")
        finish(.idle)
    }

    private func launchHelper(pairingData: Data, eventPort: UInt16, tunnelPort: UInt16) throws {
        guard let helperID = Self.helperBundleIdentifier else {
            throw HelperLaunchError("The JIT helper extension is missing from this copy of JESSI. Make sure your signing tool keeps app extensions.")
        }

        let helper = try NSExtension(identifier: helperID)
        helper.setRequestInterruptionBlock { [weak self] _ in
            DispatchQueue.main.async { self?.helperExited(reason: "The JIT helper was interrupted.") }
        }
        helper.setRequestCancellationBlock { [weak self] _, error in
            DispatchQueue.main.async {
                self?.helperExited(reason: "The JIT helper was cancelled\(error.map { ": \($0.localizedDescription)" } ?? ".")")
            }
        }
        helper.setRequestCompletionBlock { [weak self] _, _ in
            DispatchQueue.main.async { self?.helperExited(reason: nil) }
        }
        helperExtension = helper

        let item = NSExtensionItem()
        item.userInfo = [
            "pid": NSNumber(value: getpid()),
            "pairingFile": pairingData,
            "eventPort": NSNumber(value: eventPort),
            "txm": NSNumber(value: usesJITScript),
            "targetIP": "10.7.0.1",
            "tunnelPort": NSNumber(value: tunnelPort),
        ]

        appendLog("Starting JIT helper (\(usesJITScript ? "TXM, staying attached" : "attach and detach"))…")
        helper.beginRequest(withInputItems: [item]) { [weak self] requestID in
            let helperPID = helper.pid(forRequestIdentifier: requestID)
            DispatchQueue.main.async {
                self?.helperRequest = requestID
                self?.appendLog("JIT helper running (pid \(helperPID))")
            }
        }
    }

    private func handle(_ event: [String: Any]) {
        switch event["event"] as? String {
        case "log":
            if let message = event["message"] as? String { appendLog(message) }
        case "stage":
            switch event["stage"] as? String {
            case "tunnel": phase = .connecting
            case "ddi": phase = .mountingDDI
            case "attach": phase = .attaching
            case "attached": phase = .attached
            case "enabled": verifyEnabled()
            case "detached":
                if phase == .attached {
                    phase = .failed("The debugger detached. Enable JIT again before starting a server.")
                }
            default: break
            }
        case "error":
            let message = event["message"] as? String ?? "Unknown error"
            let code = (event["code"] as? NSNumber)?.intValue ?? -1
            if phase == .attached {
                Self.helperLostWhileAttached = true
                finish(.failed("\(Self.explain(message, code: code))\n\n\(Self.restartMessage)"))
            } else {
                finish(.failed(Self.explain(message, code: code)))
            }
        default:
            break
        }
        refreshStatus()
    }

    private func verifyEnabled() {
        jitEnabled = Self.isJITUsable
        finish(jitEnabled ? .enabled : .failed("The debugger attached, but iOS did not mark JESSI as debugged."))
    }

    private func helperExited(reason: String?) {
        helperRequest = nil
        refreshStatus()
        switch phase {
        case .connecting, .mountingDDI, .attaching:
            finish(.failed(reason ?? "The JIT helper exited before JIT was enabled."))
        case .attached:
            Self.helperLostWhileAttached = true
            finish(.failed(Self.restartMessage))
        default:
            finish(phase)
        }
    }

    private func finish(_ newPhase: Phase) {
        phase = newPhase
        if newPhase != .attached {
            stopStatusTimer()
            eventListener?.close()
            eventListener = nil
        }
    }

    private func startStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.refreshStatus() }
        }
    }

    private func stopStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 500 {
            logLines.removeFirst(logLines.count - 500)
        }
        os_log("%{public}@", log: Self.osLog, type: .default, "[JIT] \(line)")
    }

    private static var helperBundleIdentifier: String? {
        guard let plugIns = Bundle.main.builtInPlugInsURL,
              let contents = try? FileManager.default.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil) else {
            return nil
        }
        for appex in contents where appex.pathExtension == "appex" {
            guard let bundle = Bundle(url: appex),
                  let info = bundle.infoDictionary?["NSExtension"] as? [String: Any],
                  info["NSExtensionPrincipalClass"] as? String == "JESSIJITHelperRequestHandler" else {
                continue
            }
            return bundle.bundleIdentifier
        }
        return nil
    }

    private static var deviceNeedsJITScript: Bool {
        jessi_is_txm_device()
    }

    private static func explain(_ message: String, code: Int) -> String {
        let lowered = message.lowercased()
        if code == -9 || lowered.contains("pair") && (lowered.contains("verify") || lowered.contains("invalid")) {
            return "\(message)\n\nThe pairing file may be invalid or from another device. Generate a new one and import it again."
        }
        if lowered.contains("connection reset") || code == 54 {
            return "\(message)\n\nThe device closed the connection, which usually means it doesn't recognise this pairing file. Generate a new pairing file for this device and import it again. If you just did, make sure LocalDevVPN is connected."
        }
        if lowered.contains("timed out") || lowered.contains("unreachable") || lowered.contains("connection refused")
            || lowered.contains("no route") || code == 61 {
            return "\(message)\n\nMake sure LocalDevVPN is installed and connected (the VPN icon should be showing), then try again."
        }
        return message
    }
}

private struct HelperLaunchError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum PairingFileStore {
    static let supportedTypes: [UTType] = [
        UTType(filenameExtension: "mobiledevicepairing", conformingTo: .data),
        UTType(filenameExtension: "mobiledevicepair", conformingTo: .data),
        UTType(filenameExtension: "plist", conformingTo: .data),
        .propertyList,
    ].compactMap { $0 }

    private static var storedURL: URL {
        URL(fileURLWithPath: JessiPaths.pairingFilePath())
    }

    static var exists: Bool {
        guard let data = try? Data(contentsOf: storedURL) else { return false }
        return isRemotePairingFile(data)
    }

    static func load() -> Data? {
        guard let data = try? Data(contentsOf: storedURL), isRemotePairingFile(data) else { return nil }
        return data
    }

    static func importFile(from url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard isRemotePairingFile(data) else {
            throw HelperLaunchError("This file isn't a pairing file for iOS 26.4+ (RemotePairing). Generate a new pairing file and try again.")
        }
        try store(data)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: storedURL)
    }

    private static func store(_ data: Data) throws {
        try data.write(to: storedURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func isRemotePairingFile(_ data: Data) -> Bool {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return false
        }
        return plist["private_key"] != nil && plist["public_key"] != nil && plist["identifier"] != nil
    }
}

nonisolated final class HelperEventListener: @unchecked Sendable {
    let port: UInt16
    private let listenFD: Int32
    private let lock = NSLock()
    private var clientFD: Int32 = -1
    private var closed = false

    init(onEvent: @escaping @Sendable ([String: Any]) -> Void) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HelperLaunchError("Couldn't open the JIT helper channel (errno \(errno))") }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Bool in
                bind(fd, pointer, length) == 0 && listen(fd, 1) == 0 && getsockname(fd, pointer, &length) == 0
            }
        }
        guard bound else {
            Darwin.close(fd)
            throw HelperLaunchError("Couldn't open the JIT helper channel (errno \(errno))")
        }

        listenFD = fd
        port = UInt16(bigEndian: address.sin_port)

        let thread = Thread { [self] in
            self.acceptAndRead(onEvent: onEvent)
        }
        thread.name = "JESSI.jit-events"
        thread.start()
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        shutdown(listenFD, SHUT_RDWR)
        Darwin.close(listenFD)
        if clientFD >= 0 {
            shutdown(clientFD, SHUT_RDWR)
        }
    }

    private func acceptAndRead(onEvent: ([String: Any]) -> Void) {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }

        lock.lock()
        if closed {
            lock.unlock()
            Darwin.close(client)
            return
        }
        clientFD = client
        lock.unlock()

        defer {
            lock.lock()
            clientFD = -1
            lock.unlock()
            Darwin.close(client)
        }

        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = read(client, &buffer, buffer.count)
            if count <= 0 { return }
            pending.append(buffer, count: count)

            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                if let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    onEvent(event)
                }
            }
        }
    }
}

final class RemotePairingDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    static let fallbackPort: UInt16 = 49152

    private let browser = NetServiceBrowser()
    private var pending: [NetService] = []
    private var candidates: [(port: UInt16, hostName: String?)] = []
    private var completion: ((UInt16?) -> Void)?
    private var timeout: Timer?
    private var ownAddresses = Set<String>()

    func findOwnPort(timeout seconds: TimeInterval, completion: @escaping (UInt16?) -> Void) {
        self.completion = completion
        ownAddresses = Self.currentInterfaceAddresses()
        browser.delegate = self
        browser.searchForServices(ofType: "_remotepairing._tcp.", inDomain: "local.")
        timeout = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.finishFromTimeout()
        }
    }

    func cancel() {
        completion = nil
        teardown()
    }

    private func teardown() {
        timeout?.invalidate()
        timeout = nil
        browser.stop()
        pending.forEach { $0.stop() }
        pending.removeAll()
    }

    private func finish(_ port: UInt16?) {
        guard let completion else { return }
        self.completion = nil
        teardown()
        completion(port)
    }

    private func finishFromTimeout() {
        let ownHost = ProcessInfo.processInfo.hostName.lowercased()
        let byName = candidates.filter { ($0.hostName ?? "").lowercased().hasPrefix(ownHost.replacingOccurrences(of: ".local", with: "")) }
        finish(byName.count == 1 ? byName[0].port : nil)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        pending.append(service)
        service.delegate = self
        service.resolve(withTimeout: 4)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard service(sender, isPendingResolve: true), sender.port > 0, sender.port <= Int(UInt16.max) else { return }
        let port = UInt16(sender.port)
        candidates.append((port, sender.hostName))
        let addresses = (sender.addresses ?? []).compactMap { Self.numericHost(from: $0) }
        if addresses.contains(where: { ownAddresses.contains($0) }) {
            finish(port)
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {}

    private func service(_ service: NetService, isPendingResolve: Bool) -> Bool {
        pending.contains(where: { $0 === service })
    }

    private static func numericHost(from sockaddrData: Data) -> String? {
        sockaddrData.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(base.assumingMemoryBound(to: sockaddr.self), socklen_t(sockaddrData.count),
                                 &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            guard rc == 0 else { return nil }
            return String(cString: host).split(separator: "%").first.map(String.init)
        }
    }

    private static func currentInterfaceAddresses() -> Set<String> {
        var result = Set<String>()
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            if let addr = entry.pointee.ifa_addr {
                let family = Int32(addr.pointee.sa_family)
                if family == AF_INET || family == AF_INET6 {
                    let length = family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size
                    let data = Data(bytes: addr, count: length)
                    if let host = numericHost(from: data) { result.insert(host) }
                }
            }
            cursor = entry.pointee.ifa_next
        }
        return result
    }
}
