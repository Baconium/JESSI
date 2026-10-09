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
        return clients(for: version).filter { !FileManager.default.fileExists(atPath: webDirectory.appendingPathComponent($0.file).path) }
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

        let dest = webDirectory.appendingPathComponent(client.file)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: patched, to: dest)
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
        install(0)
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

struct EaglercraftError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
