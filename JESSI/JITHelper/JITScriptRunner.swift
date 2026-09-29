import Foundation
import JavaScriptCore

final class JITScriptRunner {
    private let session: DebugSession
    private let pid: Int32
    private let log: (String) -> Void
    private let onAttached: () -> Void
    private var context: JSContext?
    private var reportedAttach = false

    init(session: DebugSession, pid: Int32, log: @escaping (String) -> Void, onAttached: @escaping () -> Void) {
        self.session = session
        self.pid = pid
        self.log = log
        self.onAttached = onAttached
    }

    func run(script: String) throws {
        guard let context = JSContext() else { throw HelperError("Failed to create JavaScript context") }
        self.context = context

        let getPid: @convention(block) () -> Int = { [pid] in Int(pid) }

        let sendCommand: @convention(block) (String?) -> String? = { [weak self] command in
            guard let self, let command else { return "" }
            do {
                let response = try self.session.send(command) ?? ""
                if !self.reportedAttach, command.hasPrefix("vAttach"), response.hasPrefix("T") {
                    self.reportedAttach = true
                    self.onAttached()
                }
                return response
            } catch {
                self.raise(error.localizedDescription)
                return nil
            }
        }

        let prepareMemoryRegion: @convention(block) (UInt64, UInt64) -> String = { [weak self] start, size in
            guard let self else { return "" }
            do {
                let result = try self.session.prepareMemoryRegion(start: start, size: size)
                if result.failed > 0 {
                    self.log("prepare 0x\(String(start, radix: 16)) (\(result.pages) pages): \(result.failed) writes rejected, first \(result.firstFailure ?? "?")")
                    return "E\(result.failed)"
                }
                self.log("prepare 0x\(String(start, radix: 16)): \(result.pages) pages OK")
                return "OK"
            } catch {
                self.raise(error.localizedDescription)
                return ""
            }
        }

        let logFunction: @convention(block) (String) -> Void = { [weak self] message in
            self?.log(message)
        }

        let hasTXM: @convention(block) () -> Bool = { true }

        context.setObject(getPid, forKeyedSubscript: "get_pid" as NSString)
        context.setObject(sendCommand, forKeyedSubscript: "send_command" as NSString)
        context.setObject(prepareMemoryRegion, forKeyedSubscript: "prepare_memory_region" as NSString)
        context.setObject(logFunction, forKeyedSubscript: "log" as NSString)
        context.setObject(hasTXM, forKeyedSubscript: "hasTXM" as NSString)

        context.evaluateScript(script)
        if let exception = context.exception {
            throw HelperError("JIT script stopped: \(exception)")
        }
    }

    private func raise(_ message: String) {
        guard let context else { return }
        context.exception = JSValue(object: message, in: context)
    }
}
