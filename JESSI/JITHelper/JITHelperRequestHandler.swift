// ya know, now that I think of it, I could prolly make the JVM also run in an app extension...
// update: added this functionality

import Foundation
import JessiJIT
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
    private let session: JITSession

    init(userInfo: [AnyHashable: Any]) {
        let channel = HostChannel(port: (userInfo["eventPort"] as? NSNumber)?.intValue ?? 0)
        self.channel = channel
        session = JITSession(
            pid: (userInfo["pid"] as? NSNumber)?.int32Value ?? 0,
            pairingData: userInfo["pairingFile"] as? Data,
            targetIP: (userInfo["targetIP"] as? String) ?? "10.7.0.1",
            tunnelPort: (userInfo["tunnelPort"] as? NSNumber).map { UInt16(truncatingIfNeeded: $0.intValue) } ?? JITSession.defaultTunnelPort,
            useScript: (userInfo["txm"] as? NSNumber)?.boolValue ?? false,
            script: userInfo["script"] as? String,
            log: { message in
                os_log("%{public}@", log: osLog, type: .default, message)
                channel.send(["event": "log", "message": message])
            },
            stage: { stage in
                channel.send(["event": "stage", "stage": stage])
            })
    }

    func run() {
        do {
            try session.run()
        } catch {
            let code = (error as? HelperError)?.code ?? -1
            os_log("%{public}@", log: osLog, type: .default, "Error: \(error.localizedDescription)")
            channel.send(["event": "log", "message": "Error: \(error.localizedDescription)"])
            channel.send(["event": "error", "message": error.localizedDescription, "code": code])
        }
    }
}
