//
//  ModsView.swift
//  JESSI
//
//  Created by roooot on 01.02.26.
//

import Foundation
import Combine
import SwiftUI
import ZIPFoundation

extension Int {
    var compact: String {
        let num = Double(self)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0

        switch num {
        case 1_000_000_000...:
            return (formatter.string(from: NSNumber(value: num / 1_000_000_000)) ?? "0") + "B"
        case 1_000_000...:
            return (formatter.string(from: NSNumber(value: num / 1_000_000)) ?? "0") + "M"
        case 1_000...:
            return (formatter.string(from: NSNumber(value: num / 1_000)) ?? "0") + "K"
        default:
            return "\(self)"
        }
    }
}

struct ModrinthResponse: Decodable {
    let hits: [ModrinthMod]
}

enum ModProvider: String, CaseIterable, Identifiable {
    case modrinth
    case curseForge = "curseforge"

    var id: String { rawValue }
}

enum ContentType: String, CaseIterable, Codable, Identifiable {
    case mod
    case modpack
    case resourcepack
    case datapack

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mod: return "Mods"
        case .modpack: return "Modpacks"
        case .resourcepack: return "Resourcepacks"
        case .datapack: return "Datapacks"
        }
    }

    var dirname: String {
        switch self {
        case .mod: return "mods"
        case .modpack: return "modpacks"
        case .resourcepack: return "resourcepacks"
        case .datapack: return "datapacks"
        }
    }

    var modrinthprojecttype: String {
        rawValue
    }

    var curseforgeclassid: String {
        switch self {
        case .mod: return "6"
        case .modpack: return "4471"
        case .resourcepack: return "12"
        case .datapack: return "6945"
        }
    }

    static func fromcurseforgeclassid(_ id: Int?) -> ContentType {
        switch id {
        case 4471: return .modpack
        case 12: return .resourcepack
        case 6945: return .datapack
        default: return .mod
        }
    }

}

struct ModSearchItem: Identifiable {
    let id: String
    let provider: ModProvider
    let providerID: String
    let contentType: ContentType
    let title: String
    let description: String
    let downloads: Int
    let iconURL: String?
    let author: String?
    let follows: Int
}

struct ModrinthMod: Decodable, Identifiable {
    let id: String
    let slug: String
    let title: String
    let description: String
    let downloads: Int
    let iconURL: String?
    let author: String?
    let projectType: String
    let follows: Int

    enum CodingKeys: String, CodingKey {
        case id = "project_id"
        case slug
        case title
        case description
        case downloads
        case iconURL = "icon_url"
        case author
        case projectType = "project_type"
        case follows
    }
}

struct ModrinthVersion: Decodable {
    let id: String
    let game_versions: [String]
    let loaders: [String]
    let files: [ModrinthFile]
    let dependencies: [ModrinthDependency]?
}

struct ModrinthDependency: Decodable {
    let project_id: String?
    let version_id: String?
    let file_name: String?
    let dependency_type: String
}

enum DepTarget {
    case modrinth(projectID: String, versionID: String?)
    case curseForge(modid: Int, name: String)

    var dedupKey: String {
        switch self {
        case .modrinth(let p, let v):
            return "modrinth:\(p):\(v ?? "")"
        case .curseForge(let id, _):
            return "cf:\(id)"
        }
    }
}

struct ModrinthFile: Decodable {
    let id: String
    let url: String
    let filename: String
    let primary: Bool
    let hashes: ModrinthFileHashes?
}

struct ModrinthFileHashes: Decodable {
    let sha1: String?
}

nonisolated let curseForgeBaseURL = "https://api.curseforge.com/v1"
nonisolated let curseForgeGameIDMinecraft = 432
nonisolated private let curseForgeRequiredRelation = 3

nonisolated struct CurseForgeSearchResponse: Decodable {
    let data: [CurseForgeMod]
}

nonisolated struct CurseForgeMod: Decodable {
    let id: Int
    let name: String
    let summary: String
    let downloadCount: Double
    let thumbsUpCount: Int?
    let classId: Int?
    let classInfo: CurseForgeClassInfo?
    let logo: CurseForgeLogo?
    let authors: [CurseForgeAuthor]?
    let latestFiles: [CurseForgeFile]?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case summary
        case downloadCount
        case thumbsUpCount
        case classId
        case classInfo = "class"
        case logo
        case authors
        case latestFiles
    }
}

nonisolated struct CurseForgeClassInfo: Decodable {
    let id: Int
}

nonisolated struct CurseForgeLogo: Decodable {
    let url: String?
}

nonisolated struct CurseForgeAuthor: Decodable {
    let name: String
}

nonisolated struct CurseForgeFilesResponse: Decodable {
    let data: [CurseForgeFile]
}

nonisolated struct CurseForgeFileResponse: Decodable {
    let data: CurseForgeFile
}

nonisolated struct CurseForgeFile: Decodable {
    let id: Int
    let fileName: String
    let downloadURL: String?
    let gameVersions: [String]?
    let dependencies: [CurseForgeFileDependency]?
    let hashes: [CurseForgeFileHash]?

    enum CodingKeys: String, CodingKey {
        case id
        case fileName
        case downloadURL = "downloadUrl"
        case gameVersions
        case dependencies
        case hashes
    }
}

nonisolated struct CurseForgeFileHash: Decodable {
    let value: String
    let algo: Int

    static let sha1 = 1
}

nonisolated struct ModrinthFileLookup: Decodable {
    let project_id: String
}

nonisolated struct ModrinthProjectEnvironment: Decodable {
    let id: String
    let client_side: String
    let server_side: String

    var runsOnServer: Bool { server_side.lowercased() != "unsupported" }
}

nonisolated struct CurseForgeFileDependency: Decodable {
    let modId: Int
    let relationType: Int
}

nonisolated struct CurseForgeDownloadURLResponse: Decodable {
    let data: String?
}

nonisolated private struct CurseForgeModpackManifest: Decodable {
    let files: [CurseForgeModpackManifestFile]
    let overrides: String?
}

nonisolated private struct CurseForgeModpackManifestFile: Decodable {
    let projectID: Int
    let fileID: Int
    let required: Bool?
}

nonisolated func modserror(_ message: String, code: Int = 0) -> NSError {
    NSError(domain: "dev.baconium.jessi.mods", code: code, userInfo: [NSLocalizedDescriptionKey: message])
}

nonisolated func curseForgeRequest(url: URL, key: String) -> URLRequest {
    var request = URLRequest(url: url)
    request.setValue(key, forHTTPHeaderField: "x-api-key")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("JESSI :3", forHTTPHeaderField: "User-Agent")
    return request
}

nonisolated func throwIfCurseForgeError(response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) else { return }
    switch http.statusCode {
    case 401, 403:
        throw modserror("CurseForge rejected the API key (HTTP \(http.statusCode)). Try adding your own key in Settings.", code: http.statusCode)
    case 429:
        throw modserror("CurseForge rate limit reached, give it a moment and try again.", code: 429)
    default:
        throw modserror("CurseForge returned HTTP \(http.statusCode).", code: http.statusCode)
    }
}

nonisolated func parseCurseForgeDownloadPath(from data: Data) -> String? {
    if let decoded = try? JSONDecoder().decode(CurseForgeDownloadURLResponse.self, from: data),
       let value = decoded.data?.trimmingCharacters(in: .whitespacesAndNewlines),
       !value.isEmpty {
        return value
    }

    if let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
        let unquoted = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if unquoted.hasPrefix("http") {
            return unquoted
        }
    }

    return nil
}

nonisolated func fallbackCurseForgeFileURL(fileID: Int, fileName: String) -> URL? {
    let bucket = fileID / 1000
    let tail = fileID % 1000
    let encodedName = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName

    let candidates = [
        "https://mediafilez.forgecdn.net/files/\(bucket)/\(tail)/\(encodedName)",
        "https://edge.forgecdn.net/files/\(bucket)/\(tail)/\(encodedName)"
    ]

    for raw in candidates {
        if let url = URL(string: raw) {
            return url
        }
    }
    return nil
}

nonisolated func curseForgeFetch(_ url: URL) async throws -> (Data, URLResponse) {
    var key = try await CurseForgeKeyStore.shared.key()
    var (data, response) = try await URLSession.shared.data(for: curseForgeRequest(url: url, key: key))

    if let http = response as? HTTPURLResponse,
       http.statusCode == 401 || http.statusCode == 403,
       await CurseForgeKeyStore.shared.userkey == nil {
        await CurseForgeKeyStore.shared.invalidateremotekey()
        key = try await CurseForgeKeyStore.shared.key()
        (data, response) = try await URLSession.shared.data(for: curseForgeRequest(url: url, key: key))
    }

    return (data, response)
}

nonisolated func curseForgeGET(_ url: URL) async throws -> Data {
    let (data, response) = try await curseForgeFetch(url)
    try throwIfCurseForgeError(response: response)
    return data
}

nonisolated func curseForgeFileName(projectID: Int, fileID: Int) async throws -> String? {
    let endpoint = URL(string: "\(curseForgeBaseURL)/mods/\(projectID)/files/\(fileID)")!
    let data = try await curseForgeGET(endpoint)
    return try? JSONDecoder().decode(CurseForgeFileResponse.self, from: data).data.fileName
}

nonisolated func resolveCurseForgeDownloadURL(projectID: Int, fileID: Int, fileName: String?, inlineURL: String?) async throws -> URL? {
    if let inline = inlineURL?.trimmingCharacters(in: .whitespacesAndNewlines),
       !inline.isEmpty,
       let url = URL(string: inline) {
        return url
    }

    let endpoint = URL(string: "\(curseForgeBaseURL)/mods/\(projectID)/files/\(fileID)/download-url")!
    let (data, response) = try await curseForgeFetch(endpoint)
    if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
       let parsed = parseCurseForgeDownloadPath(from: data),
       let url = URL(string: parsed) {
        return url
    }

    var resolvedName = fileName
    if resolvedName == nil {
        resolvedName = try? await curseForgeFileName(projectID: projectID, fileID: fileID)
    }
    guard let resolvedName else { return nil }
    return fallbackCurseForgeFileURL(fileID: fileID, fileName: resolvedName)
}

@MainActor
final class CurseForgeKeyStore {
    static let shared = CurseForgeKeyStore()

    private static let remotekeyURL = URL(string: "https://baconium.dev/jessi/cursekey")!

    private var remotekey: String?
    private var fetchtask: Task<String?, Never>?

    private init() {}

    var userkey: String? {
        let saved = JessiSettings.shared().curseForgeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return saved.isEmpty ? nil : saved
    }

    func invalidateremotekey() {
        remotekey = nil
        fetchtask = nil
    }

    func prefetch() {
        guard userkey == nil, remotekey == nil, fetchtask == nil else { return }
        Task { _ = try? await key() }
    }

    func key() async throws -> String {
        if let userkey { return userkey }
        if let remotekey { return remotekey }

        let task: Task<String?, Never>
        if let fetchtask {
            task = fetchtask
        } else {
            task = Task { await Self.fetchremotekey() }
            fetchtask = task
        }

        let fetched = await task.value
        fetchtask = nil

        guard let fetched else {
            throw modserror("couldn't get a CurseForge API key. Check your connection, or add your own key in Settings.")
        }
        remotekey = fetched
        return fetched
    }

    private static func fetchremotekey() async -> String? {
        var request = URLRequest(url: remotekeyURL)
        request.setValue("JESSI :3", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        modlogger.log("request: \(remotekeyURL.absoluteString)")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                modlogger.log("CurseForge API key request failed: HTTP \(http.statusCode)")
                return nil
            }

            let key = (String(data: data, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !key.contains("<") else {
                modlogger.log("CurseForge API key request returned nothing usable")
                return nil
            }

            modlogger.log("fetched CurseForge API key (\(key.count) chars)")
            return key
        } catch {
            modlogger.log("CurseForge API key request failed: \(error.localizedDescription)")
            return nil
        }
    }
}


struct InstalledModRecord: Codable {
    let filename: String
    let contentType: ContentType
    let managedPaths: [String]?
    let sourceURL: String?
    let sha1: String?

    init(filename: String, contentType: ContentType, managedPaths: [String]?,
         sourceURL: String? = nil, sha1: String? = nil) {
        self.filename = filename
        self.contentType = contentType
        self.managedPaths = managedPaths
        self.sourceURL = sourceURL
        self.sha1 = sha1
    }
}

nonisolated private struct ModpackModDownload: Sendable {
    let projectID: Int
    let fileID: Int

    var id: String { "\(projectID):\(fileID)" }
}

nonisolated private final class ModpackDownloadState: @unchecked Sendable {
    private(set) var managed: Set<String>
    private(set) var failures: [String] = []
    private let lock = NSLock()

    init(overrides: Set<String>) {
        managed = overrides
    }

    func addManaged(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        managed.insert(path)
    }

    func addFailure(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        failures.append(id)
    }
}

private struct MrpackIndex: Decodable {
    let files: [MrpackFile]
}

private struct MrpackFile: Decodable {
    let path: String
    let downloads: [String]
}

@MainActor
final class ModsVM: ObservableObject {
    @Published var query: String = ""
    @Published var mods: [ModSearchItem] = []
    @Published var isloading = false
    @Published var errmsg: String?
    @Published var initialload = false
    @Published var extraload = false
    @Published var installedmods: [String: InstalledModRecord] = [:]
    @Published var installingmods: Set<String> = []
    @Published var failedmods: Set<String> = []
    @Published var provider: ModProvider = .modrinth
    @Published var contentType: ContentType = .mod
    
    private let modrinthURL = "https://api.modrinth.com/v2/search"
    private var offset = 0
    private let limit = 20
    private var canload = true
    private var cfindex = 0
    
    private var servername: String?
    private var serversoft: String?
    var serverver: String?
    
    init(servername: String) {
        self.servername = servername
        readconfig(for: servername)
        loadinstalledmods()
    }
    
    enum ServerSoftware: String {
        case vanilla
        case forge
        case neoforge
        case fabric
        case quilt
        case custom
    }

    func parsedserversoft() -> ServerSoftware? {
        let soft = serversoft?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch soft {
        case "vanilla":
            return .vanilla
        case "forge":
            return .forge
        case "neoforge", "neo-forge":
            return .neoforge
        case "fabric":
            return .fabric
        case "quilt":
            return .quilt
        case "custom", "custom jar":
            return .custom
        default:
            return nil
        }
    }

    private func loaderFacet(for software: ServerSoftware) -> String? {
        switch software {
        case .forge:
            return "categories:forge"
        case .neoforge:
            return "categories:neoforge"
        case .fabric:
            return "categories:fabric"
        case .quilt:
            return "categories:quilt"
        default:
            return nil
        }
    }

    func curseForgeModLoaderType() -> Int? {
        switch parsedserversoft() {
        case .forge:
            return 1
        case .fabric:
            return 4
        case .quilt:
            return 5
        case .neoforge:
            return 6
        default:
            return nil
        }
    }

    
    private func readconfig(for server: String) {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            modlogger.log("failed to locate documents directory")
            return
        }
        
        let configurl = docs.appendingPathComponent("servers/\(server)/jessiserverconfig.json")
        modlogger.log("reading config at: \(configurl.path)")
        
        guard fm.fileExists(atPath: configurl.path) else {
            modlogger.log("config file does not exist")
            return
        }
        
        do {
            let data = try Data(contentsOf: configurl)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: String] {
                self.serversoft = json["software"]
                self.serverver = json["minecraftVersion"]
                
                modlogger.log("loaded config → software=\(serversoft ?? "n/a"), version=\(serverver ?? "n/a")")
            }
        } catch {
            modlogger.log("failed to read jessiserverconfig.json: \(error.localizedDescription)")
        }
        
        modlogger.divider()
    }
    
    func reset() async {
        offset = 0
        cfindex = 0
        canload = true
        mods = []
        await search(initial: true)
    }
    
    func search(initial: Bool = false) async {
        guard canload, !initialload, !extraload else { return }
        
        if initial { initialload = true } else { extraload = true }
        if initial || mods.isEmpty {
            isloading = true
        }
        errmsg = nil
        defer {
            if initial { initialload = false } else { extraload = false }
            isloading = false
        }
        
        do {
            var collected: [ModSearchItem] = []
            var pages = 0

            while canload, collected.isEmpty, pages < 5 {
                pages += 1
                let page: SearchPage
                switch provider {
                case .modrinth:
                    page = try await searchModrinth()
                case .curseForge:
                    page = try await searchCurseForge()
                }

                if page.rawCount < limit { canload = false }

                var known = Set(mods.map { $0.id })
                known.formUnion(collected.map { $0.id })
                collected.append(contentsOf: page.items.filter { !known.contains($0.id) })
            }

            modlogger.log("received \(collected.count) \(contentType.rawValue)s from \(provider.rawValue)")
            mods.append(contentsOf: collected)
            modlogger.divider()
        } catch {
            errmsg = error.localizedDescription
        }
    }

    private struct SearchPage {
        let items: [ModSearchItem]
        let rawCount: Int
    }

    private func searchModrinth() async throws -> SearchPage {
        var components = URLComponents(string: modrinthURL)!
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        var queryitems: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)")
        ]

        if !trimmed.isEmpty {
            queryitems.append(URLQueryItem(name: "query", value: trimmed))
        }

        var facets: [[String]] = [
            ["project_type:\(contentType.modrinthprojecttype)"]
        ]

        if let version = serverver, !version.isEmpty {
            facets.append(["versions:\(version)"])
        }

        if contentType == .mod || contentType == .modpack {
            facets.append(["server_side:required", "server_side:optional"])
        }

        if contentType == .mod, let software = parsedserversoft(), software != .custom,
           let loader = loaderFacet(for: software) {
            facets.append([loader])
        }

        if let facetsdata = try? JSONSerialization.data(withJSONObject: facets, options: []),
           let facetsstring = String(data: facetsdata, encoding: .utf8) {
            queryitems.append(URLQueryItem(name: "facets", value: facetsstring))
        }

        components.queryItems = queryitems
        let url = components.url!
        modlogger.log("request: \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.setValue("JESSI :3", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await URLSession.shared.data(for: request)
        let decoded = try JSONDecoder().decode(ModrinthResponse.self, from: data)
        offset += decoded.hits.count

        let items = decoded.hits.map {
            ModSearchItem(
                id: "\(ModProvider.modrinth.rawValue):\($0.id)",
                provider: .modrinth,
                providerID: $0.id,
                contentType: contentType,
                title: $0.title,
                description: $0.description,
                downloads: $0.downloads,
                iconURL: $0.iconURL,
                author: $0.author,
                follows: $0.follows
            )
        }
        return SearchPage(items: items, rawCount: decoded.hits.count)
    }

    private func searchCurseForge() async throws -> SearchPage {
        var components = URLComponents(string: "\(curseForgeBaseURL)/mods/search")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "gameId", value: "\(curseForgeGameIDMinecraft)"),
            URLQueryItem(name: "classId", value: contentType.curseforgeclassid),
            URLQueryItem(name: "pageSize", value: "\(limit)"),
            URLQueryItem(name: "index", value: "\(cfindex)"),
            URLQueryItem(name: "sortField", value: "2"),
            URLQueryItem(name: "sortOrder", value: "desc")
        ]

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            items.append(URLQueryItem(name: "searchFilter", value: trimmed))
        }
        if let version = serverver?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty {
            items.append(URLQueryItem(name: "gameVersion", value: version))
        }
        if contentType == .mod, let loadertype = curseForgeModLoaderType() {
            items.append(URLQueryItem(name: "modLoaderType", value: "\(loadertype)"))
        }

        components.queryItems = items
        let url = components.url!
        modlogger.log("request: \(url.absoluteString)")

        let data: Data
        do {
            data = try await curseForgeGET(url)
        } catch let error as NSError where error.code == 401 || error.code == 403 {
            throw modserror("This CurseForge API key isn't allowed to search. CurseForge gates the search endpoint separately, so downloads can still work. Try another key in Settings.", code: error.code)
        }
        let decoded = try JSONDecoder().decode(CurseForgeSearchResponse.self, from: data)
        cfindex += decoded.data.count

        var results = decoded.data
        if contentType == .mod {
            let clientOnly = await clientOnlyCurseForgeIDs(in: results)
            if !clientOnly.isEmpty {
                modlogger.log("hiding \(clientOnly.count) client-only mod(s)")
                results = results.filter { !clientOnly.contains($0.id) }
            }
        }

        let searchItems = results.map { item in
            ModSearchItem(
                id: "\(ModProvider.curseForge.rawValue):\(item.id)",
                provider: .curseForge,
                providerID: "\(item.id)",
                contentType: ContentType.fromcurseforgeclassid(item.classId ?? item.classInfo?.id),
                title: item.name,
                description: item.summary,
                downloads: Int(item.downloadCount),
                iconURL: item.logo?.url,
                author: item.authors?.first?.name,
                follows: item.thumbsUpCount ?? 0
            )
        }
        return SearchPage(items: searchItems, rawCount: decoded.data.count)
    }

    private func clientOnlyCurseForgeIDs(in mods: [CurseForgeMod]) async -> Set<Int> {
        var modIDForHash: [String: Int] = [:]
        for mod in mods {
            for file in (mod.latestFiles ?? []).prefix(4) {
                for hash in file.hashes ?? [] where hash.algo == CurseForgeFileHash.sha1 {
                    modIDForHash[hash.value] = mod.id
                }
            }
        }
        guard !modIDForHash.isEmpty else { return [] }

        guard let lookups = try? await modrinthProjectsForHashes(Array(modIDForHash.keys)) else {
            return []
        }

        var projectIDsForMod: [Int: Set<String>] = [:]
        for (hash, lookup) in lookups {
            guard let modID = modIDForHash[hash] else { continue }
            projectIDsForMod[modID, default: []].insert(lookup.project_id)
        }
        guard !projectIDsForMod.isEmpty else { return [] }

        let allProjectIDs = Set(projectIDsForMod.values.flatMap { $0 })
        guard let environments = try? await modrinthEnvironments(for: Array(allProjectIDs)) else {
            return []
        }

        return Set(projectIDsForMod.compactMap { modID, projectIDs -> Int? in
            let known = projectIDs.compactMap { environments[$0] }
            guard !known.isEmpty else { return nil }
            return known.allSatisfy { !$0.runsOnServer } ? modID : nil
        })
    }

    private func modrinthProjectsForHashes(_ hashes: [String]) async throws -> [String: ModrinthFileLookup] {
        var request = URLRequest(url: URL(string: "https://api.modrinth.com/v2/version_files")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("JESSI :3", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "hashes": hashes,
            "algorithm": "sha1"
        ])

        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode([String: ModrinthFileLookup].self, from: data)
    }

    private func modrinthEnvironments(for projectIDs: [String]) async throws -> [String: ModrinthProjectEnvironment] {
        let encoded = try JSONSerialization.data(withJSONObject: projectIDs)
        var components = URLComponents(string: "https://api.modrinth.com/v2/projects")!
        components.queryItems = [
            URLQueryItem(name: "ids", value: String(data: encoded, encoding: .utf8) ?? "[]")
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("JESSI :3", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        let projects = try JSONDecoder().decode([ModrinthProjectEnvironment].self, from: data)
        return Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
    }
    
    private func locatemodsregistry() -> URL? {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first,
              let servername = self.servername else { return nil }
        let serverdir = docs.appendingPathComponent("servers").appendingPathComponent(servername)
        return serverdir.appendingPathComponent("jessimods.json")
    }
    
    func saveinstalledmods() {
        guard let file = locatemodsregistry() else { return }
        do {
            let data = try JSONEncoder().encode(installedmods)
            try data.write(to: file, options: [.atomic])
        } catch {
            modlogger.enclosedlog("failed to save installed mods: \(error)")
            modlogger.flushdivider()
        }
    }
    
    func loadinstalledmods() {
        guard let file = locatemodsregistry(),
              FileManager.default.fileExists(atPath: file.path) else { return }

        do {
            let data = try Data(contentsOf: file)
            if let records = try? JSONDecoder().decode([String: InstalledModRecord].self, from: data) {
                installedmods = records
            } else {
                let legacy = try JSONDecoder().decode([String: String].self, from: data)
                installedmods = legacy.mapValues { InstalledModRecord(filename: $0, contentType: .mod, managedPaths: nil) }
                saveinstalledmods()
            }
        } catch {
            modlogger.enclosedlog("failed to load installed mods: \(error)")
            modlogger.flushdivider()
        }
    }
    
    func deleteinstalledmod(ids: [String]) {
        guard let serverdir = serverRootURL() else { return }
        for modid in ids {
            deleteInstalledRecord(modid: modid, serverdir: serverdir, excluding: [])
        }
        saveinstalledmods()
    }

    func cleanupExistingInstall(for mod: ModSearchItem, keeping newRecord: InstalledModRecord) {
        guard let existingKey = installedKey(for: mod),
              let serverdir = serverRootURL() else { return }

        var protectedPaths = Set<String>()
        if let managed = newRecord.managedPaths {
            protectedPaths.formUnion(managed)
        }
        protectedPaths.insert("\(newRecord.contentType.dirname)/\(newRecord.filename)")

        deleteInstalledRecord(modid: existingKey, serverdir: serverdir, excluding: protectedPaths)
    }

    private func serverRootURL() -> URL? {
        let fm = FileManager.default
        guard let servername = self.servername else { return nil }
        return fm.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("servers")
            .appendingPathComponent(servername)
    }

    private func deleteInstalledRecord(modid: String, serverdir: URL, excluding protectedPaths: Set<String>) {
        let fm = FileManager.default
        guard let record = installedmods[modid] else { return }

        if let managedPaths = record.managedPaths {
            for relativePath in managedPaths {
                if protectedPaths.contains(relativePath) { continue }
                let managedFile = serverdir.appendingPathComponent(relativePath)
                if fm.fileExists(atPath: managedFile.path) {
                    do {
                        try fm.removeItem(at: managedFile)
                        modlogger.enclosedlog("deleted managed file: \(managedFile.path)")
                        modlogger.flushdivider()
                    } catch {
                        modlogger.enclosedlog("failed to delete managed file: \(error)")
                        modlogger.flushdivider()
                    }
                }
            }
        }

        let recordFileRelative = "\(record.contentType.dirname)/\(record.filename)"
        if !protectedPaths.contains(recordFileRelative) {
            let extensiondir = serverdir.appendingPathComponent(record.contentType.dirname)
            let modfile = extensiondir.appendingPathComponent(record.filename)
            if fm.fileExists(atPath: modfile.path) {
                do {
                    try fm.removeItem(at: modfile)
                    modlogger.enclosedlog("deleted mod file: \(modfile.path)")
                    modlogger.flushdivider()
                } catch {
                    modlogger.enclosedlog("failed to delete mod file: \(error)")
                    modlogger.flushdivider()
                }
            }
        }

        installedmods.removeValue(forKey: modid)
    }

    func installedKey(for mod: ModSearchItem) -> String? {
        if installedmods[mod.id] != nil {
            return mod.id
        }
        if mod.provider == .modrinth, mod.contentType == .mod, installedmods[mod.providerID] != nil {
            return mod.providerID
        }
        return nil
    }

    func isInstalled(_ mod: ModSearchItem) -> Bool {
        installedKey(for: mod) != nil
    }

    func markInstallFailed(_ modID: String) {
        failedmods.insert(modID)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            failedmods.remove(modID)
        }
    }
}


private struct Mod: View {
    @EnvironmentObject var model: ModsVM
    
    let servername: String
    let mod: ModSearchItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            let size: CGFloat = 48

            if let icon = mod.iconURL, let url = URL(string: icon) {
                if #available(iOS 15.0, *) {
                    AsyncImage(url: url) { image in
                        image.resizable()
                    } placeholder: {
                        Color.gray.opacity(0.3)
                    }
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                } else {
                    RemoteImage(url: url)
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
            } else {
                Color.gray.opacity(0.3)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 2.5) {
                    Text(mod.title)
                        .font(.system(size: 15, weight: .bold))
                    
                    Spacer()
                    
                    if model.installingmods.contains(mod.id) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .frame(width: 15, height: 15)
                            .scaleEffect(15 / 20)
                    } else if model.failedmods.contains(mod.id) {
                        Image(systemName: "xmark.octagon.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.red)

                        Text("Failed")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.red)
                    } else if model.isInstalled(mod) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.green)
                        
                        Text("Installed")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.green)
                    }
                }
                
                // disgusting
                // I think its beautiful <3
                // thanks man :)
                (
                    Text("by ")
                        .foregroundColor(.secondary)
                    +
                    Text(mod.author ?? "n/a")
                        .underline()
                        .foregroundColor(.secondary)
                )
                .font(.system(size: 13))
                .lineLimit(2)
                    
                Text(mod.description)
                    .font(.system(size: 13))
                    .foregroundColor(Color(UIColor.tertiaryLabel))
                    .lineLimit(2)

                HStack {
                    HStack(spacing: 2.5) {
                        Image(systemName: "arrowshape.down.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        
                        Text("\(mod.downloads.compact)")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    
                    if mod.follows > 0 {
                        HStack(spacing: 2.5) {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            
                            Text("\(mod.follows.compact)")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 6)
        .onTapGesture {
            installmod()
        }
    }
    
    func modloader() -> String? {
        if mod.contentType == .datapack { return "datapack" }
        guard mod.contentType == .mod else { return nil }
        switch model.parsedserversoft() {
        case .fabric: return "fabric"
        case .forge: return "forge"
        case .neoforge: return "neoforge"
        case .quilt: return "quilt"
        case .vanilla: return "minecraft"
        default: return nil
        }
    }

    private func installmod() {
        guard !model.installingmods.contains(mod.id), !model.isInstalled(mod) else {
            return
        }
        model.failedmods.remove(mod.id)
        model.installingmods.insert(mod.id)

        Task {
            do {
                let installedRecord: InstalledModRecord
                switch mod.provider {
                case .modrinth:
                    installedRecord = try await modrinthinstall()
                case .curseForge:
                    installedRecord = try await curseforgeinstall()
                }

                _ = await MainActor.run {
                    model.cleanupExistingInstall(for: mod, keeping: installedRecord)
                    if mod.provider == .modrinth {
                        model.installedmods.removeValue(forKey: mod.providerID)
                    }
                    model.installedmods[mod.id] = installedRecord
                    model.saveinstalledmods()
                    model.installingmods.remove(mod.id)
                    model.failedmods.remove(mod.id)
                }

            } catch {
                modlogger.enclosedlog("error installing mod \(mod.title): \(error)")
                modlogger.flushdivider()
                _ = await MainActor.run {
                    model.installingmods.remove(mod.id)
                    model.markInstallFailed(mod.id)
                }
            }
        }
    }

    private func modrinthinstall() async throws -> InstalledModRecord {
        guard let versionsurl = URL(string: "https://api.modrinth.com/v2/project/\(mod.providerID)/version") else {
            throw NSError(domain: "invalid modrinth version URL", code: 0)
        }

        let (data, _) = try await URLSession.shared.data(from: versionsurl)
        let versions = try JSONDecoder().decode([ModrinthVersion].self, from: data)

        let loader = modloader()
        let mcversion = model.serverver?.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = versions.first { version in
            let matchesVersion = mcversion?.isEmpty != false || version.game_versions.contains(mcversion!)
            let matchesLoader = loader == nil || version.loaders.contains(loader!)
            return matchesVersion && matchesLoader
        } ?? versions.first

        guard let matching else {
            throw NSError(domain: "no compatible version found", code: 0)
        }

        guard let file = pickModrinthFile(from: matching) else {
            throw modserror("no downloadable file found")
        }

        guard let fileurl = URL(string: file.url) else {
            throw NSError(domain: "invalid file URL", code: 0)
        }

        let (moddata, _) = try await URLSession.shared.data(from: fileurl)
        if mod.contentType == .modpack, file.filename.lowercased().hasSuffix(".mrpack") {
            return try await installModpackFromMrpack(data: moddata, filename: file.filename)
        }
        if mod.contentType == .datapack, file.filename.lowercased().hasSuffix(".zip") {
            return try installdatapackzip(data: moddata, filename: file.filename)
        }
        if mod.contentType == .mod {
            var visited: Set<String> = ["modrinth:\(mod.providerID):"]
            await installDependencies(targets: modrinthDepTargets(of: matching), visited: &visited)
        }
        return try writeModFile(data: moddata, filename: file.filename,
                               sourceURL: file.url, sha1: file.hashes?.sha1)
    }

    private func curseforgeinstall() async throws -> InstalledModRecord {
        guard let modid = Int(mod.providerID) else {
            throw modserror("invalid CurseForge mod id")
        }

        let mcversion = model.serverver?.trimmingCharacters(in: .whitespacesAndNewlines)
        let loadertype = mod.contentType == .mod ? model.curseForgeModLoaderType() : nil

        var files = try await curseforgefiles(modid: modid, gameversion: mcversion, loadertype: loadertype)
        if files.isEmpty {
            files = try await curseforgefiles(modid: modid, gameversion: nil, loadertype: nil)
        }
        guard !files.isEmpty else {
            throw modserror("no CurseForge files found for this project")
        }

        let preferred = files.filter { isPreferredCurseForgeFile($0) }
        let candidates = preferred.isEmpty ? files : preferred

        var selected: (file: CurseForgeFile, url: URL)?
        for file in candidates {
            if let resolved = try await resolveCurseForgeDownloadURL(
                projectID: modid,
                fileID: file.id,
                fileName: file.fileName,
                inlineURL: file.downloadURL
            ) {
                selected = (file, resolved)
                break
            }
        }

        guard let selected else {
            throw modserror("no downloadable CurseForge file for this version and loader")
        }

        let (moddata, _) = try await URLSession.shared.data(from: selected.url)
        let filename = selected.file.fileName
        let lowername = filename.lowercased()

        if mod.contentType == .modpack, lowername.hasSuffix(".mrpack") {
            return try await installModpackFromMrpack(data: moddata, filename: filename)
        }
        if mod.contentType == .modpack {
            return try await installCurseForgeModpackZip(data: moddata, filename: filename)
        }
        if mod.contentType == .datapack, lowername.hasSuffix(".zip") {
            return try installdatapackzip(data: moddata, filename: filename)
        }
        if mod.contentType == .mod {
            var visited: Set<String> = ["cf:\(modid)"]
            await installDependencies(targets: curseForgeDepTargets(of: selected.file), visited: &visited)
        }
        let cfsha1 = selected.file.hashes?.first { $0.algo == CurseForgeFileHash.sha1 }?.value
        return try writeModFile(data: moddata, filename: filename,
                               sourceURL: selected.url.absoluteString, sha1: cfsha1)
    }

    private func curseforgefiles(modid: Int, gameversion: String?, loadertype: Int?) async throws -> [CurseForgeFile] {
        var components = URLComponents(string: "\(curseForgeBaseURL)/mods/\(modid)/files")!
        var items = [
            URLQueryItem(name: "pageSize", value: "50"),
            URLQueryItem(name: "index", value: "0")
        ]
        if let gameversion, !gameversion.isEmpty {
            items.append(URLQueryItem(name: "gameVersion", value: gameversion))
        }
        if let loadertype {
            items.append(URLQueryItem(name: "modLoaderType", value: "\(loadertype)"))
        }
        components.queryItems = items
        let url = components.url!
        modlogger.log("request: \(url.absoluteString)")

        let data = try await curseForgeGET(url)
        return try JSONDecoder().decode(CurseForgeFilesResponse.self, from: data).data
    }

    private func isPreferredCurseForgeFile(_ file: CurseForgeFile) -> Bool {
        let name = file.fileName.lowercased()
        switch mod.contentType {
        case .mod:
            return name.hasSuffix(".jar")
        case .modpack:
            return name.hasSuffix(".mrpack") || name.hasSuffix(".zip")
        case .resourcepack, .datapack:
            return name.hasSuffix(".zip")
        }
    }

    private func curseForgeDepTargets(of file: CurseForgeFile) -> [DepTarget] {
        (file.dependencies ?? [])
            .filter { $0.relationType == curseForgeRequiredRelation }
            .map { DepTarget.curseForge(modid: $0.modId, name: "\($0.modId)") }
    }

    private func pickModrinthFile(from version: ModrinthVersion) -> ModrinthFile? {
        let wanted: [ModrinthFile]
        switch mod.contentType {
        case .mod:
            wanted = version.files.filter { $0.filename.lowercased().hasSuffix(".jar") }
        case .modpack:
            wanted = version.files.filter { $0.filename.lowercased().hasSuffix(".mrpack") }
        case .resourcepack, .datapack:
            wanted = version.files.filter { $0.filename.lowercased().hasSuffix(".zip") }
        }
        let pool = wanted.isEmpty ? version.files : wanted
        return pool.first(where: { $0.primary }) ?? pool.first
    }

    private func pickModrinthVersion(_ projectID: String) async throws -> ModrinthVersion {
        let versionsurl = URL(string: "https://api.modrinth.com/v2/project/\(projectID)/version")!
        let (data, _) = try await URLSession.shared.data(from: versionsurl)
        let versions = try JSONDecoder().decode([ModrinthVersion].self, from: data)

        let loader = modloader()
        let mcversion = model.serverver?.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = versions.first { version in
            let matchesVersion = mcversion?.isEmpty != false || version.game_versions.contains(mcversion!)
            let matchesLoader = loader == nil || version.loaders.contains(loader!)
            return matchesVersion && matchesLoader
        }
        if let first {
            return first
        }
        if let any = versions.first {
            return any
        }
        throw NSError(domain: "no compatible modrinth version found", code: 0)
    }

    private func modsDirURL() -> URL? {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return docs.appendingPathComponent("servers")
            .appendingPathComponent(servername)
            .appendingPathComponent("mods")
    }

    private func installDependencies(targets: [DepTarget], visited: inout Set<String>) async {
        guard mod.contentType == .mod, !targets.isEmpty else { return }
        modlogger.enclosedlog("installing \(targets.count) required dependency(ies) for \(mod.title)")

        for target in targets {
            let key = target.dedupKey
            if visited.contains(key) { continue }
            visited.insert(key)
            await installDepTarget(target, visited: &visited)
        }
    }

    private func modrinthDepTargets(of version: ModrinthVersion) -> [DepTarget] {
        (version.dependencies ?? [])
            .filter { isRequiredModrinthType($0.dependency_type) }
            .compactMap { dep in
                guard let projectID = dep.project_id else { return nil }
                return DepTarget.modrinth(projectID: projectID, versionID: dep.version_id)
            }
    }

    private func isRequiredModrinthType(_ t: String) -> Bool {
        let s = t.lowercased()
        return s == "required" || s == "server-side" || s == "common"
    }

    private func installDepTarget(_ target: DepTarget, visited: inout Set<String>) async {
        switch target {
        case .modrinth(let projectID, let versionID):
            await installModrinthDep(projectID: projectID, versionID: versionID, visited: &visited)
        case .curseForge(let modid, let name):
            await installCurseForgeDep(modid: modid, name: name, visited: &visited)
        }
    }

    private func installModrinthDep(projectID: String, versionID: String?, visited: inout Set<String>) async {
        var resolved: ModrinthVersion?
        if let versionID {
            resolved = try? await fetchModrinthVersion(versionID)
        }
        if resolved == nil {
            resolved = try? await pickModrinthVersion(projectID)
        }

        guard let version = resolved else {
            modlogger.enclosedlog("warning: skipped modrinth dep \(projectID) (no compatible version)")
            modlogger.flushdivider()
            return
        }

        guard let file = pickModrinthFile(from: version), let url = URL(string: file.url) else {
            modlogger.enclosedlog("warning: skipped modrinth dep \(projectID) (no downloadable file)")
            modlogger.flushdivider()
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            try writeDepFile(data: data, filename: file.filename)
        } catch {
            modlogger.enclosedlog("warning: failed to install modrinth dep \(projectID): \(error.localizedDescription)")
            modlogger.flushdivider()
            return
        }

        for sub in modrinthDepTargets(of: version) {
            let key = sub.dedupKey
            if visited.contains(key) { continue }
            visited.insert(key)
            await installDepTarget(sub, visited: &visited)
        }
    }

    private func fetchModrinthVersion(_ versionID: String) async throws -> ModrinthVersion {
        guard let url = URL(string: "https://api.modrinth.com/v2/version/\(versionID)") else {
            throw modserror("invalid modrinth version URL")
        }
        var request = URLRequest(url: url)
        request.setValue("JESSI :3", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(ModrinthVersion.self, from: data)
    }

    private func installCurseForgeDep(modid: Int, name: String, visited: inout Set<String>) async {
        let mcversion = model.serverver?.trimmingCharacters(in: .whitespacesAndNewlines)
        let loadertype = model.curseForgeModLoaderType()

        var files = (try? await curseforgefiles(modid: modid, gameversion: mcversion, loadertype: loadertype)) ?? []
        if files.isEmpty {
            files = (try? await curseforgefiles(modid: modid, gameversion: nil, loadertype: nil)) ?? []
        }

        let jars = files.filter { $0.fileName.lowercased().hasSuffix(".jar") }
        let candidates = jars.isEmpty ? files : jars

        var picked: (file: CurseForgeFile, url: URL)?
        for file in candidates {
            if let resolved = try? await resolveCurseForgeDownloadURL(
                projectID: modid,
                fileID: file.id,
                fileName: file.fileName,
                inlineURL: file.downloadURL
            ) {
                picked = (file, resolved)
                break
            }
        }

        guard let picked else {
            modlogger.enclosedlog("warning: skipped dep \(name) (no compatible file)")
            modlogger.flushdivider()
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: picked.url)
            try writeDepFile(data: data, filename: picked.file.fileName)
        } catch {
            modlogger.enclosedlog("warning: failed to download dep \(name): \(error.localizedDescription)")
            modlogger.flushdivider()
            return
        }

        for sub in curseForgeDepTargets(of: picked.file) {
            let key = sub.dedupKey
            if visited.contains(key) { continue }
            visited.insert(key)
            await installDepTarget(sub, visited: &visited)
        }
    }

    private func writeDepFile(data: Data, filename: String) throws {
        let dir = modsDirURL()
        guard let dir else {
            throw NSError(domain: "documents directory not found", code: 0)
        }
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let path = dir.appendingPathComponent(filename)
        try data.write(to: path)
        modlogger.enclosedlog("installed dependency \(filename) to \(path.path)")
        modlogger.flushdivider()
    }

    private func installModpackFromMrpack(data: Data, filename: String) async throws -> InstalledModRecord {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "documents directory not found", code: 0)
        }

        let serverRoot = docs
            .appendingPathComponent("servers")
            .appendingPathComponent(servername)
        try fm.createDirectory(at: serverRoot, withIntermediateDirectories: true)

        let tempRoot = fm.temporaryDirectory
            .appendingPathComponent("jessi-mrpack-install", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let archiveURL = tempRoot.appendingPathComponent(filename)
        try data.write(to: archiveURL, options: [.atomic])

        let archive = try Archive(url: archiveURL, accessMode: .read)
        guard let indexEntry = archive["modrinth.index.json"] else {
            throw NSError(domain: "invalid mrpack: missing modrinth.index.json", code: 0)
        }

        let indexData = try dataForEntry(indexEntry, in: archive)
        let index = try JSONDecoder().decode(MrpackIndex.self, from: indexData)

        var managed = Set<String>()

        for entry in archive {
            if entry.path.hasSuffix("/") { continue }
            guard let relative = stripMrpackOverridePrefix(entry.path) else { continue }
            let normalized = try normalizedRelativePath(relative)
            let destination = serverRoot.appendingPathComponent(normalized)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) {
                try? fm.removeItem(at: destination)
            }
            _ = try archive.extract(entry, to: destination)
            managed.insert(normalized)
        }

        for file in index.files {
            let normalized = try normalizedRelativePath(file.path)
            guard let downloadString = file.downloads.first,
                  let url = URL(string: downloadString) else {
                throw NSError(domain: "invalid mrpack file download URL", code: 0)
            }

            let (fileData, _) = try await URLSession.shared.data(from: url)
            let destination = serverRoot.appendingPathComponent(normalized)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileData.write(to: destination, options: [.atomic])
            managed.insert(normalized)
        }

        let modpacksDir = serverRoot.appendingPathComponent(ContentType.modpack.dirname)
        try fm.createDirectory(at: modpacksDir, withIntermediateDirectories: true)
        let manifestName = "\(mod.provider)-\(mod.providerID).installed.json"
        let manifestURL = modpacksDir.appendingPathComponent(manifestName)
        let managedPaths = managed.sorted()
        let manifestData = try JSONEncoder().encode(managedPaths)
        try manifestData.write(to: manifestURL, options: [.atomic])

        modlogger.enclosedlog("installed modpack \(mod.title) with \(managedPaths.count) files")
        modlogger.flushdivider()
        return InstalledModRecord(filename: manifestName, contentType: .modpack, managedPaths: managedPaths)
    }

    private func installCurseForgeModpackZip(data: Data, filename: String) async throws -> InstalledModRecord {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw modserror("documents directory not found")
        }

        let serverroot = docs
            .appendingPathComponent("servers")
            .appendingPathComponent(servername)
        try fm.createDirectory(at: serverroot, withIntermediateDirectories: true)

        let temproot = fm.temporaryDirectory
            .appendingPathComponent("jessi-curseforge-modpack-install", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temproot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temproot) }

        let archiveurl = temproot.appendingPathComponent(filename)
        try data.write(to: archiveurl, options: [.atomic])
        let archive = try Archive(url: archiveurl, accessMode: .read)

        guard let manifestentry = archive["manifest.json"] else {
            throw modserror("invalid CurseForge modpack: missing manifest.json")
        }
        let manifestdata = try dataForEntry(manifestentry, in: archive)
        let manifest = try JSONDecoder().decode(CurseForgeModpackManifest.self, from: manifestdata)

        let declaredoverrides = manifest.overrides?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let overridesprefix = declaredoverrides.isEmpty ? "overrides" : declaredoverrides

        var managed: Set<String> = []
        for entry in archive {
            if entry.path.hasSuffix("/") { continue }
            guard let relative = stripPrefix(overridesprefix, from: entry.path) ?? stripMrpackOverridePrefix(entry.path) else { continue }
            let normalized = try normalizedRelativePath(relative)
            let destination = serverroot.appendingPathComponent(normalized)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) {
                try? fm.removeItem(at: destination)
            }
            _ = try archive.extract(entry, to: destination)
            managed.insert(normalized)
        }

        let modsdir = serverroot.appendingPathComponent(ContentType.mod.dirname)
        try fm.createDirectory(at: modsdir, withIntermediateDirectories: true)

        let downloads = manifest.files.map { ModpackModDownload(projectID: $0.projectID, fileID: $0.fileID) }

        let downloadState = ModpackDownloadState(overrides: managed)

        await withTaskGroup(of: Void.self) { group in
            var iterator = downloads.makeIterator()
            let maxConcurrent = 8

            func spawnNext() {
                guard let entry = iterator.next() else { return }
                group.addTask {
                    do {
                        guard let fileurl = try await resolveCurseForgeDownloadURL(
                            projectID: entry.projectID,
                            fileID: entry.fileID,
                            fileName: nil,
                            inlineURL: nil
                        ) else {
                            downloadState.addFailure(entry.id)
                            return
                        }

                        let (filedata, _) = try await URLSession.shared.data(from: fileurl)
                        let decodedname = fileurl.lastPathComponent.removingPercentEncoding
                        let name = (decodedname?.isEmpty ?? true) ? "\(entry.fileID).jar" : decodedname!
                        let destination = modsdir.appendingPathComponent(name)
                        try filedata.write(to: destination, options: [.atomic])
                        downloadState.addManaged("mods/\(name)")
                    } catch {
                        downloadState.addFailure(entry.id)
                    }
                }
            }

            for _ in 0..<min(maxConcurrent, downloads.count) {
                spawnNext()
            }
            while await group.next() != nil {
                spawnNext()
            }
        }

        managed = downloadState.managed
        let unresolved = downloadState.failures.count

        if !manifest.files.isEmpty, unresolved == manifest.files.count {
            for relativePath in managed {
                let path = serverroot.appendingPathComponent(relativePath)
                if fm.fileExists(atPath: path.path) {
                    try? fm.removeItem(at: path)
                }
            }
            throw modserror("could not download any of the modpack's mods from CurseForge")
        }

        if unresolved > 0 {
            modlogger.enclosedlog("warning: skipped \(unresolved) unresolved CurseForge modpack mods")
            modlogger.flushdivider()
        }

        let modpacksdir = serverroot.appendingPathComponent(ContentType.modpack.dirname)
        try fm.createDirectory(at: modpacksdir, withIntermediateDirectories: true)
        let markername = "\(mod.provider)-\(mod.providerID).installed.json"
        let markerurl = modpacksdir.appendingPathComponent(markername)
        let managedpaths = managed.sorted()
        let markerdata = try JSONEncoder().encode(managedpaths)
        try markerdata.write(to: markerurl, options: [.atomic])

        modlogger.enclosedlog("installed modpack \(mod.title) with \(managedpaths.count) files")
        modlogger.flushdivider()
        return InstalledModRecord(filename: markername, contentType: .modpack, managedPaths: managedpaths)
    }

    private func stripPrefix(_ prefix: String, from path: String) -> String? {
        let full = "\(prefix)/"
        guard path.hasPrefix(full) else { return nil }
        return String(path.dropFirst(full.count))
    }

    private func installdatapackzip(data: Data, filename: String) throws -> InstalledModRecord {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "documents directory not found", code: 0)
        }

        let serverroot = docs
            .appendingPathComponent("servers")
            .appendingPathComponent(servername)
        let datapacksroot = serverroot.appendingPathComponent(ContentType.datapack.dirname)
        try fm.createDirectory(at: datapacksroot, withIntermediateDirectories: true)

        let temproot = fm.temporaryDirectory
            .appendingPathComponent("jessi-datapack-install", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temproot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temproot) }

        let archiveurl = temproot.appendingPathComponent(filename)
        try data.write(to: archiveurl, options: [.atomic])
        let archive = try Archive(url: archiveurl, accessMode: .read)
        let commonRoot = try commonArchiveRootFolder(in: archive)

        let basefolder = (filename as NSString).deletingPathExtension
        let trimmedbase = basefolder.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = "datapack-\(mod.provider)-\(mod.providerID)"
        let rawfolder = trimmedbase.isEmpty ? fallback : trimmedbase
        let foldername = rawfolder
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let installroot = datapacksroot.appendingPathComponent(foldername, isDirectory: true)
        try fm.createDirectory(at: installroot, withIntermediateDirectories: true)

        var managed = Set<String>()
        for entry in archive {
            if entry.path.hasSuffix("/") { continue }
            var normalized = try normalizedRelativePath(entry.path)
            if let commonRoot, let stripped = stripPrefix(commonRoot, from: normalized) {
                normalized = stripped
            }

            let destination = installroot.appendingPathComponent(normalized)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) {
                try? fm.removeItem(at: destination)
            }
            _ = try archive.extract(entry, to: destination)
            managed.insert("datapacks/\(foldername)/\(normalized)")
        }

        if managed.isEmpty {
            throw NSError(domain: "invalid datapack zip: no files found", code: 0)
        }

        let markername = "\(mod.provider)-\(mod.providerID).installed.json"
        let markerurl = datapacksroot.appendingPathComponent(markername)
        let managedpaths = managed.sorted()
        let markerdata = try JSONEncoder().encode(managedpaths)
        try markerdata.write(to: markerurl, options: [.atomic])

        modlogger.enclosedlog("installed datapack \(mod.title) with \(managedpaths.count) files")
        modlogger.flushdivider()
        return InstalledModRecord(filename: markername, contentType: .datapack, managedPaths: managedpaths)
    }

    private func commonArchiveRootFolder(in archive: Archive) throws -> String? {
        var root: String?
        for entry in archive {
            if entry.path.hasSuffix("/") { continue }
            let normalized = try normalizedRelativePath(entry.path)
            guard let first = normalized.split(separator: "/").first else { continue }
            let component = String(first)

            if let root, root != component {
                return nil
            }
            root = component
        }
        return root
    }

    private func dataForEntry(_ entry: Entry, in archive: Archive) throws -> Data {
        var out = Data()
        _ = try archive.extract(entry) { chunk in
            out.append(chunk)
        }
        return out
    }

    private func stripMrpackOverridePrefix(_ path: String) -> String? {
        if path.hasPrefix("overrides/") {
            return String(path.dropFirst("overrides/".count))
        }
        if path.hasPrefix("server-overrides/") {
            return String(path.dropFirst("server-overrides/".count))
        }
        return nil
    }

    private func normalizedRelativePath(_ path: String) throws -> String {
        var raw = path.replacingOccurrences(of: "\\", with: "/")
        while raw.hasPrefix("/") { raw.removeFirst() }
        let components = raw.split(separator: "/").map(String.init)
        var cleaned: [String] = []
        for component in components {
            if component.isEmpty || component == "." { continue }
            if component == ".." {
                throw NSError(domain: "invalid archive path", code: 0)
            }
            cleaned.append(component)
        }
        guard !cleaned.isEmpty else {
            throw NSError(domain: "invalid archive path", code: 0)
        }
        return cleaned.joined(separator: "/")
    }

    private func effectiveContentType(for filename: String) -> ContentType {
        if mod.contentType == .datapack, filename.lowercased().hasSuffix(".jar") {
            return .mod
        }
        return mod.contentType
    }

    private func writeModFile(data: Data, filename: String,
                              sourceURL: String? = nil, sha1: String? = nil) throws -> InstalledModRecord {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw modserror("documents directory not found")
        }

        let contentType = effectiveContentType(for: filename)
        let extensionsDir = docs
            .appendingPathComponent("servers")
            .appendingPathComponent(servername)
            .appendingPathComponent(contentType.dirname)

        if !fm.fileExists(atPath: extensionsDir.path) {
            try fm.createDirectory(at: extensionsDir, withIntermediateDirectories: true)
        }

        let modpath = extensionsDir.appendingPathComponent(filename)
        try data.write(to: modpath)

        modlogger.enclosedlog("installed \(mod.title) to \(modpath.path)")
        modlogger.flushdivider()
        return InstalledModRecord(filename: filename, contentType: contentType, managedPaths: nil,
                                  sourceURL: sourceURL, sha1: sha1)
    }
}

struct ModsView: View {
    @StateObject private var model: ModsVM
    @State private var showinstalledmods = false
    @State private var showlogs = false

    let servername: String
    
    init(servername: String) {
        self.servername = servername
        _model = StateObject(wrappedValue: ModsVM(servername: servername))
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                if #available(iOS 15.0, *) {
                    HStack(spacing: 8) {
                        TextField(model.provider == .modrinth ? "Search Modrinth" : "Search CurseForge", text: $model.query)
                            .textFieldStyle(.plain)
                            .onChange(of: model.query) { _ in
                                Task { await model.reset() }
                            }
                            .onSubmit {
                                Task { await model.search() }
                            }

                        Menu {
                            Picker("Type", selection: $model.contentType) {
                                ForEach(ContentType.allCases) { type in
                                    Text(type.title).tag(type)
                                }
                            }
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease")
                                .foregroundColor(.white)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(UIColor.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else { }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            
            Picker("", selection: $model.provider) {
                Text("Modrinth").tag(ModProvider.modrinth)
                Text("CurseForge").tag(ModProvider.curseForge)
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding(.horizontal, 16)
            .onChange(of: model.provider) { _ in
                Task { await model.reset() }
            }
            .onChange(of: model.contentType) { _ in
                Task { await model.reset() }
            }

            Group {
                if model.isloading {
                    ProgressView("Searching...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = model.errmsg {
                    Text(error)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    
                    Spacer()
                } else if model.mods.isEmpty {
                    Text("No \(model.contentType.title.lowercased()) found.")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    
                    Spacer()
                } else {
                    if #available(iOS 15, *) {
                        List {
                            ForEach(model.mods) { mod in
                                Mod(servername: servername, mod: mod)
                                    .environmentObject(model)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        if model.isInstalled(mod) {
                                            Button(role: .destructive) {
                                                if let key = model.installedKey(for: mod) {
                                                    model.deleteinstalledmod(ids: [key])
                                                }
                                            } label: {
                                                Label("Delete", systemImage: "trash")
                                            }
                                        }
                                    }
                                    .onAppear {
                                        if mod.id == model.mods.last?.id {
                                            Task { await model.search() }
                                        }
                                    }
                            }
                        }
                        .listStyle(.plain)
                    } else {
                        List {
                            ForEach(model.mods) { mod in
                                Mod(servername: servername, mod: mod)
                                    .environmentObject(model)
                                    .onAppear {
                                        if mod.id == model.mods.last?.id {
                                            Task { await model.search() }
                                        }
                                    }
                            }
                            .onDelete { offsets in
                                let mod = offsets.compactMap { index -> String? in
                                    let mod = model.mods[index]
                                    return model.installedKey(for: mod)
                                }
                                
                                model.deleteinstalledmod(ids: mod)
                            }
                        }
                        .listStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle(model.contentType.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showlogs = true
                } label: {
                    Text("Show Logs")
                        .foregroundColor(.green)
                }
            }
        }
        .sheet(isPresented: $showlogs) {
            LogsViewSheet(logger: modlogger)
                .background(Color(UIColor.systemBackground).ignoresSafeArea())
        }
        .background(Color(UIColor.systemBackground).ignoresSafeArea())
        .onAppear {
            CurseForgeKeyStore.shared.prefetch()
            Task { await model.search(initial: true) }
        }
    }
}
