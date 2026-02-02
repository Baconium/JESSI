import SwiftUI
import UniformTypeIdentifiers

struct FileBrowserView: View {
    let directory: String
    let title: String
    @State private var files: [FileItem] = []
    @State private var selectedFile: String? = nil
    @State private var isEditingFile: Bool = false

    @State private var showingFileImporter: Bool = false
    @State private var importError: String? = nil
    @State private var showImportError: Bool = false
    
    @State private var modsSheetItem: SheetItem? = nil

    struct FileItem: Identifiable {
        let id = UUID()
        let name: String
        let path: String
        let isDirectory: Bool
        let modDate: Date
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            List {
                Section {
                    ForEach(sortedFiles) { file in
                        NavigationLink(destination: fileDestination(for: file)) {
                            HStack(spacing: 12) {
                                Image(systemName: file.isDirectory ? "folder.fill" : "doc.text.fill")
                                    .foregroundColor(file.isDirectory ? .blue : .gray)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(file.name)
                                        .font(.system(size: 16, weight: .medium))
                                    Text(formatDate(file.modDate))
                                        .font(.system(size: 12, weight: .regular))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                        }
                    }
                } footer: {
                    Text("Deleting or modifing files may result in your server not working or not being able to install mods. Only do this if you know what youre doing.")
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
            .padding(.horizontal, 16)
            .padding(.bottom, createButtonBottomPadding)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
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
                importError = err.localizedDescription
                showImportError = true
            case .success(let urls):
                importPickedFiles(urls)
            }
        }
        .sheet(item: $modsSheetItem) { item in
            NavigationView {
                ModsView(servername: item.input)
            }
        }
        .alert(isPresented: $showImportError) {
            Alert(
                title: Text("Import Failed"),
                message: Text(importError ?? "Unknown error"),
                dismissButton: .default(Text("OK"))
            )
        }
        .onAppear { reload() }
    }
    
    private var createButtonBottomPadding: CGFloat {
        24
    }

    private var sortedFiles: [FileItem] {
        files.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    @ViewBuilder
    private func fileDestination(for file: FileItem) -> some View {
        if file.isDirectory {
            FileBrowserView(directory: file.path, title: file.name)
        } else {
            TextEditorView(filePath: file.path, title: file.name)
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
                    importError = error.localizedDescription
                    showImportError = true
                }
            }

            if let coordError = coordError {
                importError = coordError.localizedDescription
                showImportError = true
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

            HStack {
                Button("Discard") {

                }
                .foregroundColor(.red)

                Spacer()

                Button(action: save) {
                    if isSaving {
                        ProgressView()
                            .progressViewStyle(.circular)
                    } else {
                        Text("Save")
                    }
                }
                .foregroundColor(.blue)
                .disabled(isSaving)
            }
            .padding()
            .background(Color(.systemGray6))
        }
        .navigationBarTitle(title, displayMode: .inline)
        .onAppear { loadFile() }
    }

    private func loadFile() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              let text = String(data: data, encoding: .utf8) else {
            errorMsg = "Failed to load file"
            return
        }
        self.content = text
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
