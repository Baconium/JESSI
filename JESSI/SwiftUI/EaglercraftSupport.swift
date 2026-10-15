import Combine
import Darwin
import Foundation
import UIKit
import ZIPFoundation

enum Eaglercraft {
    static let serverVersion = "1.12.2"
    static let clientVersions = ["1.8.8", "1.12.2"]
    static let javaVersion = "21"

    struct Download {
        let label: String
        let url: URL
        let path: String
    }

    struct HangarPlugin {
        let label: String
        let project: String
        let path: String
    }

    struct Client {
        let label: String
        let detail: String
        let file: String
        let url: URL
    }

    private static func eaglerXServerAsset(_ name: String) -> URL {
        URL(string: "https://github.com/lax1dude/eaglerxserver/releases/latest/download/\(name).jar")!
    }

    static let directPlugins: [Download] = [
        Download(label: "EaglerXServer", url: eaglerXServerAsset("EaglerXServer"), path: "plugins/EaglerXServer.jar"),
        Download(label: "EaglerWeb", url: eaglerXServerAsset("EaglerWeb"), path: "plugins/EaglerWeb.jar"),
    ]

    static let hangarPlugins: [HangarPlugin] = [
        HangarPlugin(label: "ViaVersion", project: "ViaVersion", path: "plugins/ViaVersion.jar"),
        HangarPlugin(label: "ViaBackwards", project: "ViaBackwards", path: "plugins/ViaBackwards.jar"),
        HangarPlugin(label: "ViaRewind", project: "ViaRewind", path: "plugins/ViaRewind.jar"),
    ]

    private static func clientZip(_ path: String) -> URL {
        URL(string: "https://cdn.eaglercraft.net/objects/dl/\(path)")!
    }

    static func clients(for version: String) -> [Client] {
        switch version {
        case "1.12.2":
            return [
                Client(label: " Eaglercraft 1.12.2 (WASM)", detail: "<br>Recommended, use JS if this doesn't work.", file: "1.12.2-wasm.html", url: clientZip("1.12.2/Eaglercraft_1.12.2_u3_WASM_Offline.zip")),
                Client(label: " Eaglercraft 1.12.2 (JS)", detail: "<br>Legacy browser support", file: "1.12.2.html", url: clientZip("1.12.2/Eaglercraft_1.12.2_u3_Offline.zip")),
            ]
        default:
            return [
                Client(label: " EaglercraftX 1.8.8 (WASM)", detail: "<br>Recommended, use JS if this doesn't work.", file: "1.8.8-wasm.html", url: clientZip("1.8.8/EaglercraftX_1.8_u53_WASM-GC_Offline.zip")),
                Client(label: " EaglercraftX 1.8.8 (JS)", detail: "<br>Legacy browser support", file: "1.8.8.html", url: clientZip("1.8.8/EaglercraftX_1.8_u53_Offline_Signed.zip")),
            ]
        }
    }

    static func hangarLatestURL(_ project: String) -> URL {
        URL(string: "https://hangar.papermc.io/api/v1/projects/\(project)/latestrelease")!
    }

    static func hangarDownloadURL(_ project: String, version: String) -> URL? {
        let escaped = version.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? version
        return URL(string: "https://hangar.papermc.io/api/v1/projects/\(project)/versions/\(escaped)/PAPER/download")
    }

    static func webDirectory(for version: String) -> URL {
        URL(fileURLWithPath: JessiPaths.documentsDirectory(), isDirectory: true)
            .appendingPathComponent("Eaglercraft/web/\(version)", isDirectory: true)
    }

    static func documentRootFromPlugin(for version: String) -> String {
        "../../../../Eaglercraft/web/\(version)"
    }

    static func missingClients(for version: String) -> [Client] {
        let webDirectory = webDirectory(for: version)
        let fm = FileManager.default
        return clients(for: version).filter {
            !fm.fileExists(atPath: webDirectory.appendingPathComponent($0.file).path)
                || !fm.fileExists(atPath: partsDirectory(for: $0, in: webDirectory).appendingPathComponent("0.txt").path)
        }
    }

    static let partSize = 2 << 20

    private static func partsDirectory(for client: Client, in webDirectory: URL) -> URL {
        webDirectory.appendingPathComponent((client.file as NSString).deletingPathExtension, isDirectory: true)
    }

    static func splitInstalledClient(_ client: Client, version: String) -> Bool {
        let webDirectory = webDirectory(for: version)
        let page = webDirectory.appendingPathComponent(client.file)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: page.path))?[.size] as? Int, size > partSize else { return false }
        return (try? writeParts(from: page, client: client, webDirectory: webDirectory)) != nil
    }

    private static func writeParts(from source: URL, client: Client, webDirectory: URL) throws {
        guard let loaderURL = Bundle.main.url(forResource: "EaglercraftLoader", withExtension: "html"),
              let template = try? String(contentsOf: loaderURL, encoding: .utf8) else {
            throw EaglercraftError("EaglercraftLoader.html is missing!")
        }
        let fm = FileManager.default
        let parts = partsDirectory(for: client, in: webDirectory)
        let staging = webDirectory.appendingPathComponent(".\(parts.lastPathComponent).parts")
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let data = try Data(contentsOf: source, options: .alwaysMapped)
        guard !data.isEmpty else { throw EaglercraftError("\(client.label) web page is empty.") }
        for (index, start) in stride(from: 0, to: data.count, by: partSize).enumerated() {
            try data.subdata(in: start..<min(start + partSize, data.count)).write(to: staging.appendingPathComponent("\(index).txt"))
        }
        try? fm.removeItem(at: parts)
        try fm.moveItem(at: staging, to: parts)

        let page = template
            .replacingOccurrences(of: "{{TITLE}}", with: client.label.trimmingCharacters(in: .whitespaces))
            .replacingOccurrences(of: "{{PARTS}}", with: parts.lastPathComponent)
            .replacingOccurrences(of: "{{TAG}}", with: String(UUID().uuidString.prefix(8)))
            .replacingOccurrences(of: "{{SIZE}}", with: String(data.count))
            .replacingOccurrences(of: "{{PART_SIZE}}", with: String(partSize))
        try page.write(to: webDirectory.appendingPathComponent(client.file), atomically: true, encoding: .utf8)
    }

    static func installClient(_ client: Client, version: String, fromZip zip: URL) throws {
        let webDirectory = webDirectory(for: version)
        let archive = try Archive(url: zip, accessMode: .read)
        guard let entry = archive.first(where: { $0.type == .file && $0.path.lowercased().hasSuffix(".html") }) else {
            throw EaglercraftError("\(client.label) download didn't contain a web page.")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: webDirectory, withIntermediateDirectories: true)
        let extracted = webDirectory.appendingPathComponent(".\(client.file).download")
        let patched = webDirectory.appendingPathComponent(".\(client.file).tmp")
        defer {
            try? fm.removeItem(at: extracted)
            try? fm.removeItem(at: patched)
        }
        try? fm.removeItem(at: extracted)
        _ = try archive.extract(entry, to: extracted, skipCRC32: true)
        try injectLaunchHook(from: extracted, to: patched)
        try writeParts(from: patched, client: client, webDirectory: webDirectory)
    }

    static func injectLaunchHook(from source: URL, to dest: URL) throws {
        guard let hookURL = Bundle.main.url(forResource: "EaglercraftInject", withExtension: "html"),
              let hook = try? Data(contentsOf: hookURL) else {
            throw EaglercraftError("EaglercraftInject.html is missing!")
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let start = try input.read(upToCount: 64 * 1024) ?? Data()
        let lowered = Data(start.map { (65...90).contains($0) ? $0 + 32 : $0 })
        guard let head = lowered.range(of: Data("<head>".utf8)) else {
            throw EaglercraftError("Couldn't find where to add the server address")
        }

        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let output = try FileHandle(forWritingTo: dest)
        defer { try? output.close() }
        try output.write(contentsOf: start.prefix(head.upperBound))
        try output.write(contentsOf: Data("\n".utf8) + hook)
        try output.write(contentsOf: start.suffix(from: head.upperBound))
        while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
    }

    static func writeLandingPage(for version: String) throws {
        guard let source = Bundle.main.url(forResource: "EaglercraftIndex", withExtension: "html"),
              let template = try? String(contentsOf: source, encoding: .utf8) else {
            throw EaglercraftError("EaglercraftIndex.html is missing!")
        }
        let cards = clients(for: version).enumerated().map { index, client in
            """
            <a class="client\(index == 0 ? " recommended" : "")" href="\(client.file)"><div><strong>\(client.label)</strong><span>\(client.detail)</span></div><br><div><button type="button" style="background-color: #1f1f1f; color: white; border: 3px solid #333; border-radius: 12px; padding: 12px; font-size: 24px; text-align: center;">Launch Eaglercraft</button></div><br></a>
            """
        }.joined(separator: "\n")
        let page = template
            .replacingOccurrences(of: "{{VERSION}}", with: version)
            .replacingOccurrences(of: "{{CLIENTS}}", with: cards)
        let webDirectory = webDirectory(for: version)
        try FileManager.default.createDirectory(at: webDirectory, withIntermediateDirectories: true)
        try page.write(to: webDirectory.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    }

    static func writeServerConfig(serverDir: URL, serverName: String, version: String) throws {
        let fm = FileManager.default

        let eaglerX = serverDir.appendingPathComponent("plugins/EaglercraftXServer", isDirectory: true)
        try fm.createDirectory(at: eaglerX, withIntermediateDirectories: true)
        let quotedName = serverName.replacingOccurrences(of: "'", with: "''")
        let settings = """
        server_name: '\(quotedName)'
        skin_service:
          download_vanilla_skins_to_clients: false

        """
        try settings.write(to: eaglerX.appendingPathComponent("settings.yml"), atomically: true, encoding: .utf8)
        try raiseHTTPRateLimit(serverDir: serverDir)

        let eaglerWeb = serverDir.appendingPathComponent("plugins/EaglerWeb", isDirectory: true)
        try fm.createDirectory(at: eaglerWeb, withIntermediateDirectories: true)
        let web: [String: Any] = [
            "memory_cache_expires_after": 60,
            "memory_cache_max_files": 8,
            "file_io_thread_count": 1,
            "enable_cors_support": false,
            "listeners": [
                "*": [
                    "document_root": documentRootFromPlugin(for: version),
                    "page_index": ["index.html"],
                    "page_404": NSNull(),
                    "page_429": NSNull(),
                    "page_500": NSNull(),
                    "autoindex": ["enable": false, "date_format": "dd-MMM-YYYY hh:mm aa"],
                ] as [String: Any],
            ],
        ]
        let json = try JSONSerialization.data(withJSONObject: web, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: eaglerWeb.appendingPathComponent("settings.json"))

        let icon = serverDir.appendingPathComponent("server-icon.png")
        if !fm.fileExists(atPath: icon.path), let png = defaultServerIcon() {
            try? png.write(to: icon)
        }
    }

    static func raiseHTTPRateLimit(serverDir: URL) throws {
        let wanted = ["limit": 300, "limit_lockout": 600]
        let file = serverDir.appendingPathComponent("plugins/EaglercraftXServer/listener.yml")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let yaml = "ratelimit:\n  http:\n" + wanted.keys.sorted().map { "    \($0): \(wanted[$0]!)\n" }.joined()
            try yaml.write(to: file, atomically: true, encoding: .utf8)
            return
        }
        var lines = text.components(separatedBy: "\n")
        var section = ""
        var changed = false
        for i in lines.indices {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let indent = lines[i].prefix { $0 == " " }.count
            if indent == 0 {
                section = trimmed == "ratelimit:" ? "ratelimit" : ""
            } else if indent == 2, section.hasPrefix("ratelimit") {
                section = trimmed == "http:" ? "ratelimit.http" : "ratelimit"
            } else if indent == 4, section == "ratelimit.http", let colon = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[..<colon])
                guard let value = wanted[key] else { continue }
                if let current = Int(trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)), current >= value { continue }
                lines[i] = "    \(key): \(value)"
                changed = true
            }
        }
        if changed {
            try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        }
    }

    private static func defaultServerIcon() -> Data? {
        guard let path = Bundle.main.path(forResource: "AppIcon60x60@2x", ofType: "png"),
              let image = UIImage(contentsOfFile: path) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: 64, height: 64)
        return UIGraphicsImageRenderer(size: size, format: format).pngData { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    static func webVersion(forServerAt serverDir: String) -> String? {
        guard isEaglercraftServer(at: serverDir) else { return nil }
        let settings = (serverDir as NSString).appendingPathComponent("plugins/EaglerWeb/settings.json")
        if let data = FileManager.default.contents(atPath: settings),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let listeners = json["listeners"] as? [String: Any] {
            for case let listener as [String: Any] in listeners.values {
                if let root = listener["document_root"] as? String,
                   let version = root.split(separator: "/").last.map(String.init),
                   clientVersions.contains(version) {
                    return version
                }
            }
        }
        let config = (serverDir as NSString).appendingPathComponent("jessiserverconfig.json")
        if let data = FileManager.default.contents(atPath: config),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = json["eaglercraftVersion"] as? String,
           clientVersions.contains(version) {
            return version
        }
        return nil
    }

    static func restoreWebFiles(for version: String, status: @escaping (String, Double) -> Void, completion: @escaping (Error?) -> Void) {
        let missing = missingClients(for: version)
        func finish(_ error: Error?) {
            if error == nil {
                do { try writeLandingPage(for: version) } catch { return completion(error) }
            }
            completion(error)
        }
        func install(_ index: Int) {
            guard index < missing.count else { return finish(nil) }
            let client = missing[index]
            if splitInstalledClient(client, version: version) { return install(index + 1) }
            let label = "Downloading \(client.label) (\(index + 1)/\(missing.count))..."
            status(label, 0)
            var observation: NSKeyValueObservation?
            let task = URLSession.shared.downloadTask(with: client.url) { location, response, error in
                observation?.invalidate()
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard let location, error == nil, (200..<300).contains(code) else {
                    return finish(error ?? EaglercraftError("Couldn't download \(client.label) (HTTP \(code))."))
                }
                let zip = FileManager.default.temporaryDirectory.appendingPathComponent("eaglercraft-\(UUID().uuidString).zip")
                defer { try? FileManager.default.removeItem(at: zip) }
                do {
                    try FileManager.default.moveItem(at: location, to: zip)
                    status("Unpacking \(client.label)...", 1)
                    try installClient(client, version: version, fromZip: zip)
                } catch {
                    return finish(error)
                }
                install(index + 1)
            }
            observation = task.progress.observe(\.fractionCompleted) { progress, _ in
                status(label, progress.fractionCompleted)
            }
            task.resume()
        }
        DispatchQueue.global(qos: .userInitiated).async { install(0) }
    }

    static func isEaglercraftServer(at serverDir: String) -> Bool {
        let config = (serverDir as NSString).appendingPathComponent("jessiserverconfig.json")
        guard let data = FileManager.default.contents(atPath: config),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let software = json["software"] as? String else { return false }
        return software.caseInsensitiveCompare("Eaglercraft") == .orderedSame
    }

    struct Link: Identifiable {
        let label: String
        let url: String
        var id: String { url }
    }

    static func browserLinks(for serverDir: String) -> [Link] {
        let port = serverPort(at: serverDir)
        var links: [Link] = []
        if let ip = wifiIPv4Address() {
            links.append(Link(label: "On this Wi-Fi", url: "http://\(ip):\(port)"))
        }
        return links
    }

    private static func wifiIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.pointee.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }

    static func serverPort(at serverDir: String) -> Int {
        let props = (serverDir as NSString).appendingPathComponent("server.properties")
        guard let text = try? String(contentsOfFile: props, encoding: .utf8) else { return 25565 }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("server-port=") else { continue }
            if let port = Int(trimmed.dropFirst("server-port=".count).trimmingCharacters(in: .whitespaces)), port > 0 {
                return port
            }
        }
        return 25565
    }
}

final class EaglercraftTunnel: ObservableObject {
    static let shared = EaglercraftTunnel()
    static let enabledKey = "jessi.eaglercraft.cloudflare"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    enum State: Equatable {
        case off
        case downloading(Double)
        case starting
        case online(String)
        case failed(String)
    }

    @Published private(set) var state: State = .off

    #if targetEnvironment(macCatalyst)
    private static let libraryName = "libcloudflared-maccatalyst.dylib"
    #else
    private static let libraryName = "libcloudflared.dylib"
    #endif
    private static let downloadURL = URL(string: "https://baconium.dev/jessi/cloudflared/\(libraryName)")!
    static var libraryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tunneling/cloudflare/\(libraryName)", isDirectory: false)
    }

    static var logURL: URL {
        libraryURL.deletingLastPathComponent().appendingPathComponent("cloudflared.log", isDirectory: false)
    }

    private typealias RunFn = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
    private typealias StopFn = @convention(c) () -> Void

    private static let healthCheckInterval: TimeInterval = 15
    private static let failedHealthChecksBeforeRestart = 4

    private var generation = 0
    private var gamePort = 0
    private var worker: JessiWorker?
    private var child: JessiChildProcess?
    private var stopInProcess: StopFn?
    private var pollTimer: Timer?
    private var healthTimer: Timer?
    private var failedHealthChecks = 0
    private var downloadObservation: NSKeyValueObservation?
    private let inProcessQueue = DispatchQueue(label: "JESSI.cloudflared")

    func start(gamePort: Int) {
        guard Self.isEnabled else { return }
        switch state {
        case .off, .failed: break
        default: return
        }
        generation += 1
        self.gamePort = gamePort
        let gen = generation
        let installed = FileManager.default.fileExists(atPath: Self.libraryURL.path)
        state = installed ? .starting : .downloading(0)
        downloadLibrary(installed: installed, generation: gen) { [weak self] error in
            guard let self, self.generation == gen else { return }
            if let error, !FileManager.default.fileExists(atPath: Self.libraryURL.path) {
                self.state = .failed("Couldn't download Cloudflare: \(error.localizedDescription)")
            } else {
                self.launch(gamePort: gamePort, generation: gen)
            }
        }
    }

    func stop() {
        generation += 1
        pollTimer?.invalidate()
        pollTimer = nil
        healthTimer?.invalidate()
        healthTimer = nil
        downloadObservation = nil
        worker?.send(["cmd": "stop"])
        worker = nil
        child?.terminate()
        child = nil
        stopInProcess?()
        stopInProcess = nil
        state = .off
    }

    private static let etagKey = "jessi.eaglercraft.cloudflare.etag.\(libraryName)"

    private func downloadLibrary(installed: Bool, generation gen: Int, completion: @escaping (Error?) -> Void) {
        var request = URLRequest(url: Self.downloadURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if installed, let etag = UserDefaults.standard.string(forKey: Self.etagKey) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let task = URLSession.shared.downloadTask(with: request) { location, response, error in
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            var failure: Error? = error
            if failure == nil, code == 304 {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            if failure == nil, let location, (200..<300).contains(code) {
                do {
                    guard TunnelingModel.machoHasCodeSignature(atPath: location.path) else {
                        throw EaglercraftError("The downloaded Cloudflare library isn't signed, so it can't be loaded.")
                    }
                    let fm = FileManager.default
                    let dest = Self.libraryURL
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? fm.removeItem(at: dest)
                    try fm.moveItem(at: location, to: dest)
                    UserDefaults.standard.set(http?.value(forHTTPHeaderField: "ETag"), forKey: Self.etagKey)
                } catch {
                    failure = error
                }
            } else if failure == nil {
                failure = EaglercraftError("HTTP \(code)")
            }
            DispatchQueue.main.async { completion(failure) }
        }
        downloadObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            DispatchQueue.main.async {
                guard let self, self.generation == gen, self.pollTimer == nil, progress.fractionCompleted > 0, progress.fractionCompleted < 1 else { return }
                switch self.state {
                case .downloading, .starting: self.state = .downloading(progress.fractionCompleted)
                default: break
                }
            }
        }
        task.resume()
    }

    private func launch(gamePort: Int, generation gen: Int) {
        guard let metricsPort = Self.freeLoopbackPort() else {
            state = .failed("Couldn't find a free local port for Cloudflare.")
            return
        }
        state = .starting
        let args = ["tunnel", "--no-autoupdate", "--url", "http://127.0.0.1:\(gamePort)", "--metrics", "127.0.0.1:\(metricsPort)"]
        if JessiWorkerHost.shouldUseWorkers {
            launchWorker(args: args, generation: gen)
        } else if JessiChildProcess.isSupported {
            launchChildProcess(args: args, generation: gen)
        } else {
            launchInProcess(args: args, generation: gen)
        }
        pollHostname(metricsPort: metricsPort, generation: gen)
    }

    private func launchWorker(args: [String], generation gen: Int) {
        let job: [String: Any] = ["type": "cloudflared", "library": Self.libraryURL.path, "args": args]
        worker = JessiWorkerHost.launchJob(job, needsJIT: true, onLog: { line in
            NSLog("[JESSI] [cloudflared] %@", line.trimmingCharacters(in: .whitespacesAndNewlines))
        }, onEvent: { [weak self] event in
            guard let self, self.generation == gen, event["event"] as? String == "error" else { return }
            self.state = .failed(event["message"] as? String ?? "Cloudflare failed to start.")
        }, onExit: { [weak self] code, problem in
            guard let self, self.generation == gen else { return }
            self.worker = nil
            self.pollTimer?.invalidate()
            self.pollTimer = nil
            if case .failed = self.state { return }
            self.state = .failed(problem ?? "Cloudflare stopped unexpectedly (\(code)).")
        })
    }

    private func launchChildProcess(args: [String], generation gen: Int) {
        do {
            child = try JessiChildProcess.spawn(["--cloudflared", Self.libraryURL.path] + args, logURL: Self.logURL) { [weak self] code in
                guard let self, self.generation == gen else { return }
                let reason = self.child?.lastLogLine().map { ": \($0)" } ?? ""
                self.child = nil
                self.pollTimer?.invalidate()
                self.pollTimer = nil
                self.healthTimer?.invalidate()
                self.healthTimer = nil
                self.state = .failed("Cloudflare stopped unexpectedly (\(code))\(reason)")
            }
        } catch {
            state = .failed("Couldn't start Cloudflare: \(error.localizedDescription)")
        }
    }

    private func launchInProcess(args: [String], generation gen: Int) {
        let path = Self.libraryURL.path
        let handle: UnsafeMutableRawPointer?
        if JITEnabler.isJITUsable {
            handle = jessi_dlopen_with_dyld_bypass(path, RTLD_NOW)
        } else if jessi_has_trollstore_privileges() || jessi_is_running_on_macos() {
            handle = dlopen(path, RTLD_NOW)
        } else {
            handle = nil
        }
        guard let handle,
              let runSymbol = dlsym(handle, "cloudflared_run"),
              let stopSymbol = dlsym(handle, "cloudflared_stop") else {
            let reason = dlerror().map { String(cString: $0) } ?? "JIT is not enabled"
            state = .failed("Couldn't load Cloudflare: \(reason)")
            return
        }
        let run = unsafeBitCast(runSymbol, to: RunFn.self)
        stopInProcess = unsafeBitCast(stopSymbol, to: StopFn.self)
        inProcessQueue.async { [weak self] in
            var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
            let result = run(Int32(args.count), &argv)
            argv.forEach { free($0) }
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.stopInProcess = nil
                self.pollTimer?.invalidate()
                self.pollTimer = nil
                self.state = .failed("Cloudflare stopped unexpectedly (\(result)).")
            }
        }
    }

    private func pollHostname(metricsPort: Int, generation gen: Int) {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.generation == gen else { return }
            Self.fetchHostname(metricsPort: metricsPort) { hostname in
                guard let hostname, self.generation == gen, self.state == .starting else { return }
                self.pollTimer?.invalidate()
                self.pollTimer = nil
                self.state = .online("https://\(hostname)")
                self.watchHealth(metricsPort: metricsPort, generation: gen)
            }
        }
    }

    private func watchHealth(metricsPort: Int, generation gen: Int) {
        failedHealthChecks = 0
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: Self.healthCheckInterval, repeats: true) { [weak self] _ in
            guard let self, self.generation == gen else { return }
            Self.isReady(metricsPort: metricsPort) { ready in
                guard self.generation == gen, case .online = self.state else { return }
                self.failedHealthChecks = ready ? 0 : self.failedHealthChecks + 1
                guard self.failedHealthChecks >= Self.failedHealthChecksBeforeRestart else { return }
                NSLog("[JESSI] [cloudflared] tunnel has been down for %d checks, restarting it", self.failedHealthChecks)
                let port = self.gamePort
                self.stop()
                self.start(gamePort: port)
            }
        }
    }

    private static func isReady(metricsPort: Int, completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(metricsPort)/ready")!)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let ready = (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { completion(ready) }
        }.resume()
    }

    private static func fetchHostname(metricsPort: Int, completion: @escaping (String?) -> Void) {
        let base = "http://127.0.0.1:\(metricsPort)"
        func get(_ path: String, _ done: @escaping (Int, Data?) -> Void) {
            var request = URLRequest(url: URL(string: base + path)!)
            request.timeoutInterval = 2
            URLSession.shared.dataTask(with: request) { data, response, _ in
                done((response as? HTTPURLResponse)?.statusCode ?? 0, data)
            }.resume()
        }
        get("/ready") { readyCode, _ in
            guard readyCode == 200 else { return DispatchQueue.main.async { completion(nil) } }
            get("/quicktunnel") { _, data in
                let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let hostname = (json?["hostname"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                DispatchQueue.main.async { completion(hostname) }
            }
        }
    }

    private static func freeLoopbackPort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        return bound ? Int(UInt16(bigEndian: addr.sin_port)) : nil
    }
}

struct EaglercraftError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
