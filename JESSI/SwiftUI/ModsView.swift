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
    let dependencies: [ModrinthDependency]?
}

struct ModrinthDependency: Decodable {
    let project_id: String
    let file_id: String?
    let version: String?
    let dependency_type: String
}

struct BaconiumDep: Decodable {
    let name: String
    let slug: String
    let modid: Int
    let relation: String
    let required: Bool
}

enum DepTarget {
    case modrinth(projectID: String, fileID: String?)
    case curseForge(modid: Int, name: String)

    var dedupKey: String {
        switch self {
        case .modrinth(let p, let f):
            return "modrinth:\(p):\(f ?? "")"
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
}

struct BaconiumSearchItem: Decodable {
    let name: String
    let slug: String
    let modid: Int
    let author: String
    let description: String
    let downloads: String
    let dllink: String
    let logo: String?
}

struct BaconiumFile: Decodable {
    let id: Int
    let filename: String
    let fileurl: String
    let versions: [String]
    let loaders: [String]
}

struct BaconiumJarURLResponse: Decodable {
    let url: String
}

struct BaconiumModpack: Decodable {
    let name: String
    let version: String?
    let author: String?
    let minecraft: String?
    let modloaders: [BaconiumModLoader]?
    let overrides: String?
    let zipfile: String?
    let zipfileid: Int
    let filecount: Int?
    let mods: [BaconiumModpackMod]
}

struct BaconiumModLoader: Decodable {
    let id: String
    let primary: Bool?
}

struct BaconiumModpackMod: Decodable {
    let projectID: Int
    let fileID: Int
    let required: Bool?
    let name: String?
    let slug: String?
    let filename: String?
    let downloadUrl: String?

    enum CodingKeys: String, CodingKey {
        case projectID = "projectID"
        case fileID = "fileID"
        case required
        case name
        case slug
        case filename
        case downloadUrl = "downloadUrl"
    }
}

let baconiumURL = "https://baconium.dev/curseclient/api.php"

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
    private var cfpage = 0
    
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

    func curseForgeModLoaderName() -> String? {
        switch parsedserversoft() {
        case .forge:
            return "Forge"
        case .fabric:
            return "Fabric"
        case .quilt:
            return "Quilt"
        case .neoforge:
            return "NeoForge"
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
        cfpage = 0
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
            let knownIDs = Set(mods.map { $0.id })
            let newItemsDeduped = newItems.filter { !knownIDs.contains($0.id) }
            mods.append(contentsOf: newItemsDeduped)
            offset += newItemsDeduped.count
            modlogger.divider()
        } catch {
            errmsg = error.localizedDescription
        }
    }

    private func searchModrinth() async throws -> [ModSearchItem] {
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
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchterm = trimmed.isEmpty ? "minecraft" : trimmed
        let page = cfpage + 1

        var components = URLComponents(string: baconiumURL)!
        var queryItems = [
            URLQueryItem(name: "q", value: "search"),
            URLQueryItem(name: "query", value: searchterm),
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "class", value: contentType.curseforgeclassid)
        ]

        if let version = serverver?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty {
            queryItems.append(URLQueryItem(name: "gameversion", value: version))
        }
        if contentType == .mod, let loader = curseForgeModLoaderName() {
            queryItems.append(URLQueryItem(name: "loader", value: loader.lowercased()))
        }

        components.queryItems = queryItems
        let url = components.url!
        modlogger.log("request: \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.setValue("JESSI :3", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        let decoded = try JSONDecoder().decode([BaconiumSearchItem].self, from: data)
        cfpage = page

        return decoded.map { item in
            let icon = item.logo?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ModSearchItem(
                id: "\(ModProvider.curseForge.rawValue):\(item.modid)",
                provider: .curseForge,
                providerID: "\(item.modid)",
                contentType: contentType,
                title: item.name,
                description: item.description,
                downloads: Int(item.downloads) ?? 0,
                iconURL: (icon?.isEmpty == false) ? icon : nil,
                author: item.author,
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
        if mod.contentType == .mod {
            var visited: Set<String> = []
            await installDependencies(visited: &visited)
        }
        return try writeModFile(data: moddata, filename: file.filename)
    }

    private func curseforgeinstall() async throws -> InstalledModRecord {
        guard let modid = Int(mod.providerID) else {
            throw NSError(domain: "invalid CurseForge mod id", code: 0)
        }

        let mcversion = model.serverver?.trimmingCharacters(in: .whitespacesAndNewlines)
        let loadername = model.contentType == .mod ? model.curseForgeModLoaderName()?.lowercased() : nil

        if mod.contentType == .modpack {
            let manifest = try await baconiummodpack(modid: modid)
            let zippage = "https://www.curseforge.com/minecraft/mc-mods/\(modid)/files/\(manifest.zipfileid)"
            guard let zipurl = try await resolveBaconiumFileURL(fileurl: zippage) else {
                throw NSError(domain: "could not resolve modpack download URL", code: 0)
            }
            let zipname = manifest.zipfile ?? "\(modid).zip"
            let (zipdata, _) = try await URLSession.shared.data(from: zipurl)
            return try await installBaconiumModpack(manifest: manifest, data: zipdata, filename: zipname)
        }

        let files = try await baconiumfiles(forModID: modid, gameversion: mcversion, loader: loadername)

        let candidates = files.filter { file in
            isPreferredBaconiumFile(file) &&
            (mcversion?.isEmpty == true || file.versions.contains(where: { $0.lowercased() == mcversion!.lowercased() })) &&
            (loadername == nil || file.loaders.contains(where: { $0.lowercased() == loadername! }))
        }

        var selected: (file: BaconiumFile, url: URL)? = nil
        for file in candidates {
            if let resolved = try await resolveBaconiumFileURL(fileurl: file.fileurl) {
                selected = (file, resolved)
                break
            }
        }

        guard let selected else {
            throw NSError(domain: "no CurseForge file found for this version and loader", code: 0)
        }

        let (moddata, _) = try await URLSession.shared.data(from: selected.url)
        if mod.contentType == .modpack, selected.file.filename.lowercased().hasSuffix(".mrpack") {
            return try await installModpackFromMrpack(data: moddata, filename: selected.file.filename)
        }
        if mod.contentType == .datapack, selected.file.filename.lowercased().hasSuffix(".zip") {
            return try await installdatapackzip(data: moddata, filename: selected.file.filename)
        }
        if mod.contentType == .mod {
            var visited: Set<String> = []
            await installDependencies(visited: &visited)
        }
        return try writeModFile(data: moddata, filename: selected.file.filename)
    }

    private func baconiumfiles(forModID modid: Int, gameversion: String? = nil, loader: String? = nil) async throws -> [BaconiumFile] {
        var components = URLComponents(string: baconiumURL)!
        var items = [
            URLQueryItem(name: "q", value: "files"),
            URLQueryItem(name: "url", value: "\(modid)")
        ]
        if let gameversion, !gameversion.isEmpty {
            items.append(URLQueryItem(name: "gameversion", value: gameversion))
        }
        if let loader, !loader.isEmpty {
            items.append(URLQueryItem(name: "loader", value: loader))
        }
        components.queryItems = items
        let url = components.url!
        modlogger.log("request: \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.setValue("JESSI :3", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        let files = try JSONDecoder().decode([BaconiumFile].self, from: data)

        guard !files.isEmpty else {
            throw NSError(domain: "no CurseForge files found for this mod", code: 0)
        }
        return files
    }

    private func baconiummodpack(modid: Int) async throws -> BaconiumModpack {
        var components = URLComponents(string: baconiumURL)!
        components.queryItems = [
            URLQueryItem(name: "q", value: "modpack"),
            URLQueryItem(name: "url", value: "\(modid)")
        ]
        let url = components.url!
        modlogger.log("request: \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.setValue("JESSI :3", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(BaconiumModpack.self, from: data)
    }

    private func isPreferredBaconiumFile(_ file: BaconiumFile) -> Bool {
        let name = file.filename.lowercased()
        switch mod.contentType {
        case .mod:
            return name.hasSuffix(".jar")
        case .modpack:
            return name.hasSuffix(".mrpack") || name.hasSuffix(".zip")
        case .resourcepack, .datapack:
            return name.hasSuffix(".zip")
        }
    }

    private func resolveBaconiumFileURL(fileurl: String) async throws -> URL? {
        var components = URLComponents(string: baconiumURL)!
        components.queryItems = [
            URLQueryItem(name: "q", value: "jarurl"),
            URLQueryItem(name: "url", value: fileurl)
        ]
        let url = components.url!
        modlogger.log("request: \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.setValue("JESSI :3", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)

        guard let decoded = try? JSONDecoder().decode(BaconiumJarURLResponse.self, from: data),
              !decoded.url.isEmpty,
              let direct = URL(string: decoded.url) else {
            return nil
        }
        return direct
    }

    private func baconiumdeps(modid: Int) async throws -> [BaconiumDep] {
        var components = URLComponents(string: baconiumURL)!
        components.queryItems = [
            URLQueryItem(name: "q", value: "deps"),
            URLQueryItem(name: "url", value: "\(modid)")
        ]
        let url = components.url!
        modlogger.log("request: \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.setValue("JESSI :3", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode([BaconiumDep].self, from: data)
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

    private func installDependencies(visited: inout Set<String>) async {
        guard mod.contentType == .mod else { return }
        let mainKey = mod.provider == .curseForge
            ? "cf:\(mod.providerID)"
            : "modrinth:\(mod.providerID):"
        visited.insert(mainKey)

        let mainTargets = await depTargets(for: mod.provider, providerID: mod.providerID)
        guard !mainTargets.isEmpty else { return }
        modlogger.enclosedlog("installing \(mainTargets.count) required dependency(ies) for \(mod.title)")

        for target in mainTargets {
            let key = target.dedupKey
            if visited.contains(key) { continue }
            visited.insert(key)
            await installDepTarget(target, visited: &visited)
        }
    }

    private func depTargets(for provider: ModProvider, providerID: String) async -> [DepTarget] {
        switch provider {
        case .modrinth:
            guard let version = try? await pickModrinthVersion(providerID) else { return [] }
            return (version.dependencies ?? [])
                .filter { isRequiredModrinthType($0.dependency_type) }
                .map { DepTarget.modrinth(projectID: $0.project_id, fileID: $0.file_id) }
        case .curseForge:
            guard let modid = Int(providerID) else { return [] }
            do {
                let deps = try await baconiumdeps(modid: modid)
                return deps
                    .filter { isRequiredBaconium($0) }
                    .map { DepTarget.curseForge(modid: $0.modid, name: $0.name) }
            } catch {
                modlogger.enclosedlog("warning: could not fetch dependency list for CurseForge mod \(modid): \(error.localizedDescription)")
                modlogger.flushdivider()
                return []
            }
        }
    }

    private func isRequiredModrinthType(_ t: String) -> Bool {
        let s = t.lowercased()
        return s == "required" || s == "server-side" || s == "common"
    }

    private func isRequiredBaconium(_ d: BaconiumDep) -> Bool {
        return d.required || d.relation.lowercased() == "required"
    }

    private func installDepTarget(_ target: DepTarget, visited: inout Set<String>) async {
        switch target {
        case .modrinth(let projectID, let fileID):
            await installModrinthDep(projectID: projectID, fileID: fileID, visited: &visited)
        case .curseForge(let modid, let name):
            await installCurseForgeDep(modid: modid, name: name, visited: &visited)
        }
    }

    private func installModrinthDep(projectID: String, fileID: String?, visited: inout Set<String>) async {
        guard let version = try? await pickModrinthVersion(projectID) else {
            modlogger.enclosedlog("warning: skipped modrinth dep \(projectID) (no compatible version)")
            modlogger.flushdivider()
            return
        }

        var data: Data
        var filename: String
        if let fileID,
           let file = version.files.first(where: { $0.id == fileID }),
           let url = URL(string: file.url) {
            do {
                (data, _) = try await URLSession.shared.data(from: url)
                filename = file.filename
            } catch {
                modlogger.enclosedlog("warning: skipped modrinth dep \(projectID) file \(fileID) (download failed)")
                modlogger.flushdivider()
                return
            }
        } else {
            guard let file = version.files.first(where: { $0.primary }) ?? version.files.first,
                  let url = URL(string: file.url) else {
                modlogger.enclosedlog("warning: skipped modrinth dep \(projectID) (no downloadable file)")
                modlogger.flushdivider()
                return
            }
            do {
                (data, _) = try await URLSession.shared.data(from: url)
            } catch {
                modlogger.enclosedlog("warning: skipped modrinth dep \(projectID) (download failed)")
                modlogger.flushdivider()
                return
            }
            filename = file.filename
        }

        do {
            try writeDepFile(data: data, filename: filename)
        } catch {
            modlogger.enclosedlog("warning: failed to write modrinth dep \(projectID): \(error.localizedDescription)")
            modlogger.flushdivider()
            return
        }

        let subTargets = (version.dependencies ?? [])
            .filter { isRequiredModrinthType($0.dependency_type) }
            .map { DepTarget.modrinth(projectID: $0.project_id, fileID: $0.file_id) }
        for sub in subTargets {
            let key = sub.dedupKey
            if visited.contains(key) { continue }
            visited.insert(key)
            await installDepTarget(sub, visited: &visited)
        }
    }

    private func installCurseForgeDep(modid: Int, name: String, visited: inout Set<String>) async {
        let mcversion = model.serverver?.trimmingCharacters(in: .whitespacesAndNewlines)
        let loadername = model.curseForgeModLoaderName()?.lowercased()

        guard let files = try? await baconiumfiles(forModID: modid) else {
            modlogger.enclosedlog("warning: skipped dep \(name) (no CurseForge files found)")
            modlogger.flushdivider()
            return
        }

        let candidates = files.filter { file in
            file.filename.lowercased().hasSuffix(".jar") &&
            (mcversion?.isEmpty == true || file.versions.contains(where: { $0.lowercased() == mcversion!.lowercased() })) &&
            (loadername == nil || file.loaders.contains(where: { $0.lowercased() == loadername! }))
        }

        var picked: (file: BaconiumFile, url: URL)? = nil
        for file in candidates {
            if let resolved = try? await resolveBaconiumFileURL(fileurl: file.fileurl) {
                picked = (file, resolved)
                break
            }
        }
        if picked == nil, let first = candidates.first, let resolved = try? await resolveBaconiumFileURL(fileurl: first.fileurl) {
            picked = (first, resolved)
        }

        guard let picked else {
            modlogger.enclosedlog("warning: skipped dep \(name) (no compatible file)")
            modlogger.flushdivider()
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: picked.url)
            try writeDepFile(data: data, filename: picked.file.filename)
        } catch {
            modlogger.enclosedlog("warning: failed to download dep \(name): \(error.localizedDescription)")
            modlogger.flushdivider()
            return
        }

        guard let subDeps = try? await baconiumdeps(modid: modid) else { return }
        for sub in subDeps.filter(isRequiredBaconium) {
            let key = "cf:\(sub.modid)"
            if visited.contains(key) { continue }
            visited.insert(key)
            await installCurseForgeDep(modid: sub.modid, name: sub.name, visited: &visited)
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

    private func installBaconiumModpack(manifest: BaconiumModpack, data: Data, filename: String) async throws -> InstalledModRecord {
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

        var managed: Set<String> = []
        for entry in archive {
            if entry.path.hasSuffix("/") { continue }
            guard let relative = stripMrpackOverridePrefix(entry.path) ?? stripPrefix(manifest.overrides ?? "overrides", from: entry.path) else { continue }
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

        struct ModDownload {
            let id: String
            let url: URL
            let filename: String
        }

        var downloads: [ModDownload] = []
        var unresolvedCount = 0
        for modEntry in manifest.mods {
            guard let downloadUrlString = modEntry.downloadUrl,
                  let fileurl = URL(string: downloadUrlString) else {
                unresolvedCount += 1
                continue
            }
            let decodedName = fileurl.lastPathComponent.removingPercentEncoding
            let name = (decodedName?.isEmpty ?? true)
                ? "\(modEntry.fileID).jar"
                : (decodedName ?? "\(modEntry.fileID).jar")
            downloads.append(ModDownload(
                id: "\(modEntry.projectID):\(modEntry.fileID)",
                url: fileurl,
                filename: name
            ))
        }

        final class ModpackDownloadState: @unchecked Sendable {
            var managed: Set<String>
            var failures: [String] = []
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
        let downloadState = ModpackDownloadState(overrides: managed)

        await withTaskGroup(of: Void.self) { group in
            var iterator = downloads.makeIterator()
            let maxConcurrent = 8

            func spawnNext() {
                guard let entry = iterator.next() else { return }
                group.addTask {
                    do {
                        let (filedata, _) = try await URLSession.shared.data(from: entry.url)
                        let destination = modsdir.appendingPathComponent(entry.filename)
                        try filedata.write(to: destination, options: [.atomic])
                        downloadState.addManaged("mods/\(entry.filename)")
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
        let totalUnresolved = unresolvedCount + downloadState.failures.count

        if !manifest.mods.isEmpty, totalUnresolved == manifest.mods.count {
            for relativePath in managed {
                let path = serverroot.appendingPathComponent(relativePath)
                if fm.fileExists(atPath: path.path) {
                    try? fm.removeItem(at: path)
                }
            }
            throw NSError(
                domain: "could not download any CurseForge modpack mods",
                code: 0
            )
        }

        if totalUnresolved > 0 {
            modlogger.enclosedlog("warning: skipped \(totalUnresolved) unresolved CurseForge modpack mods")
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
