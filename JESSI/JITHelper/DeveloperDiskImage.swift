import Foundation

enum DeveloperDiskImage {
    private struct Item {
        let name: String
        let fileName: String
    }

    static var usesCryptex: Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return version.majorVersion > 26 || (version.majorVersion == 26 && version.minorVersion >= 4)
    }

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(usesCryptex ? "DDI-Cryptex" : "DDI-Personalized", isDirectory: true)
    }

    private static var baseURL: String {
        "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/"
            + (usesCryptex ? "Xcode_iOS_DDI_Cryptex/" : "Xcode_iOS_DDI_Personalized/")
    }

    private static var items: [Item] {
        var items = [
            Item(name: "build manifest", fileName: "BuildManifest.plist"),
            Item(name: "disk image", fileName: "Image.dmg"),
            Item(name: "trust cache", fileName: "Image.dmg.trustcache"),
        ]
        if usesCryptex {
            items.append(Item(name: "cryptex info", fileName: "Image.dmg.cryptex_info"))
            items.append(Item(name: "root hash", fileName: "Image.dmg.root_hash"))
        }
        return items
    }

    static var isDownloaded: Bool {
        items.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.fileName).path) }
    }

    static func downloadMissing(progress: (String) -> Void) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        for item in items {
            let destination = directory.appendingPathComponent(item.fileName)
            if fileManager.fileExists(atPath: destination.path) { continue }
            guard let url = URL(string: baseURL + item.fileName) else {
                throw HelperError("Invalid DDI URL for \(item.fileName)")
            }

            progress("Downloading \(item.name)…")
            let temporary = try download(url)
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    private static func download(_ url: URL) throws -> URL {
        let finished = DispatchSemaphore(value: 0)
        var result: Result<URL, Error> = .failure(HelperError("Download did not complete"))

        let task = URLSession.shared.downloadTask(with: url) { location, response, error in
            defer { finished.signal() }
            if let error {
                result = .failure(error)
                return
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let location else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                result = .failure(HelperError("DDI download failed (HTTP \(status)) for \(url.lastPathComponent)"))
                return
            }
            let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do {
                try FileManager.default.moveItem(at: location, to: kept)
                result = .success(kept)
            } catch {
                result = .failure(error)
            }
        }
        task.resume()
        finished.wait()
        return try result.get()
    }
}
