import Darwin
import Foundation

// this is for trollstore/jailbreaks only

final class JessiChildProcess {
    let pid: pid_t
    let logURL: URL
    private(set) var exited = false

    static var isSupported: Bool {
        !jessi_is_running_on_macos() && jessi_has_trollstore_privileges()
    }

    private init(pid: pid_t, logURL: URL) {
        self.pid = pid
        self.logURL = logURL
    }

    static func spawn(_ arguments: [String], logURL: URL, input: Data? = nil, onExit: @escaping (Int32) -> Void) throws -> JessiChildProcess {
        guard let executable = Bundle.main.executablePath else { throw POSIXError(.ENOENT) }
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var inputPipe: [Int32] = [-1, -1]
        if input != nil {
            guard pipe(&inputPipe) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            _ = fcntl(inputPipe[1], F_SETNOSIGPIPE, 1)
        }
        defer {
            if inputPipe[0] >= 0 { close(inputPipe[0]) }
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if inputPipe[0] >= 0 {
            posix_spawn_file_actions_adddup2(&actions, inputPipe[0], STDIN_FILENO)
        } else {
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, logURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
        guard result == 0 else {
            if inputPipe[1] >= 0 { close(inputPipe[1]) }
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
        }

        if let input, inputPipe[1] >= 0 {
            input.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = write(inputPipe[1], buffer.baseAddress! + offset, buffer.count - offset)
                    if written <= 0 { break }
                    offset += written
                }
            }
            close(inputPipe[1])
        }

        let process = JessiChildProcess(pid: pid, logURL: logURL)
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            let code = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            DispatchQueue.main.async {
                process.exited = true
                onExit(code)
            }
        }
        return process
    }

    func terminate() {
        guard !exited else { return }
        kill(pid, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [self] in
            if !exited { kill(pid, SIGKILL) }
        }
    }

    func lastLogLine() -> String? {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return nil }
        return text.split(whereSeparator: \.isNewline).last.map { String($0).trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
    }
}
