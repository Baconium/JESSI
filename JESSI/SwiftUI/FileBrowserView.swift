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

    static func fromModrinthProjectType(_ rawValue: String?, fallback: ContentType) -> ContentType {
        guard let rawValue else { return fallback }
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalized {
        case "mod", "mods":
            return .mod
        case "modpack", "modpacks":
            return .modpack
        case "resourcepack", "resourcepacks":
            return .resourcepack
        case "datapack", "datapacks", "data_pack", "data_packs":
            return .datapack
        default:
            return fallback
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
}

struct ModrinthFile: Decodable {
    let url: String
    let filename: String
    let primary: Bool
}

struct CurseForgeSearchResponse: Decodable {
    let data: [CurseForgeMod]
}

struct CurseForgeMod: Decodable {
    let id: Int
    let name: String
    let summary: String
    let downloadCount: Int
    let classId: Int?
    let classInfo: CurseForgeClassInfo?
    let logo: CurseForgeLogo?
    let authors: [CurseForgeAuthor]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case summary
        case downloadCount
        case classId
        case classInfo = "class"
        case logo
        case authors
    }
}

struct CurseForgeClassInfo: Decodable {
    let id: Int
}

struct CurseForgeLogo: Decodable {
    let url: String?
}

struct CurseForgeAuthor: Decodable {
    let name: String
}

struct CurseForgeFilesResponse: Decodable {
    let data: [CurseForgeFile]
}

struct CurseForgeFile: Decodable {
    let id: Int
    let fileName: String
    let downloadURL: String?

    enum CodingKeys: String, CodingKey {
        case id
        case fileName
        case downloadURL = "downloadUrl"
    }
}

struct CurseForgeDownloadURLResponse: Decodable {
    let data: String
}

struct InstalledModRecord: Codable {
    let filename: String
    let contentType: ContentType
    let managedPaths: [String]?
}

private struct MrpackIndex: Decodable {
    let files: [MrpackFile]
}

private struct MrpackFile: Decodable {
    let path: String
    let downloads: [String]
}

private struct CurseForgeModpackManifest: Decodable {
    let files: [CurseForgeModpackManifestFile]
}

private struct CurseForgeModpackManifestFile: Decodable {
    let projectID: Int
    let fileID: Int
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
    
    private let modrinthBaseURL = "https://api.modrinth.com/v2/search"
    private let curseForgeBaseURL = "https://api.curseforge.com/v1"
    private var offset = 0
    private let limit = 20
    private var canload = true
    
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

    var curseForgeAPIKey: String? {
        let saved = JessiSettings.shared().curseForgeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !saved.isEmpty {
            return saved
        }
        return Bundle.main.object(forInfoDictionaryKey: "CURSEFORGE_API_KEY") as? String
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
            let newItems: [ModSearchItem]
            switch provider {
            case .modrinth:
                newItems = try await searchModrinth()
            case .curseForge:
                newItems = try await searchCurseForge()
            }

            modlogger.log("received \(newItems.count) mods from \(provider.rawValue)")

            if newItems.count < limit { canload = false }
            mods.append(contentsOf: newItems)
            offset += newItems.count
            modlogger.divider()
        } catch {
            errmsg = error.localizedDescription
        }
    }

    private func searchModrinth() async throws -> [ModSearchItem] {
        var components = URLComponents(string: modrinthBaseURL)!
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

        if contentType == .mod, let software = parsedserversoft(), software != .custom {
            facets.append(["server_side:required", "server_side:optional"])

            if let loader = loaderFacet(for: software) {
                facets.append([loader])
            }
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
        return decoded.hits.map {
            let resolvedType = ContentType.fromModrinthProjectType($0.projectType, fallback: contentType)
            return ModSearchItem(
                id: "\(ModProvider.modrinth.rawValue):\($0.id)",
                provider: .modrinth,
                providerID: $0.id,
                contentType: resolvedType,
                title: $0.title,
                description: $0.description,
                downloads: $0.downloads,
                iconURL: $0.iconURL,
                author: $0.author,
                follows: $0.follows
            )
        }
    }

    private func searchCurseForge() async throws -> [ModSearchItem] {
        guard let key = curseForgeAPIKey, !key.isEmpty else {
            throw NSError(
                domain: "Missing CurseForge API key in Settings or Info.plist",
                code: 0
            )
        }

        var components = URLComponents(string: "\(curseForgeBaseURL)/mods/search")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "gameId", value: "432"),
            URLQueryItem(name: "classId", value: contentType.curseforgeclassid),
            URLQueryItem(name: "pageSize", value: "\(limit)"),
            URLQueryItem(name: "index", value: "\(offset)")
        ]

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            items.append(URLQueryItem(name: "searchFilter", value: trimmed))
        }

        if let version = serverver, !version.isEmpty {
            items.append(URLQueryItem(name: "gameVersion", value: version))
        }

        if contentType == .mod, let loaderType = curseForgeModLoaderType() {
            items.append(URLQueryItem(name: "modLoaderType", value: "\(loaderType)"))
        }

        components.queryItems = items
        let url = components.url!
        modlogger.log("request: \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        let (data, _) = try await URLSession.shared.data(for: request)
        let decoded = try JSONDecoder().decode(CurseForgeSearchResponse.self, from: data)

        return decoded.data.map { mod in
            ModSearchItem(
                id: "\(ModProvider.curseForge.rawValue):\(mod.id)",
                provider: .curseForge,
                providerID: "\(mod.id)",
                contentType: ContentType.fromcurseforgeclassid(mod.classId ?? mod.classInfo?.id),
                title: mod.name,
                description: mod.summary,
                downloads: Int(mod.downloadCount),
                iconURL: mod.logo?.url,
                author: mod.authors.first?.name,
                follows: 0
            )
        }
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

        guard let file = matching.files.first(where: { $0.primary }) ?? matching.files.first else {
            throw NSError(domain: "no downloadable file found", code: 0)
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
        return try writeModFile(data: moddata, filename: file.filename)
    }

    private func curseforgeinstall() async throws -> InstalledModRecord {
        guard let key = model.curseForgeAPIKey, !key.isEmpty else {
            throw NSError(domain: "Missing CurseForge API key in Settings or Info.plist", code: 0)
        }

        guard let modid = Int(mod.providerID) else {
            throw NSError(domain: "invalid CurseForge mod id", code: 0)
        }

        var filecomponents = URLComponents(string: "https://api.curseforge.com/v1/mods/\(modid)/files")!
        var queryitems = [
            URLQueryItem(name: "pageSize", value: "50"),
            URLQueryItem(name: "index", value: "0")
        ]

        if let mcversion = model.serverver?.trimmingCharacters(in: .whitespacesAndNewlines), !mcversion.isEmpty {
            queryitems.append(URLQueryItem(name: "gameVersion", value: mcversion))
        }
        if mod.contentType == .mod, let loader = model.curseForgeModLoaderType() {
            queryitems.append(URLQueryItem(name: "modLoaderType", value: "\(loader)"))
        }
        filecomponents.queryItems = queryitems

        var filerequest = URLRequest(url: filecomponents.url!)
        filerequest.setValue(key, forHTTPHeaderField: "x-api-key")
        let (filedata, _) = try await URLSession.shared.data(for: filerequest)
        let files = try JSONDecoder().decode(CurseForgeFilesResponse.self, from: filedata).data

        guard !files.isEmpty else {
            throw NSError(domain: "no compatible CurseForge file found", code: 0)
        }

        let preferred = files.filter { isPreferredCurseForgeFile($0) }
        let candidateFiles = preferred.isEmpty ? files : preferred
        var selected: (file: CurseForgeFile, url: URL)? = nil
        for file in candidateFiles {
            if let resolved = try await resolveCurseForgeFileURL(modid: modid, file: file, key: key) {
                selected = (file, resolved)
                break
            }
        }

        guard let selected else {
            throw NSError(domain: "invalid CurseForge file URL", code: 0)
        }

        let (moddata, _) = try await URLSession.shared.data(from: selected.url)
        if mod.contentType == .modpack, selected.file.fileName.lowercased().hasSuffix(".mrpack") {
            return try await installModpackFromMrpack(data: moddata, filename: selected.file.fileName)
        }
        if mod.contentType == .modpack, selected.file.fileName.lowercased().hasSuffix(".zip") {
            return try await installcurseforgemodpackzip(data: moddata, filename: selected.file.fileName, key: key)
        }
        if mod.contentType == .datapack, selected.file.fileName.lowercased().hasSuffix(".zip") {
            return try installdatapackzip(data: moddata, filename: selected.file.fileName)
        }
        return try writeModFile(data: moddata, filename: selected.file.fileName)
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

    private func resolveCurseForgeFileURL(modid: Int, file: CurseForgeFile, key: String) async throws -> URL? {
        if let inline = file.downloadURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !inline.isEmpty,
           let url = URL(string: inline) {
            return url
        }

        let downloadurl = URL(string: "https://api.curseforge.com/v1/mods/\(modid)/files/\(file.id)/download-url")!
        var downloadrequest = URLRequest(url: downloadurl)
        downloadrequest.setValue(key, forHTTPHeaderField: "x-api-key")
        let (downloaddata, _) = try await URLSession.shared.data(for: downloadrequest)

        guard let parsed = parseCurseForgeDownloadPath(from: downloaddata),
              let url = URL(string: parsed) else {
            return fallbackCurseForgeFileURL(fileID: file.id, fileName: file.fileName)
        }
        return url
    }

    private func fallbackCurseForgeFileURL(fileID: Int, fileName: String) -> URL? {
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

    private func parseCurseForgeDownloadPath(from data: Data) -> String? {
        if let decoded = try? JSONDecoder().decode(CurseForgeDownloadURLResponse.self, from: data) {
            let value = decoded.data.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }

        if let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) {
            let unquoted = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !unquoted.isEmpty, unquoted.hasPrefix("http") {
                return unquoted
            }
        }

        return nil
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

    private func installcurseforgemodpackzip(data: Data, filename: String, key: String) async throws -> InstalledModRecord {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "documents directory not found", code: 0)
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
            throw NSError(domain: "invalid curseforge modpack: missing manifest.json", code: 0)
        }

        let manifestdata = try dataForEntry(manifestentry, in: archive)
        let manifest = try JSONDecoder().decode(CurseForgeModpackManifest.self, from: manifestdata)

        var managed = Set<String>()

        for entry in archive {
            if entry.path.hasSuffix("/") { continue }
            guard let relative = stripMrpackOverridePrefix(entry.path) ?? stripPrefix("overrides", from: entry.path) else { continue }
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

        var unresolvedFiles: [String] = []
        for file in manifest.files {
            guard let fileurl = try await resolveCurseForgeManifestFileURL(projectID: file.projectID, fileID: file.fileID, key: key) else {
                unresolvedFiles.append("\(file.projectID):\(file.fileID)")
                continue
            }
            let (filedata, _) = try await URLSession.shared.data(from: fileurl)
            let filename = fileurl.lastPathComponent.isEmpty ? "\(file.fileID).jar" : fileurl.lastPathComponent
            let destination = modsdir.appendingPathComponent(filename)
            try filedata.write(to: destination, options: [.atomic])
            managed.insert("mods/\(filename)")
        }

        if !manifest.files.isEmpty, unresolvedFiles.count == manifest.files.count {
            for relativePath in managed {
                let path = serverroot.appendingPathComponent(relativePath)
                if fm.fileExists(atPath: path.path) {
                    try? fm.removeItem(at: path)
                }
            }
            throw NSError(
                domain: "could not resolve any CurseForge modpack files",
                code: 0
            )
        }

        if !unresolvedFiles.isEmpty {
            modlogger.enclosedlog("warning: skipped \(unresolvedFiles.count) unresolved CurseForge modpack files")
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

    private func resolveCurseForgeManifestFileURL(projectID: Int, fileID: Int, key: String) async throws -> URL? {
        let downloadurl = URL(string: "https://api.curseforge.com/v1/mods/\(projectID)/files/\(fileID)/download-url")!
        var downloadrequest = URLRequest(url: downloadurl)
        downloadrequest.setValue(key, forHTTPHeaderField: "x-api-key")
        let (downloaddata, _) = try await URLSession.shared.data(for: downloadrequest)

        guard let parsed = parseCurseForgeDownloadPath(from: downloaddata),
              let url = URL(string: parsed) else {
            return nil
        }
        return url
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

    private func writeModFile(data: Data, filename: String) throws -> InstalledModRecord {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "documents directory not found", code: 0)
        }

        let extensionsDir = docs
            .appendingPathComponent("servers")
            .appendingPathComponent(servername)
            .appendingPathComponent(mod.contentType.dirname)

        if !fm.fileExists(atPath: extensionsDir.path) {
            try fm.createDirectory(at: extensionsDir, withIntermediateDirectories: true)
        }

        let modpath = extensionsDir.appendingPathComponent(filename)
        try data.write(to: modpath)

        modlogger.enclosedlog("installed \(mod.title) to \(modpath.path)")
        modlogger.flushdivider()
        return InstalledModRecord(filename: filename, contentType: mod.contentType, managedPaths: nil)
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
            Task { await model.search(initial: true) }
        }
    }
}
