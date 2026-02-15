import Foundation
import Combine
import UIKit

struct ServerProperty: Identifiable, Equatable, Hashable {
    let id = UUID()
    var key: String
    var value: String
}

class ServerPropertiesManager: ObservableObject {
    private let fileURL: URL
    @Published var properties: [ServerProperty] = []
    @Published var serverIcon: UIImage? = nil
    
    var serverRoot: URL {
        return fileURL.deletingLastPathComponent()
    }
    
    init(serverPath: String) {
        self.fileURL = URL(fileURLWithPath: serverPath).appendingPathComponent("server.properties")
        load()
        loadIcon()
    }
    
    func loadIcon() {
        let iconURL = serverRoot.appendingPathComponent("server-icon.png")
        if let data = try? Data(contentsOf: iconURL), let image = UIImage(data: data) {
            self.serverIcon = image
        } else {
            self.serverIcon = nil
        }
    }
    
    func updateIcon(_ image: UIImage) {
        let normalized = normalizeIcon(image)
        self.serverIcon = normalized
        if let data = normalized.pngData() {
            let iconURL = serverRoot.appendingPathComponent("server-icon.png")
            try? data.write(to: iconURL)
        }
    }
    
    private func normalizeIcon(_ img: UIImage) -> UIImage {
        let target = CGSize(width: 64, height: 64)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let r = UIGraphicsImageRenderer(size: target, format: format)
        return r.image { ctx in
            UIColor.clear.setFill()
            ctx.fill(CGRect(origin: .zero, size: target))
            img.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else {
            return
        }
        
        var newProps: [ServerProperty] = []
        let lines = content.components(separatedBy: .newlines)
        
        for line in lines {
            let trimming = line.trimmingCharacters(in: .whitespaces)
            if trimming.isEmpty || trimming.hasPrefix("#") { continue }
            
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count >= 1 {
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                newProps.append(ServerProperty(key: key, value: value))
            }
        }
        
        newProps.sort { $0.key < $1.key }
        self.properties = newProps
    }
    
    func save() {
        var content = "#Minecraft server properties\n#\(Date())\n"
        for prop in properties {
            content += "\(prop.key)=\(prop.value)\n"
        }
        
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
    }
    
    func updateProperty(key: String, value: String) {
        if let index = properties.firstIndex(where: { $0.key == key }) {
            properties[index].value = value
        } else {
            properties.append(ServerProperty(key: key, value: value))
            properties.sort { $0.key < $1.key }
        }
        save()
    }
    
    func getProperty(key: String) -> String {
        return properties.first(where: { $0.key == key })?.value ?? ""
    }
}
