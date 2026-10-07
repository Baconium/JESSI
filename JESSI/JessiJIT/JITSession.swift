import Foundation

public final class JITSession {
    public static let defaultTunnelPort = DeviceTunnel.defaultPort

    private let pid: Int32
    private let pairingData: Data?
    private let targetIP: String
    private let tunnelPort: UInt16
    private let useScript: Bool
    private let script: String?
    private let log: (String) -> Void
    private let stage: (String) -> Void
    public init(pid: Int32,
                pairingData: Data?,
                targetIP: String,
                tunnelPort: UInt16,
                useScript: Bool,
                script: String? = nil,
                log: @escaping (String) -> Void,
                stage: @escaping (String) -> Void) {
        self.pid = pid
        self.pairingData = pairingData
        self.targetIP = targetIP
        self.tunnelPort = tunnelPort
        self.useScript = useScript
        self.script = script
            ?? Bundle(for: JITSession.self).url(forResource: "universal", withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        self.log = log
        self.stage = stage
    }

    public func run() throws {
        guard pid > 0 else { throw HelperError("JESSI did not send its process ID") }
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
        let attach = try session.send("vAttach;\(String(UInt32(pid), radix: 16))") ?? ""
        guard attach.hasPrefix("T") || attach.hasPrefix("S") else {
            throw HelperError("debugserver refused to attach: \(attach.isEmpty ? "no reply" : attach)")
        }
        log("Attached to JESSI (pid \(pid))")
        let detach = try session.send("D") ?? ""
        log("Detached: \(detach)")
        stage("enabled")
    }

    private func runScriptSession(_ session: DebugSession) throws {
        guard let script, !script.isEmpty else { throw HelperError("JIT script is missing") }

        let heartbeat = HeartbeatKeepAlive(pairingData: pairingData ?? Data(), targetIP: targetIP, port: tunnelPort) { self.log($0) }
        defer { heartbeat.stop() }

        let runner = JITScriptRunner(session: session, pid: pid, log: { self.log($0) }) {
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
