import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum ServerSoftwareSwift: String, CaseIterable, Identifiable {
    case vanilla = "Vanilla"
    case paper = "Paper"
    case forge = "Forge"
    case neoforge = "NeoForge"
    case fabric = "Fabric"
    case quilt = "Quilt"
    case customJar = "Custom Jar"
    var id: String { rawValue }
}

struct CreateServerView: View {
    @State private var software: ServerSoftwareSwift = .vanilla
    @State private var previousSoftware: ServerSoftwareSwift = .vanilla
    @State private var serverName: String = ""

    @State private var mcVersion: String = ""
    @State private var availableVersions: [String] = []
    @State private var loadingVersions: Bool = false
    @State private var versionFetchError: String? = nil

    @State private var showSoftwareMenu: Bool = false
    @State private var showVersionMenu: Bool = false
    @State private var softwareAnchorFrame: CGRect = .zero
    @State private var versionAnchorFrame: CGRect = .zero

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

    @State private var jarImportError: String? = nil
    @State private var showJarImportError: Bool = false

    @State private var showForgeWarning: Bool = false
    @State private var pendingCreateServer: Bool = false

    @Environment(\.presentationMode) private var presentation

    private var menuAnimation: Animation {
        .spring(response: 0.28, dampingFraction: 0.88, blendDuration: 0.12)
    }

    private struct DocumentPicker: UIViewControllerRepresentable {
        let contentTypes: [UTType]
        let onPick: (URL) -> Void
        let onCancel: () -> Void

        func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
            picker.delegate = context.coordinator
            return picker
        }

        func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

        func makeCoordinator() -> Coordinator {
            Coordinator(onPick: onPick, onCancel: onCancel)
        }

        class Coordinator: NSObject, UIDocumentPickerDelegate {
            let onPick: (URL) -> Void
            let onCancel: () -> Void

            init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
                self.onPick = onPick
                self.onCancel = onCancel
            }

            func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
                guard let url = urls.first else { return }
                onPick(url)
            }

            func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
                onCancel()
            }
        }
    }

    private struct ImagePicker: UIViewControllerRepresentable {
        let onPick: (UIImage) -> Void
        let onCancel: () -> Void

        func makeUIViewController(context: Context) -> UIImagePickerController {
            let picker = UIImagePickerController()
            picker.sourceType = .photoLibrary
            picker.delegate = context.coordinator
            return picker
        }

        func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

        func makeCoordinator() -> Coordinator {
            Coordinator(onPick: onPick, onCancel: onCancel)
        }

        class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
            let onPick: (UIImage) -> Void
            let onCancel: () -> Void

            init(onPick: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
                self.onPick = onPick
                self.onCancel = onCancel
            }

            func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
                if let image = info[.originalImage] as? UIImage {
                    onPick(image)
                }
            }

            func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
                onCancel()
            }
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            List {
                Section(header: Text("Required Settings")) {
                    Button(action: {
                        withAnimation(menuAnimation) {
                            showVersionMenu = false
                            showSoftwareMenu = true
                        }
                    }) {
                        HStack {
                            Text("Software")
                                .foregroundColor(.primary)
                            Spacer()
                            Text(software.rawValue)
                                .foregroundColor(.green)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .background(FrameReporter(id: "software"))
                    .accessibilityLabel(Text("Software"))
                    .accessibilityValue(Text(software.rawValue))


                    TextField("Server Name", text: $serverName)

                    if software == .customJar {
                        Button(action: { showingJarImporter = true }) {
                            HStack {
                                Text("Custom Jar")
                                    .foregroundColor(.primary)
                                Spacer()
                                Text(customJarURL == nil ? "Select..." : (customJarURL!.lastPathComponent))
                                    .foregroundColor(.green)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())
                    } else {
                        if loadingVersions {
                            HStack {
                                Text("Minecraft Version")
                                Spacer()
                                Text("Loading...")
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            Button(action: { openVersionMenu() }) {
                                HStack {
                                    Text("Minecraft Version")
                                        .foregroundColor(.primary)
                                    Spacer()
                                    Text(mcVersion.isEmpty ? "Select..." : mcVersion)
                                        .foregroundColor(.green)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PlainButtonStyle())
                            .background(FrameReporter(id: "version"))
                        }
                        if let err = versionFetchError {
                            Text(err)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }

                }

                Section(header: Text("Server Icon (Optional)")) {
                    Button(action: { showingIconImporter = true }) {
                        HStack {
                            Text("Import server icon")
                                .foregroundColor(.primary)
                            Spacer()
                            Text(serverIcon == nil ? "Select..." : "Selected")
                                .foregroundColor(.green)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
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

                Section {
                    Color.clear
                        .frame(height: 15)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Server Setup")
            .navigationBarTitleDisplayMode(.inline)

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
            .cornerRadius(14)
            .shadow(color: Color.black.opacity(0.5), radius: 8, x: 0, y: 4)
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .onPreferenceChange(FramePreferenceKey.self) { frames in
            if let f = frames["software"] { self.softwareAnchorFrame = f }
            if let f = frames["version"] { self.versionAnchorFrame = f }
        }
        .overlay(
            Group {
                if showSoftwareMenu {
                    DropdownOverlay(
                        isPresented: $showSoftwareMenu,
                        anchorFrame: softwareAnchorFrame,
                        items: softwareDropdownItems,
                        maxVisibleRows: 5.5
                    )
                }
                if showVersionMenu {
                    DropdownOverlay(
                        isPresented: $showVersionMenu,
                        anchorFrame: versionAnchorFrame,
                        items: versionDropdownItems,
                        maxVisibleRows: 5.5
                    )
                }
            }
        )
        .onAppear { ensureBaseDirectories() }
        .onChange(of: software) { newValue in
            if newValue == .customJar {
                mcVersion = ""
                availableVersions = []
                versionFetchError = nil
            } else {
                customJarURL = nil
            }

            if previousSoftware != newValue, newValue != .customJar {
                mcVersion = ""
                availableVersions = []
                versionFetchError = nil
            }

            previousSoftware = newValue
        }
        .sheet(isPresented: $showingJarImporter) {
            DocumentPicker(contentTypes: [.data], onPick: { url in
                importCustomJar(from: url)
                showingJarImporter = false
            }, onCancel: {
                showingJarImporter = false
            })
        }
        .sheet(isPresented: $showingIconImporter) {
            ImagePicker(onPick: { image in
                serverIcon = normalizeIcon(image)
                showingIconImporter = false
            }, onCancel: {
                showingIconImporter = false
            })
        }
        .alert(isPresented: $showCreateError) {
            Alert(
                title: Text("Create Server Failed"),
                message: Text(createError ?? "Unknown error"),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert(isPresented: $showJarImportError) {
            Alert(
                title: Text("Import Failed"),
                message: Text(jarImportError ?? "Unknown error"),
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

    private func importCustomJar(from pickedURL: URL) {
        let ext = pickedURL.pathExtension.lowercased()
        guard ext == "jar" else {
            jarImportError = "Please select a .jar file."
            showJarImportError = true
            return
        }

        let scoped = pickedURL.startAccessingSecurityScopedResource()
        defer { if scoped { pickedURL.stopAccessingSecurityScopedResource() } }

        do {
            let fm = FileManager.default
            let cachesDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? fm.temporaryDirectory
            let importsDir = cachesDir.appendingPathComponent("ImportedJars", isDirectory: true)
            try fm.createDirectory(at: importsDir, withIntermediateDirectories: true)

            let destURL = importsDir.appendingPathComponent(pickedURL.lastPathComponent)
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }

            do {
                try fm.copyItem(at: pickedURL, to: destURL)
            } catch {
                let data = try Data(contentsOf: pickedURL)
                try data.write(to: destURL, options: .atomic)
            }

            customJarURL = destURL
        } catch {
            jarImportError = error.localizedDescription
            showJarImportError = true
        }
    }

    private var softwareDropdownItems: [DropdownItem] {
        ServerSoftwareSwift.allCases.map { s in
            DropdownItem(
                id: s.rawValue,
                title: s.rawValue,
                isSelected: s == software,
                isEnabled: true,
                systemImage: nil,
                tint: nil,
                action: {
                    software = s
                }
            )
        }
    }

    private var versionDropdownItems: [DropdownItem] {
        var items: [DropdownItem] = []

        if loadingVersions {
            items.append(
                DropdownItem(
                    id: "loading",
                    title: "Loading...",
                    isSelected: false,
                    isEnabled: false,
                    systemImage: nil,
                    tint: .secondary,
                    action: { }
                )
            )
        }

        for v in availableVersions.prefix(400) {
            items.append(
                DropdownItem(
                    id: v,
                    title: v,
                    isSelected: v == mcVersion,
                    isEnabled: true,
                    systemImage: nil,
                    tint: nil,
                    action: {
                        mcVersion = v
                    }
                )
            )
        }

        if availableVersions.isEmpty, !loadingVersions {
            items.append(
                DropdownItem(
                    id: "empty",
                    title: "No versions loaded",
                    isSelected: false,
                    isEnabled: false,
                    systemImage: nil,
                    tint: .secondary,
                    action: { }
                )
            )
        }

        return items
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

    private func openVersionMenu() {
        versionFetchError = nil

        if showVersionMenu {
            withAnimation(menuAnimation) {
                showVersionMenu = false
            }
            return
        }

        if availableVersions.isEmpty {
            fetchVersions(force: true) {
                withAnimation(menuAnimation) {
                    showSoftwareMenu = false
                    showVersionMenu = true
                }
            }
        } else {
            withAnimation(menuAnimation) {
                showSoftwareMenu = false
                showVersionMenu = true
            }
        }
    }

    private struct DropdownItem: Identifiable {
        let id: String
        let title: String
        let isSelected: Bool
        let isEnabled: Bool
        let systemImage: String?
        let tint: Color?
        let action: () -> Void
    }

    private struct FramePreferenceKey: PreferenceKey {
        static var defaultValue: [String: CGRect] = [:]
        static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { _, new in new })
        }
    }

    private struct FrameReporter: View {
        let id: String
        var body: some View {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: FramePreferenceKey.self, value: [id: proxy.frame(in: .global)])
            }
        }
    }

    private struct DropdownOverlay: View {
        @Binding var isPresented: Bool
        let anchorFrame: CGRect
        let items: [DropdownItem]
        let maxVisibleRows: Double

        @State private var menuVisible: Bool = false

        private let rowHeight: CGFloat = 44
        private let maxWidth: CGFloat = 280
        private let minWidth: CGFloat = 220
        private let edgePadding: CGFloat = 12
        private let verticalGap: CGFloat = 4
        private let proximityAdjust: CGFloat = 100

        private func resolvedAnchor(in screen: CGRect) -> CGRect {
            if anchorFrame == .zero {
                return CGRect(x: screen.midX, y: screen.midY, width: 0, height: 0)
            }
            return anchorFrame
        }

        private func animateIn() {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88, blendDuration: 0.12)) {
                menuVisible = true
            }
        }

        private func dismiss() {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.92, blendDuration: 0.10)) {
                menuVisible = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                isPresented = false
            }
        }

        var body: some View {
            let screen = UIScreen.main.bounds
            let anchor = resolvedAnchor(in: screen)
            let preferred = max(minWidth, min(maxWidth, anchor.width * 0.62))
            let width = min(preferred, screen.width - (edgePadding * 2))
            let visibleRows = min(CGFloat(maxVisibleRows), CGFloat(max(items.count, 1)))
            let menuHeight = max(rowHeight, visibleRows * rowHeight)

            let x = min(max(anchor.maxX - (width / 2), (width / 2) + edgePadding), screen.width - (width / 2) - edgePadding)

            let belowCenterY = anchor.maxY + (menuHeight / 2) + verticalGap - proximityAdjust
            let aboveCenterY = anchor.minY - (menuHeight / 2) - verticalGap + proximityAdjust
            let canFitBelow = (belowCenterY + (menuHeight / 2)) <= (screen.height - edgePadding)
            let y: CGFloat = canFitBelow
                ? belowCenterY
                : max(aboveCenterY, (menuHeight / 2) + edgePadding)

            return ZStack {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismiss()
                    }

                Rectangle()
                    .fill(Color.black.opacity(0.001))
                    .frame(width: anchor.width, height: anchor.height)
                    .position(x: anchor.midX, y: anchor.midY)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismiss()
                    }

                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(items) { item in
                                Button(action: {
                                    item.action()
                                    dismiss()
                                }) {
                                    HStack(spacing: 10) {
                                        if let img = item.systemImage {
                                            Image(systemName: img)
                                                .foregroundColor(item.tint ?? .primary)
                                        }

                                        Text(item.title)
                                            .foregroundColor(item.tint ?? .primary)
                                            .lineLimit(1)

                                        Spacer(minLength: 10)

                                        if item.isSelected {
                                            Image(systemName: "checkmark")
                                                .foregroundColor(.green)
                                        }
                                    }
                                    .padding(.horizontal, 14)
                                    .frame(height: rowHeight)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(PlainButtonStyle())
                                .disabled(!item.isEnabled)

                                Divider().background(Color(UIColor.separator))
                            }
                        }
                    }
                    .frame(maxHeight: CGFloat(maxVisibleRows) * rowHeight)
                }
                .frame(width: width)
                .background(
                    Color(UIColor.secondarySystemBackground)
                        .overlay(Color(UIColor.systemBackground).opacity(0.06))
                )
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.black.opacity(0.07), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.16), radius: 18, x: 0, y: 10)
                .scaleEffect(menuVisible ? 1 : 0.01, anchor: .topTrailing)
                .opacity(menuVisible ? 1 : 0)
                .position(x: x, y: y)
                .onAppear { animateIn() }
            }
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

        func finishOnMain(_ versions: [String], _ err: String?) {
            DispatchQueue.main.async {
                self.loadingVersions = false
                if let err = err { self.versionFetchError = err }
                if !versions.isEmpty { self.availableVersions = versions }
                completion?()
            }
        }

        if software == .customJar {
            finishOnMain([], nil)
            return
        }

        switch software {
        case .paper:
            guard let url = URL(string: "https://api.papermc.io/v2/projects/paper") else {
                finishOnMain([], "Invalid Paper version URL")
                return
            }
            fetchJSON(url) { result in
                switch result {
                case .failure(let err):
                    finishOnMain([], "Failed to load Paper versions: \(err.localizedDescription)")
                case .success(let json):
                    guard let dict = json as? [String: Any],
                          let versions = dict["versions"] as? [String]
                    else {
                        finishOnMain([], "Failed to parse Paper version list")
                        return
                    }
                    finishOnMain(Array(versions.reversed()), nil)
                }
            }
            return

        case .fabric:
            guard let url = URL(string: "https://meta.fabricmc.net/v2/versions/game") else {
                finishOnMain([], "Invalid Fabric version URL")
                return
            }
            fetchJSON(url) { result in
                switch result {
                case .failure(let err):
                    finishOnMain([], "Failed to load Fabric versions: \(err.localizedDescription)")
                case .success(let json):
                    guard let arr = json as? [[String: Any]] else {
                        finishOnMain([], "Failed to parse Fabric version list")
                        return
                    }
                    let versions: [String] = arr.compactMap { $0["version"] as? String }
                    let stable = Set(arr.compactMap { (($0["stable"] as? Bool) == true) ? ($0["version"] as? String) : nil })
                    let sorted = versions.sorted { a, b in
                        let sa = stable.contains(a)
                        let sb = stable.contains(b)
                        if sa != sb { return sa && !sb }
                        return self.isVersionHigher(a, than: b)
                    }
                    finishOnMain(sorted, nil)
                }
            }
            return

        case .quilt:
            guard let url = URL(string: "https://meta.quiltmc.org/v3/versions/game") else {
                finishOnMain([], "Invalid Quilt version URL")
                return
            }
            fetchJSON(url) { result in
                switch result {
                case .failure(let err):
                    finishOnMain([], "Failed to load Quilt versions: \(err.localizedDescription)")
                case .success(let json):
                    guard let arr = json as? [[String: Any]] else {
                        finishOnMain([], "Failed to parse Quilt version list")
                        return
                    }
                    let versions: [String] = arr.compactMap { $0["version"] as? String }
                    let stable = Set(arr.compactMap { (($0["stable"] as? Bool) == true) ? ($0["version"] as? String) : nil })
                    let sorted = versions.sorted { a, b in
                        let sa = stable.contains(a)
                        let sb = stable.contains(b)
                        if sa != sb { return sa && !sb }
                        return self.isVersionHigher(a, than: b)
                    }
                    finishOnMain(sorted, nil)
                }
            }
            return

        case .forge:
            guard let promosURL = URL(string: "https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json") else {
                finishOnMain([], "Invalid Forge promotions URL")
                return
            }
            fetchJSON(promosURL) { promoRes in
                switch promoRes {
                case .failure(let err):
                    finishOnMain([], "Failed to load Forge versions: \(err.localizedDescription)")
                case .success(let json):
                    guard let dict = json as? [String: Any],
                          let promos = dict["promos"] as? [String: Any]
                    else {
                        finishOnMain([], "Failed to parse Forge promotions")
                        return
                    }

                    var supported = Set<String>()
                    for key in promos.keys {
                        if let idx = key.firstIndex(of: "-") {
                            supported.insert(String(key[..<idx]))
                        }
                    }

                    guard let manifestURL = URL(string: "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json") else {
                        finishOnMain([], "Invalid Mojang manifest URL")
                        return
                    }
                    self.fetchJSON(manifestURL) { manRes in
                        switch manRes {
                        case .failure(let err):
                            finishOnMain([], "Failed to load versions: \(err.localizedDescription)")
                        case .success(let json2):
                            guard let m = json2 as? [String: Any],
                                  let versions = m["versions"] as? [[String: Any]]
                            else {
                                finishOnMain([], "Failed to parse version list")
                                return
                            }
                            var releases: [String] = []
                            for v in versions {
                                guard let id = v["id"] as? String else { continue }
                                let type = (v["type"] as? String) ?? ""
                                if type == "release", supported.contains(id) {
                                    releases.append(id)
                                }
                            }
                            finishOnMain(releases, nil)
                        }
                    }
                }
            }
            return

        case .neoforge:
            guard let metadataURL = URL(string: "https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml") else {
                finishOnMain([], "Invalid NeoForge metadata URL")
                return
            }

            fetchText(metadataURL) { metaRes in
                switch metaRes {
                case .failure(let err):
                    finishOnMain([], "Failed to load NeoForge versions: \(err.localizedDescription)")
                case .success(let xml):
                    let neoVersions = self.extractMavenVersions(from: xml)
                    var supportedMinorPatch = Set<String>()
                    for v in neoVersions {
                        let parts = v.split(separator: ".")
                        if parts.count >= 2 {
                            supportedMinorPatch.insert("\(parts[0]).\(parts[1])")
                        }
                    }

                    guard let manifestURL = URL(string: "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json") else {
                        finishOnMain([], "Invalid Mojang manifest URL")
                        return
                    }
                    self.fetchJSON(manifestURL) { manRes in
                        switch manRes {
                        case .failure(let err):
                            finishOnMain([], "Failed to load versions: \(err.localizedDescription)")
                        case .success(let json2):
                            guard let m = json2 as? [String: Any],
                                  let versions = m["versions"] as? [[String: Any]]
                            else {
                                finishOnMain([], "Failed to parse version list")
                                return
                            }

                            var releases: [String] = []
                            for v in versions {
                                guard let id = v["id"] as? String else { continue }
                                let type = (v["type"] as? String) ?? ""
                                if type != "release" { continue }

                                let comps = id.split(separator: ".")
                                if comps.count >= 3, comps[0] == "1" {
                                    let key = "\(comps[1]).\(comps[2])"
                                    if supportedMinorPatch.contains(key) {
                                        releases.append(id)
                                    }
                                }
                            }
                            finishOnMain(releases, nil)
                        }
                    }
                }
            }
            return

        case .vanilla, .customJar:
            break
        }

        let urlString = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"
        guard let url = URL(string: urlString) else {
            finishOnMain([], "Invalid version URL")
            return
        }

        URLSession.shared.dataTask(with: url) { data, _, error in
            if let error = error {
                finishOnMain([], "Failed to load versions: \(error.localizedDescription)")
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let versions = json["versions"] as? [[String: Any]]
            else {
                finishOnMain([], "Failed to parse version list")
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
            finishOnMain(releases + snapshots, nil)
        }.resume()
    }

    private func createServer() {
        if (software == .forge || software == .neoforge) && !jessi_is_trollstore_installed() {
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

        let config: [String: String] = [
            "software": software.rawValue,
            "minecraftVersion": mcVersion
        ]
        
        let configurl = URL(fileURLWithPath: (dir as NSString).appendingPathComponent("jessiserverconfig.json"))
        do {
            let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted])
            try data.write(to: configurl, options: .atomic)
        } catch {
            print("Failed to write jessiserverconfig.json: \(error.localizedDescription)")
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
        case .paper:
            setStatus("Downloading Paper...")
            downloadPaperServerJar(mcVersion: mcVersion, to: serverDir, completion: completion)
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

    private func downloadPaperServerJar(mcVersion: String, to serverDir: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let buildsURL = URL(string: "https://api.papermc.io/v2/projects/paper/versions/\(mcVersion)/builds") else {
            completion(.failure(InstallerError.message("Invalid Paper builds URL")))
            return
        }

        fetchJSON(buildsURL) { result in
            switch result {
            case .failure(let err):
                completion(.failure(err))
            case .success(let json):
                guard let dict = json as? [String: Any],
                      let builds = dict["builds"] as? [[String: Any]],
                      !builds.isEmpty
                else {
                    completion(.failure(InstallerError.message("No Paper builds found for \(mcVersion)")))
                    return
                }

                let chosen = builds.max { a, b in
                    (a["build"] as? Int ?? 0) < (b["build"] as? Int ?? 0)
                } ?? builds.last!

                guard let buildNumber = chosen["build"] as? Int else {
                    completion(.failure(InstallerError.message("Failed to parse Paper build number")))
                    return
                }

                var downloadName: String? = nil
                if let downloads = chosen["downloads"] as? [String: Any],
                   let app = downloads["application"] as? [String: Any],
                   let name = app["name"] as? String {
                    downloadName = name
                }

                let name = downloadName ?? "paper-\(mcVersion)-\(buildNumber).jar"
                let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name

                guard let jarURL = URL(string: "https://api.papermc.io/v2/projects/paper/versions/\(mcVersion)/builds/\(buildNumber)/downloads/\(encodedName)") else {
                    completion(.failure(InstallerError.message("Invalid Paper download URL")))
                    return
                }

                let dest = serverDir.appendingPathComponent("server.jar")
                self.downloadFile(jarURL, to: dest, completion: completion)
            }
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

    private func fetchText(_ url: URL, completion: @escaping (Result<String, Error>) -> Void) {
        URLSession.shared.dataTask(with: url) { data, _, error in
            if let error = error { completion(.failure(error)); return }
            guard let data = data, let text = String(data: data, encoding: .utf8) else {
                completion(.failure(InstallerError.message("Empty response")))
                return
            }
            completion(.success(text))
        }.resume()
    }

    private func isVersionHigher(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0) ?? -1 }
        }
        let pa = parts(a)
        let pb = parts(b)
        let n = max(pa.count, pb.count)
        for i in 0..<n {
            let va = i < pa.count ? pa[i] : 0
            let vb = i < pb.count ? pb[i] : 0
            if va != vb { return va > vb }
        }
        return a.localizedStandardCompare(b) == .orderedDescending
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
        
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        if JessiSettings.shared().runInBackground {
            bgTask = UIApplication.shared.beginBackgroundTask {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            let code = self.runJavaTool(jarPath: installerJar.path, javaVersion: javaVersion, workingDir: serverDir.path, argsPath: argsPath.path)
            
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
            
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

        let isTrollStore = jessi_is_trollstore_installed()

        if let a4 = a4 {
            var argv: [UnsafeMutablePointer<CChar>?] = [a0, a1, a2, a3, a4, nil]
            return argv.withUnsafeMutableBufferPointer { buf in
                if isTrollStore {
                    return Int32(jessi_spawn_tool(5, buf.baseAddress))
                } else {
                    return Int32(jessi_tool_main(5, buf.baseAddress))
                }
            }
        }

        var argv: [UnsafeMutablePointer<CChar>?] = [a0, a1, a2, a3, nil]
        return argv.withUnsafeMutableBufferPointer { buf in
            if isTrollStore {
                return Int32(jessi_spawn_tool(4, buf.baseAddress))
            } else {
                return Int32(jessi_tool_main(4, buf.baseAddress))
            }
        }
    }
}
