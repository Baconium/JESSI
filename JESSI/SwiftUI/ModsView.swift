//
//  ModsView.swift
//  JESSI
//
//  Created by roooot on 01.02.26.
//

import Foundation
import Combine
import SwiftUI

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

struct ModSearchItem: Identifiable {
    let id: String
    let provider: ModProvider
    let providerID: String
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
    let logo: CurseForgeLogo?
    let authors: [CurseForgeAuthor]
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
}

struct CurseForgeDownloadURLResponse: Decodable {
    let data: String
}

@MainActor
final class ModsVM: ObservableObject {
    @Published var query: String = ""
    @Published var mods: [ModSearchItem] = []
    @Published var isloading = false
    @Published var errmsg: String?
    @Published var initialload = false
    @Published var extraload = false
    @Published var installedmods: [String: String] = [:]
    @Published var installingmods: Set<String> = []
    @Published var provider: ModProvider = .modrinth
    
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
        await search()
    }
    
    func search(initial: Bool = false) async {
        guard canload, !initialload, !extraload else { return }
        
        if initial { initialload = true } else { extraload = true }
        errmsg = nil
        
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
        
        if initial { initialload = false } else { extraload = false }
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

        if let software = parsedserversoft(), software != .custom {
            var facets: [[String]] = [
                ["project_type:mod"],
                ["server_side:required", "server_side:optional"]
            ]

            if let version = serverver {
                facets.insert(["versions:\(version)"], at: 0)
            }

            if let loader = loaderFacet(for: software) {
                facets.append([loader])
            }

            if let facetsdata = try? JSONSerialization.data(withJSONObject: facets, options: []),
               let facetsstring = String(data: facetsdata, encoding: .utf8) {
                queryitems.append(URLQueryItem(name: "facets", value: facetsstring))
            }
        }

        components.queryItems = queryitems
        let url = components.url!
        modlogger.log("request: \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.setValue("JESSI :3", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await URLSession.shared.data(for: request)
        let decoded = try JSONDecoder().decode(ModrinthResponse.self, from: data)
        return decoded.hits.map {
            ModSearchItem(
                id: "\(ModProvider.modrinth.rawValue):\($0.id)",
                provider: .modrinth,
                providerID: $0.id,
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
            URLQueryItem(name: "classId", value: "6"),
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

        if let loaderType = curseForgeModLoaderType() {
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
            installedmods = try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            modlogger.enclosedlog("failed to load installed mods: \(error)")
            modlogger.flushdivider()
        }
    }
    
    func deleteinstalledmod(ids: [String]) {
        guard let servername = self.servername else { return }
        let fm = FileManager.default
        guard let modsdir = fm.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("servers")
            .appendingPathComponent(servername)
            .appendingPathComponent("mods") else { return }

        for modid in ids {
            if let filename = installedmods[modid] {
                let modfile = modsdir.appendingPathComponent(filename)
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
                installedmods.removeValue(forKey: modid)
            }
        }

        saveinstalledmods()
    }

    func installedKey(for mod: ModSearchItem) -> String? {
        if installedmods[mod.id] != nil {
            return mod.id
        }
        if mod.provider == .modrinth, installedmods[mod.providerID] != nil {
            return mod.providerID
        }
        return nil
    }

    func isInstalled(_ mod: ModSearchItem) -> Bool {
        installedKey(for: mod) != nil
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
        Task { @MainActor in
            model.installingmods.insert(mod.id)
        }

        Task {
            do {
                let installedFilename: String
                switch mod.provider {
                case .modrinth:
                    installedFilename = try await installFromModrinth()
                case .curseForge:
                    installedFilename = try await installFromCurseForge()
                }

                _ = await MainActor.run {
                    if mod.provider == .modrinth {
                        model.installedmods.removeValue(forKey: mod.providerID)
                    }
                    model.installedmods[mod.id] = installedFilename
                    model.saveinstalledmods()
                    model.installingmods.remove(mod.id)
                }

            } catch {
                modlogger.enclosedlog("Error installing mod \(mod.title): \(error)")
                modlogger.flushdivider()
                _ = await MainActor.run {
                    model.installingmods.remove(mod.id)
                }
            }
        }
    }

    private func installFromModrinth() async throws -> String {
        guard let versionsurl = URL(string: "https://api.modrinth.com/v2/project/\(mod.providerID)/version") else {
            throw NSError(domain: "invalid modrinth version URL", code: 0)
        }

        let (data, _) = try await URLSession.shared.data(from: versionsurl)
        let versions = try JSONDecoder().decode([ModrinthVersion].self, from: data)

        guard let mcversion = model.serverver else {
            throw NSError(domain: "no server Minecraft version configured", code: 0)
        }

        let loader = modloader()

        guard let matching = versions.first(where: { version in
            version.game_versions.contains(mcversion) &&
            (loader == nil || version.loaders.contains(loader!))
        }) else {
            throw NSError(domain: "no compatible version found", code: 0)
        }

        guard let file = matching.files.first(where: { $0.primary }) ?? matching.files.first else {
            throw NSError(domain: "no downloadable file found", code: 0)
        }

        guard let fileurl = URL(string: file.url) else {
            throw NSError(domain: "invalid file URL", code: 0)
        }

        let (moddata, _) = try await URLSession.shared.data(from: fileurl)
        try writeModFile(data: moddata, filename: file.filename)
        return file.filename
    }

    private func installFromCurseForge() async throws -> String {
        guard let key = model.curseForgeAPIKey, !key.isEmpty else {
            throw NSError(domain: "Missing CurseForge API key in Settings or Info.plist", code: 0)
        }

        guard let mcversion = model.serverver else {
            throw NSError(domain: "no server Minecraft version configured", code: 0)
        }

        guard let modID = Int(mod.providerID) else {
            throw NSError(domain: "invalid CurseForge mod id", code: 0)
        }

        var filesComponents = URLComponents(string: "https://api.curseforge.com/v1/mods/\(modID)/files")!
        var queryItems = [
            URLQueryItem(name: "pageSize", value: "50"),
            URLQueryItem(name: "index", value: "0"),
            URLQueryItem(name: "gameVersion", value: mcversion)
        ]
        if let loader = model.curseForgeModLoaderType() {
            queryItems.append(URLQueryItem(name: "modLoaderType", value: "\(loader)"))
        }
        filesComponents.queryItems = queryItems

        var filesRequest = URLRequest(url: filesComponents.url!)
        filesRequest.setValue(key, forHTTPHeaderField: "x-api-key")
        let (filesData, _) = try await URLSession.shared.data(for: filesRequest)
        let files = try JSONDecoder().decode(CurseForgeFilesResponse.self, from: filesData).data

        guard let selectedFile = files.first else {
            throw NSError(domain: "no compatible CurseForge file found", code: 0)
        }

        let downloadURL = URL(string: "https://api.curseforge.com/v1/mods/\(modID)/files/\(selectedFile.id)/download-url")!
        var downloadRequest = URLRequest(url: downloadURL)
        downloadRequest.setValue(key, forHTTPHeaderField: "x-api-key")
        let (downloadData, _) = try await URLSession.shared.data(for: downloadRequest)
        let downloadPath = try JSONDecoder().decode(CurseForgeDownloadURLResponse.self, from: downloadData).data

        guard let fileURL = URL(string: downloadPath) else {
            throw NSError(domain: "invalid CurseForge file URL", code: 0)
        }

        let (moddata, _) = try await URLSession.shared.data(from: fileURL)
        try writeModFile(data: moddata, filename: selectedFile.fileName)
        return selectedFile.fileName
    }

    private func writeModFile(data: Data, filename: String) throws {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "documents directory not found", code: 0)
        }

        let modsDir = docs
            .appendingPathComponent("servers")
            .appendingPathComponent(servername)
            .appendingPathComponent("mods")

        if !fm.fileExists(atPath: modsDir.path) {
            try fm.createDirectory(at: modsDir, withIntermediateDirectories: true)
        }

        let modpath = modsDir.appendingPathComponent(filename)
        try data.write(to: modpath)

        modlogger.enclosedlog("installed \(mod.title) to \(modpath.path)")
        modlogger.flushdivider()
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
                    TextField(model.provider == .modrinth ? "Search Modrinth" : "Search CurseForge", text: $model.query)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(UIColor.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .onChange(of: model.query) { _ in
                            Task { await model.reset() }
                        }
                        .onSubmit {
                            Task { await model.search() }
                        }
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

            Group {
                if model.isloading {
                    ProgressView("Searching...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = model.errmsg {
                    Text(error)
                        .foregroundColor(.red)
                        .padding()
                } else if model.mods.isEmpty {
                    Text("No mods found.")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                            .listStyle(.plain)
                        }
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
        .navigationTitle("Mods")
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
            Task { await model.search() }
        }
    }
}
