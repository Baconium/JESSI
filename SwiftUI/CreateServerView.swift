import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum ServerSoftwareSwift: String, CaseIterable, Identifiable {
    case vanilla = "Vanilla"
    case forge = "Forge"
    case neoforge = "NeoForge"
    case fabric = "Fabric"
    case quilt = "Quilt"
    case customJar = "Custom Jar"
    var id: String { rawValue }
}

struct CreateServerView: View {

    @State private var software: ServerSoftwareSwift = .vanilla
    @State private var serverName: String = ""

    @State private var mcVersion: String = ""
    @State private var availableVersions: [String] = []
    @State private var loadingVersions: Bool = false
    @State private var showVersionPicker: Bool = false
    @State private var versionFilter: String = ""
    @State private var versionFetchError: String? = nil

    @State private var showingIconImporter: Bool = false
    @State private var showingJarImporter: Bool = false

    @State private var serverIcon: UIImage? = nil
    @State private var customJarURL: URL? = nil

    @State private var maxPlayers: String = ""
    @State private var viewDistance: String = ""
    @State private var simulationDistance: String = ""
    @State private var spawnProtection: String = ""
    @State private var whitelist: Bool = false
    @State private var motd: String = ""
    @State private var seed: String = ""

    @State private var isCreating: Bool = false
    @State private var createStatus: String = ""
    @State private var createError: String? = nil
    @State private var showCreateError: Bool = false

    @State private var showForgeWarning: Bool = false
    @State private var pendingCreateServer: Bool = false

    @Environment(\.presentationMode) private var presentation

    private struct DocumentPicker: UIViewControllerRepresentable {
        let contentTypes: [UTType]
        let onPick: (URL) -> Void

        func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
            picker.delegate = context.coordinator
            return picker
        }

        func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

        func makeCoordinator() -> Coordinator {
            Coordinator(onPick: onPick)
        }

        class Coordinator: NSObject, UIDocumentPickerDelegate {
            let onPick: (URL) -> Void

            init(onPick: @escaping (URL) -> Void) {
                self.onPick = onPick
            }

            func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
                guard let url = urls.first else { return }
                onPick(url)
            }
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            List {
                Section(header: Text("Required Settings")) {
                    Picker("Software", selection: $software) {
                        ForEach(ServerSoftwareSwift.allCases) { s in
                            Text(s.rawValue).tag(s)
                        }
                    }


                    TextField("Server Name", text: $serverName)

                    if software == .customJar {
                        HStack {
                            Text("Custom Jar")
                            Spacer()
                            Button(customJarURL == nil ? "Select..." : (customJarURL!.lastPathComponent)) {
                                showingJarImporter = true
                            }
                        }
                    } else {
                        HStack {
                            Text("Minecraft Version")
                            Spacer()
                            if loadingVersions {
                                Text("Loading...").foregroundColor(.secondary)
                            } else if mcVersion.isEmpty {
                                Button("Select...") { openVersionPicker() }
                                    .foregroundColor(.blue)
                            } else {
                                Button(mcVersion) { openVersionPicker() }
                            }
                        }
                        if let err = versionFetchError {
                            Text(err)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }

                }

                Section(header: Text("Server Icon (Optional)")) {
                    HStack {
                        Text("Import server icon")
                        Spacer()
                        Button(serverIcon == nil ? "Select..." : "Selected") { showingIconImporter = true }
                            .foregroundColor(.blue)
                    }
                }

                Section(header: Text("Quick Settings (Optional)")) {
                    QuickSettingValueRow(title: "Max Players", defaultValue: "20", text: $maxPlayers, keyboardType: .numberPad)
                    QuickSettingValueRow(title: "View Distance", defaultValue: "10", text: $viewDistance, keyboardType: .numberPad)
                    QuickSettingValueRow(title: "Simulation Distance", defaultValue: "10", text: $simulationDistance, keyboardType: .numberPad)
                    QuickSettingValueRow(title: "Spawn Protection", defaultValue: "16", text: $spawnProtection, keyboardType: .numberPad)
                    Toggle("Whitelist", isOn: $whitelist)
                    QuickSettingValueRow(title: "MOTD", defaultValue: "A Minecraft Server", text: $motd, keyboardType: .default, fieldWidth: 200)
                    QuickSettingValueRow(title: "World Seed", defaultValue: "Random", text: $seed, keyboardType: .default, fieldWidth: 200)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Server Setup")
            .navigationBarTitleDisplayMode(.inline)
            .padding(.bottom, 88)

            Button(action: createServer) {
                HStack(spacing: 10) {
                    if isCreating {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    }
                    Text(isCreating ? (createStatus.isEmpty ? "Working..." : createStatus) : "Create Server")
                        .font(.system(size: 17, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .disabled(isCreating)
            .foregroundColor(.white)
            .background(Color.green)
            .cornerRadius(12)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .onAppear { ensureBaseDirectories() }
        .onChange(of: software) { newValue in
            if newValue == .customJar {
                mcVersion = ""
            } else {
                customJarURL = nil
            }
        }
        .fileImporter(
            isPresented: $showingJarImporter,
            allowedContentTypes: [UTType(filenameExtension: "jar") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                customJarURL = urls.first
            case .failure:
                break
            }
        }
        .sheet(isPresented: $showVersionPicker) {
            NavigationView {
                VersionPickerSheet(
                    versions: availableVersions,
                    filter: $versionFilter,
                    selected: mcVersion,
                    onSelect: { v in
                        mcVersion = v
                        showVersionPicker = false
                    },
                    onCancel: {
                        showVersionPicker = false
                    },
                    onReload: {
                        fetchVersions(force: true)
                    }
                )
            }
        }
        .sheet(isPresented: $showingIconImporter) {
            DocumentPicker(contentTypes: [.image]) { url in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
                    serverIcon = normalizeIcon(img)
                }
                showingIconImporter = false
            }
        }
        .alert(isPresented: $showCreateError) {
            Alert(
                title: Text("Create Server Failed"),
                message: Text(createError ?? "Unknown error"),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert(isPresented: $showForgeWarning) {
            Alert(
                title: Text("Warning"),
                message: Text("Warning: Creating a Forge/NeoForge server may cause the app to crash after the server is created. Proceed with caution."),
                dismissButton: .default(Text("Dismiss"), action: {
                    if pendingCreateServer {
                        pendingCreateServer = false
                        createServerConfirmed()
                    }
                })
            )
        }
    }

    private struct VersionPickerSheet: View {
        let versions: [String]
        @Binding var filter: String
        let selected: String
        let onSelect: (String) -> Void
        let onCancel: () -> Void
        let onReload: () -> Void

        private var filtered: [String] {
            let f = filter.trimmingCharacters(in: .whitespacesAndNewlines)
            if f.isEmpty { return versions }
            return versions.filter { $0.localizedCaseInsensitiveContains(f) }
        }

        var body: some View {
            List {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Search version", text: $filter)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                }

                Section {
                    ForEach(filtered.prefix(250), id: \.self) { v in
                        Button(action: { onSelect(v) }) {
                            HStack {
                                Text(v)
                                Spacer()
                                if v == selected {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.green)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle("Minecraft Version")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(
                leading: Button("Cancel") { onCancel() },
                trailing: Button(action: { onReload() }) { Image(systemName: "arrow.clockwise") }
            )
        }
    }

    private struct QuickSettingValueRow: View {
        let title: String
        let defaultValue: String
        @Binding var text: String
        let keyboardType: UIKeyboardType
        let fieldWidth: CGFloat

        init(title: String, defaultValue: String, text: Binding<String>, keyboardType: UIKeyboardType, fieldWidth: CGFloat = 140) {
            self.title = title
            self.defaultValue = defaultValue
            self._text = text
            self.keyboardType = keyboardType
            self.fieldWidth = fieldWidth
        }

        var body: some View {
            HStack(spacing: 12) {
                Text(title)
                    .foregroundColor(.primary)
                Spacer()
                ZStack(alignment: .leading) {
                    if text.isEmpty {
                        Text(defaultValue)
                            .foregroundColor(.primary)
                            .opacity(0.65)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.trailing, 10)
                    }
                    DoneTextField(text: $text, keyboardType: keyboardType)
                        .padding(.trailing, 10)
                        .padding(.vertical, 8)
                }
                .frame(width: fieldWidth)
                .background(Color(UIColor.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private struct DoneTextField: UIViewRepresentable {
        @Binding var text: String
        let keyboardType: UIKeyboardType

        final class Coordinator: NSObject {
            var parent: DoneTextField

            init(parent: DoneTextField) {
                self.parent = parent
            }

            @objc func textChanged(_ sender: UITextField) {
                parent.text = sender.text ?? ""
            }

            @objc func doneTapped(_ sender: UIBarButtonItem) {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(parent: self)
        }

        func makeUIView(context: Context) -> UITextField {
            let tf = UITextField(frame: .zero)
            tf.borderStyle = .none
            tf.backgroundColor = .clear
            tf.textColor = UIColor.label
            tf.font = UIFont.systemFont(ofSize: 16)
            tf.keyboardType = keyboardType
            tf.autocapitalizationType = .none
            tf.autocorrectionType = .no
            tf.textAlignment = .right
            tf.returnKeyType = .done
            tf.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)

            let toolbar = UIToolbar()
            toolbar.sizeToFit()
            let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
            let done = UIBarButtonItem(title: "Done", style: .done, target: context.coordinator, action: #selector(Coordinator.doneTapped(_:)))
            toolbar.items = [flex, done]
            tf.inputAccessoryView = toolbar

            return tf
        }

        func updateUIView(_ uiView: UITextField, context: Context) {
            if uiView.text != text {
                uiView.text = text
            }
            if uiView.keyboardType != keyboardType {
                uiView.keyboardType = keyboardType
            }
        }
    }

    private func ensureBaseDirectories() {
        let fm = FileManager.default
        let root = serversRoot()
        if !fm.fileExists(atPath: root) {
            try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        }
    }

    private func serversRoot() -> String {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? ""
        return (docs as NSString).appendingPathComponent("servers")
    }

    private func openVersionPicker() {
        versionFetchError = nil
        if availableVersions.isEmpty {
            fetchVersions(force: true) {
                showVersionPicker = true
            }
        } else {
            showVersionPicker = true
        }
    }

    private func normalizeIcon(_ img: UIImage) -> UIImage {
        let target = CGSize(width: 64, height: 64)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let r = UIGraphicsImageRenderer(size: target, format: format)
        return r.image { ctx in
            UIColor.clear.setFill()
            ctx.fill(CGRect(origin: .zero, size: target))
            img.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    private func fetchVersions(force: Bool, completion: (() -> Void)? = nil) {
        if loadingVersions { return }
        if !force, !availableVersions.isEmpty { completion?(); return }

        loadingVersions = true
        let urlString = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"
        guard let url = URL(string: urlString) else {
            loadingVersions = false
            versionFetchError = "Invalid version URL"
            return
        }

        URLSession.shared.dataTask(with: url) { data, response, error in
            func finish(_ versions: [String], _ err: String?) {
                DispatchQueue.main.async {
                    self.loadingVersions = false
                    if let err = err { self.versionFetchError = err }
                    if !versions.isEmpty { self.availableVersions = versions }
                    completion?()
                }
            }

            if let error = error {
                finish([], "Failed to load versions: \(error.localizedDescription)")
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let versions = json["versions"] as? [[String: Any]]
            else {
                finish([], "Failed to parse version list")
                return
            }

            var releases: [String] = []
            var snapshots: [String] = []
            for v in versions {
                guard let id = v["id"] as? String else { continue }
                let type = (v["type"] as? String) ?? ""
                if type == "release" { releases.append(id) }
                else { snapshots.append(id) }
            }
            finish(releases + snapshots, nil)
        }.resume()
    }

    private func createServer() {
        if software == .forge || software == .neoforge {
            pendingCreateServer = true
            showForgeWarning = true
            return
        }
        createServerConfirmed()
    }

    private func createServerConfirmed() {
        if isCreating { return }

        let fm = FileManager.default
        var name = serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "Server" }

        if mcVersion.isEmpty && software != .customJar { return }
        if software == .customJar && customJarURL == nil { return }

        let root = serversRoot()
        var dir = (root as NSString).appendingPathComponent(name)
        if fm.fileExists(atPath: dir) {
            for i in 2..<1000 {
                let candidate = (root as NSString).appendingPathComponent("\(name) \(i)")
                if !fm.fileExists(atPath: candidate) { dir = candidate; break }
            }
        }
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        if let icon = serverIcon, let png = icon.pngData() {
            let p = (dir as NSString).appendingPathComponent("server-icon.png")
            try? png.write(to: URL(fileURLWithPath: p))
        }

        var props: [String: String] = [:]
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if !trim(maxPlayers).isEmpty { props["max-players"] = trim(maxPlayers) }
        if !trim(viewDistance).isEmpty { props["view-distance"] = trim(viewDistance) }
        if !trim(simulationDistance).isEmpty { props["simulation-distance"] = trim(simulationDistance) }
        if !trim(spawnProtection).isEmpty { props["spawn-protection"] = trim(spawnProtection) }
        props["white-list"] = whitelist ? "true" : "false"
        if !trim(motd).isEmpty { props["motd"] = trim(motd) }
        if !trim(seed).isEmpty { props["level-seed"] = trim(seed) }
        if !props.isEmpty {
            var out = "# Managed by JESSI\n"
            for k in props.keys.sorted() { out += "\(k)=\(props[k]!)\n" }
            let p = (dir as NSString).appendingPathComponent("server.properties")
            try? out.write(toFile: p, atomically: true, encoding: .utf8)
        }

        if software == .customJar, let url = customJarURL {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let dest = URL(fileURLWithPath: (dir as NSString).appendingPathComponent("server.jar"))
            try? fm.removeItem(at: dest)
            _ = try? fm.copyItem(at: url, to: dest)
        }

        isCreating = true
        createStatus = "Preparing..."

        let serverDirURL = URL(fileURLWithPath: dir, isDirectory: true)
        let selectedVersion = mcVersion

        if software == .customJar {
            finishCreate(success: true)
            return
        }

        installSoftware(software: software, mcVersion: selectedVersion, serverDir: serverDirURL) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.finishCreate(success: true)
                case .failure(let err):
                    self.isCreating = false
                    self.createError = err.localizedDescription
                    self.showCreateError = true
                }
            }
        }
    }

    private func finishCreate(success: Bool) {
        isCreating = false
        createStatus = ""
        if success {
            NotificationCenter.default.post(name: Notification.Name("JessiServersChanged"), object: nil)
            presentation.wrappedValue.dismiss()
        }
    }

    private enum InstallerError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self {
            case .message(let m): return m
            }
        }
    }

    private func installSoftware(
        software: ServerSoftwareSwift,
        mcVersion: String,
        serverDir: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        switch software {
        case .vanilla:
            setStatus("Downloading Vanilla...")
            downloadVanillaServerJar(mcVersion: mcVersion, to: serverDir, completion: completion)
        case .fabric:
            setStatus("Downloading Fabric...")
            downloadFabricServerJar(mcVersion: mcVersion, to: serverDir, completion: completion)
        case .quilt:
            setStatus("Downloading Quilt...")
            downloadQuiltServerJar(mcVersion: mcVersion, to: serverDir, completion: completion)
        case .forge:
            setStatus("Installing Forge...")
            installForge(mcVersion: mcVersion, to: serverDir, completion: completion)
        case .neoforge:
            setStatus("Installing NeoForge...")
            installNeoForge(mcVersion: mcVersion, to: serverDir, completion: completion)
        case .customJar:
            completion(.success(()))
        }
    }

    private func setStatus(_ s: String) {
        DispatchQueue.main.async {
            self.createStatus = s
        }
    }

    private func downloadFile(_ url: URL, to dest: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        let task = URLSession.shared.downloadTask(with: url) { tmpURL, _, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let tmpURL = tmpURL else {
                completion(.failure(InstallerError.message("Download failed (no temp file).")))
                return
            }
            do {
                let fm = FileManager.default
                try? fm.removeItem(at: dest)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: tmpURL, to: dest)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
        task.resume()
    }

    private func fetchJSON(_ url: URL, completion: @escaping (Result<Any, Error>) -> Void) {
        URLSession.shared.dataTask(with: url) { data, _, error in
            if let error = error { completion(.failure(error)); return }
            guard let data = data else { completion(.failure(InstallerError.message("Empty response"))); return }
            do {
                let json = try JSONSerialization.jsonObject(with: data, options: [])
                completion(.success(json))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private func downloadVanillaServerJar(mcVersion: String, to serverDir: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let manifestURL = URL(string: "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json") else {
            completion(.failure(InstallerError.message("Invalid Mojang manifest URL")))
            return
        }

        fetchJSON(manifestURL) { result in
            switch result {
            case .failure(let err): completion(.failure(err))
            case .success(let json):
                guard let dict = json as? [String: Any],
                      let versions = dict["versions"] as? [[String: Any]]
                else {
                    completion(.failure(InstallerError.message("Failed to parse Mojang version list")))
                    return
                }

                guard let versionEntry = versions.first(where: { ($0["id"] as? String) == mcVersion }),
                      let versionInfoURLString = versionEntry["url"] as? String,
                      let versionInfoURL = URL(string: versionInfoURLString)
                else {
                    completion(.failure(InstallerError.message("Could not find version metadata for \(mcVersion)")))
                    return
                }

                self.fetchJSON(versionInfoURL) { res2 in
                    switch res2 {
                    case .failure(let err): completion(.failure(err))
                    case .success(let json2):
                        guard let d2 = json2 as? [String: Any],
                              let downloads = d2["downloads"] as? [String: Any],
                              let server = downloads["server"] as? [String: Any],
                              let serverURLString = server["url"] as? String,
                              let serverURL = URL(string: serverURLString)
                        else {
                            completion(.failure(InstallerError.message("Version \(mcVersion) does not include a server download.")))
                            return
                        }

                        let dest = serverDir.appendingPathComponent("server.jar")
                        self.downloadFile(serverURL, to: dest, completion: completion)
                    }
                }
            }
        }
    }

    private func downloadFabricServerJar(mcVersion: String, to serverDir: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let loaderListURL = URL(string: "https://meta.fabricmc.net/v2/versions/loader/\(mcVersion)") else {
            completion(.failure(InstallerError.message("Invalid Fabric loader URL")))
            return
        }
        guard let installerListURL = URL(string: "https://meta.fabricmc.net/v2/versions/installer") else {
            completion(.failure(InstallerError.message("Invalid Fabric installer URL")))
            return
        }

        fetchJSON(loaderListURL) { loaderRes in
            switch loaderRes {
            case .failure(let err): completion(.failure(err))
            case .success(let json):
                guard let arr = json as? [[String: Any]], !arr.isEmpty else {
                    completion(.failure(InstallerError.message("No Fabric loader versions found for \(mcVersion)")))
                    return
                }

                func loaderVersion(from item: [String: Any]) -> String? {
                    guard let loader = item["loader"] as? [String: Any] else { return nil }
                    return loader["version"] as? String
                }
                func loaderStable(from item: [String: Any]) -> Bool {
                    guard let loader = item["loader"] as? [String: Any] else { return false }
                    return (loader["stable"] as? Bool) ?? false
                }

                let chosenLoader = arr.first(where: { loaderStable(from: $0) }) ?? arr.first!
                guard let loaderVersion = loaderVersion(from: chosenLoader) else {
                    completion(.failure(InstallerError.message("Failed to pick Fabric loader version")))
                    return
                }

                self.fetchJSON(installerListURL) { installerRes in
                    switch installerRes {
                    case .failure(let err): completion(.failure(err))
                    case .success(let json2):
                        guard let installers = json2 as? [[String: Any]], !installers.isEmpty else {
                            completion(.failure(InstallerError.message("No Fabric installer versions found")))
                            return
                        }
                        let chosenInstaller = installers.first(where: { ($0["stable"] as? Bool) == true }) ?? installers.first!
                        guard let installerVersion = chosenInstaller["version"] as? String else {
                            completion(.failure(InstallerError.message("Failed to pick Fabric installer version")))
                            return
                        }

                        guard let jarURL = URL(string: "https://meta.fabricmc.net/v2/versions/loader/\(mcVersion)/\(loaderVersion)/\(installerVersion)/server/jar") else {
                            completion(.failure(InstallerError.message("Invalid Fabric server jar URL")))
                            return
                        }

                        let dest = serverDir.appendingPathComponent("server.jar")
                        self.downloadFile(jarURL, to: dest, completion: completion)
                    }
                }
            }
        }
    }

    private func downloadQuiltServerJar(mcVersion: String, to serverDir: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let loaderListURL = URL(string: "https://meta.quiltmc.org/v3/versions/loader/\(mcVersion)") else {
            completion(.failure(InstallerError.message("Invalid Quilt loader URL")))
            return
        }
        guard let installerListURL = URL(string: "https://meta.quiltmc.org/v3/versions/installer") else {
            completion(.failure(InstallerError.message("Invalid Quilt installer URL")))
            return
        }

        fetchJSON(loaderListURL) { loaderRes in
            switch loaderRes {
            case .failure(let err): completion(.failure(err))
            case .success(let json):
                guard let arr = json as? [[String: Any]], !arr.isEmpty else {
                    completion(.failure(InstallerError.message("No Quilt loader versions found for \(mcVersion)")))
                    return
                }

                func loaderVersion(from item: [String: Any]) -> String? {
                    guard let loader = item["loader"] as? [String: Any] else { return nil }
                    return loader["version"] as? String
                }

                guard let quiltLoaderVersion = loaderVersion(from: arr.first!) else {
                    completion(.failure(InstallerError.message("Failed to pick Quilt loader version")))
                    return
                }

                self.fetchJSON(installerListURL) { installerRes in
                    switch installerRes {
                    case .failure(let err): completion(.failure(err))
                    case .success(let json2):
                        guard let installers = json2 as? [[String: Any]], !installers.isEmpty else {
                            completion(.failure(InstallerError.message("No Quilt installer versions found")))
                            return
                        }

                        let chosenInstaller = installers.first(where: { ($0["stable"] as? Bool) == true }) ?? installers.first!
                        guard let installerVersion = chosenInstaller["version"] as? String else {
                            completion(.failure(InstallerError.message("Failed to pick Quilt installer version")))
                            return
                        }

                        guard let jarURL = URL(string: "https://meta.quiltmc.org/v3/versions/loader/\(mcVersion)/\(quiltLoaderVersion)/\(installerVersion)/server/jar") else {
                            completion(.failure(InstallerError.message("Invalid Quilt server jar URL")))
                            return
                        }

                        let dest = serverDir.appendingPathComponent("server.jar")
                        self.downloadFile(jarURL, to: dest, completion: completion)
                    }
                }
            }
        }
    }

    private func installForge(mcVersion: String, to serverDir: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let promosURL = URL(string: "https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json") else {
            completion(.failure(InstallerError.message("Invalid Forge promotions URL")))
            return
        }

        fetchJSON(promosURL) { res in
            switch res {
            case .failure(let err): completion(.failure(err))
            case .success(let json):
                guard let dict = json as? [String: Any],
                      let promos = dict["promos"] as? [String: Any]
                else {
                    completion(.failure(InstallerError.message("Failed to parse Forge promotions")))
                    return
                }

                let latestKey = "\(mcVersion)-latest"
                let recommendedKey = "\(mcVersion)-recommended"
                let forgeVersion = (promos[latestKey] as? String) ?? (promos[recommendedKey] as? String)
                guard let forgeVersion = forgeVersion, !forgeVersion.isEmpty else {
                    completion(.failure(InstallerError.message("Forge does not provide builds for \(mcVersion).")))
                    return
                }

                let artifactVersion = "\(mcVersion)-\(forgeVersion)"
                guard let installerURL = URL(string: "https://maven.minecraftforge.net/net/minecraftforge/forge/\(artifactVersion)/forge-\(artifactVersion)-installer.jar") else {
                    completion(.failure(InstallerError.message("Invalid Forge installer URL")))
                    return
                }

                let installerDest = serverDir.appendingPathComponent("forge-installer.jar")
                self.downloadFile(installerURL, to: installerDest) { dlRes in
                    switch dlRes {
                    case .failure(let err): completion(.failure(err))
                    case .success:
                        self.runInstallerJar(installerJar: installerDest, serverDir: serverDir, completion: completion)
                    }
                }
            }
        }
    }

    private func installNeoForge(mcVersion: String, to serverDir: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let metadataURL = URL(string: "https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml") else {
            completion(.failure(InstallerError.message("Invalid NeoForge metadata URL")))
            return
        }

        URLSession.shared.dataTask(with: metadataURL) { data, _, error in
            if let error = error { completion(.failure(error)); return }
            guard let data = data, let xml = String(data: data, encoding: .utf8), !xml.isEmpty else {
                completion(.failure(InstallerError.message("NeoForge metadata is empty")))
                return
            }

            let prefix = self.neoForgePrefix(forMinecraftVersion: mcVersion)
            let versions = self.extractMavenVersions(from: xml)
            let candidates = versions.filter { $0.hasPrefix(prefix) }
            guard let chosen = candidates.last ?? versions.last else {
                completion(.failure(InstallerError.message("Could not determine a NeoForge version")))
                return
            }

            guard let installerURL = URL(string: "https://maven.neoforged.net/releases/net/neoforged/neoforge/\(chosen)/neoforge-\(chosen)-installer.jar") else {
                completion(.failure(InstallerError.message("Invalid NeoForge installer URL")))
                return
            }

            let installerDest = serverDir.appendingPathComponent("neoforge-installer.jar")
            self.downloadFile(installerURL, to: installerDest) { dlRes in
                switch dlRes {
                case .failure(let err): completion(.failure(err))
                case .success:
                    self.runInstallerJar(installerJar: installerDest, serverDir: serverDir, completion: completion)
                }
            }
        }.resume()
    }

    private func neoForgePrefix(forMinecraftVersion mc: String) -> String {
        let parts = mc.split(separator: ".")
        guard parts.count >= 3 else { return "" }
        if parts[0] == "1" {
            return "\(parts[1]).\(parts[2])."
        }
        return "\(parts[0]).\(parts[1])."
    }

    private func extractMavenVersions(from xml: String) -> [String] {
        var out: [String] = []
        var searchRange = xml.startIndex..<xml.endIndex
        while let start = xml.range(of: "<version>", options: [], range: searchRange),
              let end = xml.range(of: "</version>", options: [], range: start.upperBound..<xml.endIndex) {
            let v = String(xml[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { out.append(v) }
            searchRange = end.upperBound..<xml.endIndex
        }
        return out
    }

    private func runInstallerJar(installerJar: URL, serverDir: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        func completeOnMain(_ result: Result<Void, Error>) {
            DispatchQueue.main.async {
                completion(result)
            }
        }

        let argsPath = serverDir.appendingPathComponent("jessi-installer-args.txt")
        do {
            try "--installServer\n".write(to: argsPath, atomically: true, encoding: .utf8)
        } catch {
            completeOnMain(.failure(error))
            return
        }

        let javaVersion = JessiSettings.shared().javaVersion
        DispatchQueue.global(qos: .userInitiated).async {
            let code = self.runJavaTool(jarPath: installerJar.path, javaVersion: javaVersion, workingDir: serverDir.path, argsPath: argsPath.path)
            if code != 0 {
                completeOnMain(.failure(InstallerError.message("Installer failed with exit code \(code). Try a different Java version in Settings.")))
                return
            }

            guard let unixArgsRel = self.findUnixArgsRelativePath(serverDir: serverDir) else {
                completeOnMain(.failure(InstallerError.message("Installed, but couldn't find unix_args.txt (Forge/NeoForge launcher args).")))
                return
            }

            let launchArgs = "@\(unixArgsRel)\nnogui\n"
            do {
                try launchArgs.write(to: serverDir.appendingPathComponent("jessi-launch-args.txt"), atomically: true, encoding: .utf8)
                completeOnMain(.success(()))
            } catch {
                completeOnMain(.failure(error))
            }
        }
    }

    private func findUnixArgsRelativePath(serverDir: URL) -> String? {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: serverDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        for case let url as URL in e {
            if url.lastPathComponent == "unix_args.txt" {
                let rel = url.path.replacingOccurrences(of: serverDir.path + "/", with: "")
                return rel
            }
        }
        return nil
    }

    private func runJavaTool(jarPath: String, javaVersion: String, workingDir: String, argsPath: String?) -> Int32 {
        let a0 = strdup("--tool")
        let a1 = strdup(jarPath)
        let a2 = strdup(javaVersion)
        let a3 = strdup(workingDir)
        let a4 = argsPath != nil ? strdup(argsPath!) : nil
        defer {
            free(a0); free(a1); free(a2); free(a3)
            if let a4 = a4 { free(a4) }
        }

        if let a4 = a4 {
            var argv: [UnsafeMutablePointer<CChar>?] = [a0, a1, a2, a3, a4, nil]
            return argv.withUnsafeMutableBufferPointer { buf in
                Int32(jessi_tool_main(5, buf.baseAddress))
            }
        }

        var argv: [UnsafeMutablePointer<CChar>?] = [a0, a1, a2, a3, nil]
        return argv.withUnsafeMutableBufferPointer { buf in
            Int32(jessi_tool_main(4, buf.baseAddress))
        }
    }
}
