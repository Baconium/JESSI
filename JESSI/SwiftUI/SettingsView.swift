import SwiftUI
import Combine
import UIKit
import Darwin

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
}

struct SettingsView: View {
    @StateObject private var model = SettingsModel()

    var body: some View {
        List {
            Section(header: Text("Java")) {
                HStack(alignment: .center, spacing: 12) {
                    Text("Version")
                    Spacer()
                    Picker("Java", selection: $model.javaVersion) {
                        ForEach(model.availableJavaVersions, id: \.self) { ver in
                            Text("Java \(ver)").tag(ver)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .frame(maxWidth: 260)
                }
                .onChange(of: model.javaVersion) { newValue in
                    model.applyAndSaveJavaVersion(newValue)
                }

                HStack(alignment: .center, spacing: 12) {
                    Text("Launch Arguments")
                    Spacer()
                    DoneToolbarTextField(text: $model.launchArgs, placeholder: "Advanced users only", keyboardType: .default, textAlignment: .right, font: UIFont.systemFont(ofSize: 14), onEndEditing: { model.applyAndSaveLaunchArgs() })
                        .frame(maxWidth: 420)
                        .onChange(of: model.launchArgs) { _ in model.applyAndSaveLaunchArgs() }
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

            Section(header: Text("System")) {
                HStack {
                    Text("JIT Enabled")
                    Spacer()
                    Text(model.isJITEnabled ? "Yes" : "No")
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
        }
    }
}
