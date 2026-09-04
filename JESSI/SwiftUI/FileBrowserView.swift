import SwiftUI
import UniformTypeIdentifiers
import UIKit
import Darwin

struct FileBrowserView: View {
    let directory: String
    let title: String
    @State private var files: [FileItem] = []
    @State private var selectedFile: String? = nil
    @State private var isEditingFile: Bool = false

    @State private var showingFileImporter: Bool = false
    
    @State private var modsSheetItem: SheetItem? = nil

    @State private var renameTarget: FileItem? = nil
    @State private var renameText: String = ""
    @State private var showingRenameSheet: Bool = false

    @State private var shareItem: ShareItem? = nil
    @State private var directoryMonitor: DispatchSourceFileSystemObject? = nil
    @State private var pendingReloadWorkItem: DispatchWorkItem? = nil
    
    private enum BrowserAlert: Identifiable {
        case confirmDelete(FileItem)
        case error(String)

        var id: String {
            switch self {
            case .confirmDelete(let item): return "delete:\(item.path)"
            case .error(let msg): return "error:\(msg)"
            }
        }
    }

    @State private var alert: BrowserAlert? = nil

    struct FileItem: Identifiable {
        var id: String { path }
        let name: String
        let path: String
        let isDirectory: Bool
        let modDate: Date
    }

    private struct ShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    private struct ShareSheet: UIViewControllerRepresentable {
        let activityItems: [Any]

        func makeUIViewController(context: Context) -> UIActivityViewController {
            let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
            if let popover = controller.popoverPresentationController {
                let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
                let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first
                popover.sourceView = window
                popover.sourceRect = window?.bounds ?? .zero
            }
            return controller
        }

        func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            List {
                Section {
                    ForEach(sortedFiles) { file in
                        NavigationLink(destination: fileDestination(for: file)) {
                            HStack(spacing: 12) {
                                Image(systemName: file.isDirectory ? "folder.fill" : "doc.text.fill")
                                    .foregroundColor(file.isDirectory ? .green : .gray)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(file.name)
                                        .font(.system(size: 16, weight: .medium))
                                    if let priority = packPriority(for: file) {
                                        Text(priority == 1
                                             ? "Priority 1 - overrides the packs below"
                                             : "Priority \(priority)")
                                            .font(.system(size: 12, weight: .regular))
                                            .foregroundColor(.secondary)
                                    } else {
                                        Text(formatDate(file.modDate))
                                            .font(.system(size: 12, weight: .regular))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                            }
                        }
                        .contextMenu {
                            Button {
                                shareItem = ShareItem(url: URL(fileURLWithPath: file.path))
                            } label: {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            Button(action: { beginRename(file) }) {
                                Label("Rename", systemImage: "pencil")
                            }
                            Button(action: { beginDelete(file) }) {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .normalizedSeparator()
                    }
                    .onMove { source, destination in
                        guard isPrioritized else { return }
                        var current = sortedFiles
                        current.move(fromOffsets: source, toOffset: destination)
                        packOrder.write(current
                            .filter { !$0.isDirectory && ResourcePackOrder.isPackFile($0.name) }
                            .map { $0.name })
                        reload()
                    }
                    .onDelete { indexSet in
                        guard let idx = indexSet.first else { return }
                        let current = sortedFiles
                        guard idx < current.count else { return }

                        let item = current[idx]
                        if item.isDirectory {
                            alert = .confirmDelete(item)
                        } else {
                            deleteItem(item)
                        }
                    }
                }

                Section {
                    Color.clear
                        .frame(height: 15)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(InsetGroupedListStyle())
            
            Spacer()
            
            Button {
                modsSheetItem = SheetItem(input: title)
            } label: {
                Text("Install Mods")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .foregroundColor(.white)
            .background(Color.green)
            .cornerRadius(14)
            .shadow(color: Color.black.opacity(0.5), radius: 8, x: 0, y: 4)
            .padding(.horizontal, 16)
            .padding(.bottom, createButtonBottomPadding)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Group {
                    if isPrioritized {
                        EditButton()
                            .foregroundColor(.green)
                    }
                }
            }
        }
        .navigationBarItems(trailing: Button(action: { showingFileImporter = true }) {
            Image(systemName: "plus")
        })
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .failure(let err):
                alert = .error(err.localizedDescription)
            case .success(let urls):
                importPickedFiles(urls)
            }
        }
        .sheet(item: $modsSheetItem) { item in
            NavigationView {
                ModsView(servername: item.input)
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(activityItems: [item.url])
        }
        .sheet(isPresented: $showingRenameSheet) {
            NavigationView {
                Form {
                    Section(header: Text(renameTarget?.isDirectory == true ? "Rename Folder" : "Rename File")) {
                        TextField("Name", text: $renameText)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                }
                .navigationTitle("Rename")
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarItems(
                    leading: Button("Cancel") { showingRenameSheet = false },
                    trailing: Button("Save") {
                        if let target = renameTarget {
                            renameItem(target, newName: renameText)
                        }
                        showingRenameSheet = false
                    }
                )
            }
        }
        .alert(item: $alert) { a in
            switch a {
            case .confirmDelete(let item):
                let isDirText = item.isDirectory ? "folder" : "file"
                return Alert(
                    title: Text("Delete \(isDirText)") ,
                    message: Text("Delete \"\(item.name)\"? This cannot be undone."),
                    primaryButton: .destructive(Text("Delete")) {
                        deleteItem(item)
                    },
                    secondaryButton: .cancel()
                )
            case .error(let msg):
                return Alert(
                    title: Text("Error"),
                    message: Text(msg),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
        .onAppear {
            reload()
            startDirectoryMonitor()
        }
        .onDisappear {
            stopDirectoryMonitor()
        }
    }
    
    private var createButtonBottomPadding: CGFloat {
        24
    }

    private var packOrder: ResourcePackOrder {
        ResourcePackOrder(directory: URL(fileURLWithPath: directory))
    }

    private var isPrioritized: Bool {
        guard URL(fileURLWithPath: directory).lastPathComponent == ContentType.resourcepack.dirname else {
            return false
        }
        return files.filter { !$0.isDirectory && ResourcePackOrder.isPackFile($0.name) }.count > 1
    }

    private func packPriority(for file: FileItem) -> Int? {
        guard isPrioritized, !file.isDirectory, ResourcePackOrder.isPackFile(file.name) else { return nil }
        guard let index = packOrder.resolved().firstIndex(of: file.name) else { return nil }
        return index + 1
    }

    private var sortedFiles: [FileItem] {
        guard isPrioritized else {
            return files.sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }

        let ranks = Dictionary(uniqueKeysWithValues: packOrder.resolved().enumerated().map { ($0.element, $0.offset) })
        return files.sorted { a, b in
            switch (ranks[a.name], ranks[b.name]) {
            case let (lhs?, rhs?): return lhs < rhs
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }

    private func beginRename(_ item: FileItem) {
        renameTarget = item
        renameText = item.name
        showingRenameSheet = true
    }

    private func beginDelete(_ item: FileItem) {
        alert = .confirmDelete(item)
    }

    private func showError(_ message: String) {
        alert = .error(message)
    }

    private static let editableExtensions: Set<String> = [
        "txt", "log", "json", "yml", "yaml", "toml", "cfg", "conf", "ini",
        "properties", "xml", "html", "css", "js", "md", "sh", "bat", "cmd",
        "csv", "env", "gitignore", "lang", "mcmeta", "nbt"
    ]

    private func isEditableTextFile(_ file: FileItem) -> Bool {
        let ext = (file.name as NSString).pathExtension.lowercased()
        if ext.isEmpty { return true }
        return Self.editableExtensions.contains(ext)
    }

    @ViewBuilder
    private func fileDestination(for file: FileItem) -> some View {
        if file.isDirectory {
            FileBrowserView(directory: file.path, title: file.name)
        } else if isEditableTextFile(file) {
            TextEditorView(filePath: file.path, title: file.name)
        } else {
            NonEditableFileView(fileName: file.name, filePath: file.path)
        }
    }

    private func reload() {
        let fm = FileManager.default
        var items: [FileItem] = []
        guard let contents = try? fm.contentsOfDirectory(atPath: directory) else {
            self.files = []
            return
        }

        for name in contents {
            let path = (directory as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir) {
                let attrs = try? fm.attributesOfItem(atPath: path)
                let modDate = (attrs?[.modificationDate] as? Date) ?? Date()
                items.append(FileItem(name: name, path: path, isDirectory: isDir.boolValue, modDate: modDate))
            }
        }
        self.files = items
    }

    private func startDirectoryMonitor() {
        stopDirectoryMonitor()

        let fd = open(directory, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler { [directory] in
            DispatchQueue.main.async {
                guard !directory.isEmpty else { return }
                self.scheduleReloadFromMonitor()
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        directoryMonitor = source
        source.resume()
    }

    private func stopDirectoryMonitor() {
        pendingReloadWorkItem?.cancel()
        pendingReloadWorkItem = nil
        directoryMonitor?.cancel()
        directoryMonitor = nil
    }

    private func scheduleReloadFromMonitor() {
        pendingReloadWorkItem?.cancel()
        let item = DispatchWorkItem {
            reload()
        }
        pendingReloadWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    private func deleteItem(_ item: FileItem) {
        let fm = FileManager.default
        do {
            try fm.removeItem(atPath: item.path)
            reload()
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func renameItem(_ item: FileItem, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed != item.name else { return }

        let parent = (item.path as NSString).deletingLastPathComponent
        let newPath = (parent as NSString).appendingPathComponent(trimmed)

        let fm = FileManager.default
        if fm.fileExists(atPath: newPath) {
            showError("An item named \"\(trimmed)\" already exists.")
            return
        }

        do {
            try fm.moveItem(atPath: item.path, toPath: newPath)
            reload()
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func importPickedFiles(_ urls: [URL]) {
        let fm = FileManager.default
        let destDir = URL(fileURLWithPath: directory, isDirectory: true)

        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let baseName = url.lastPathComponent
            let destURL = uniqueDestinationURL(in: destDir, preferredName: baseName)

            let coordinator = NSFileCoordinator()
            var coordError: NSError?
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { newURL in
                do {
                    try fm.copyItem(at: newURL, to: destURL)
                } catch {
                    alert = .error(error.localizedDescription)
                }
            }

            if let coordError = coordError {
                alert = .error(coordError.localizedDescription)
            }
        }

        reload()
    }

    private func uniqueDestinationURL(in dir: URL, preferredName: String) -> URL {
        let fm = FileManager.default
        let base = (preferredName as NSString).deletingPathExtension
        let ext = (preferredName as NSString).pathExtension

        func makeName(_ n: String) -> String {
            if ext.isEmpty { return n }
            return "\(n).\(ext)"
        }

        var candidate = dir.appendingPathComponent(makeName(base))
        if !fm.fileExists(atPath: candidate.path) { return candidate }

        for i in 2..<1000 {
            let name = makeName("\(base) \(i)")
            candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }

        return dir.appendingPathComponent(makeName("\(base) \(Int(Date().timeIntervalSince1970))"))
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .short
        return formatter.string(from: date)
    }
}

struct TextEditorView: View {
    let filePath: String
    let title: String
    @State private var content: String = ""
    @State private var isSaving: Bool = false
    @State private var errorMsg: String? = nil
    
    @State private var ogcontent: String = ""
    @State private var showUnsavedExitConfirm = false
    @Environment(\.presentationMode) var presentationMode

    var hasUnsavedChanges: Bool {
        content != ogcontent
    }

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $content)
                .font(.system(size: 14, design: .monospaced))
                .padding()

            if let error = errorMsg {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .padding()
            }
        }
        .navigationBarTitle("\(title)\(hasUnsavedChanges ? " *" : "")", displayMode: .inline)
        .navigationBarBackButtonHidden(false)
        .navigationBarItems(trailing: Button(action: save) {
            if isSaving {
                ProgressView()
                    .progressViewStyle(.circular)
            } else {
                Text("Save")
                    .foregroundColor(.green)
            }
        }
        .disabled(isSaving))
        .onAppear { loadFile() }
        .onDisappear { handleDisappear() }
        .alert(isPresented: $showUnsavedExitConfirm) {
            Alert(
                title: Text("Unsaved Changes"),
                message: Text("Do you want to save your changes before leaving?"),
                primaryButton: .default(Text("Save")) {
                    save()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        presentationMode.wrappedValue.dismiss()
                    }
                },
                secondaryButton: .destructive(Text("Discard")) {
                    presentationMode.wrappedValue.dismiss()
                }
            )
        }
    }
    
    private func handleDisappear() {
        if hasUnsavedChanges {
            showUnsavedExitConfirm = true
        }
    }

    private func loadFile() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              let text = String(data: data, encoding: .utf8) else {
            errorMsg = "Failed to load file"
            return
        }
        content = text
        ogcontent = text
    }

    private func save() {
        isSaving = true
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            do {
                try content.write(toFile: filePath, atomically: true, encoding: .utf8)
                DispatchQueue.main.async {
                    isSaving = false
                    errorMsg = nil
                }
            } catch {
                DispatchQueue.main.async {
                    isSaving = false
                    errorMsg = "Save failed: \(error.localizedDescription)"
                }
            }
        }
    }
}

struct NonEditableFileView: View {
    let fileName: String
    let filePath: String

    @State private var shareItem: ShareItemNE? = nil

    private struct ShareItemNE: Identifiable {
        let id = UUID()
        let url: URL
    }

    private struct ShareSheet: UIViewControllerRepresentable {
        let activityItems: [Any]

        func makeUIViewController(context: Context) -> UIActivityViewController {
            let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
            if let popover = controller.popoverPresentationController {
                let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
                let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first
                popover.sourceView = window
                popover.sourceRect = window?.bounds ?? .zero
            }
            return controller
        }

        func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
    }

    private var fileExtension: String {
        (fileName as NSString).pathExtension.lowercased()
    }

    private var fileSize: String {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: filePath),
              let size = attrs[.size] as? UInt64 else { return "Unknown" }
        if size < 1024 { return "\(size) B" }
        if size < 1024 * 1024 { return String(format: "%.1f KB", Double(size) / 1024) }
        return String(format: "%.1f MB", Double(size) / (1024 * 1024))
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: iconForExtension(fileExtension))
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .foregroundColor(.secondary)

            VStack(spacing: 6) {
                Text(fileName)
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text(fileSize)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Text("This file type cannot be edited in JESSI.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button(action: {
                shareItem = ShareItemNE(url: URL(fileURLWithPath: filePath))
            }) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.system(size: 17, weight: .semibold))
                    .padding(.vertical, 12)
                    .padding(.horizontal, 32)
            }
            .foregroundColor(.white)
            .background(Color.green)
            .cornerRadius(12)

            Spacer()
        }
        .navigationBarTitle(fileName, displayMode: .inline)
        .sheet(item: $shareItem) { item in
            ShareSheet(activityItems: [item.url])
        }
    }

    private func iconForExtension(_ ext: String) -> String {
        switch ext {
        case "jar": return "shippingbox.fill"
        case "png", "jpg", "jpeg", "gif", "bmp", "ico", "webp": return "photo.fill"
        case "zip", "gz", "tar", "rar", "7z", "xz": return "doc.zipper"
        case "dat", "dat_old", "mca", "nbt": return "cylinder.fill"
        default: return "doc.fill"
        }
    }
}
