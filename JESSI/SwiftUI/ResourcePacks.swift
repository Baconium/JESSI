// server.properties only has one resource pack url option, so this
// pretty much just merges multiple resource packs into one if there
// are multiple packs installed

import Foundation
import Combine
import CryptoKit
import Network
import SwiftUI
import ZIPFoundation

enum ResourcePackHosting: String, CaseIterable, Identifiable, Codable {
    case local
    case relay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: return "This Device"
        case .relay: return "JESSI Relay"
        }
    }
}

enum ResourcePackPrompt: String, CaseIterable, Identifiable, Codable {
    case prompt
    case require

    var id: String { rawValue }

    var title: String {
        switch self {
        case .prompt: return "Prompt"
        case .require: return "Require"
        }
    }
}

private let resourcePackMaxBytes = 250 * 1024 * 1024
private let legacyResourcePackMaxBytes = 100 * 1024 * 1024

private let packOrderFilename = "jessipackorder.json"
private let mergedPackDirname = ".jessimerged"
private let mergedPackFilename = "jessi-merged-pack.zip"
private let sealedPackFilename = "jessi-sealed-pack.bin"


struct ResourcePackOrder {
    let directory: URL

    private var orderFile: URL { directory.appendingPathComponent(packOrderFilename) }

    static func isOrderFile(_ name: String) -> Bool {
        name == packOrderFilename
    }

    static func isPackFile(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".zip")
    }

    func resolved() -> [String] {
        let fm = FileManager.default
        let onDisk = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { Self.isPackFile($0) }
        guard !onDisk.isEmpty else { return [] }

        let known = Set(onDisk)
        var ordered = saved().filter { known.contains($0) }
        let placed = Set(ordered)
        let fresh = onDisk.filter { !placed.contains($0) }.sorted()
        ordered.insert(contentsOf: fresh, at: 0)
        return ordered
    }

    func saved() -> [String] {
        guard let data = try? Data(contentsOf: orderFile),
              let names = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return names
    }

    func write(_ names: [String]) {
        guard let data = try? JSONEncoder().encode(names) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: orderFile, options: [.atomic])
    }
}

struct MergedPack {
    let url: URL
    let sha1: String
    let byteCount: Int
    let packCount: Int
}

enum ResourcePackMerger {
    static func merge(packs: [String], in directory: URL, fallbackFormat: Int) throws -> MergedPack {
        guard !packs.isEmpty else {
            throw modserror("no resource packs to merge")
        }

        let fm = FileManager.default
        let outputDir = directory.appendingPathComponent(mergedPackDirname, isDirectory: true)
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let output = outputDir.appendingPathComponent(mergedPackFilename)
        if fm.fileExists(atPath: output.path) {
            try fm.removeItem(at: output)
        }

        let archive = try Archive(url: output, accessMode: .create)

        var claimed = Set<String>()
        var iconData: Data?
        var manifests: [PackManifestInfo] = []

        for name in packs {
            let packURL = directory.appendingPathComponent(name)
            guard let source = try? Archive(url: packURL, accessMode: .read) else {
                modlogger.log("skipping \(name): not a readable zip")
                continue
            }

            if let info = manifestInfo(in: source) { manifests.append(info) }

            for entry in source {
                guard entry.type == .file else { continue }
                guard let path = normalizedPackPath(entry.path) else { continue }

                if path == "pack.mcmeta" { continue }
                if path == "pack.png" {
                    if iconData == nil { iconData = try? data(for: entry, in: source) }
                    continue
                }

                if claimed.contains(path) { continue }
                claimed.insert(path)

                let payload = try data(for: entry, in: source)
                try archive.addEntry(
                    with: path,
                    type: .file,
                    uncompressedSize: Int64(payload.count),
                    compressionMethod: .deflate
                ) { position, size in
                    let start = Int(position)
                    let end = min(start + size, payload.count)
                    guard start < end else { return Data() }
                    return payload.subdata(in: start..<end)
                }
            }
        }

        guard !claimed.isEmpty else {
            throw modserror("the resource packs contained no files")
        }

        let manifest = try manifestData(from: manifests, fallbackFormat: fallbackFormat, packCount: packs.count)
        try archive.addEntry(
            with: "pack.mcmeta",
            type: .file,
            uncompressedSize: Int64(manifest.count),
            compressionMethod: .deflate
        ) { position, size in
            let start = Int(position)
            let end = min(start + size, manifest.count)
            guard start < end else { return Data() }
            return manifest.subdata(in: start..<end)
        }

        if let iconData, !iconData.isEmpty {
            try archive.addEntry(
                with: "pack.png",
                type: .file,
                uncompressedSize: Int64(iconData.count),
                compressionMethod: .deflate
            ) { position, size in
                let start = Int(position)
                let end = min(start + size, iconData.count)
                guard start < end else { return Data() }
                return iconData.subdata(in: start..<end)
            }
        }

        let merged = try Data(contentsOf: output, options: .mappedIfSafe)
        let digest = Insecure.SHA1.hash(data: merged)
        let sha1 = digest.map { String(format: "%02x", $0) }.joined()

        modlogger.log("merged \(packs.count) pack(s) into \(claimed.count) files (\(merged.count) bytes)")
        return MergedPack(url: output, sha1: sha1, byteCount: merged.count, packCount: packs.count)
    }

    struct PackManifestInfo {
        var packFormat: Int?
        var minFormat: Int?
        var maxFormat: Int?
    }

    static func manifestInfo(in archive: Archive) -> PackManifestInfo? {
        guard let entry = archive["pack.mcmeta"],
              let raw = try? data(for: entry, in: archive),
              let pack = jsonObject(raw)?["pack"] as? [String: Any] else {
            return nil
        }

        func major(_ any: Any?) -> Int? {
            if let value = any as? Int { return value }
            if let pair = any as? [Any], let first = pair.first as? Int { return first }
            return nil
        }

        var info = PackManifestInfo()
        info.packFormat = pack["pack_format"] as? Int
        info.minFormat = major(pack["min_format"])
        info.maxFormat = major(pack["max_format"])

        if let supported = pack["supported_formats"] as? [Int], supported.count >= 2 {
            info.minFormat = info.minFormat ?? supported.first
            info.maxFormat = info.maxFormat ?? supported.last
        } else if let supported = pack["supported_formats"] as? [String: Any] {
            info.minFormat = info.minFormat ?? major(supported["min_inclusive"])
            info.maxFormat = info.maxFormat ?? major(supported["max_inclusive"])
        }

        return info
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        var payload = data
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        if payload.count >= 3, Array(payload.prefix(3)) == bom {
            payload = payload.dropFirst(3)
        }
        return (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
    }

    private static func manifestData(from manifests: [PackManifestInfo],
                                     fallbackFormat: Int, packCount: Int) throws -> Data {
        let description = packCount == 1
            ? "Served by JESSI"
            : "\(packCount) packs merged by JESSI"

        let declared = manifests.compactMap { $0.packFormat ?? $0.minFormat }
        let packFormat = declared.first ?? fallbackFormat
        let lower = manifests.compactMap { $0.minFormat ?? $0.packFormat }.max()
        let upper = manifests.compactMap { $0.maxFormat }.min()

        var pack: [String: Any] = [
            "pack_format": packFormat,
            "description": description
        ]
        if let lower, let upper, lower <= upper {
            pack["supported_formats"] = [lower, upper]
            pack["min_format"] = lower
            pack["max_format"] = upper
        }

        return try JSONSerialization.data(withJSONObject: ["pack": pack], options: [.prettyPrinted])
    }

    static func data(for entry: Entry, in archive: Archive) throws -> Data {
        var out = Data()
        _ = try archive.extract(entry) { out.append($0) }
        return out
    }

    private static func normalizedPackPath(_ path: String) -> String? {
        var raw = path.replacingOccurrences(of: "\\", with: "/")
        while raw.hasPrefix("/") { raw.removeFirst() }

        var cleaned: [String] = []
        for component in raw.split(separator: "/").map(String.init) {
            if component.isEmpty || component == "." { continue }
            if component == ".." { return nil }
            cleaned.append(component)
        }
        guard !cleaned.isEmpty else { return nil }
        return cleaned.joined(separator: "/")
    }
}

final class ResourcePackHTTPServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "dev.baconium.jessi.resourcepack.http")
    private var payload: Data = Data()
    private var path: String = "/pack.zip"

    private(set) var port: UInt16?

    func start(serving file: URL, at path: String, preferredPort: UInt16) throws {
        stop()

        self.payload = try Data(contentsOf: file, options: .mappedIfSafe)
        self.path = path.hasPrefix("/") ? path : "/\(path)"

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        guard let nwPort = NWEndpoint.Port(rawValue: preferredPort) else {
            throw modserror("invalid resource pack port")
        }

        let listener = try NWListener(using: parameters, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)

        self.listener = listener
        self.port = preferredPort
        modlogger.log("serving \(self.path) on port \(preferredPort) (\(payload.count) bytes)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        payload = Data()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, !data.isEmpty else {
                connection.cancel()
                return
            }

            let request = String(decoding: data, as: UTF8.self)
            guard let line = request.split(separator: "\r\n", maxSplits: 1).first else {
                connection.cancel()
                return
            }

            let parts = line.split(separator: " ")
            let method = parts.first.map(String.init) ?? ""
            let target = parts.count > 1 ? String(parts[1]) : ""

            guard method == "GET" || method == "HEAD" else {
                self.respondNotFound(on: connection)
                return
            }
            guard target == self.path else {
                self.respondNotFound(on: connection)
                return
            }

            self.respondWithPack(on: connection, includeBody: method == "GET")
        }
    }

    private func respondWithPack(on connection: NWConnection, includeBody: Bool) {
        let header = """
        HTTP/1.1 200 OK\r
        Content-Type: application/zip\r
        Content-Length: \(payload.count)\r
        Connection: close\r
        \r

        """
        var response = Data(header.utf8)
        if includeBody {
            response.append(payload)
        }
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func respondNotFound(on connection: NWConnection) {
        let response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

enum ResourcePackRelay {
    static let base = "https://baconium.dev/jessi/resourcepacks"
    static let authHeader = "X-JR-Auth"
    static let authToken = "c012e0abe13901f342eeb99cfc69bf4b"
    static let magic = "JRP1"
    static let frameSize = 1 << 20
    static let pollInterval: UInt64 = 20

    private struct RegisterResponse: Decodable { let id: String }
    private struct WaitResponse: Decodable { let deliver: Bool }

    private static func authed(_ url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(authToken, forHTTPHeaderField: authHeader)
        request.setValue("JESSI :3", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func register(sha1: String, plaintextLength: Int, frameSize: Int) async throws -> String {
        guard let url = URL(string: "\(base)/session/") else {
            throw modserror("invalid relay URL")
        }

        var request = authed(url, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "sha1": sha1,
            "plaintextLength": plaintextLength,
            "frameSize": frameSize
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, "register the pack with the relay")
        return try JSONDecoder().decode(RegisterResponse.self, from: data).id
    }

    static func waitForDemand(id: String) async throws -> Bool {
        guard let url = URL(string: "\(base)/wait.php?id=\(id)") else {
            throw modserror("invalid relay URL")
        }

        var request = authed(url, method: "GET")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            throw RelayError.sessionGone
        }
        try check(response, "ask the relay for pending downloads")
        return try JSONDecoder().decode(WaitResponse.self, from: data).deliver
    }

    enum RelayError: Error, LocalizedError {
        case sessionGone

        var errorDescription: String? {
            "The relay no longer has this pack. Apply it again to re-publish."
        }
    }

    private struct DeliverResponse: Decodable { let status: String? }

    static func deliver(id: String, sealedFile: URL) async throws {
        guard let url = URL(string: "\(base)/deliver.php?id=\(id)") else {
            throw modserror("invalid relay URL")
        }

        var request = authed(url, method: "POST")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: sealedFile)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            throw RelayError.sessionGone
        }
        try check(response, "send the pack to the relay")

        let status = (try? JSONDecoder().decode(DeliverResponse.self, from: data))?.status
        if status == "expired" {
            throw RelayError.sessionGone
        }
    }

    static func packURL(id: String, keyHex: String) -> URL? {
        URL(string: "\(base)/pack.php?id=\(id)&key=\(keyHex)")
    }

    private static func check(_ response: URLResponse, _ what: String) throws {
        guard let http = response as? HTTPURLResponse,
              !(200...299).contains(http.statusCode) else { return }
        if http.statusCode == 403 {
            throw modserror("The relay rejected this app's credentials. It may need updating.")
        }
        throw modserror("Couldn't \(what) (HTTP \(http.statusCode)).")
    }

    static func seal(_ file: URL, to output: URL, using key: SymmetricKey) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: output.path) {
            try fm.removeItem(at: output)
        }
        guard fm.createFile(atPath: output.path, contents: nil) else {
            throw modserror("could not stage the encrypted pack")
        }

        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        let out = try FileHandle(forWritingTo: output)
        defer { try? out.close() }

        let plaintextLength = (try fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?
            .uint64Value ?? 0

        var header = Data(magic.utf8)
        withUnsafeBytes(of: UInt32(frameSize).bigEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: plaintextLength.bigEndian) { header.append(contentsOf: $0) }
        try out.write(contentsOf: header)

        var index: UInt64 = 0
        while true {
            let chunk = try input.read(upToCount: frameSize) ?? Data()
            if chunk.isEmpty { break }

            let aad = withUnsafeBytes(of: index.bigEndian) { Data($0) }
            let sealed = try AES.GCM.seal(chunk, using: key, authenticating: aad)
            guard let combined = sealed.combined else {
                throw modserror("could not encrypt the resource pack")
            }
            try out.write(contentsOf: combined)

            index += 1
            if chunk.count < frameSize { break }
        }

        modlogger.log("sealed \(plaintextLength) bytes into \(index) frame(s)")
    }
}

@MainActor
final class RelaySession: ObservableObject {
    static let shared = RelaySession()

    struct Pack {
        let id: String
        let sealedFile: URL
        let serverName: String
    }

    @Published private(set) var isPolling = false

    private var pack: Pack?
    private var pollTask: Task<Void, Never>?
    private var deliverTask: Task<Void, Never>?
    private var serverRunning = false

    private init() {}

    func adopt(_ pack: Pack) {
        self.pack = pack
        deliver()
        restartPollIfNeeded()
    }

    @discardableResult
    func restoreIfPossible(from serverRoot: URL) -> Bool {
        if pack?.serverName == serverRoot.lastPathComponent { return true }
        restore(from: serverRoot)
        return pack != nil
    }

    func sessionIsAlive() async -> Bool {
        guard let pack else { return false }
        do {
            _ = try await ResourcePackRelay.waitForDemand(id: pack.id)
            return true
        } catch {
            return false
        }
    }

    private func deliver() {
        guard let pack, deliverTask == nil else { return }
        deliverTask = Task { [weak self] in
            do {
                modlogger.log("sending the resource pack to the relay")
                try await ResourcePackRelay.deliver(id: pack.id, sealedFile: pack.sealedFile)
                modlogger.log("the relay is holding the pack")
            } catch {
                modlogger.log("could not send the pack to the relay: \(error.localizedDescription)")
            }
            self?.deliverTask = nil
        }
    }

    func forget() {
        stopPolling()
        deliverTask?.cancel()
        deliverTask = nil
        pack = nil
    }

    func setServerRunning(_ running: Bool, serverRoot: URL?) {
        serverRunning = running

        guard running else {
            stopPolling()
            return
        }

        if let serverRoot, pack?.serverName != serverRoot.lastPathComponent {
            restore(from: serverRoot)
        }
        restartPollIfNeeded()
    }

    private func stopPolling() {
        guard pollTask != nil else { return }
        pollTask?.cancel()
        pollTask = nil
        isPolling = false
        modlogger.log("relay poll stopped")
    }

    static func unescapeJavaProperty(_ raw: String) -> String {
        guard raw.contains("\\") else { return raw }

        var out = ""
        var iterator = raw.makeIterator()
        while let character = iterator.next() {
            guard character == "\\", let escaped = iterator.next() else {
                out.append(character)
                continue
            }
            switch escaped {
            case "n": out.append("\n")
            case "r": out.append("\r")
            case "t": out.append("\t")
            default: out.append(escaped)
            }
        }
        return out
    }

    private func restore(from serverRoot: URL) {
        pack = nil

        let propsFile = serverRoot.appendingPathComponent("server.properties")
        guard let text = try? String(contentsOf: propsFile, encoding: .utf8) else { return }

        let prefix = "resource-pack="
        guard let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix(prefix) }) else { return }
        let raw = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        let value = Self.unescapeJavaProperty(raw)

        guard value.hasPrefix(ResourcePackRelay.base),
              let components = URLComponents(string: value),
              let id = components.queryItems?.first(where: { $0.name == "id" })?.value,
              id.count == 32 else { return }

        let sealed = serverRoot
            .appendingPathComponent(ContentType.resourcepack.dirname)
            .appendingPathComponent(mergedPackDirname)
            .appendingPathComponent(sealedPackFilename)
        guard FileManager.default.fileExists(atPath: sealed.path) else {
            modlogger.log("relay session \(id) can't resume: the sealed pack is gone. Apply it again.")
            return
        }

        pack = Pack(id: id, sealedFile: sealed, serverName: serverRoot.lastPathComponent)
        modlogger.log("resumed relay session \(id)")
    }

    private func restartPollIfNeeded() {
        guard serverRunning, pack != nil, pollTask == nil else { return }
        isPolling = true
        modlogger.log("relay poll started")
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    private func pollLoop() async {
        var backoff: UInt64 = ResourcePackRelay.pollInterval

        while !Task.isCancelled, serverRunning, let pack {
            do {
                let wanted = try await ResourcePackRelay.waitForDemand(id: pack.id)
                backoff = ResourcePackRelay.pollInterval

                if wanted {
                    modlogger.enclosedlog("a player is waiting for the resource pack; sending it")
                    modlogger.flushdivider()
                    deliver()
                }
            } catch ResourcePackRelay.RelayError.sessionGone {
                modlogger.enclosedlog("the relay dropped this pack; players will join without it until it is applied again")
                modlogger.flushdivider()
                break
            } catch {
                if Task.isCancelled { break }
                modlogger.log("relay poll error: \(error.localizedDescription)")
                backoff = min(backoff * 2, 120)
            }
            try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
        }
        isPolling = false
    }
}

@MainActor
final class ResourcePackManager: ObservableObject {
    @Published private(set) var packs: [String] = []
    @Published private(set) var isPublishing = false
    @Published private(set) var status: String?
    @Published private(set) var statusIsError = false

    @Published var hosting: ResourcePackHosting {
        didSet {
            guard hosting != oldValue else { return }
            defaults.set(hosting.rawValue, forKey: hostingKey)
        }
    }

    @Published var prompt: ResourcePackPrompt {
        didSet {
            guard prompt != oldValue else { return }
            defaults.set(prompt.rawValue, forKey: promptKey)
            applyPromptMode()
        }
    }

    static let portKey = "jessi.resourcepack.port"

    private static var instances: [String: ResourcePackManager] = [:]

    static func shared(for properties: ServerPropertiesManager) -> ResourcePackManager {
        let name = properties.serverRoot.lastPathComponent
        if let existing = instances[name] {
            DispatchQueue.main.async { existing.reload() }
            return existing
        }
        let created = ResourcePackManager(properties: properties)
        instances[name] = created
        return created
    }

    private let properties: ServerPropertiesManager
    private let defaults = UserDefaults.standard
    private let server = ResourcePackHTTPServer()

    private var serverName: String { properties.serverRoot.lastPathComponent }
    private var fingerprintKey: String { "jessi.resourcepack.fingerprint.\(serverName)" }
    private var mergedSHA1Key: String { "jessi.resourcepack.mergedsha1.\(serverName)" }
    private var mergedSizeKey: String { "jessi.resourcepack.mergedsize.\(serverName)" }
    private var hostingKey: String { "jessi.resourcepack.hosting.\(serverName)" }
    private var promptKey: String { "jessi.resourcepack.prompt.\(serverName)" }

    private var directory: URL {
        properties.serverRoot.appendingPathComponent(ContentType.resourcepack.dirname, isDirectory: true)
    }

    private var order: ResourcePackOrder { ResourcePackOrder(directory: directory) }

    var port: UInt16 {
        let stored = defaults.integer(forKey: Self.portKey)
        guard stored > 0, stored <= 65535 else { return 25566 }
        return UInt16(stored)
    }

    var needsHosting: Bool {
        packs.count > 1 || (packs.count == 1 && directLink(for: packs[0]) == nil)
    }

    var hasPacks: Bool { !packs.isEmpty }

    init(properties: ServerPropertiesManager) {
        self.properties = properties

        let name = properties.serverRoot.lastPathComponent
        let store = UserDefaults.standard
        self.hosting = ResourcePackHosting(
            rawValue: store.string(forKey: "jessi.resourcepack.hosting.\(name)") ?? ""
        ) ?? .local
        self.prompt = ResourcePackPrompt(
            rawValue: store.string(forKey: "jessi.resourcepack.prompt.\(name)") ?? ""
        ) ?? .prompt

        reload()
    }

    func reload() {
        let resolved = order.resolved()
        guard resolved != packs else { return }
        packs = resolved
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var updated = packs
        updated.move(fromOffsets: source, toOffset: destination)
        packs = updated
        order.write(updated)
    }

    func clear() {
        server.stop()
        RelaySession.shared.forget()
        properties.updateProperty(key: "resource-pack", value: "")
        properties.updateProperty(key: "resource-pack-sha1", value: "")
        properties.updateProperty(key: "require-resource-pack", value: "false")
        status = "Cleared"
        statusIsError = false
    }

    func prepareForLaunch() async {
        reload()
        guard hasPacks else {
            clear()
            return
        }
        await publish()
    }

    private func packFingerprint() -> String {
        let fm = FileManager.default
        return packs.map { name -> String in
            let url = directory.appendingPathComponent(name)
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
            let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            return "\(name):\(size):\(Int(modified))"
        }.joined(separator: "|")
    }

    private func reusableMergedPack() -> MergedPack? {
        guard packFingerprint() == defaults.string(forKey: fingerprintKey),
              let sha1 = defaults.string(forKey: mergedSHA1Key) else { return nil }

        let size = defaults.integer(forKey: mergedSizeKey)
        guard size > 0 else { return nil }

        let merged = directory
            .appendingPathComponent(mergedPackDirname)
            .appendingPathComponent(mergedPackFilename)
        let attrs = try? FileManager.default.attributesOfItem(atPath: merged.path)
        guard let onDisk = (attrs?[.size] as? NSNumber)?.intValue, onDisk == size else { return nil }

        return MergedPack(url: merged, sha1: sha1, byteCount: size, packCount: packs.count)
    }

    private func rememberMergedPack(_ merged: MergedPack) {
        defaults.set(packFingerprint(), forKey: fingerprintKey)
        defaults.set(merged.sha1, forKey: mergedSHA1Key)
        defaults.set(merged.byteCount, forKey: mergedSizeKey)
    }

    func publish() async {
        guard !isPublishing else { return }
        isPublishing = true
        status = nil
        statusIsError = false
        defer { isPublishing = false }

        reload()
        guard !packs.isEmpty else {
            clear()
            return
        }

        do {
            let url: URL
            let sha1: String

            if packs.count == 1, let link = directLink(for: packs[0]) {
                url = link.url
                sha1 = link.sha1
                server.stop()
                modlogger.log("using the original download URL for \(packs[0])")
            } else {
                let merged: MergedPack
                if let reusable = reusableMergedPack() {
                    modlogger.log("resource packs unchanged; reusing the merged pack")
                    merged = reusable
                } else {
                    merged = try ResourcePackMerger.merge(
                        packs: packs,
                        in: directory,
                        fallbackFormat: 34
                    )
                    rememberMergedPack(merged)
                }
                try checkSize(merged)
                url = try await serve(merged)
                sha1 = merged.sha1
            }

            properties.updateProperty(key: "resource-pack", value: url.absoluteString)
            properties.updateProperty(key: "resource-pack-sha1", value: sha1)
            properties.updateProperty(key: "resource-pack-id", value: UUID().uuidString.lowercased())
            applyPromptMode()

            let summary = "Serving \(packs.count) pack\(packs.count == 1 ? "" : "s")"
            if url.host?.contains("forgecdn") == true || url.host?.contains("modrinth") == true {
                status = "\(summary) from its original download link"
            } else if hosting == .relay {
                status = "\(summary) through the JESSI relay, which holds it while the server runs."
            } else if hosting == .local {
                status = "\(summary) from this device. Port \(port) has to be reachable from the internet, the same way \(properties.getProperty(key: "server-port").isEmpty ? "25565" : properties.getProperty(key: "server-port")) is."
            }
            statusIsError = false
            modlogger.log("resource-pack set to \(url.absoluteString)")
        } catch {
            status = error.localizedDescription
            statusIsError = true
            modlogger.log("publish failed: \(error.localizedDescription)")
        }
        modlogger.divider()
    }

    private func serve(_ merged: MergedPack) async throws -> URL {
        switch hosting {
        case .relay:
            if let existing = await reusableRelayURL() {
                modlogger.log("the relay still has this pack; keeping the existing session")
                return existing
            }
            return try await publishToRelay(merged)
        case .local:
            let path = "/\(merged.sha1).zip"
            try server.start(serving: merged.url, at: path, preferredPort: port)
            guard let host = await publicAddress() else {
                throw modserror("could not work out this device's public address. Switch hosting to JESSI Relay, or check your connection.")
            }
            guard let url = URL(string: "http://\(host):\(port)\(path)") else {
                throw modserror("could not build the resource pack URL")
            }
            return url
        }
    }

    private func publishToRelay(_ merged: MergedPack) async throws -> URL {
        let key = SymmetricKey(size: .bits256)
        let sealed = merged.url.deletingLastPathComponent()
            .appendingPathComponent(sealedPackFilename)

        try ResourcePackRelay.seal(merged.url, to: sealed, using: key)

        let id = try await ResourcePackRelay.register(
            sha1: merged.sha1,
            plaintextLength: merged.byteCount,
            frameSize: ResourcePackRelay.frameSize
        )

        try await ResourcePackRelay.deliver(id: id, sealedFile: sealed)

        let keyHex = key.withUnsafeBytes { bytes in
            bytes.map { String(format: "%02x", $0) }.joined()
        }
        guard let url = ResourcePackRelay.packURL(id: id, keyHex: keyHex) else {
            throw modserror("the relay returned an unusable session id")
        }

        RelaySession.shared.adopt(RelaySession.Pack(
            id: id,
            sealedFile: sealed,
            serverName: properties.serverRoot.lastPathComponent
        ))
        modlogger.log("relay session \(id) registered and holding the pack")
        return url
    }

    private func reusableRelayURL() async -> URL? {
        let value = RelaySession.unescapeJavaProperty(properties.getProperty(key: "resource-pack"))
        guard value.hasPrefix(ResourcePackRelay.base),
              let url = URL(string: value),
              RelaySession.shared.restoreIfPossible(from: properties.serverRoot),
              await RelaySession.shared.sessionIsAlive() else {
            return nil
        }
        return url
    }

    private func checkSize(_ merged: MergedPack) throws {
        let limit = legacyClient() ? legacyResourcePackMaxBytes : resourcePackMaxBytes
        guard merged.byteCount > limit else { return }
        let mib = Double(merged.byteCount) / 1_048_576
        let limitMiB = limit / 1_048_576
        throw modserror(String(
            format: "the merged pack is %.1f MiB, over the %d MiB the client accepts. Remove a pack and try again.",
            mib, limitMiB
        ))
    }

    private func legacyClient() -> Bool {
        guard let version = minecraftVersion() else { return false }
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2, parts[0] == 1 else { return false }
        return parts[1] < 18
    }

    private func minecraftVersion() -> String? {
        let config = properties.serverRoot.appendingPathComponent("jessiserverconfig.json")
        guard let data = try? Data(contentsOf: config),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return json["minecraftVersion"]
    }

    private func applyPromptMode() {
        guard hasPacks else { return }
        properties.updateProperty(
            key: "require-resource-pack",
            value: prompt == .require ? "true" : "false"
        )
    }

    private func directLink(for filename: String) -> (url: URL, sha1: String)? {
        let registry = properties.serverRoot.appendingPathComponent("jessimods.json")
        guard let data = try? Data(contentsOf: registry),
              let records = try? JSONDecoder().decode([String: InstalledModRecord].self, from: data) else {
            return nil
        }

        for record in records.values where record.filename == filename {
            guard record.contentType == .resourcepack,
                  let source = record.sourceURL,
                  let sha1 = record.sha1,
                  !sha1.isEmpty,
                  let url = URL(string: source) else { continue }
            return (url, sha1)
        }
        return nil
    }

    private func publicAddress() async -> String? {
        guard let url = URL(string: "https://api.ipify.org?format=json") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("JESSI :3", forHTTPHeaderField: "User-Agent")

        struct IPResponse: Decodable { let ip: String }
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let decoded = try? JSONDecoder().decode(IPResponse.self, from: data),
              !decoded.ip.isEmpty else {
            return nil
        }
        return decoded.ip
    }
}
