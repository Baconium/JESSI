import SwiftUI
import Combine
import UIKit
import Darwin
import ZIPFoundation

final class SettingsModel: ObservableObject {
    @Published var availableJavaVersions: [String] = []
    @Published var javaVersion: String = "8"
    @Published var heapText: String = "768"
    @Published var heapMB: Int = 768
    @Published var flagNettyNoNative: Bool = true
    @Published var flagJnaNoSys: Bool = false
    @Published var isJITEnabled: Bool = false
    @Published var totalRAM: String = ""
    @Published var freeRAM: String = ""
    @Published var launchArgs: String = ""
    @Published var iOS26JIT: Bool = false
    @Published var isIOS26: Bool = false

    init() {
        let s = JessiSettings.shared()
        availableJavaVersions = JessiSettings.availableJavaVersions()
        javaVersion = s.javaVersion
        heapMB = s.maxHeapMB
        heapText = String(heapMB)

        flagNettyNoNative = s.flagNettyNoNative
        flagJnaNoSys = s.flagJnaNoSys
        isJITEnabled = isJITEnabledCheck()
        totalRAM = formatRAM(ProcessInfo.processInfo.physicalMemory)
        freeRAM = formatRAM(getFreeMemory())
        launchArgs = s.launchArguments
        iOS26JIT = s.iOS26JITSupport
        isIOS26 = jessi_is_ios26_or_later()
    }

    func applyAndSaveJavaVersion(_ ver: String) {
        let s = JessiSettings.shared()
        s.javaVersion = ver
        s.save()
    }

    func applyAndSaveLaunchArgs() {
        let s = JessiSettings.shared()
        s.launchArguments = launchArgs
        s.save()
    }

    func applyAndSaveHeap(_ mb: Int) {
        let clamped = max(128, min(8192, mb))
        let snapped = (clamped / 64) * 64

        heapMB = snapped
        heapText = String(snapped)

        let s = JessiSettings.shared()
        s.maxHeapMB = snapped
        s.save()
    }

    
    func applyAndSaveFlags() {
        let s = JessiSettings.shared()
        s.flagNettyNoNative = flagNettyNoNative
        s.flagJnaNoSys = flagJnaNoSys
        s.save()
    }
    
    func applyAndSaveIOS26JIT() {
        let s = JessiSettings.shared()
        s.iOS26JITSupport = iOS26JIT
        s.save()
    }

    func applyHeapFromText() {
        let raw = heapText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            heapText = String(heapMB)
            return
        }
        applyAndSaveHeap(Int(raw) ?? heapMB)
    }

    var heapDescription: String {
        if heapMB < 513 { return "Low — the server will be highly unstable with this little ram" }
        if heapMB > 4095 { return "High — make sure your device has enough ram!" }
        return "Recommended: 1024–2048 MB depending on your device. if you exceed the amount of ram your device has the app will crash!"
    }

    private func isJITEnabledCheck() -> Bool {
        return jessi_check_jit_enabled()
    }

    private func formatRAM(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        return String(format: "%.0f MB", mb)
    }

    private func getFreeMemory() -> UInt64 {
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let hostPort = mach_host_self()
        let result = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let pageSize = UInt64(vm_kernel_page_size)
            let freePages = UInt64(vmStats.free_count + vmStats.inactive_count)
            return freePages * pageSize
        }
        return 0
    }
    
    func refreshAvailableJavaVersions() {
        availableJavaVersions = JessiSettings.availableJavaVersions()
    }
    
    private let jres: [String: URL] = [
        "8": URL(string: "https://crystall1ne.dev/cdn/amethyst-ios/jre8-ios-aarch64.zip")!,
        "17": URL(string: "https://crystall1ne.dev/cdn/amethyst-ios/jre17-ios-aarch64.zip")!,
        "21": URL(string: "https://crystall1ne.dev/cdn/amethyst-ios/jre21-ios-aarch64.zip")!
    ]

    private var runtimesdir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Runtimes")
    }

    func fetch(version: String) async {
        guard let url = jres[version] else {
            runtimelogger.log("Unknown Java version: \(version)")
            return
        }

        runtimelogger.log("Downloading Java \(version)…")

        do {
            try FileManager.default.createDirectory(at: runtimesdir, withIntermediateDirectories: true)

            let zipPath = runtimesdir.appendingPathComponent("jre\(version).zip")
            let (data, _) = try await URLSession.shared.data(from: url)
            try data.write(to: zipPath)

            let extractDir = runtimesdir.appendingPathComponent("jre\(version)")
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

            runtimelogger.log("Extracting Java \(version)…")
            try extract(at: zipPath, to: extractDir)
            
            runtimelogger.log("Java \(version) installed successfully at \(extractDir.path)")
            runtimelogger.divider()
            
            refreshAvailableJavaVersions()
        } catch {
            runtimelogger.log("Error installing Java \(version): \(error.localizedDescription)")
            runtimelogger.divider()
        }
    }

    func fetchall() async {
        var versions = ["17", "21"]
        
        if #unavailable(iOS 26.0) {
            versions.append(contentsOf: ["8"])
        }
        
        for version in versions {
            await fetch(version: version)
        }
    }

    private func extract(at zipPath: URL, to destDir: URL) throws {
        guard let archive = Archive(url: zipPath, accessMode: .read) else {
            throw NSError(domain: "ZIP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to open ZIP archive"])
        }

        for entry in archive {
            let entryPath = destDir.appendingPathComponent(entry.path)
            if entry.type == .directory {
                try FileManager.default.createDirectory(at: entryPath, withIntermediateDirectories: true)
            } else {
                try archive.extract(entry, to: entryPath)
            }
        }
    }
    
    func getRuntimeSize(version: String) -> String {
        let runtimesdir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Runtimes/jre\(version)")
        
        guard FileManager.default.fileExists(atPath: runtimesdir.path) else {
            return "--"
        }
        
        do {
            let enumerator = FileManager.default.enumerator(at: runtimesdir, includingPropertiesForKeys: [.fileSizeKey], options: [], errorHandler: nil)
            var total: UInt64 = 0
            for case let fileURL as URL in enumerator! {
                let attrs = try fileURL.resourceValues(forKeys: [.fileSizeKey])
                total += UInt64(attrs.fileSize ?? 0)
            }
            
            let mb = Double(total) / (1024 * 1024)
            return String(format: "%.1f MB", mb)
        } catch {
            return "--"
        }
    }
    
    func deleteRuntime(at offsets: IndexSet) {
        for index in offsets {
            let version = availableJavaVersions[index]
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Runtimes/jre\(version)")
            
            do {
                if FileManager.default.fileExists(atPath: dir.path) {
                    try FileManager.default.removeItem(at: dir)
                    runtimelogger.log("Deleted runtime for Java \(version)")
                    runtimelogger.divider()
                }
            } catch {
                runtimelogger.log("Failed to delete runtime \(version): \(error)")
                runtimelogger.divider()
            }
        }
        
        availableJavaVersions.remove(atOffsets: offsets)
    }
}

struct SettingsView: View {
    @StateObject private var model = SettingsModel()
    @StateObject private var logger = runtimelogger
    @State private var runtime: String = "21"

    var body: some View {
        List {
            Section(header: Text("Java")) {
                HStack(alignment: .center, spacing: 12) {
                    Text("Version")
                    Spacer()
                    if model.availableJavaVersions.isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(Color.yellow)
                        Text("No runtimes found")
                            .foregroundColor(Color.secondary)
                    } else {
                        Picker("Java", selection: $model.javaVersion) {
                            ForEach(model.availableJavaVersions, id: \.self) { ver in
                                Text("Java \(ver)").tag(ver)
                            }
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .frame(maxWidth: 260)
                    }
                }
                .onChange(of: model.javaVersion) { newValue in
                    model.applyAndSaveJavaVersion(newValue)
                }

                HStack(alignment: .center, spacing: 12) {
                    Text("Launch Arguments")
                    Spacer()
                    DoneToolbarTextField(text: $model.launchArgs, placeholder: "Advanced users only", keyboardType: .default, textAlignment: .right, onEndEditing: { model.applyAndSaveLaunchArgs() })
                        .frame(maxWidth: 420)
                        .onChange(of: model.launchArgs) { _ in model.applyAndSaveLaunchArgs() }
                }
            } header: {
                Text("Java")
            } footer: {
                VStack(alignment: .leading) {
                    if model.availableJavaVersions.isEmpty {
                        Text("JESSI requires a Java Runtime to work. You can get one using the 'Fetch Runtimes' button.")
                    }
                    
                    if #available(iOS 26.0, *) {
                        Text("Java 8 is not supported on iOS 26 or later.")
                    }
                }
            }
            
            Section {
                if model.availableJavaVersions.isEmpty {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(Color.yellow)
                        Text("No runtimes found")
                            .foregroundColor(Color.secondary)
                            .bold()
                    }
                }
                
                ForEach(model.availableJavaVersions, id: \.self) { ver in
                    HStack {
                        Text("Java \(ver)")
                        Spacer()
                        Text(model.getRuntimeSize(version: ver))
                            .foregroundColor(.secondary)
                    }
                }
                .onDelete(perform: model.deleteRuntime)
                
                Picker("Runtime", selection: $runtime) {
                    if #unavailable(iOS 26.0) {
                        Text("Java 8").tag("8")
                    }
                    Text("Java 17").tag("17")
                    Text("Java 21").tag("21")
                    Text("All").tag("all")
                }
                
                Button("Fetch Runtime") {
                    Task {
                        if runtime == "all" {
                            await model.fetchall()
                        } else {
                            await model.fetch(version: runtime)
                        }
                    }
                }
            } header: {
                Text("Runtimes")
            } footer: {
                if #available(iOS 26.0, *) {
                    Text("Java 8 is not supported on iOS 26 or later.")
                }
            }
        
            if !logger.logs.isEmpty {
                ForEach(logger.logs, id: \.self) { log in
                    Text(log)
                        .font(.system(.body, design: .monospaced))
                        // .font(.system(size: 15))
                        .onTapGesture {
                            UIPasteboard.general.string = log
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                }
            }

            Section(header: Text("Memory"), footer: Text(model.heapDescription)) {
                HStack(spacing: 12) {
                    Text("RAM")
                    Spacer()
                    DoneToolbarTextField(
                        text: $model.heapText,
                        placeholder: "128-8192",
                        keyboardType: .numberPad,
                        textAlignment: .right,
                        font: UIFont.systemFont(ofSize: 16, weight: .semibold),
                        onEndEditing: { model.applyHeapFromText() }
                    )
                    .frame(width: 92)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("\(model.heapMB) MB")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)
                        Spacer()
                    }

                    Slider(
                        value: Binding(
                            get: { Double(model.heapMB) },
                            set: { model.applyAndSaveHeap(Int($0)) }
                        ),
                        in: 128...8192,
                        step: 64
                    )
                }
            }            
            
            if model.isIOS26 {
                Section(header: Text("Trusted Execution Monitor"), footer: Text("Enable for A15/M2 on iOS 26.")) {
                    Toggle("TXM Support", isOn: $model.iOS26JIT)
                        .onChange(of: model.iOS26JIT) { _ in
                            model.applyAndSaveIOS26JIT()
                        }
                }
            }

            Section(header: Text("System")) {
                HStack {
                    Text("JIT Enabled")
                    Spacer()
                    Text(model.isJITEnabled ? "Yes" : "No")
                        .foregroundColor(model.isJITEnabled ? .green : .red)
                }
                HStack {
                    Text("iOS Version")
                    Spacer()
                    Text(model.isIOS26 ? "26+" : "< 26")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Total RAM")
                    Spacer()
                    Text(model.totalRAM)
                }
                HStack {
                    Text("Free RAM (estimated)")
                    Spacer()
                    Text(model.freeRAM)
                }

            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let s = JessiSettings.shared()
            model.javaVersion = s.javaVersion
            model.heapMB = s.maxHeapMB
            model.heapText = String(s.maxHeapMB)
            model.iOS26JIT = s.iOS26JITSupport
        }
    }
}
