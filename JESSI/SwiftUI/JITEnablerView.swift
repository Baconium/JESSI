import SwiftUI
import UniformTypeIdentifiers

struct JITSettingsSection: View {
    @ObservedObject private var enabler = JITEnabler.shared
    @State private var showImporter = false
    var onJITStatusChange: () -> Void = {}

    var body: some View {
        Section {
            HStack {
                Text("Pairing File")
                Spacer()
                if enabler.hasPairingFile {
                    Text("Imported")
                        .foregroundColor(.green)
                } else {
                    Text("Not Imported")
                        .foregroundColor(.secondary)
                }
            }
            .normalizedSeparator()

            Button {
                showImporter = true
            } label: {
                Text(enabler.hasPairingFile ? "Replace Pairing File" : "Import Pairing File")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .foregroundColor(.primary)
            .fileImporter(isPresented: $showImporter, allowedContentTypes: PairingFileStore.supportedTypes) { result in
                if case .success(let url) = result {
                    enabler.importPairingFile(from: url)
                }
            }
            .normalizedSeparator()

            Button {
                enabler.enableJIT()
            } label: {
                HStack {
                    Text(enableButtonTitle)
                    Spacer()
                    if enabler.phase.isBusy {
                        ProgressView()
                    }
                }
            }
            .foregroundColor(.primary)
            .disabled(enabler.phase.isBusy || !enabler.hasPairingFile || enabler.jitEnabled)
            .normalizedSeparator()
        } header: {
            Text("JIT")
        } footer: {
            footer
        }
        .onAppear { enabler.refreshStatus() }
        .onReceive(enabler.$jitEnabled) { _ in onJITStatusChange() }
    }

    private var enableButtonTitle: String {
        switch enabler.phase {
        case .connecting: return "Connecting…"
        case .mountingDDI: return "Mounting Developer Disk Image…"
        case .attaching: return "Attaching…"
        case .attached, .enabled: return "JIT Enabled"
        case .idle, .failed: return enabler.jitEnabled ? "JIT Enabled" : "Enable JIT"
        }
    }

    @ViewBuilder
    private var footer: some View {
        if case .failed(let message) = enabler.phase {
            Text(message)
                .foregroundColor(.red)
        } else if !enabler.hasPairingFile {
            Text("Import your pairing file and connect [LocalDevVPN](\(JITEnabler.localDevVPNURL.absoluteString)) before enabling JIT!")
        } else if enabler.usesJITScript {
            Text("Connect [LocalDevVPN](\(JITEnabler.localDevVPNURL.absoluteString)) first. This device uses TXM, so a JIT script will be automatically attached.")
        } else {
            Text("Connect [LocalDevVPN](\(JITEnabler.localDevVPNURL.absoluteString)) first.")
        }
    }
}
