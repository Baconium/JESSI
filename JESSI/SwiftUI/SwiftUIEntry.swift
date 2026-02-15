import Foundation
import SwiftUI
import Combine
import UIKit

struct SheetItem: Identifiable {
    let id = UUID()
    let input: String
}

@objc public class JessiSwiftUIEntry: NSObject {
    private static var didConfigureListAppearance = false

    private static func configureListAppearance() {
        guard !didConfigureListAppearance else { return }
        didConfigureListAppearance = true

        let insets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        UITableView.appearance().separatorInset = insets
        UITableView.appearance().layoutMargins = insets
        UITableView.appearance().separatorInsetReference = .fromCellEdges
        UITableViewCell.appearance().separatorInset = insets
        UITableViewCell.appearance().layoutMargins = insets
    }

    @objc public static func makeRootTabViewController() -> UIViewController {
        configureListAppearance()
        let hosting = UIHostingController(rootView: RootTabView())
        return hosting
    }

    @objc public static func makeServerManagerViewController() -> UIViewController {
        configureListAppearance()
        let view = ServerManagerView()
        let hosting = UIHostingController(rootView: view)
        hosting.title = "Server Manager"
        return hosting
    }

    @objc public static func makeLaunchViewController() -> UIViewController {
        configureListAppearance()
        let view = LaunchView()
        let hosting = UIHostingController(rootView: view)
        hosting.title = "Launch"
        return hosting
    }

    @objc public static func makeSettingsViewController() -> UIViewController {
        configureListAppearance()
        let view = SettingsView()
        let hosting = UIHostingController(rootView: view)
        hosting.title = "Settings"
        return hosting
    }

    @objc public static func makeCreateServerViewController() -> UIViewController {
        configureListAppearance()
        let view = CreateServerView()
        let hosting = UIHostingController(rootView: view)
        hosting.title = "Server Setup"
        return hosting
    }
}

func getServersRoot() -> String {
    let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? ""
    return (docs as NSString).appendingPathComponent("servers")
}

struct ServerFolder: Identifiable, Hashable {
    let id = UUID()
    let name: String
}

final class ServerListModel: ObservableObject {
    @Published var folders: [ServerFolder] = []
    private var cancellables = Set<AnyCancellable>()

    init() {
        reload()
        NotificationCenter.default.publisher(for: Notification.Name("JessiServersChanged"))
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
    }

    func reload() {
        let root = getServersRoot()
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: root) else { self.folders = []; return }
        var names: [String] = []
        for name in items {
            let p = (root as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                names.append(name)
            }
        }
        names.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        self.folders = names.map { ServerFolder(name: $0) }
    }
}

struct ServerManagerView: View {
    @StateObject private var model = ServerListModel()
    @State private var showingCreateServer: Bool = false

    @State private var renameTarget: String? = nil
    @State private var renameText: String = ""
    @State private var showingRenameSheet: Bool = false
    
    @State private var modsSheetItem: SheetItem? = nil

    private enum ManagerAlert: Identifiable {
        case confirmDelete(String)
        case error(String)

        var id: String {
            switch self {
            case .confirmDelete(let name): return "delete:\(name)"
            case .error(let msg): return "error:\(msg)"
            }
        }
    }

    @State private var alert: ManagerAlert? = nil

    private func serverIconPath(for serverName: String) -> String {
        return ((getServersRoot() as NSString).appendingPathComponent(serverName) as NSString)
            .appendingPathComponent("server-icon.png")
    }

    @ViewBuilder
    private func serverIconView(for serverName: String) -> some View {
        if let img = UIImage(contentsOfFile: serverIconPath(for: serverName)) {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Image(systemName: "server.rack")
                .resizable()
                .scaledToFit()
                .foregroundColor(.primary)
                .frame(width: 26, height: 26)
        }
    }

    private var createButtonBottomPadding: CGFloat {
        24
    }

    private func beginRename(_ name: String) {
        renameTarget = name
        renameText = name
        showingRenameSheet = true
    }

    private func beginDelete(_ name: String) {
        alert = .confirmDelete(name)
    }

    private func showError(_ message: String) {
        alert = .error(message)
    }

    private func renameServer(oldName: String, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed != oldName else { return }

        let root = getServersRoot()
        let fm = FileManager.default
        let oldPath = (root as NSString).appendingPathComponent(oldName)
        let newPath = (root as NSString).appendingPathComponent(trimmed)

        if fm.fileExists(atPath: newPath) {
            showError("A server named \"\(trimmed)\" already exists.")
            return
        }

        do {
            try fm.moveItem(atPath: oldPath, toPath: newPath)
            NotificationCenter.default.post(name: Notification.Name("JessiServersChanged"), object: nil)
            model.reload()
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func deleteServer(name: String) {
        let root = getServersRoot()
        let fm = FileManager.default
        let path = (root as NSString).appendingPathComponent(name)
        do {
            try fm.removeItem(atPath: path)
            NotificationCenter.default.post(name: Notification.Name("JessiServersChanged"), object: nil)
            model.reload()
        } catch {
            showError(error.localizedDescription)
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            List {
                Section {
                    ForEach(model.folders) { f in
                        NavigationLink(
                            destination: FileBrowserView(
                                directory: getServersRoot().appending("/").appending(f.name),
                                title: f.name
                            )
                        ) {
                            HStack(spacing: 12) {
                                serverIconView(for: f.name)
                                    .frame(width: 44, height: 44)
                                    .background(Color.clear)

                                Text(f.name)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.primary)

                                Spacer()

                                if #available(iOS 18.0, *) {
                                    EmptyView()
                                } else {
                                    Image(systemName: "chevron.right")
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .contextMenu {
                            Button {
                                modsSheetItem = SheetItem(input: f.name)
                            } label: {
                                Label("Install Mods", systemImage: "wrench.and.screwdriver.fill")
                            }
                            Button(action: { beginRename(f.name) }) {
                                Label("Rename", systemImage: "pencil")
                            }
                            Button(action: { beginDelete(f.name) }) {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .onDelete { indexSet in
                        guard let idx = indexSet.first, idx < model.folders.count else { return }
                        beginDelete(model.folders[idx].name)
                    }
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle("Server Manager")
            .navigationBarTitleDisplayMode(.inline)

            Button(action: { showingCreateServer = true }) {
                Text("Create New Server")
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
        .sheet(item: $modsSheetItem) { item in
            NavigationView {
                ModsView(servername: item.input)
            }
        }
        .sheet(isPresented: $showingCreateServer) {
            NavigationView {
                CreateServerView()
            }
        }
        .sheet(isPresented: $showingRenameSheet) {
            NavigationView {
                Form {
                    Section(header: Text("Rename Server")) {
                        TextField("Server Name", text: $renameText)
                            .autocapitalization(.words)
                    }
                }
                .navigationTitle("Rename")
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarItems(
                    leading: Button("Cancel") { showingRenameSheet = false },
                    trailing: Button("Save") {
                        if let old = renameTarget {
                            renameServer(oldName: old, newName: renameText)
                        }
                        showingRenameSheet = false
                    }
                )
            }
        }
        .alert(item: $alert) { a in
            switch a {
            case .confirmDelete(let name):
                return Alert(
                    title: Text("Delete Server"),
                    message: Text("Delete \"\(name)\"? This cannot be undone."),
                    primaryButton: .destructive(Text("Delete")) {
                        deleteServer(name: name)
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
    }
}
