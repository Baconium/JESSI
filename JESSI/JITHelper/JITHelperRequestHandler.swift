// ya know, now that I think of it, I could prolly make the JVM also run in an app extension...

import Foundation
import os

private let osLog = OSLog(subsystem: "com.baconmania.jessi.JITHelper", category: "jit")

final class HostChannel {
    private var socketFD: Int32 = -1
    private let lock = NSLock()

    init(port: Int) {
        guard port > 0 else { return }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port)).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            socketFD = fd
        } else {
            close(fd)
        }
    }

    deinit {
        if socketFD >= 0 { close(socketFD) }
    }

    func send(_ event: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: event) else { return }
        data.append(0x0A)

        lock.lock()
        defer { lock.unlock() }
        guard socketFD >= 0 else { return }
        if !pending.isEmpty {
            flushPending()
            guard pending.isEmpty else {
                droppedEvents += 1
                return
            }
        }
        if droppedEvents > 0 {
            let notice = "{\"event\":\"log\",\"message\":\"(\(droppedEvents) helper log lines dropped while JESSI was stopped)\"}\n"
            droppedEvents = 0
            pending = Data(notice.utf8)
            flushPending()
        }
        pending.append(data)
        flushPending()
    }

    private var pending = Data()
    private var droppedEvents = 0

    private func flushPending() {
        while !pending.isEmpty {
            let written = pending.withUnsafeBytes { Darwin.send(socketFD, $0.baseAddress!, $0.count, 0) }
            if written > 0 {
                pending.removeFirst(written)
            } else if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                return
            } else {
                close(socketFD)
                socketFD = -1
                pending.removeAll()
                return
            }
        }
    }
}

@objc(JESSIJITHelperRequestHandler)
final class JITHelperRequestHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let userInfo = (context.inputItems.first as? NSExtensionItem)?.userInfo ?? [:]
        let thread = Thread {
            JITHelperSession(userInfo: userInfo).run()
            context.completeRequest(returningItems: nil)
        }
        thread.name = "JESSI.jit-helper"
        thread.stackSize = 4 << 20
        thread.start()
    }
}

private final class JITHelperSession {
    private let channel: HostChannel
    private let hostPID: Int32
    private let pairingData: Data?
    private let targetIP: String
    private let tunnelPort: UInt16
    private let useScript: Bool
    private let script: String?

    init(userInfo: [AnyHashable: Any]) {
        channel = HostChannel(port: (userInfo["eventPort"] as? NSNumber)?.intValue ?? 0)
        hostPID = (userInfo["pid"] as? NSNumber)?.int32Value ?? 0
        pairingData = userInfo["pairingFile"] as? Data
        targetIP = (userInfo["targetIP"] as? String) ?? "10.7.0.1"
        tunnelPort = (userInfo["tunnelPort"] as? NSNumber).map { UInt16(truncatingIfNeeded: $0.intValue) } ?? DeviceTunnel.defaultPort
        useScript = (userInfo["txm"] as? NSNumber)?.boolValue ?? false
        script = (userInfo["script"] as? String)
            ?? Bundle.main.url(forResource: "universal", withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    func run() {
        do {
            try enableJIT()
        } catch {
            let helperError = error as? HelperError
            log("Error: \(error.localizedDescription)")
            channel.send(["event": "error", "message": error.localizedDescription, "code": helperError?.code ?? -1])
        }
    }

    private func log(_ message: String) {
        os_log("%{public}@", log: osLog, type: .default, message)
        channel.send(["event": "log", "message": message])
    }

    private func stage(_ stage: String) {
        channel.send(["event": "stage", "stage": stage])
    }

    private func enableJIT() throws {
        guard hostPID > 0 else { throw HelperError("JESSI did not send its process ID") }
        guard let pairingData, !pairingData.isEmpty else { throw HelperError("No pairing file was provided", code: -17) }

        stage("tunnel")
        log("Connecting to \(targetIP):\(tunnelPort) through the loopback VPN…")
        var tunnel = try DeviceTunnel(pairingData: pairingData, targetIP: targetIP, port: tunnelPort, hostname: "JESSI")
        log("Tunnel connected (\(tunnel.serviceCount()) services)")

        if try !tunnel.hasDebugServer() {
            stage("ddi")
            log("debugserver isn't available yet; mounting the Developer Disk Image (\(DeveloperDiskImage.usesCryptex ? "cryptex" : "personalized"))")
            try DeveloperDiskImage.downloadMissing { self.log($0) }
            log("Mounting Developer Disk Image…")
            tunnel = try mountDeveloperDiskImage(pairingData: pairingData)
            log("Developer Disk Image mounted")
        }

        stage("attach")
        let session = try DebugSession(tunnel: tunnel)
        let noAck = (try? session.enterNoAckMode()) ?? nil
        log("QStartNoAckMode: \(noAck ?? "<nil>")")

        if useScript {
            try runScriptSession(session)
        } else {
            try attachAndDetach(session)
        }
    }

    private func mountDeveloperDiskImage(pairingData: Data) throws -> DeviceTunnel {
        let finished = DispatchSemaphore(value: 0)
        var mountError: Error?
        let targetIP = targetIP
        let tunnelPort = tunnelPort
        let mountThread = Thread {
            do {
                let tunnel = try DeviceTunnel(pairingData: pairingData, targetIP: targetIP, port: tunnelPort, hostname: "JESSIMount")
                if DeveloperDiskImage.usesCryptex {
                    try tunnel.installCryptexDDI(from: DeveloperDiskImage.directory)
                } else {
                    try tunnel.mountPersonalizedDDI(from: DeveloperDiskImage.directory)
                }
            } catch {
                mountError = error
            }
            finished.signal()
        }
        mountThread.name = "JESSI.ddi-mount"
        mountThread.start()

        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            let mountReturned = finished.wait(timeout: .now() + 4) == .success
            if mountReturned, let mountError {
                log("Mount reported: \(mountError.localizedDescription)")
            }
            if let fresh = try? DeviceTunnel(pairingData: pairingData, targetIP: targetIP, port: tunnelPort, hostname: "JESSI"),
               (try? fresh.hasDebugServer()) == true {
                log("Reconnected (\(fresh.serviceCount()) services)\(mountReturned ? "" : "; the mount call hasn't returned, continuing anyway")")
                return fresh
            }

            if mountReturned {
                if let mountError { throw mountError }
                throw HelperError("The Developer Disk Image was mounted, but debugserver still isn't available.")
            }
        }
        throw HelperError("Timed out mounting the Developer Disk Image.")
    }

    private func attachAndDetach(_ session: DebugSession) throws {
        let attach = try session.send("vAttach;\(String(UInt32(hostPID), radix: 16))") ?? ""
        guard attach.hasPrefix("T") || attach.hasPrefix("S") else {
            throw HelperError("debugserver refused to attach: \(attach.isEmpty ? "no reply" : attach)")
        }
        log("Attached to JESSI (pid \(hostPID))")
        let detach = try session.send("D") ?? ""
        log("Detached: \(detach)")
        stage("enabled")
    }

    private func runScriptSession(_ session: DebugSession) throws {
        guard let script, !script.isEmpty else { throw HelperError("JIT script is missing") }

        let heartbeat = HeartbeatKeepAlive(pairingData: pairingData ?? Data(), targetIP: targetIP, port: tunnelPort) { self.log($0) }
        defer { heartbeat.stop() }

        let runner = JITScriptRunner(session: session, pid: hostPID, log: { self.log($0) }) {
            self.stage("attached")
        }
        do {
            try runner.run(script: script)
        } catch {
            stage("detached")
            throw error
        }
        log("JIT script finished")
        stage("detached")
    }
}
