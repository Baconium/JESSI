import Foundation
import SwiftUI
import Combine
import UIKit

@objc public class JessiSwiftUIEntry: NSObject {
    @objc public static func makeRootTabViewController() -> UIViewController {
        let hosting = UIHostingController(rootView: RootTabView())
        return hosting
    }

    @objc public static func makeServerManagerViewController() -> UIViewController {
        let view = ServerManagerView()
        let hosting = UIHostingController(rootView: view)
        hosting.title = "Server Manager"
        return hosting
    }

    @objc public static func makeLaunchViewController() -> UIViewController {
        let view = LaunchView()
        let hosting = UIHostingController(rootView: view)
        hosting.title = "Launch"
        return hosting
    }

    @objc public static func makeSettingsViewController() -> UIViewController {
        let view = SettingsView()
        let hosting = UIHostingController(rootView: view)
        hosting.title = "Settings"
        return hosting
    }

    @objc public static func makeCreateServerViewController() -> UIViewController {
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
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(model.folders.enumerated()), id: \.element.id) { idx, f in
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

                                    Image(systemName: "chevron.right")
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 16)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(action: { beginRename(f.name) }) {
                                    Label("Rename", systemImage: "pencil")
                                }
                                Button(action: { beginDelete(f.name) }) {
                                    Label("Delete", systemImage: "trash")
                                }
                            }

                            if idx != model.folders.count - 1 {
                                Divider()
                                    .padding(.horizontal, 16)
                            }
                        }
                    }
                    .background(Color(UIColor.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                }
                .padding(.bottom, 140)
            }
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
            .padding(.horizontal, 16)
            .padding(.bottom, createButtonBottomPadding)
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
