import SwiftUI
import Combine
import Security
import Darwin
import Network

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

    @Published var availableserviceids: [String] = []
    @Published var selectedserviceid: String = ""
    @Published var installedserviceids: Set<String> = []

    @Published var installerrormsg: String? = nil
    @Published var showinstallerror: Bool = false

    private let selectedKey = "jessi.tunnel.service"

    init() {
        let stored = UserDefaults.standard.string(forKey: selectedKey)
        selectedserviceid = stored ?? allServices.first?.id ?? ""

        refreshinstalledservices()
        refreshavailableservices()
    }

    func applyandsaveselectedservice(_ id: String) {
        selectedserviceid = id
        UserDefaults.standard.set(id, forKey: selectedKey)
    }

    func displayname(for id: String) -> String {
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

    func refreshinstalledservices() {
        let installed = allServices.compactMap { info -> String? in
            if info.fileName == nil { return info.id }
            guard let fileURL = serviceFileURL(for: info.id) else { return nil }
            return FileManager.default.fileExists(atPath: fileURL.path) ? info.id : nil
        }
        installedserviceids = Set(installed)
    }

    func refreshavailableservices() {
        availableserviceids = allServices.map { $0.id }.filter(installedserviceids.contains)

        if !availableserviceids.contains(selectedserviceid), let first = availableserviceids.first {
            applyandsaveselectedservice(first)
        }
    }

    func deleteInstalledService(_ id: String) {
        guard installedserviceids.contains(id) else { return }
        try? FileManager.default.removeItem(at: serviceDir(for: id))
        refreshinstalledservices()
        refreshavailableservices()
    }

    private func installoneservice(id: String, completion: @escaping (Result<Void, Error>) -> Void) {
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

    func installservices(
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
                    self.installerrormsg = message
                    self.showinstallerror = true
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
                    self.refreshinstalledservices()
                    self.refreshavailableservices()
                }
                updateQueueCSV("")
                updateInProgress(false)
                clearSelection()
                return
            }

            let current = remaining.removeFirst()
            updateQueueCSV(([current] + remaining).joined(separator: ","))

            self.installoneservice(id: current) { result in
                switch result {
                case .success:
                    DispatchQueue.main.async {
                        self.refreshinstalledservices()
                        self.refreshavailableservices()
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

    static func autoinstallplayitondemand() {
        let defaults = UserDefaults.standard
        let autoKey = "jessi.tunnel.autoInstall.started"
        guard !defaults.bool(forKey: autoKey) else { return }
        defaults.set(true, forKey: autoKey)

        let model = TunnelingModel()
        model.refreshinstalledservices()
        if model.installedserviceids.contains("playit") {
            return
        }

        model.installservices(
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
    @Published var isstopping: Bool = false
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
            setstatus("Disconnected")
            setlastaddr(nil)
        }
    }

    func resetlink() {
        defaults.removeObject(forKey: secretkeykey)
        defaults.removeObject(forKey: statuskey)
        defaults.removeObject(forKey: lastaddrkey)
        defaults.removeObject(forKey: lasterrkey)
        linked = false
        setstatus("Disconnected")
        setlastaddr(nil)
        seterror(nil)
    }

    func clearcache() {
        resetlink()
        
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let configDir = home + "/.config/playit"
        try? fm.removeItem(atPath: configDir)
        
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let playitAppSupport = appSupport.appendingPathComponent("playit")
        try? fm.removeItem(at: playitAppSupport)
        
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let playitDocuments = documents.appendingPathComponent("playit")
        try? fm.removeItem(at: playitDocuments)
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
        if isstarting || isstopping { return }
        guard islibrarypresent else {
            seterror("Playit library missing")
            return
        }
        guard let secret = defaults.string(forKey: secretkeykey), !secret.isEmpty else {
            seterror("Playit not linked")
            return
        }

        isstarting = true
        seterror(nil)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let error = self.startlibrary(secretkey: secret)
            DispatchQueue.main.async {
                self.isstarting = false
                if let error {
                    self.seterror(error)
                } else {
                    self.startstatuspolling()
                    self.refreshfromlibrary()
                }
            }
        }
    }

    func stopifpossible() {
        if isstarting || isstopping { return }
        guard let handle = libhandle else {
            setstatus("Stopped")
            setlastaddr(nil)
            seterror(nil)
            laststatuscode = .stopped
            return
        }

        guard let playitstop = loadsymbol(handle, name: "playit_stop", type: PlayitStopFn.self) else {
            seterror("Failed to load Playit stop symbol")
            return
        }

        isstopping = true
        seterror(nil)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let stopResult = playitstop()

            DispatchQueue.main.async {
                self.isstopping = false
                if stopResult != 0 {
                    self.seterror("Playit stop failed (\(stopResult))")
                    return
                }

                self.laststatuscode = .stopped
                self.setstatus("Stopped")
                self.setlastaddr(nil)
                self.seterror(nil)
                self.refreshfromlibrary()
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
            "secret_key": secretkey
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

        let addressValue: String? = {
            guard let addr = s.last_address else { return nil }
            let value = String(cString: addr)
            return value.isEmpty ? nil : value
        }()
        setlastaddr(addressValue)

        if code == .disconnected, addressValue == nil, s.last_error == nil, libhandle != nil {
            setstatus("Online (No Active Tunnels)")
        } else {
            setstatus(code.displayname)
        }

        if let err = s.last_error {
            let value = String(cString: err)
            let lower = value.lowercased()
            if lower.contains("over port limit") {
                setstatus("Account Over Port Limit")
            }
            seterror(value)
            if value.contains("InvalidAgentKey") {
                resetlink()
                seterror("Playit link expired or invalid. Please re-link.")
                showinvalidkeyalert = true
            }
        } else {
            seterror(nil)
        }
    }

    private func loadsymbol<T>(_ handle: UnsafeMutableRawPointer, name: String, type: T.Type) -> T? {
        guard let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: type)
    }

    func beginClaimFlow() {
        if claiming { return }

        let code = generateclaimcode()
        let url = "https://playit.gg/claim/\(code)"
        storeclaimurl(url)

        claimstatus = "Waiting for approval... \n"
        claiming = true
        tunnelinglogger.log("welcome to:");
        tunnelinglogger.log("ROOOOTS AMAZING PLAYIT INTEGRATION");
        tunnelinglogger.divider();
        tunnelinglogger.log("Playit: claim started (\(code))")

        claimTask?.cancel()
        claimTask = Task { [weak self] in
            await self?.runclaimflow(code: code)
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
        seterror(message)
    }

    @MainActor
    private func finishClaimSuccess(secretKey: String) {
        claiming = false
        storesecretkey(secretKey)
        linked = true
        seterror(nil)
        tunnelinglogger.log("Playit: claim success")
        bringAgentOnlineAfterClaim()
    }

    @MainActor
    private func bringAgentOnlineAfterClaim() {
        // Refresh persisted state first; `islibrarypresent` can be stale if install state changed.
        refresh()

        guard islibrarypresent else {
            seterror("Playit linked, but the Playit library is missing.")
            return
        }

        // First attempt immediately.
        startifpossible()

        Task { @MainActor in
            // Retry startup/status a few times to handle claim->connect race conditions.
            for attempt in 0..<8 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.refreshfromlibrary()

                if self.laststatuscode == .connected {
                    return
                }

                // In this FFI, `.disconnected` can also mean "no active tunnel yet".
                // Only retry startup when clearly not running/failed.
                if !self.isstarting && (self.laststatuscode == .stopped || self.laststatuscode == .error || self.laststatuscode == nil) {
                    tunnelinglogger.log("Playit: retrying agent start after claim (attempt \(attempt + 2))")
                    self.startifpossible()
                }
            }
        }
    }

    private func storeclaimurl(_ url: String) {
        claimurl = url
        defaults.set(url, forKey: claimurlkey)
    }

    private func storesecretkey(_ key: String) {
        defaults.set(key, forKey: secretkeykey)
    }

    private func setstatus(_ value: String) {
        status = value
        defaults.set(value, forKey: statuskey)
    }

    private func setlastaddr(_ value: String?) {
        lastaddr = value
        if let value {
            defaults.set(value, forKey: lastaddrkey)
        } else {
            defaults.removeObject(forKey: lastaddrkey)
        }
    }

    private func seterror(_ value: String?) {
        lasterr = value
        if let value {
            defaults.set(value, forKey: lasterrkey)
        } else {
            defaults.removeObject(forKey: lasterrkey)
        }
    }

    private func generateclaimcode() -> String {
        var bytes = [UInt8](repeating: 0, count: 5)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if result != errSecSuccess {
            bytes = (0..<5).map { _ in UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func runclaimflow(code: String) async {
        let version = appversionstring()
        let setupReq = ClaimSetupRequest(code: code, agent_type: "self-managed", version: version)

        while !Task.isCancelled {
            do {
                let result: ApiResult<String, String> = try await post(path: "/claim/setup", body: setupReq)
                switch result {
                case .success(let status):
                    let state = parseclaimsetupstatus(status)
                    switch state {
                    case .waitingForUserVisit:
                        await updateClaimStatus("Open the link to continue")
                    case .waitingForUser:
                        await updateClaimStatus("Approve the request in your browser")
                    case .userAccepted:
                        await updateClaimStatus("Approved. Finalizing…")
                        tunnelinglogger.log("Playit: claim approved")
                        await exchangeclaim(code: code)
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

    private func exchangeclaim(code: String) async {
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

    private func appversionstring() -> String {
        let bundle = Bundle.main
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "JESSI (iOS) \(version) (\(build))"
    }

    private func parseclaimsetupstatus(_ raw: String) -> ClaimSetupState {
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
    tunnelinglogger.log("[playit-ios] \(prefix) \(text)")
}
