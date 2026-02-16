import SwiftUI
import UIKit
import SafariServices
import Security
import Darwin
import Combine
import Network

private struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ScrollContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ScrollViewHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct InstallTunnelingRow: View {
    let name: String
    let isInstalled: Bool
    let isSelected: Bool
    let isInstalling: Bool
    let onToggle: () -> Void

    private var iconName: String {
        if isInstalled || isSelected { return "checkmark.circle.fill" }
        return "circle"
    }

    private var iconColor: Color {
        if isInstalled { return .green }
        if isSelected { return Color.accentColor }
        return .secondary
    }

    private var statusText: String? {
        if isInstalling { return "Installing…" }
        if isInstalled { return "Installed" }
        return nil
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .foregroundColor(iconColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .foregroundColor(.primary)

                    if let statusText {
                        Text(statusText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isInstalled)
    }
}

final class TunnelingModel: ObservableObject {
    struct ServiceInfo: Identifiable {
        let id: String
        let name: String
        let fileName: String?
        let downloadURL: URL?
    }

    static let services: [ServiceInfo] = [
        ServiceInfo(
            id: "playit",
            name: "Playit",
            fileName: "libplayit_agent.dylib",
            downloadURL: URL(string: "https://github.com/rooootdev/playit-ios/releases/download/latest/libplayit_agent.dylib")
        ),
        ServiceInfo(
            id: "upnp",
            name: "UPnP",
            fileName: nil,
            downloadURL: nil
        ),
        ServiceInfo(
            id: "none",
            name: "None",
            fileName: nil,
            downloadURL: nil
        )
    ]

    var allServices: [ServiceInfo] { Self.services }

    @Published var availableServiceIds: [String] = []
    @Published var selectedServiceId: String = ""
    @Published var installedServiceIds: Set<String> = []

    @Published var installErrorMessage: String? = nil
    @Published var showInstallError: Bool = false

    private let selectedKey = "jessi.tunnel.service"

    init() {
        let stored = UserDefaults.standard.string(forKey: selectedKey)
        selectedServiceId = stored ?? allServices.first?.id ?? ""

        refreshInstalledServices()
        refreshAvailableServices()
    }

    func applyAndSaveSelectedService(_ id: String) {
        selectedServiceId = id
        UserDefaults.standard.set(id, forKey: selectedKey)
    }

    func displayName(for id: String) -> String {
        allServices.first(where: { $0.id == id })?.name ?? id
    }

    private func info(for id: String) -> ServiceInfo? {
        allServices.first(where: { $0.id == id })
    }

    private var servicesDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tunneling", isDirectory: true)
    }

    private func serviceFileURL(for id: String) -> URL? {
        guard let info = info(for: id), let fileName = info.fileName else { return nil }
        return servicesDir
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private func serviceDir(for id: String) -> URL {
        servicesDir.appendingPathComponent(id, isDirectory: true)
    }

    func refreshInstalledServices() {
        let installed = allServices.compactMap { info -> String? in
            if info.fileName == nil { return info.id }
            guard let fileURL = serviceFileURL(for: info.id) else { return nil }
            return FileManager.default.fileExists(atPath: fileURL.path) ? info.id : nil
        }
        installedServiceIds = Set(installed)
    }

    func refreshAvailableServices() {
        availableServiceIds = allServices.map { $0.id }.filter(installedServiceIds.contains)

        if !availableServiceIds.contains(selectedServiceId), let first = availableServiceIds.first {
            applyAndSaveSelectedService(first)
        }
    }

    func deleteInstalledService(_ id: String) {
        guard installedServiceIds.contains(id) else { return }
        try? FileManager.default.removeItem(at: serviceDir(for: id))
        refreshInstalledServices()
        refreshAvailableServices()
    }

    private func installOneService(id: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let info = info(for: id), let downloadURL = info.downloadURL, let fileName = info.fileName else {
            completion(.failure(NSError(domain: "JESSI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown service: \(id)"])) )
            return
        }

        let fm = FileManager.default
        let tmpRoot = fm.temporaryDirectory.appendingPathComponent("jessi-tunneling-install", isDirectory: true)
        let workDir = tmpRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let downloadPath = workDir.appendingPathComponent(fileName)

        let task = URLSession.shared.downloadTask(with: downloadURL) { tempURL, _, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let tempURL else {
                completion(.failure(NSError(domain: "JESSI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Download failed"])))
                return
            }

            do {
                try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: workDir) }

                if fm.fileExists(atPath: downloadPath.path) { try? fm.removeItem(at: downloadPath) }
                try fm.moveItem(at: tempURL, to: downloadPath)

                let finalDir = self.serviceDir(for: id)
                let staging = self.servicesDir.appendingPathComponent("\(id).staging-\(UUID().uuidString)", isDirectory: true)
                if fm.fileExists(atPath: staging.path) { try? fm.removeItem(at: staging) }
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)

                let stagedFile = staging.appendingPathComponent(fileName, isDirectory: false)
                if fm.fileExists(atPath: stagedFile.path) { try? fm.removeItem(at: stagedFile) }
                try fm.moveItem(at: downloadPath, to: stagedFile)

                if fm.fileExists(atPath: finalDir.path) {
                    let backup = self.servicesDir.appendingPathComponent("\(id).backup-\(UUID().uuidString)", isDirectory: true)
                    try? fm.removeItem(at: backup)
                    try fm.moveItem(at: finalDir, to: backup)
                    try? fm.removeItem(at: backup)
                }

                try fm.moveItem(at: staging, to: finalDir)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }

        task.resume()
    }

    func installServices(
        services: [String],
        updateInProgress: @escaping (Bool) -> Void,
        updateQueueCSV: @escaping (String) -> Void,
        clearSelection: @escaping () -> Void,
        showErrors: Bool = true
    ) {
        let validIds = Set(allServices.map { $0.id })
        let queue = services.filter(validIds.contains).filter { info(for: $0)?.downloadURL != nil }

        func fail(_ message: String) {
            if showErrors {
                DispatchQueue.main.async {
                    self.installErrorMessage = message
                    self.showInstallError = true
                }
            }
            updateQueueCSV("")
            updateInProgress(false)
            clearSelection()
        }

        guard !queue.isEmpty else {
            fail("Nothing to install.")
            return
        }

        var remaining = queue
        func next() {
            guard !remaining.isEmpty else {
                DispatchQueue.main.async {
                    self.refreshInstalledServices()
                    self.refreshAvailableServices()
                }
                updateQueueCSV("")
                updateInProgress(false)
                clearSelection()
                return
            }

            let current = remaining.removeFirst()
            updateQueueCSV(([current] + remaining).joined(separator: ","))

            self.installOneService(id: current) { result in
                switch result {
                case .success:
                    DispatchQueue.main.async {
                        self.refreshInstalledServices()
                        self.refreshAvailableServices()
                    }
                    next()
                case .failure(let error):
                    fail(error.localizedDescription)
                }
            }
        }

        updateInProgress(true)
        updateQueueCSV(queue.joined(separator: ","))
        next()
    }

    static func autoInstallPlayitIfNeeded() {
        let defaults = UserDefaults.standard
        let autoKey = "jessi.tunnel.autoInstall.started"
        guard !defaults.bool(forKey: autoKey) else { return }
        defaults.set(true, forKey: autoKey)

        let model = TunnelingModel()
        model.refreshInstalledServices()
        if model.installedServiceIds.contains("playit") {
            return
        }

        model.installServices(
            services: ["playit"],
            updateInProgress: { defaults.set($0, forKey: "jessi.tunnel.install.inProgress") },
            updateQueueCSV: { defaults.set($0, forKey: "jessi.tunnel.install.queue") },
            clearSelection: { defaults.set("", forKey: "jessi.tunnel.install.selection") },
            showErrors: false
        )
    }
}

final class PlayitModel: ObservableObject {
    @Published var islibrarypresent: Bool = false
    @Published var status: String = "Disconnected"
    @Published var lastaddr: String? = nil
    @Published var lasterr: String? = nil
    @Published var linked: Bool = false
    @Published var claimurl: String = ""
    @Published var claiming: Bool = false
    @Published var claimstatus: String = ""
    @Published var isstarting: Bool = false
    @Published var showinvalidkeyalert: Bool = false

    private let claimurlkey = "jessi.playit.claimurl"
    private let secretkeykey = "jessi.playit.secretkey"
    private let lastaddrkey = "jessi.playit.lastaddress"
    private let statuskey = "jessi.playit.status"
    private let lasterrkey = "jessi.playit.lasterror"
    private let apibase = "https://api.playit.gg"

    private var claimTask: Task<Void, Never>? = nil
    private var libhandle: UnsafeMutableRawPointer? = nil
    private var statustimer: Timer? = nil
    private var laststatuscode: PlayitStatusCode? = nil
    private var connectingsince: Date? = nil
    private var didwarnconnecting: Bool = false

    private var defaults: UserDefaults { .standard }

    var libraryPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("Tunneling", isDirectory: true)
            .appendingPathComponent("playit", isDirectory: true)
            .appendingPathComponent("libplayit_agent.dylib", isDirectory: false)
            .path
    }

    func refresh() {
        islibrarypresent = FileManager.default.fileExists(atPath: libraryPath)

        claimurl = defaults.string(forKey: claimurlkey) ?? ""
        linked = (defaults.string(forKey: secretkeykey) ?? "").isEmpty == false
        status = defaults.string(forKey: statuskey) ?? "Disconnected"
        lastaddr = defaults.string(forKey: lastaddrkey)
        lasterr = defaults.string(forKey: lasterrkey)

        if claimurl.isEmpty && linked {
            claimurl = "https://playit.gg"
        }

        if libhandle == nil && !isstarting {
            setStatus("Disconnected")
            setLastAddr(nil)
        }
    }

    func resetlink() {
        defaults.removeObject(forKey: secretkeykey)
        defaults.removeObject(forKey: statuskey)
        defaults.removeObject(forKey: lastaddrkey)
        defaults.removeObject(forKey: lasterrkey)
        linked = false
        setStatus("Disconnected")
        setLastAddr(nil)
        setError(nil)
    }

    func startstatuspolling() {
        if statustimer != nil { return }
        statustimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshfromlibrary()
        }
    }

    func stopstatuspolling() {
        statustimer?.invalidate()
        statustimer = nil
    }

    func startifpossible() {
        if isstarting { return }
        guard islibrarypresent else {
            setError("Playit library missing")
            return
        }
        guard let secret = defaults.string(forKey: secretkeykey), !secret.isEmpty else {
            setError("Playit not linked")
            return
        }

        isstarting = true
        setError(nil)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let error = self.startlibrary(secretkey: secret)
            DispatchQueue.main.async {
                self.isstarting = false
                if let error {
                    self.setError(error)
                } else {
                    self.startstatuspolling()
                    self.refreshfromlibrary()
                }
            }
        }
    }

    private func startlibrary(secretkey: String) -> String? {
        if libhandle == nil {
            libhandle = dlopen(libraryPath, RTLD_NOW)
        }
        guard let handle = libhandle else {
            let err = String(cString: dlerror())
            return "Failed to load Playit library: \(err)"
        }

        guard let playitinit = loadsymbol(handle, name: "playit_init", type: PlayitInitFn.self),
              let playitstart = loadsymbol(handle, name: "playit_start", type: PlayitStartFn.self),
              let playitsetlog = loadsymbol(handle, name: "playit_set_log_callback", type: PlayitSetLogCallbackFn.self)
        else {
            return "Failed to load Playit symbols"
        }

        playitsetlog(jessi_playit_log_callback, nil)

        let config: [String: Any] = [
            "secret_key": secretkey,
            "agent_version": "99.0.0"
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: config, options: []),
              let jsonStr = String(data: jsonData, encoding: .utf8)
        else {
            return "Failed to build Playit config"
        }

        let initResult = jsonStr.withCString { cStr in
            playitinit(cStr)
        }
        if initResult != 0 {
            return "Playit init failed (\(initResult))"
        }

        let startResult = playitstart()
        if startResult != 0 {
            return "Playit start failed (\(startResult))"
        }

        return nil
    }

    private func refreshfromlibrary() {
        guard let handle = libhandle else { return }
        guard let playitstatus = loadsymbol(handle, name: "playit_get_status_out", type: PlayitGetStatusFn.self) else {
            return
        }

        var s = PlayitStatusC(code: 0, last_address: nil, last_error: nil)
        withUnsafeMutablePointer(to: &s) { ptr in
            playitstatus(UnsafeMutableRawPointer(ptr))
        }
        let code = PlayitStatusCode(rawValue: s.code) ?? .disconnected
        if laststatuscode != code {
            laststatuscode = code
            if code == .connecting {
                connectingsince = Date()
                didwarnconnecting = false
            } else {
                connectingsince = nil
                didwarnconnecting = false
            }
        }

        setStatus(code.displayname)

        if let addr = s.last_address {
            setLastAddr(String(cString: addr))
        }

        if let err = s.last_error {
            let value = String(cString: err)
            setError(value)
            if value.contains("InvalidAgentKey") {
                resetlink()
                setError("Playit link expired or invalid. Please re-link.")
                showinvalidkeyalert = true
            }
        }
    }

    private func loadsymbol<T>(_ handle: UnsafeMutableRawPointer, name: String, type: T.Type) -> T? {
        guard let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: type)
    }

    func beginClaimFlow() {
        if claiming { return }

        let code = generateClaimCode()
        let url = "https://playit.gg/claim/\(code)"
        storeClaimUrl(url)

        claimstatus = "Waiting for approval... \n"
        claiming = true
        tunnelinglogger.log("Playit: claim started (\(code))")

        claimTask?.cancel()
        claimTask = Task { [weak self] in
            await self?.runClaimFlow(code: code)
        }
    }

    func cancelClaimFlow() {
        claimTask?.cancel()
        claimTask = nil
        claiming = false
        claimstatus = ""
    }

    @MainActor
    private func updateClaimStatus(_ text: String) {
        claimstatus.append(text + "\n")
    }

    @MainActor
    private func finishClaimWithError(_ message: String) {
        claiming = false
        setError(message)
    }

    @MainActor
    private func finishClaimSuccess(secretKey: String) {
        claiming = false
        storeSecretKey(secretKey)
        linked = true
        setError(nil)
        tunnelinglogger.log("Playit: claim success")
    }

    private func storeClaimUrl(_ url: String) {
        claimurl = url
        defaults.set(url, forKey: claimurlkey)
    }

    private func storeSecretKey(_ key: String) {
        defaults.set(key, forKey: secretkeykey)
    }

    private func setStatus(_ value: String) {
        status = value
        defaults.set(value, forKey: statuskey)
    }

    private func setLastAddr(_ value: String?) {
        lastaddr = value
        if let value {
            defaults.set(value, forKey: lastaddrkey)
        } else {
            defaults.removeObject(forKey: lastaddrkey)
        }
    }

    private func setError(_ value: String?) {
        lasterr = value
        if let value {
            defaults.set(value, forKey: lasterrkey)
        } else {
            defaults.removeObject(forKey: lasterrkey)
        }
    }

    private func generateClaimCode() -> String {
        var bytes = [UInt8](repeating: 0, count: 5)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if result != errSecSuccess {
            bytes = (0..<5).map { _ in UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func runClaimFlow(code: String) async {
        let version = appVersionString()
        let setupReq = ClaimSetupRequest(code: code, agent_type: "self-managed", version: version)

        while !Task.isCancelled {
            do {
                let result: ApiResult<String, String> = try await post(path: "/claim/setup", body: setupReq)
                switch result {
                case .success(let status):
                    let state = parseClaimSetupStatus(status)
                    switch state {
                    case .waitingForUserVisit:
                        await updateClaimStatus("Open the link to continue")
                    case .waitingForUser:
                        await updateClaimStatus("Approve the request in your browser")
                    case .userAccepted:
                        await updateClaimStatus("Approved. Finalizing…")
                        tunnelinglogger.log("Playit: claim approved")
                        await exchangeClaim(code: code)
                        return
                    case .userRejected:
                        await finishClaimWithError("Claim rejected")
                        tunnelinglogger.log("Playit: claim rejected")
                        return
                    case .unknown(let value):
                        await updateClaimStatus("Waiting… (\(value))")
                    }
                case .fail(let error):
                    await finishClaimWithError("Claim error: \(error)")
                    return
                case .error(let error):
                    await finishClaimWithError("Claim error: \(error.display)")
                    return
                }
            } catch {
                await finishClaimWithError("Claim error: \(error.localizedDescription)")
                return
            }

            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    private func exchangeClaim(code: String) async {
        let exchangeReq = ClaimExchangeRequest(code: code)
        let endAt = Date().addingTimeInterval(300)

        while !Task.isCancelled {
            do {
                let result: ApiResult<AgentSecretKey, String> = try await post(path: "/claim/exchange", body: exchangeReq)
                switch result {
                case .success(let key):
                    await finishClaimSuccess(secretKey: key.secret_key)
                    return
                case .fail(let error):
                    if Date() > endAt {
                        await finishClaimWithError("Claim timed out (\(error))")
                        return
                    }
                case .error(let error):
                    await finishClaimWithError("Claim error: \(error.display)")
                    return
                }
            } catch {
                await finishClaimWithError("Claim error: \(error.localizedDescription)")
                return
            }

            if Date() > endAt {
                await finishClaimWithError("Claim timed out")
                return
            }

            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func appVersionString() -> String {
        let bundle = Bundle.main
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "jessi-ios \(version) (\(build))"
    }

    private func parseClaimSetupStatus(_ raw: String) -> ClaimSetupState {
        let normalized = raw.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
        switch normalized {
        case "waitingforuservisit":
            return .waitingForUserVisit
        case "waitingforuser":
            return .waitingForUser
        case "useraccepted":
            return .userAccepted
        case "userrejected":
            return .userRejected
        default:
            return .unknown(raw)
        }
    }

    private func post<B: Encodable, S: Decodable, F: Decodable>(path: String, body: B) async throws -> ApiResult<S, F> {
        guard let url = URL(string: apibase + path) else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(ApiResult<S, F>.self, from: data)
    }

    struct ClaimSetupRequest: Encodable {
        let code: String
        let agent_type: String
        let version: String
    }

    struct ClaimExchangeRequest: Encodable {
        let code: String
    }

    struct AgentSecretKey: Decodable {
        let secret_key: String
    }

    enum ClaimSetupState {
        case waitingForUserVisit
        case waitingForUser
        case userAccepted
        case userRejected
        case unknown(String)
    }

    struct ApiResponseError: Decodable {
        let type: String
        let message: String?

        var display: String {
            if let message, !message.isEmpty {
                return "\(type): \(message)"
            }
            return type
        }
    }

    enum ApiResult<S: Decodable, F: Decodable>: Decodable {
        case success(S)
        case fail(F)
        case error(ApiResponseError)

        private enum CodingKeys: String, CodingKey {
            case status
            case data
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let status = try container.decode(String.self, forKey: .status)
            switch status {
            case "success":
                let value = try container.decode(S.self, forKey: .data)
                self = .success(value)
            case "fail":
                let value = try container.decode(F.self, forKey: .data)
                self = .fail(value)
            case "error":
                let value = try container.decode(ApiResponseError.self, forKey: .data)
                self = .error(value)
            default:
                let value = try container.decode(ApiResponseError.self, forKey: .data)
                self = .error(value)
            }
        }
    }
}

final class UpnpModel: ObservableObject {
    @Published var isTesting: Bool = false
    @Published var testResult: String? = nil
    @Published var testSuccess: Bool? = nil
    @Published var isApplying: Bool = false
    @Published var statusMessage: String? = nil
    @Published var statusSuccess: Bool? = nil

    private var activeConnection: NWConnection? = nil
    private var lastApplyTask: Task<Void, Never>? = nil

    func test() {
        if isTesting { return }
        isTesting = true
        testResult = nil
        testSuccess = nil

        let queue = DispatchQueue(label: "jessi.upnp.test")
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true

        let connection = NWConnection(host: "239.255.255.250", port: 1900, using: parameters)
        activeConnection = connection

        let request = """
        M-SEARCH * HTTP/1.1\r\nHOST:239.255.255.250:1900\r\nMAN:\"ssdp:discover\"\r\nMX:1\r\nST:urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n
        """

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let data = request.data(using: .utf8) ?? Data()
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        self.finish(success: false, message: "UPnP test failed: \(error.localizedDescription)")
                        connection.cancel()
                        return
                    }

                    connection.receiveMessage { data, _, _, error in
                        if let error {
                            self.finish(success: false, message: "UPnP test failed: \(error.localizedDescription)")
                            connection.cancel()
                            return
                        }

                        if let data, !data.isEmpty {
                            self.finish(success: true, message: "UPnP gateway detected")
                        }
                        connection.cancel()
                    }
                })
            case .failed(let error):
                self.finish(success: false, message: "UPnP test failed: \(error.localizedDescription)")
                connection.cancel()
            default:
                break
            }
        }

        connection.start(queue: queue)

        queue.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.isTesting else { return }
            self.finish(success: false, message: "No UPnP gateway response")
            connection.cancel()
        }
    }

    private func finish(success: Bool, message: String) {
        DispatchQueue.main.async {
            self.isTesting = false
            self.testSuccess = success
            self.testResult = message
            self.activeConnection = nil
        }
    }

    func enablePorts(_ ports: [Int]) {
        applyPorts(ports, action: .add)
    }

    func clearPorts(_ ports: [Int]) {
        applyPorts(ports, action: .delete)
    }

    private enum MappingAction {
        case add
        case delete

        var verb: String { self == .add ? "AddPortMapping" : "DeletePortMapping" }
    }

    private func applyPorts(_ ports: [Int], action: MappingAction) {
        guard !isApplying else { return }
        let uniquePorts = Array(Set(ports)).sorted()
        guard !uniquePorts.isEmpty else {
            updateStatus(success: false, message: "No valid ports provided")
            return
        }

        isApplying = true
        statusMessage = nil
        statusSuccess = nil

        lastApplyTask?.cancel()
        lastApplyTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.performMapping(action: action, ports: uniquePorts)
            DispatchQueue.main.async {
                self.isApplying = false
                self.statusSuccess = result.success
                self.statusMessage = result.message
            }
        }
    }

    private func updateStatus(success: Bool, message: String) {
        DispatchQueue.main.async {
            self.statusSuccess = success
            self.statusMessage = message
        }
    }

    private struct GatewayInfo {
        let controlURL: URL
        let serviceType: String
    }

    private struct MappingResult {
        let success: Bool
        let message: String
    }

    private func performMapping(action: MappingAction, ports: [Int]) async -> MappingResult {
        guard let gateway = await discoverGateway() else {
            return MappingResult(success: false, message: "UPnP gateway not found")
        }

        guard let localIP = localIPv4Address() else {
            return MappingResult(success: false, message: "Unable to determine local IP")
        }

        for port in ports {
            let protocols = ["TCP", "UDP"]
            for proto in protocols {
                let success = await sendPortMapping(
                    action: action,
                    gateway: gateway,
                    externalPort: port,
                    internalPort: port,
                    protocolType: proto,
                    internalClient: localIP
                )
                if !success {
                    return MappingResult(success: false, message: "UPnP \(action == .add ? "enable" : "clear") failed for port \(port)")
                }
            }
        }

        let verb = action == .add ? "Enabled" : "Cleared"
        return MappingResult(success: true, message: "\(verb) UPnP for ports \(ports.map(String.init).joined(separator: ", "))")
    }

    private func discoverGateway() async -> GatewayInfo? {
        guard let response = await sendMSearch() else { return nil }
        guard let locationURL = parseLocation(from: response) else { return nil }

        guard let xmlData = try? await URLSession.shared.data(from: locationURL).0,
              let xml = String(data: xmlData, encoding: .utf8) else {
            return nil
        }

        if let control = findControlURL(in: xml, serviceType: "urn:schemas-upnp-org:service:WANIPConnection:1", baseURL: locationURL) {
            return GatewayInfo(controlURL: control, serviceType: "urn:schemas-upnp-org:service:WANIPConnection:1")
        }

        if let control = findControlURL(in: xml, serviceType: "urn:schemas-upnp-org:service:WANPPPConnection:1", baseURL: locationURL) {
            return GatewayInfo(controlURL: control, serviceType: "urn:schemas-upnp-org:service:WANPPPConnection:1")
        }

        return nil
    }

    private func sendMSearch() async -> String? {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "jessi.upnp.search")
            var didResume = false
            func resumeOnce(_ value: String?) {
                if didResume { return }
                didResume = true
                continuation.resume(returning: value)
            }
            let parameters = NWParameters.udp
            parameters.allowLocalEndpointReuse = true
            let connection = NWConnection(host: "239.255.255.250", port: 1900, using: parameters)

            let request = """
            M-SEARCH * HTTP/1.1\r\nHOST:239.255.255.250:1900\r\nMAN:\"ssdp:discover\"\r\nMX:1\r\nST:urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n
            """

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let data = request.data(using: .utf8) ?? Data()
                    connection.send(content: data, completion: .contentProcessed { error in
                        if error != nil {
                            resumeOnce(nil)
                            connection.cancel()
                            return
                        }

                        connection.receiveMessage { data, _, _, _ in
                            if let data, let text = String(data: data, encoding: .utf8) {
                                resumeOnce(text)
                            } else {
                                resumeOnce(nil)
                            }
                            connection.cancel()
                        }
                    })
                case .failed:
                    resumeOnce(nil)
                    connection.cancel()
                default:
                    break
                }
            }

            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + 2.5) {
                resumeOnce(nil)
                connection.cancel()
            }
        }
    }

    private func parseLocation(from response: String) -> URL? {
        let lines = response.split(separator: "\n")
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "location" {
                let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                return URL(string: value)
            }
        }
        return nil
    }

    private func findControlURL(in xml: String, serviceType: String, baseURL: URL) -> URL? {
        guard let serviceRange = xml.range(of: "<serviceType>\(serviceType)</serviceType>") else {
            return nil
        }

        let tail = xml[serviceRange.lowerBound...]
        guard let serviceEnd = tail.range(of: "</service>") else { return nil }
        let serviceBlock = tail[..<serviceEnd.upperBound]

        guard let controlStart = serviceBlock.range(of: "<controlURL>")?.upperBound,
              let controlEnd = serviceBlock.range(of: "</controlURL>")?.lowerBound else {
            return nil
        }

        let controlText = String(serviceBlock[controlStart..<controlEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: controlText) {
            if url.scheme != nil { return url }
            return URL(string: controlText, relativeTo: baseURL)?.absoluteURL
        }
        return nil
    }

    private func sendPortMapping(
        action: MappingAction,
        gateway: GatewayInfo,
        externalPort: Int,
        internalPort: Int,
        protocolType: String,
        internalClient: String
    ) async -> Bool {
        let soapBody: String
        if action == .add {
            soapBody = """
            <?xml version=\"1.0\"?>
            <s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">
              <s:Body>
                <u:AddPortMapping xmlns:u=\"\(gateway.serviceType)\">
                  <NewRemoteHost></NewRemoteHost>
                  <NewExternalPort>\(externalPort)</NewExternalPort>
                  <NewProtocol>\(protocolType)</NewProtocol>
                  <NewInternalPort>\(internalPort)</NewInternalPort>
                  <NewInternalClient>\(internalClient)</NewInternalClient>
                  <NewEnabled>1</NewEnabled>
                  <NewPortMappingDescription>JESSI</NewPortMappingDescription>
                  <NewLeaseDuration>0</NewLeaseDuration>
                </u:AddPortMapping>
              </s:Body>
            </s:Envelope>
            """
        } else {
            soapBody = """
            <?xml version=\"1.0\"?>
            <s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">
              <s:Body>
                <u:DeletePortMapping xmlns:u=\"\(gateway.serviceType)\">
                  <NewRemoteHost></NewRemoteHost>
                  <NewExternalPort>\(externalPort)</NewExternalPort>
                  <NewProtocol>\(protocolType)</NewProtocol>
                </u:DeletePortMapping>
              </s:Body>
            </s:Envelope>
            """
        }

        var request = URLRequest(url: gateway.controlURL)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(gateway.serviceType)#\(action.verb)\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = soapBody.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(status) {
                return true
            }

            if status == 500, let body = String(data: data, encoding: .utf8) {
                if action == .delete, body.contains("<errorCode>714</errorCode>") {
                    return true
                }
                if action == .add, body.contains("<errorCode>718</errorCode>") {
                    return true
                }
            }
            return false
        } catch {
            return false
        }
    }

    private func localIPv4Address() -> String? {
        var address: String? = nil
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr = first
        while true {
            let iface = ptr.pointee
            let family = iface.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET) {
                let name = String(cString: iface.ifa_name)
                if name == "en0" || name == "pdp_ip0" {
                    var addr = iface.ifa_addr.pointee
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(&addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                        address = String(cString: hostname)
                        break
                    }
                }
            }
            if let next = ptr.pointee.ifa_next {
                ptr = next
            } else {
                break
            }
        }

        return address
    }
}

private enum PlayitStatusCode: Int32 {
    case stopped = 0
    case connecting = 1
    case connected = 2
    case disconnected = 3
    case error = 4

    var displayname: String {
        switch self {
        case .stopped: return "Stopped"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        case .error: return "Error"
        }
    }
}

private struct PlayitStatusC {
    let code: Int32
    let last_address: UnsafePointer<CChar>?
    let last_error: UnsafePointer<CChar>?
}

private typealias PlayitInitFn = @convention(c) (UnsafePointer<CChar>?) -> Int32
private typealias PlayitStartFn = @convention(c) () -> Int32
private typealias PlayitStopFn = @convention(c) () -> Int32
private typealias PlayitGetStatusFn = @convention(c) (UnsafeMutableRawPointer) -> Void
private typealias PlayitSetLogCallbackFn = @convention(c) (@convention(c) (Int32, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void, UnsafeMutableRawPointer?) -> Void

@_cdecl("jessi_playit_log_callback")
private func jessi_playit_log_callback(level: Int32, message: UnsafePointer<CChar>?, userData: UnsafeMutableRawPointer?) {
    let text = message.flatMap { String(validatingUTF8: $0) } ?? ""
    let prefix: String
    switch level {
    case 3: prefix = "[ERROR]"
    case 2: prefix = "[WARN]"
    case 1: prefix = "[INFO]"
    case 0: prefix = "[DEBUG]"
    default: prefix = "[TRACE]"
    }
    tunnelinglogger.log("Playit \(prefix) \(text)")
}

struct TunnelingView: View {
    @StateObject private var model = TunnelingModel()
    @StateObject private var playitmodel = PlayitModel()
    @AppStorage("jessi.server.running") private var serverRunning: Bool = false

    @State private var showInstallDropdown: Bool = false
    @AppStorage("jessi.tunnel.install.inProgress") private var installInProgress: Bool = false
    @AppStorage("jessi.tunnel.install.selection") private var installSelectionCSV: String = ""
    @AppStorage("jessi.tunnel.install.queue") private var installQueueCSV: String = ""

    @State private var didAutoResumeInstall: Bool = false
    @State private var showclaim: Bool = false
    @State private var showlogs: Bool = false
    @State private var showstatusinfo: Bool = false
    @State private var infotheusercouldmaybefinduseful: String = ""

    @State private var scrollviewheight: CGFloat = 0
    @State private var contentheight: CGFloat = 0
    @State private var scrolloffset: CGFloat = 0
    @State private var shouldautoscroll = true

    private var installSelection: Set<String> {
        csvToSet(installSelectionCSV)
    }

    private func setInstallSelection(_ selection: Set<String>) {
        installSelectionCSV = orderedIds(selection).joined(separator: ",")
    }

    private var installQueue: Set<String> {
        csvToSet(installQueueCSV)
    }

    private func csvToSet(_ csv: String) -> Set<String> {
        Set(csv.split(separator: ",").map(String.init))
    }

    private func orderedIds(_ set: Set<String>) -> [String] {
        model.allServices.map { $0.id }.filter(set.contains)
    }

    private func toggleSelection(_ id: String) {
        if model.installedServiceIds.contains(id) { return }
        if installInProgress { return }
        var next = installSelection
        if next.contains(id) {
            next.remove(id)
        } else {
            next.insert(id)
        }
        setInstallSelection(next)
    }

    var body: some View {
        VStack {
            List {
                tunnelingSection
                playitSection
            }

            if playitmodel.claiming {
                console
            }

            Spacer()

            startPlayitButton
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle("Tunneling")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showlogs = true
                } label: {
                    Text("Show Logs")
                        .foregroundColor(.green)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .alert(isPresented: $model.showInstallError) {
            Alert(
                title: Text("Tunneling Install Failed"),
                message: Text(model.installErrorMessage ?? "Unknown error"),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert(isPresented: $playitmodel.showinvalidkeyalert) {
            Alert(
                title: Text("Playit Link Invalid"),
                message: Text("Your Playit link is invalid or expired. Please link again."),
                dismissButton: .default(Text("OK"))
            )
        }
        .sheet(isPresented: $showclaim) {
            if let url = URL(string: playitmodel.claimurl), !playitmodel.claimurl.isEmpty {
                SafariView(url: url)
                    .ignoresSafeArea()
            }
        }
        .sheet(isPresented: $showlogs) {
            LogsViewSheet(logger: tunnelinglogger)
        }
        .onAppear {
            model.refreshInstalledServices()
            model.refreshAvailableServices()
            playitmodel.refresh()
            playitmodel.startstatuspolling()

            setInstallSelection(installSelection.subtracting(model.installedServiceIds))
            resumeInstallIfNeeded()

            appendConsole("Playit status: \(playitmodel.status)")
            if let addr = playitmodel.lastaddr, !addr.isEmpty {
                appendConsole("Playit address: \(addr)")
            }
            if let err = playitmodel.lasterr, !err.isEmpty {
                appendConsole("Playit error: \(err)")
            }
        }
        .onDisappear {
            playitmodel.stopstatuspolling()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            playitmodel.refresh()
        }
        .onChange(of: playitmodel.status) { newValue in
            appendConsole("Playit status: \(newValue)")
            if newValue == "Connecting" {
                appendConsole("Info: Connecting means the agent started and is negotiating a control session with Playit.")
            } else if newValue == "Connected" {
                appendConsole("Info: Connected means the tunnel is ready and an address is assigned.")
            } else if newValue == "Disconnected" {
                appendConsole("Info: Disconnected means the Playit agent is not started yet.")
            }
        }
        .onChange(of: playitmodel.lastaddr) { newValue in
            guard let newValue, !newValue.isEmpty else { return }
            appendConsole("Playit address: \(newValue)")
        }
        .onChange(of: playitmodel.lasterr) { newValue in
            guard let newValue, !newValue.isEmpty else { return }
            appendConsole("Playit error: \(newValue)")
        }
        .onChange(of: playitmodel.claimstatus) { newValue in
            guard playitmodel.claiming, !newValue.isEmpty else { return }
            appendConsole("Playit: \(newValue)")
        }
        .onChange(of: playitmodel.claiming) { newValue in
            appendConsole(newValue ? "Playit: claim started" : "Playit: claim ended")
        }
        .onChange(of: installInProgress) { newValue in
            appendConsole(newValue ? "Install: started" : "Install: finished")
        }
        .onChange(of: model.showInstallError) { newValue in
            guard newValue else { return }
            appendConsole("Install error: \(model.installErrorMessage ?? "Unknown error")")
        }
    }

    @ViewBuilder
    private var tunnelingSection: some View {
        Section {
            tunnelingPickerRow
            installToggleRow

            if showInstallDropdown {
                installList
                installButton
            }
        } header: {
            Text("Tunneling")
        } footer: {
            Text("Install a tunneling service above to expose your server.")
        }
    }

    private var tunnelingPickerRow: some View {
        HStack(alignment: .center, spacing: 2.5) {
            Text("Service")
            Spacer()
            if model.availableServiceIds.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(Color.yellow)
                Text("No services found")
                    .foregroundColor(Color.secondary)
            } else {
                Picker("Tunneling", selection: $model.selectedServiceId) {
                    ForEach(model.availableServiceIds, id: \.self) { id in
                        Text(model.displayName(for: id)).tag(id)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(maxWidth: 260)
            }
        }
        .onChange(of: model.selectedServiceId) { newValue in
            model.applyAndSaveSelectedService(newValue)
        }
    }

    private var installToggleRow: some View {
        Button(action: {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                showInstallDropdown.toggle()
            }
        }) {
            HStack(alignment: .center, spacing: 12) {
                Text("Install Tunneling Service")
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(showInstallDropdown ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    @ViewBuilder
    private var installList: some View {
        let nonInstalled = model.allServices.filter { !model.installedServiceIds.contains($0.id) }
        let installed = model.allServices.filter { model.installedServiceIds.contains($0.id) }

        ForEach(nonInstalled) { info in
            InstallTunnelingRow(
                name: info.name,
                isInstalled: false,
                isSelected: installSelection.contains(info.id),
                isInstalling: installInProgress && installQueue.contains(info.id),
                onToggle: { toggleSelection(info.id) }
            )
            .disabled(installInProgress)
        }

        ForEach(installed) { info in
            InstallTunnelingRow(
                name: info.name,
                isInstalled: true,
                isSelected: false,
                isInstalling: false,
                onToggle: { }
            )
            .disabled(true)
        }
        .onDelete { offsets in
            for i in offsets {
                guard i >= 0 && i < installed.count else { continue }
                let id = installed[i].id
                model.deleteInstalledService(id)
                setInstallSelection(installSelection.subtracting([id]))
            }
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var installButton: some View {
        Button(action: {
            let selected = installSelection.subtracting(model.installedServiceIds)
            guard !selected.isEmpty else { return }

            let ordered = orderedIds(selected)
            model.installServices(
                services: ordered,
                updateInProgress: { installInProgress = $0 },
                updateQueueCSV: { installQueueCSV = $0 },
                clearSelection: { setInstallSelection([]) }
            )
        }) {
            HStack(spacing: 10) {
                if installInProgress {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .accentColor(.white)
                }
                Text(installInProgress ? "Installing…" : "Install")
                    .font(.system(size: 17, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background((installSelection.isEmpty || installInProgress) ? Color.gray.opacity(0.35) : Color.green)
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(installSelection.isEmpty || installInProgress)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        .listRowBackground(Color(UIColor.secondarySystemBackground))
        .transition(.opacity)
    }

    @ViewBuilder
    private var playitSection: some View {
        if playitmodel.islibrarypresent {
            Section {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(playitmodel.status)
                        .foregroundColor(playitmodel.status.lowercased().contains("disconnected") ? .secondary : .green)
                    .buttonStyle(BorderlessButtonStyle())
                }

                if let address = playitmodel.lastaddr, !address.isEmpty {
                    HStack {
                        Text("Address")
                        Spacer()
                        Text(address)
                            .font(.system(size: 14, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button(action: {
                            UIPasteboard.general.string = address
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }) {
                            Image(systemName: "doc.on.doc")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                    }
                }

                Button(action: {
                    if !playitmodel.linked {
                        playitmodel.beginClaimFlow()
                    }
                    showclaim = true
                }) {
                    HStack {
                        Text(playitmodel.linked ? "Manage Playit" : "Link Playit")
                            .foregroundColor(.primary)
                        Spacer()
                        Image(systemName: playitmodel.linked ? "gearshape" : "link")
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(PlainButtonStyle())

                Button("Reset Playit Link") {
                    playitmodel.resetlink()
                }
                .disabled(!playitmodel.linked)
                .foregroundColor(.red)
                .buttonStyle(PlainButtonStyle())
            } header: {
                Text("Playit")
            } footer: {
                Text("Playit starts at the same time as your server. Link your account to get a public address.")
            }
        }
    }

    private var startPlayitButton: some View {
        let startDisabled = !serverRunning || !playitmodel.linked || !playitmodel.islibrarypresent || playitmodel.isstarting
        return Button(action: {
            playitmodel.startifpossible()
        }) {
            HStack(spacing: 10) {
                if playitmodel.isstarting {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                }
                Text(playitmodel.isstarting ? "Starting…" : "Start Playit")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .foregroundColor(.white)
            .background(Color.green)
            .cornerRadius(14)
            .shadow(color: Color.black.opacity(1.0), radius: 8, x: 0, y: 6)
            .padding(.horizontal, 16)
            .padding(.bottom, createButtonBottomPadding)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(startDisabled)
    }

    private var console: some View {
        VStack {
            HStack {
                Spacer()

                Button("Cancel") {
                    playitmodel.cancelClaimFlow()
                }
                .foregroundColor(.red)
                .buttonStyle(BorderlessButtonStyle())
            }

            GroupBox {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Color.clear
                                .frame(height: 0)
                                .background(
                                    GeometryReader { geo in
                                        Color.clear
                                            .preference(
                                                key: ScrollOffsetPreferenceKey.self,
                                                value: geo.frame(in: .named("console-scroll")).minY
                                            )
                                    }
                                )

                            HStack(spacing: 10) {
                                Text(playitmodel.claimstatus.isEmpty
                                     ? "Claiming…"
                                     : playitmodel.claimstatus)
                                .foregroundColor(.secondary)

                                Spacer()
                            }

                            Color.clear
                                .frame(height: 1)
                                .id("BOTTOM")
                        }
                        .background(
                            GeometryReader { geo in
                                Color.clear
                                    .preference(
                                        key: ScrollContentHeightPreferenceKey.self,
                                        value: geo.size.height
                                    )
                            }
                        )
                    }
                    .coordinateSpace(name: "console-scroll")
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .preference(
                                    key: ScrollViewHeightPreferenceKey.self,
                                    value: geo.size.height
                                )
                        }
                    )
                    .onPreferenceChange(ScrollContentHeightPreferenceKey.self) { newValue in
                        contentheight = newValue
                        let visibleBottom = scrolloffset + scrollviewheight
                        let distanceFromBottom = contentheight - visibleBottom
                        shouldautoscroll = distanceFromBottom < 40
                    }
                    .onPreferenceChange(ScrollViewHeightPreferenceKey.self) { newValue in
                        scrollviewheight = newValue
                        let visibleBottom = scrolloffset + scrollviewheight
                        let distanceFromBottom = contentheight - visibleBottom
                        shouldautoscroll = distanceFromBottom < 40
                    }
                    .onPreferenceChange(ScrollOffsetPreferenceKey.self) { newValue in
                        scrolloffset = -newValue
                        let visibleBottom = scrolloffset + scrollviewheight
                        let distanceFromBottom = contentheight - visibleBottom
                        shouldautoscroll = distanceFromBottom < 40
                    }
                    .onChange(of: playitmodel.claimstatus) { _ in
                        guard shouldautoscroll else { return }
                        proxy.scrollTo("BOTTOM", anchor: .bottom)
                    }
                }
            }
            .frame(minHeight: 100, maxHeight: 100)
        }
        .padding(.horizontal, 16)
    }

    private var createButtonBottomPadding: CGFloat {
        24
    }

    private func resumeInstallIfNeeded() {
        guard !didAutoResumeInstall, installInProgress else { return }
        didAutoResumeInstall = true
        let queue = installQueue
        guard !queue.isEmpty else { return }

        let ordered = orderedIds(queue)
        model.installServices(
            services: ordered,
            updateInProgress: { installInProgress = $0 },
            updateQueueCSV: { installQueueCSV = $0 },
            clearSelection: { setInstallSelection([]) }
        )
    }

    private func appendConsole(_ line: String) {
        if infotheusercouldmaybefinduseful.isEmpty {
            infotheusercouldmaybefinduseful = line
        } else {
            infotheusercouldmaybefinduseful += "\n" + line
        }
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

struct ConnectionSectionView: View {
    @StateObject private var model = TunnelingModel()
    @StateObject private var playitmodel = PlayitModel()
    @StateObject private var upnpmodel = UpnpModel()
    @AppStorage("jessi.server.running") private var serverRunning: Bool = false
    @AppStorage("jessi.tunnel.install.inProgress") private var installInProgress: Bool = false
    @AppStorage("jessi.tunnel.install.queue") private var installQueueCSV: String = ""
    @AppStorage("jessi.upnp.ports") private var upnpPortsCSV: String = "25565"

    @State private var didAutoResumeInstall: Bool = false
    @State private var showclaim: Bool = false
    @State private var showlogs: Bool = false
    @State private var showstatusinfo: Bool = false
    @State private var upnpPortsIsFirstResponder: Bool = false

    private var installQueue: Set<String> {
        Set(installQueueCSV.split(separator: ",").map(String.init))
    }

    private var isPlayitInstalling: Bool {
        installInProgress && installQueue.contains("playit")
    }

    private var isUpnpSelected: Bool {
        model.selectedServiceId == "upnp"
    }

    private var isNoneSelected: Bool {
        model.selectedServiceId == "none"
    }

    var body: some View {
        Group {
            Section {
                serviceRow

                if isNoneSelected {
                    noneSelectedRow
                } else if isUpnpSelected {
                    upnpPortsRow
                    upnpTestRow
                    upnpClearRow
                    upnpResultRow
                } else {
                    if playitmodel.islibrarypresent {
                        statusRow

                        if let address = playitmodel.lastaddr, !address.isEmpty {
                            addressRow(address)
                        }

                        linkRow
                        resetRow
                        startRow
                    } else {
                        installStatusRow
                        if !isPlayitInstalling {
                            retryInstallRow
                        }
                    }
                }
            } header: {
                Text("Connection")
            } footer: {
                connectionFooter
            }
        }
        .sheet(isPresented: $showclaim) {
            if let url = URL(string: playitmodel.claimurl), !playitmodel.claimurl.isEmpty {
                SafariView(url: url)
                    .ignoresSafeArea()
            }
        }
        .sheet(isPresented: $showlogs) {
            LogsViewSheet(logger: tunnelinglogger)
        }
        .alert(isPresented: $model.showInstallError) {
            Alert(
                title: Text("Tunneling Install Failed"),
                message: Text(model.installErrorMessage ?? "Unknown error"),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert(isPresented: $playitmodel.showinvalidkeyalert) {
            Alert(
                title: Text("Playit Link Invalid"),
                message: Text("Your Playit link is invalid or expired. Please link again."),
                dismissButton: .default(Text("OK"))
            )
        }
        .onAppear {
            model.refreshInstalledServices()
            model.refreshAvailableServices()
            playitmodel.refresh()
            playitmodel.startstatuspolling()
            resumeInstallIfNeeded()
        }
        .onDisappear {
            playitmodel.stopstatuspolling()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            playitmodel.refresh()
        }
        .onChange(of: installInProgress) { newValue in
            if !newValue {
                model.refreshInstalledServices()
                model.refreshAvailableServices()
                playitmodel.refresh()
                autoStartIfNeeded()
            }
        }
        .onChange(of: serverRunning) { newValue in
            if newValue {
                autoStartIfNeeded()
                applyUpnpIfNeeded()
            }
        }
        .onChange(of: playitmodel.linked) { _ in
            autoStartIfNeeded()
        }
        .onChange(of: playitmodel.islibrarypresent) { _ in
            autoStartIfNeeded()
        }
        .onChange(of: upnpPortsCSV) { _ in
            applyUpnpIfNeeded()
        }
    }

    private var serviceRow: some View {
        HStack(alignment: .center, spacing: 2.5) {
            Text("Service")
            Spacer()
            if model.availableServiceIds.isEmpty {
                if isPlayitInstalling {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                    Text("Installing…")
                        .foregroundColor(.secondary)
                } else {
                    Text("Unavailable")
                        .foregroundColor(.secondary)
                }
            } else {
                Picker("Tunneling", selection: $model.selectedServiceId) {
                    ForEach(model.availableServiceIds, id: \.self) { id in
                        Text(model.displayName(for: id)).tag(id)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(maxWidth: 260)
            }
        }
        .onChange(of: model.selectedServiceId) { newValue in
            model.applyAndSaveSelectedService(newValue)
            autoStartIfNeeded()
        }
    }

    @ViewBuilder
    private var connectionFooter: some View {
        if #available(iOS 15.0, *) {
            Text(makeConnectionFooterAttributedText())
        } else {
            Text(connectionFooterPlainText)
        }
    }

    private var connectionFooterPlainText: String {
        "Allow people outside of your local network to connect to your server. For more information, check the GitHub README."
    }

    @available(iOS 15.0, *)
    private func makeConnectionFooterAttributedText() -> AttributedString {
        var text = AttributedString(connectionFooterPlainText)
        if let range = text.range(of: "check the GitHub README.") {
            text[range].link = URL(string: "https://github.com/Baconium/JESSI")
            text[range].underlineStyle = .single
            text[range].foregroundColor = .gray
        }
        return text
    }

    private var statusRow: some View {
        HStack {
            Text("Status")
            Spacer()
            Text(playitmodel.status)
                .foregroundColor(playitmodel.status.lowercased().contains("disconnected") ? .secondary : .green)
            .buttonStyle(BorderlessButtonStyle())
        }
    }

    private var noneSelectedRow: some View {
        HStack {
            Text("Use LAN or port forward manually")
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private func addressRow(_ address: String) -> some View {
        HStack {
            Text("Address")
            Spacer()
            Text(address)
                .font(.system(size: 14, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: {
                UIPasteboard.general.string = address
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }) {
                Image(systemName: "doc.on.doc")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(BorderlessButtonStyle())
        }
    }

    private var linkRow: some View {
        Button(action: {
            if !playitmodel.linked {
                playitmodel.beginClaimFlow()
            }
            showclaim = true
        }) {
            HStack {
                Text(playitmodel.linked ? "Manage Playit" : "Link Playit")
                    .foregroundColor(.primary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var resetRow: some View {
        Button("Reset Playit Link") {
            playitmodel.resetlink()
        }
        .disabled(!playitmodel.linked)
        .foregroundColor(.red)
        .buttonStyle(PlainButtonStyle())
    }

    private var startRow: some View {
        let startDisabled = !serverRunning || !playitmodel.linked || !playitmodel.islibrarypresent || playitmodel.isstarting
        return Button(action: {
            playitmodel.startifpossible()
        }) {
            HStack(spacing: 10) {
                if playitmodel.isstarting {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                }
                Text(playitmodel.isstarting ? "Starting…" : "Start Playit")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(startDisabled)
    }

    private var upnpPortsRow: some View {
        HStack {
            Text("Ports")
            Spacer()
            FocusableDoneToolbarTextField(
                text: $upnpPortsCSV,
                isFirstResponder: $upnpPortsIsFirstResponder,
                placeholder: "25565,25575",
                keyboardType: .numbersAndPunctuation,
                textAlignment: .right,
                font: .systemFont(ofSize: 16)
            )
            .frame(width: 160)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            upnpPortsIsFirstResponder = true
        }
    }

    private var upnpTestRow: some View {
        Button(action: {
            upnpmodel.enablePorts(parsePorts())
            upnpmodel.test()
        }) {
            HStack(spacing: 10) {
                if upnpmodel.isTesting {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                }
                Text(upnpmodel.isTesting ? "Testing…" : "Test UPnP")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(upnpmodel.isTesting)
    }

    private var upnpClearRow: some View {
        Button(action: {
            upnpmodel.clearPorts(parsePorts())
        }) {
            HStack(spacing: 10) {
                if upnpmodel.isApplying {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                }
                Text(upnpmodel.isApplying ? "Clearing…" : "Clear UPnP Ports")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(upnpmodel.isApplying)
    }

    @ViewBuilder
    private var upnpResultRow: some View {
        if let result = upnpmodel.testResult ?? upnpmodel.statusMessage {
            HStack {
                Text(result)
                    .foregroundColor((upnpmodel.testSuccess ?? upnpmodel.statusSuccess ?? false) ? .green : .secondary)
                Spacer()
            }
        }
    }

    private var installStatusRow: some View {
        HStack {
            Text("Playit")
            Spacer()
            if isPlayitInstalling {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                Text("Installing…")
                    .foregroundColor(.secondary)
            } else {
                Text("Not installed")
                    .foregroundColor(.secondary)
            }
        }
    }

    private var retryInstallRow: some View {
        Button("Retry Playit Download") {
            startPlayitInstall(showErrors: true)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func startPlayitInstall(showErrors: Bool) {
        model.installServices(
            services: ["playit"],
            updateInProgress: { installInProgress = $0 },
            updateQueueCSV: { installQueueCSV = $0 },
            clearSelection: { },
            showErrors: showErrors
        )
    }

    private func resumeInstallIfNeeded() {
        guard !didAutoResumeInstall, installInProgress else { return }
        didAutoResumeInstall = true
        let queue = installQueue
        guard !queue.isEmpty else { return }

        model.installServices(
            services: Array(queue),
            updateInProgress: { installInProgress = $0 },
            updateQueueCSV: { installQueueCSV = $0 },
            clearSelection: { },
            showErrors: false
        )
    }

    private func autoStartIfNeeded() {
        guard model.selectedServiceId == "playit" else { return }
        guard serverRunning else { return }
        guard playitmodel.linked else { return }
        guard playitmodel.islibrarypresent else { return }
        playitmodel.startifpossible()
    }

    private func applyUpnpIfNeeded() {
        guard isUpnpSelected else { return }
        guard serverRunning else { return }
        upnpmodel.enablePorts(parsePorts())
    }

    private func parsePorts() -> [Int] {
        let parts = upnpPortsCSV.split { ",; \n\t".contains($0) }
        var out: [Int] = []
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = Int(trimmed), (1...65535).contains(value) {
                if !out.contains(value) { out.append(value) }
            }
        }
        return out
    }
}
