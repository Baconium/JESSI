import SwiftUI
import Combine
import UIKit
import Darwin

enum LaunchAlert: Identifiable {
    case noServer
    case stopConfirm
    case jitNotEnabled
    case runtime(String)

    var id: String {
        switch self {
        case .noServer:
            return "noServer"
        case .stopConfirm:
            return "stopConfirm"
        case .jitNotEnabled:
            return "jitNotEnabled"
        case .runtime(let message):
            return "runtime:\(message)"
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

final class LaunchModel: NSObject, ObservableObject {
    @Published var servers: [String] = []
    @Published var selectedServer: String = ""
    @Published var isRunning: Bool = false
    @Published var consoleText: String = ""
    @Published var commandText: String = ""
    @Published var activeAlert: LaunchAlert? = nil
    @Published var propertiesManager: ServerPropertiesManager?

    private let service: JessiServerService

    override init() {
        self.service = JessiServerService()
        super.init()
        self.service.delegate = self
        reloadServers()
        self.isRunning = service.isRunning
        updatePropertiesManager()
    }

    func reloadServers() {
        let folders = service.availableServerFolders()
        self.servers = folders
        if selectedServer.isEmpty, let first = folders.first {
            selectedServer = first
        }
        updatePropertiesManager()
    }
    
    private func updatePropertiesManager() {
        if !selectedServer.isEmpty {
            let root = service.serversRoot()
            let path = (root as NSString).appendingPathComponent(selectedServer)
            self.propertiesManager = ServerPropertiesManager(serverPath: path)
        } else {
            self.propertiesManager = nil
        }
    }

    func startServer() {
        guard !selectedServer.isEmpty else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        service.startServerNamed(selectedServer)
    }
    
    func isJITEnabledCheck() -> Bool {
        return jessi_check_jit_enabled()
    }

    func start() {
        guard !selectedServer.isEmpty else { return }

        let available = JessiSettings.availableJavaVersions()
        if available.isEmpty {
            activeAlert = .runtime("Please install a JVM in settings before launching your server! If you're unsure of which version to install, pick Java 21.")
            return
        }

        let selectedJava = JessiSettings.shared().javaVersion
        if !available.contains(selectedJava) {
            activeAlert = .runtime("Your selected Java version (Java \(selectedJava)) is not installed. Please install it or pick a different version in settings.")
            return
        }

        if !isJITEnabledCheck() {
            activeAlert = .jitNotEnabled
            return
        }

        startServer()
    }

    func stop() {
        UIApplication.shared.isIdleTimerDisabled = false
        service.stopServer()
    }

    func clearConsole() {
        service.clearConsole()
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
    }

    func copyConsole() {
        UIPasteboard.general.string = consoleText
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
    }

    func sendCommand() {
        let cmd = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        _ = service.sendRcon(cmd)
        commandText = ""
    }
}

extension LaunchModel: JessiServerServiceDelegate {
    func serverServiceDidUpdateConsole(_ consoleText: String) {
        DispatchQueue.main.async {
            self.consoleText = consoleText
            let serversRoot = self.service.serversRoot()
            let serverPath = (serversRoot as NSString).appendingPathComponent(self.selectedServer)
            let consoleLogPath = (serverPath as NSString).appendingPathComponent("console.log")
            try? consoleText.write(toFile: consoleLogPath, atomically: true, encoding: .utf8)
        }
    }

    func serverServiceDidChangeRunning(_ isRunning: Bool) {
        DispatchQueue.main.async {
            self.isRunning = isRunning
            if !isRunning {
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }
}


struct QuickSettingsView: View {
    @ObservedObject var manager: ServerPropertiesManager
    @State private var showingIconImporter = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Quick Settings")
                .font(.headline)
            
            VStack(spacing: 0) {
                SettingRow(title: "Server Icon") {
                    Button(action: { showingIconImporter = true }) {
                        if let icon = manager.serverIcon {
                            Image(uiImage: icon)
                                .resizable()
                                .interpolation(.none)
                                .frame(width: 32, height: 32)
                                .cornerRadius(4)
                        } else {
                            Text("Select...")
                                .foregroundColor(.green)
                        }
                    }
                }
                
                Divider()

                SettingRow(title: "Gamemode") {
                     Menu {
                         Picker("Gamemode", selection: Binding(
                             get: {
                                 let val = manager.getProperty(key: "gamemode").lowercased()
                                 if val == "survival" || val == "0" { return 0 }
                                 if val == "creative" || val == "1" { return 1 }
                                 if val == "adventure" || val == "2" { return 2 }
                                 if val == "spectator" || val == "3" { return 3 }
                                 return 0
                             },
                             set: { (newValue: Int) in
                                 let current = manager.getProperty(key: "gamemode")
                                 let useNumbers = Int(current) != nil
                                 let newVal: String
                                 switch newValue {
                                 case 1: newVal = useNumbers ? "1" : "creative"
                                 case 2: newVal = useNumbers ? "2" : "adventure"
                                 case 3: newVal = useNumbers ? "3" : "spectator"
                                 default: newVal = useNumbers ? "0" : "survival"
                                 }
                                 manager.updateProperty(key: "gamemode", value: newVal)
                             }
                         )) {
                             Text("Survival").tag(0)
                             Text("Creative").tag(1)
                             Text("Adventure").tag(2)
                             Text("Spectator").tag(3)
                         }
                     } label: {
                         HStack {
                             let val = manager.getProperty(key: "gamemode").lowercased()
                             let text: String = {
                                 if val == "survival" || val == "0" { return "Survival" }
                                 if val == "creative" || val == "1" { return "Creative" }
                                 if val == "adventure" || val == "2" { return "Adventure" }
                                 if val == "spectator" || val == "3" { return "Spectator" }
                                 return "Survival"
                             }()
                             
                             Text(text)
                                .foregroundColor(.green)
                             Image(systemName: "chevron.up.chevron.down")
                                 .font(.caption)
                                 .foregroundColor(.green)
                         }
                     }
                }

                Divider()

                SettingRow(title: "Difficulty") {
                    Menu {
                        Picker("Difficulty", selection: Binding(
                            get: {
                                let hc = (manager.getProperty(key: "hardcore") as NSString).boolValue
                                if hc { return 4 }
                                
                                let val = manager.getProperty(key: "difficulty").lowercased()
                                if val == "peaceful" || val == "0" { return 0 }
                                if val == "easy" || val == "1" { return 1 }
                                if val == "normal" || val == "2" { return 2 }
                                if val == "hard" || val == "3" { return 3 }
                                return 2
                            },
                            set: { (newValue: Int) in
                                let currentDiff = manager.getProperty(key: "difficulty")
                                let useNumbers = Int(currentDiff) != nil
                                
                                if newValue == 4 {
                                    manager.updateProperty(key: "hardcore", value: "true")
                                    manager.updateProperty(key: "difficulty", value: useNumbers ? "3" : "hard")
                                } else {
                                    manager.updateProperty(key: "hardcore", value: "false")
                                    let newVal: String
                                    switch newValue {
                                    case 0: newVal = useNumbers ? "0" : "peaceful"
                                    case 1: newVal = useNumbers ? "1" : "easy"
                                    case 3: newVal = useNumbers ? "3" : "hard"
                                    default: newVal = useNumbers ? "2" : "normal"
                                    }
                                    manager.updateProperty(key: "difficulty", value: newVal)
                                }
                            }
                        )) {
                            Text("Peaceful").tag(0)
                            Text("Easy").tag(1)
                            Text("Normal").tag(2)
                            Text("Hard").tag(3)
                            Text("Hardcore").tag(4)
                        }
                    } label: {
                        HStack {
                            let text: String = {
                                let hc = (manager.getProperty(key: "hardcore") as NSString).boolValue
                                if hc { return "Hardcore" }
                                let val = manager.getProperty(key: "difficulty").lowercased()
                                if val == "peaceful" || val == "0" { return "Peaceful" }
                                if val == "easy" || val == "1" { return "Easy" }
                                if val == "normal" || val == "2" { return "Normal" }
                                if val == "hard" || val == "3" { return "Hard" }
                                return "Normal"
                            }()
                            
                            Text(text)
                               .foregroundColor(.green)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }
                }
                
                Divider()

                SettingRow(title: "Max Players") {
                    TextField("20", text: Binding(
                        get: { manager.getProperty(key: "max-players") },
                        set: { manager.updateProperty(key: "max-players", value: $0) }
                    ))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                }
                
                Divider()
                
                SettingRow(title: "View Distance") {
                    TextField("10", text: Binding(
                        get: { manager.getProperty(key: "view-distance") },
                        set: { manager.updateProperty(key: "view-distance", value: $0) }
                    ))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                }

                Divider()

                SettingRow(title: "Simulation Distance") {
                    TextField("10", text: Binding(
                        get: { manager.getProperty(key: "simulation-distance") },
                        set: { manager.updateProperty(key: "simulation-distance", value: $0) }
                    ))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                }

                Divider()

                SettingRow(title: "Whitelist") {
                    Toggle("", isOn: Binding(
                        get: { (manager.getProperty(key: "white-list") as NSString).boolValue },
                        set: { manager.updateProperty(key: "white-list", value: $0 ? "true" : "false") }
                    ))
                    .labelsHidden()
                }

                Divider()

                SettingRow(title: "MOTD") {
                    TextField("A Minecraft Server", text: Binding(
                        get: { manager.getProperty(key: "motd") },
                        set: { manager.updateProperty(key: "motd", value: $0) }
                    ))
                    .multilineTextAlignment(.trailing)
                }
            }
            .background(Color(UIColor.tertiarySystemBackground))
            .cornerRadius(12)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .sheet(isPresented: $showingIconImporter) {
            ImagePicker(onPick: { image in
                manager.updateIcon(image)
                showingIconImporter = false
            }, onCancel: {
                showingIconImporter = false
            })
        }
    }
}

struct SettingRow<Content: View>: View {
    let title: String
    let content: Content
    
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    
    var body: some View {
        HStack {
            Text(title)
                .foregroundColor(.primary)
            Spacer()
            content
                .frame(maxWidth: 150, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

struct AdvancedSettingsView: View {
    @ObservedObject var manager: ServerPropertiesManager
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            List {
                ForEach(manager.properties) { prop in
                    HStack {
                        Text(prop.key)
                        Spacer()
                        
                        let isBool = prop.value.lowercased() == "true" || prop.value.lowercased() == "false"
                        
                        if isBool {
                            Toggle("", isOn: Binding(
                                get: { prop.value.lowercased() == "true" },
                                set: { manager.updateProperty(key: prop.key, value: $0 ? "true" : "false") }
                            ))
                            .labelsHidden()
                            .toggleStyle(SwitchToggleStyle(tint: .green))
                        } else {
                            TextField("", text: Binding(
                                get: { prop.value },
                                set: { manager.updateProperty(key: prop.key, value: $0) }
                            ))
                            .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
            .navigationTitle("Server Properties")
            .navigationBarItems(trailing: Button("Done") {
                presentationMode.wrappedValue.dismiss()
            })
        }
    }
}

struct LaunchView: View {
    @StateObject private var model = LaunchModel()
    @State private var exitAfterStopRequested = false
    @State private var showAdvancedSettings = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 0) {
                    HStack {
                        Text("Server")
                            .font(.headline)
                            .foregroundColor(.primary)
                        Spacer()
                        
                        if model.servers.isEmpty {
                             Text("None").foregroundColor(.secondary)
                        } else {
                             if model.isRunning {
                                 Text(model.selectedServer)
                                     .foregroundColor(.green)
                             } else {
                                 Menu {
                                     Picker("Server", selection: $model.selectedServer) {
                                         ForEach(model.servers, id: \.self) { s in
                                             Text(s).tag(s)
                                         }
                                     }
                                 } label: {
                                     HStack {
                                         Text(model.selectedServer)
                                         Image(systemName: "chevron.up.chevron.down")
                                             .font(.caption)
                                     }
                                     .foregroundColor(.green)
                                 }
                             }
                        }
                    }
                    .padding(16)
                    
                    HStack(spacing: 12) {
                        Button(action: {
                            if model.selectedServer.isEmpty {
                                model.activeAlert = .noServer
                            } else {
                                model.start()
                            }
                        }) {
                            Text("Start")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .foregroundColor(.white)
                        .background(model.isRunning ? Color.gray.opacity(0.4) : Color.green)
                        .cornerRadius(12)
                        .disabled(model.isRunning)

                        Button(action: {
                            model.activeAlert = .stopConfirm
                        }) {
                            Text("Stop")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .foregroundColor(.white)
                        .background(model.isRunning ? Color.red : Color.gray.opacity(0.35))
                        .cornerRadius(12)
                        .disabled(!model.isRunning)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(16)
                .padding(.horizontal, 16)
                .padding(.top, 16)

                HStack {
                    Text("Console")
                        .font(.headline)
                    Spacer()
                    Button(action: { model.copyConsole() }) {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundColor(.primary)

                    Button(action: { model.clearConsole() }) {
                        Label("Clear", systemImage: "trash")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.red)
                    }
                }
                .padding(.horizontal, 16)

                ConsolePanel(text: $model.consoleText)
                    .frame(height: 250)
                    .padding(.horizontal, 16)

                HStack(spacing: 0) {
                     DoneToolbarTextField(
                        text: $model.commandText,
                        placeholder: "Enter command",
                        keyboardType: .default,
                        textAlignment: .left,
                        font: UIFont.systemFont(ofSize: 15)
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.leading, 12)
                    .padding(.vertical, 12)
                    
                    Button(action: { model.sendCommand() }) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .foregroundColor(model.commandText.isEmpty ? .secondary : .green)
                    }
                    .disabled(!model.isRunning || model.commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal, 16)

                if let manager = model.propertiesManager {
                    QuickSettingsView(manager: manager)
                    
                    Button(action: { showAdvancedSettings = true }) {
                        Text("Advanced Settings")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green)
                            .cornerRadius(12)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
            }
        }
// .background(Color(UIColor.systemBackground)) // Removed so nav bar blur works
        .navigationTitle("Launch")
        .navigationBarTitleDisplayMode(.inline)
        .alert(item: $model.activeAlert) { alert in
            switch alert {
            case .noServer:
                return Alert(
                    title: Text("No server selected"),
                    message: Text("Create a server in the Servers tab first."),
                    dismissButton: .default(Text("OK"))
                )
            case .stopConfirm:
                return Alert(
                    title: Text("Stop server?"),
                    message: Text("Stopping will close JESSI after the server fully stops."),
                    primaryButton: .destructive(Text("Stop & Close")) {
                        exitAfterStopRequested = true
                        model.stop()
                    },
                    secondaryButton: .cancel(Text("Cancel"))
                )
            case .jitNotEnabled:
                return Alert(
                    title: Text("JIT Not Enabled"),
                    message: Text("Just-In-Time compilation is not enabled. The app may crash if you start the server."),
                    primaryButton: .destructive(Text("Start Anyway")) {
                        model.startServer()
                    },
                    secondaryButton: .cancel(Text("Cancel"))
                )
            case .runtime(let message):
                return Alert(
                    title: Text("No JVM Installed"),
                    message: Text(message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
        .sheet(isPresented: $showAdvancedSettings) {
            if let manager = model.propertiesManager {
                AdvancedSettingsView(manager: manager)
            }
        }
        .onChange(of: model.isRunning) { isRunning in
            guard !isRunning, exitAfterStopRequested else { return }
            exitAfterStopRequested = false
            UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                exit(0)
            }
        }
        .onAppear {
            let appearance = UINavigationBarAppearance()
            appearance.configureWithDefaultBackground()
            UINavigationBar.appearance().standardAppearance = appearance
            if #available(iOS 15.0, *) {
                UINavigationBar.appearance().scrollEdgeAppearance = nil
            }
            if #available(iOS 15.0, *) {
                UINavigationBar.appearance().compactAppearance = appearance
            }

            model.reloadServers()
        }

    }
}

private struct ConsolePanel: View {
    @Binding var text: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            ConsoleTextView(text: $text)
            if text.isEmpty {
                Text("Console output will appear here.")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(16)
            }
        }
        .background(Color(UIColor.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(UIColor.separator), lineWidth: 1)
        )
    }
}

private struct ConsoleTextView: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView(frame: .zero)
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = true
        tv.alwaysBounceVertical = true
        tv.backgroundColor = .clear
        tv.textColor = UIColor.label
        tv.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        tv.textContainer.lineBreakMode = .byCharWrapping
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        guard uiView.text != text else { return }

        let bottomThreshold: CGFloat = 24
        let visibleBottom = uiView.contentOffset.y + uiView.bounds.size.height
        let wasAtBottom = visibleBottom >= (uiView.contentSize.height - bottomThreshold)
        let oldOffset = uiView.contentOffset

        uiView.text = text
        uiView.layoutIfNeeded()

        if wasAtBottom {
            let end = NSRange(location: max(0, (uiView.text as NSString).length - 1), length: 1)
            uiView.scrollRangeToVisible(end)
        } else {
            let maxOffsetY = max(0, uiView.contentSize.height - uiView.bounds.size.height)
            uiView.setContentOffset(CGPoint(x: oldOffset.x, y: min(oldOffset.y, maxOffsetY)), animated: false)
        }
    }
}
