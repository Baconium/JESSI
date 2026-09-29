import Foundation
import idevice

struct HelperError: LocalizedError {
    let message: String
    let code: Int

    init(_ message: String, code: Int = -1) {
        self.message = message
        self.code = code
    }

    var errorDescription: String? { message }
}

enum Idevice {
    static func takeError(_ ffiError: UnsafeMutablePointer<IdeviceFfiError>?, _ fallback: String) -> HelperError {
        guard let ffiError else { return HelperError(fallback) }
        let code = Int(ffiError.pointee.code)
        let detail = ffiError.pointee.message.flatMap { String(validatingUTF8: $0) } ?? "unknown error"
        idevice_error_free(ffiError)
        return HelperError("\(fallback): \(detail)", code: code)
    }

    static func check(_ ffiError: UnsafeMutablePointer<IdeviceFfiError>?, _ fallback: String) throws {
        if let ffiError {
            throw takeError(ffiError, fallback)
        }
    }

    static func connect(
        _ fallback: String,
        _ connect: (UnsafeMutablePointer<OpaquePointer?>) -> UnsafeMutablePointer<IdeviceFfiError>?
    ) throws -> OpaquePointer {
        var handle: OpaquePointer?
        try check(connect(&handle), fallback)
        guard let handle else { throw HelperError("\(fallback): no handle returned") }
        return handle
    }
}

final class DeviceTunnel {
    let adapter: OpaquePointer
    let handshake: OpaquePointer
    
    static let defaultPort: UInt16 = 49152

    init(pairingData: Data, targetIP: String, port: UInt16 = DeviceTunnel.defaultPort, hostname: String) throws {
        var pairingFile: OpaquePointer?
        let parseError = pairingData.withUnsafeBytes { buffer in
            rp_pairing_file_from_bytes(buffer.bindMemory(to: UInt8.self).baseAddress, UInt(pairingData.count), &pairingFile)
        }
        try Idevice.check(parseError, "Failed to read pairing file")
        guard let pairingFile else { throw HelperError("Failed to read pairing file") }
        defer { rp_pairing_file_free(pairingFile) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        guard targetIP.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
            throw HelperError("Invalid target IP address \(targetIP)", code: -18)
        }

        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        let tunnelError = hostname.withCString { hostname in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    tunnel_create_rppairing(
                        $0,
                        socklen_t(MemoryLayout<sockaddr_in>.stride),
                        hostname,
                        pairingFile,
                        nil,
                        nil,
                        &adapter,
                        &handshake
                    )
                }
            }
        }
        try Idevice.check(tunnelError, "Failed to create tunnel")

        guard let adapter, let handshake else {
            if let handshake { rsd_handshake_free(handshake) }
            if let adapter { adapter_free(adapter) }
            throw HelperError("Tunnel was created without valid handles")
        }
        self.adapter = adapter
        self.handshake = handshake
    }

    deinit {
        rsd_handshake_free(handshake)
        adapter_free(adapter)
    }

    static let debugServerService = "com.apple.internal.dt.remote.debugproxy"

    func hasDebugServer() throws -> Bool {
        var available = false
        try Idevice.check(rsd_service_available(handshake, Self.debugServerService, &available), "Failed to query device services")
        return available
    }

    func serviceCount() -> Int {
        var services: UnsafeMutablePointer<CRsdServiceArray>?
        guard rsd_get_services(handshake, &services) == nil, let services else { return -1 }
        defer { rsd_free_services(services) }
        return Int(services.pointee.count)
    }

    func installCryptexDDI(from directory: URL) throws {
        var assets: OpaquePointer?
        try Idevice.check(cryptex1_assets_load(directory.path, &assets), "Failed to load DDI cryptex assets")
        guard let assets else { throw HelperError("DDI cryptex assets were not loaded") }
        defer { cryptex1_assets_free(assets) }
        try Idevice.check(cryptexd_install_ddi(adapter, handshake, assets, nil), "Failed to install DDI cryptex")
    }

    func mountPersonalizedDDI(from directory: URL) throws {
        let image = try Data(contentsOf: directory.appendingPathComponent("Image.dmg"), options: .mappedIfSafe)
        let trustcache = try Data(contentsOf: directory.appendingPathComponent("Image.dmg.trustcache"))
        let manifest = try Data(contentsOf: directory.appendingPathComponent("BuildManifest.plist"))

        let lockdown = try Idevice.connect("Failed to connect to lockdownd") { lockdownd_connect_rsd(adapter, handshake, $0) }
        var chipIDPlist: plist_t?
        let chipIDError = lockdownd_get_value(lockdown, "UniqueChipID", nil, &chipIDPlist)
        lockdownd_client_free(lockdown)
        try Idevice.check(chipIDError, "Failed to query UniqueChipID")
        var uniqueChipID: UInt64 = 0
        if let chipIDPlist {
            plist_get_uint_val(chipIDPlist, &uniqueChipID)
            plist_free(chipIDPlist)
        }
        guard uniqueChipID != 0 else { throw HelperError("Failed to decode UniqueChipID") }

        let imageMounter = try Idevice.connect("Failed to connect to image mounter") { image_mounter_connect_rsd(adapter, handshake, $0) }
        defer { image_mounter_free(imageMounter) }

        let mountError = image.withUnsafeBytes { imageBuffer in
            trustcache.withUnsafeBytes { trustcacheBuffer in
                manifest.withUnsafeBytes { manifestBuffer in
                    image_mounter_mount_personalized_rsd(
                        imageMounter,
                        adapter,
                        handshake,
                        imageBuffer.bindMemory(to: UInt8.self).baseAddress,
                        image.count,
                        trustcacheBuffer.bindMemory(to: UInt8.self).baseAddress,
                        trustcache.count,
                        manifestBuffer.bindMemory(to: UInt8.self).baseAddress,
                        manifest.count,
                        nil,
                        uniqueChipID
                    )
                }
            }
        }
        try Idevice.check(mountError, "Failed to mount personalized DDI")
    }
}

final class DebugSession {
    let tunnel: DeviceTunnel
    let remoteServer: OpaquePointer
    let debugProxy: OpaquePointer

    init(tunnel: DeviceTunnel) throws {
        self.tunnel = tunnel
        remoteServer = try Idevice.connect("Failed to connect remote server") {
            remote_server_connect_rsd(tunnel.adapter, tunnel.handshake, $0)
        }
        do {
            debugProxy = try Idevice.connect("Failed to connect debug proxy") {
                debug_proxy_connect_rsd(tunnel.adapter, tunnel.handshake, $0)
            }
        } catch {
            remote_server_free(remoteServer)
            throw error
        }
    }

    deinit {
        debug_proxy_free(debugProxy)
        remote_server_free(remoteServer)
    }

    @discardableResult
    func send(_ command: String) throws -> String? {
        guard let commandHandle = debugserver_command_new(command, nil, 0) else {
            throw HelperError("Failed to create debugserver command: \(command)")
        }
        var response: UnsafeMutablePointer<CChar>?
        let ffiError = debug_proxy_send_command(debugProxy, commandHandle, &response)
        debugserver_command_free(commandHandle)
        defer {
            if let response { idevice_string_free(response) }
        }
        try Idevice.check(ffiError, "Debugserver command failed (\(command.prefix(24)))")
        return response.map { String(cString: $0) }
    }

    func enterNoAckMode() throws -> String? {
        debug_proxy_send_ack(debugProxy)
        debug_proxy_send_ack(debugProxy)
        let response = try send("QStartNoAckMode")
        debug_proxy_set_ack_mode(debugProxy, 0)
        return response
    }

    @discardableResult
    func prepareMemoryRegion(start: UInt64, size: UInt64) throws -> (pages: Int, failed: Int, firstFailure: String?) {
        let pageSize: UInt64 = 16_384
        guard size > 0 else { return (0, 0, nil) }
        var failedWrites = 0
        var firstFailure: String?
        let pageCount = Int((size - 1) / pageSize + 1)
        let batchSize = 128

        for batchStart in stride(from: 0, to: pageCount, by: batchSize) {
            let count = min(batchSize, pageCount - batchStart)
            var packets = Data()
            packets.reserveCapacity(count * 24)
            for index in batchStart..<(batchStart + count) {
                let address = start + UInt64(index) * pageSize
                packets.append(Self.packet("M\(String(address, radix: 16)),1:69"))
            }

            let sendError = packets.withUnsafeBytes { buffer in
                debug_proxy_send_raw(debugProxy, buffer.bindMemory(to: UInt8.self).baseAddress, UInt(packets.count))
            }
            try Idevice.check(sendError, "Failed to write JIT pages")

            for index in 0..<count {
                var response: UnsafeMutablePointer<CChar>?
                let readError = debug_proxy_read_response(debugProxy, &response)
                if let response {
                    let reply = String(cString: response)
                    idevice_string_free(response)
                    if reply != "OK" {
                        failedWrites += 1
                        if firstFailure == nil {
                            let address = start + UInt64(batchStart + index) * pageSize
                            firstFailure = "0x\(String(address, radix: 16)): \(reply.isEmpty ? "<empty>" : reply)"
                        }
                    }
                }
                try Idevice.check(readError, "Failed to read JIT page write reply")
            }
        }
        return (pageCount, failedWrites, firstFailure)
    }

    func interrupt() {
        var breakByte: UInt8 = 0x03
        if let ffiError = debug_proxy_send_raw(debugProxy, &breakByte, 1) {
            idevice_error_free(ffiError)
        }
    }

    private static func packet(_ body: String) -> Data {
        let bytes = Array(body.utf8)
        let checksum = bytes.reduce(UInt8(0)) { $0 &+ $1 }
        return Data("$\(body)#\(String(format: "%02x", checksum))".utf8)
    }
}

final class HeartbeatKeepAlive {
    private let stateLock = NSLock()
    private var stopRequested = false
    private let stopped = DispatchSemaphore(value: 0)
    private let pairingData: Data
    private let targetIP: String
    private let port: UInt16
    private let log: (String) -> Void

    init(pairingData: Data, targetIP: String, port: UInt16 = DeviceTunnel.defaultPort, log: @escaping (String) -> Void) {
        self.pairingData = pairingData
        self.targetIP = targetIP
        self.port = port
        self.log = log

        let thread = Thread { [self] in
            self.run()
            self.stopped.signal()
        }
        thread.name = "JESSI.heartbeat"
        thread.start()
    }

    func stop() {
        stateLock.lock()
        stopRequested = true
        stateLock.unlock()
        _ = stopped.wait(timeout: .now() + 4)
    }

    private var shouldStop: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopRequested
    }

    private func run() {
        var consecutiveFailures = 0
        while !shouldStop && consecutiveFailures < 5 {
            if consecutiveFailures > 0 {
                Thread.sleep(forTimeInterval: Double(min(consecutiveFailures * 2, 8)))
                if shouldStop { return }
            }

            let tunnel: DeviceTunnel
            let client: OpaquePointer
            do {
                tunnel = try DeviceTunnel(pairingData: pairingData, targetIP: targetIP, port: port, hostname: "JESSIHeartbeat")
                client = try Idevice.connect("Failed to connect debug heartbeat") {
                    heartbeat_connect_rsd(tunnel.adapter, tunnel.handshake, $0)
                }
            } catch {
                consecutiveFailures += 1
                log("Heartbeat unavailable: \(error.localizedDescription)")
                continue
            }

            if serve(client: client) {
                consecutiveFailures = 0
            } else {
                consecutiveFailures += 1
            }
            heartbeat_client_free(client)
            withExtendedLifetime(tunnel) {}
            if !shouldStop {
                log("Heartbeat connection lost; reconnecting")
            }
        }
        if consecutiveFailures >= 5 {
            log("Heartbeat keepalive gave up after repeated failures")
        }
    }

    private func serve(client: OpaquePointer) -> Bool {
        var succeeded = false
        var interval: UInt64 = 2
        while !shouldStop {
            var suggestedInterval: UInt64 = 0
            if let ffiError = heartbeat_get_marco(client, interval, &suggestedInterval) {
                let description = Idevice.takeError(ffiError, "Heartbeat").message
                if description.contains("HeartbeatTimeout") {
                    interval = 2
                    continue
                }
                if description.contains("HeartbeatSleepyTime") {
                    log("Heartbeat paused: device went to sleep")
                } else if !shouldStop {
                    log("Heartbeat error: \(description)")
                }
                return succeeded
            }

            interval = min(max(suggestedInterval, 1), 3)
            if let ffiError = heartbeat_send_polo(client) {
                log("Heartbeat error: \(Idevice.takeError(ffiError, "Failed to reply to heartbeat").message)")
                return succeeded
            }
            succeeded = true
        }
        return succeeded
    }
}
