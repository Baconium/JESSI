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

final class LaunchModel: NSObject, ObservableObject {
    @Published var servers: [String] = []
    @Published var selectedServer: String = ""
    @Published var isRunning: Bool = false
    @Published var consoleText: String = ""
    @Published var commandText: String = ""
    @Published var activeAlert: LaunchAlert? = nil

    private let service: JessiServerService

    override init() {
        self.service = JessiServerService()
        super.init()
        self.service.delegate = self
        reloadServers()
        self.isRunning = service.isRunning
    }

    func reloadServers() {
        let folders = service.availableServerFolders()
        self.servers = folders
        if selectedServer.isEmpty, let first = folders.first {
            selectedServer = first
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

struct LaunchView: View {
    @StateObject private var model = LaunchModel()
    @State private var exitAfterStopRequested = false

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 0) {
                HStack {
                    Text("Server")
                        .foregroundColor(.primary)
                    Spacer()
                    if model.servers.isEmpty {
                        Text("None")
                            .foregroundColor(.secondary)
                    } else {
                        Picker("Server", selection: $model.selectedServer) {
                            ForEach(model.servers, id: \.self) { s in
                                Text(s).tag(s)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .disabled(model.isRunning)
                        .opacity(model.isRunning ? 0.6 : 1.0)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)

                Divider().padding(.horizontal, 16)

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
                .padding(.vertical, 16)
            }
            .background(Color(UIColor.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 16)

            Spacer()
                .frame(height: 8)

            HStack {
                Text("Console")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button(action: { model.copyConsole() }) {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: { model.clearConsole() }) {
                    Label("Clear", systemImage: "trash")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.red)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 16)

            ConsolePanel(text: $model.consoleText)
                .padding(.horizontal, 16)
                .frame(maxHeight: .infinity)
                .layoutPriority(1)

            HStack(spacing: 10) {
                DoneToolbarTextField(
                    text: $model.commandText,
                    placeholder: "Enter command",
                    keyboardType: .default,
                    textAlignment: .left,
                    font: UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(UIColor.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button(action: { model.sendCommand() }) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .foregroundColor(.white)
                .background(Color.green)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .disabled(!model.isRunning || model.commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity((!model.isRunning || model.commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ? 0.6 : 1.0)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(UIColor.systemBackground).ignoresSafeArea())
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
        .onChange(of: model.isRunning) { isRunning in
            guard !isRunning, exitAfterStopRequested else { return }
            exitAfterStopRequested = false
            // yeah this shit doesnt work lmao
            UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                exit(0)
            }
        }
        .onAppear { model.reloadServers() }
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
