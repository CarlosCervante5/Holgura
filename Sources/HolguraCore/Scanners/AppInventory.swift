import Foundation

public struct InstalledApp: Identifiable, Hashable, Codable, Sendable {
    public let url: URL
    public let name: String
    public let bundleID: String?
    public let version: String?
    public var size: Int64
    public var id: String { url.path }
}

/// Inventario de apps de terceros y búsqueda de sus restos en ~/Library.
public struct AppInventory: Sendable {
    public let scanner: FileScanner
    public let home: URL
    public let applicationDirectories: [URL]

    public init(scanner: FileScanner = FileScanner(),
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                applicationDirectories: [URL]? = nil) {
        self.scanner = scanner
        self.home = home
        self.applicationDirectories = applicationDirectories
            ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
    }

    /// Carpetas de ~/Library donde se buscan restos.
    public static let leftoverLocations = [
        "Library/Application Support", "Library/Caches", "Library/Preferences", "Library/Preferences/ByHost",
        "Library/Containers", "Library/Group Containers", "Library/Saved Application State",
        "Library/LaunchAgents", "Library/HTTPStorages", "Library/WebKit", "Library/Logs", "Library/Cookies",
    ]

    public func listApps(progress: ProgressBox) async throws -> [InstalledApp] {
        progress.setPhase("Buscando aplicaciones…")
        var bundles: [URL] = []
        for dir in applicationDirectories {
            for url in scanner.children(of: dir, progress: progress, includeHidden: false) {
                if url.pathExtension == "app" {
                    bundles.append(url)
                } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    // Un nivel más (p. ej. /Applications/Utilities o carpetas de suites).
                    bundles += scanner.children(of: url, progress: progress, includeHidden: false)
                        .filter { $0.pathExtension == "app" }
                }
            }
        }

        let infos: [(URL, String, String?, String?)] = bundles.compactMap { url in
            let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
            let bid = info?["CFBundleIdentifier"] as? String
            if let bid, bid.lowercased().hasPrefix("com.apple.") { return nil }
            if scanner.protected.isProtected(url) { return nil }
            let name = (info?["CFBundleDisplayName"] as? String)
                ?? (info?["CFBundleName"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            return (url, name, bid, info?["CFBundleShortVersionString"] as? String)
        }

        progress.setPhase("Midiendo \(infos.count) aplicaciones…")
        progress.setTotal(infos.count)
        let scanner = self.scanner
        let apps = try await concurrentMap(infos) { info -> InstalledApp in
            defer { progress.advance() }
            let size = try scanner.allocatedSize(of: info.0, progress: progress)
            return InstalledApp(url: info.0, name: info.1, bundleID: info.2, version: info.3, size: size)
        }
        return apps.sorted { $0.size > $1.size }
    }

    /// La app y todos sus restos (coincidencia por bundle identifier y, aparte, por nombre).
    public func leftovers(for app: InstalledApp, progress: ProgressBox = ProgressBox()) async throws -> [CleanableItem] {
        var matches: [(URL, String, Bool, String)] = [] // url, ubicación, seleccionado, nota
        let bid = app.bundleID?.lowercased()
        let appName = app.name.lowercased()
        let bundleName = app.url.deletingPathExtension().lastPathComponent.lowercased()

        for location in Self.leftoverLocations {
            let dir = home.appendingPathComponent(location)
            let label = location.replacingOccurrences(of: "Library/", with: "")
            for url in scanner.children(of: dir, progress: progress) {
                let name = url.lastPathComponent.lowercased()
                if name.hasPrefix("com.apple.") { continue }
                if let bid, Self.matchesBundleID(name: name, bundleID: bid, location: location) {
                    matches.append((url, label, true, "Coincide con \(app.bundleID ?? "")"))
                } else if ["Library/Application Support", "Library/Caches", "Library/Logs"].contains(location),
                          name == appName || name == bundleName {
                    matches.append((url, label, false, "Coincide solo por nombre: revisa antes de moverlo"))
                }
            }
        }

        let meta = Dictionary(matches.map { ($0.0, $0) }, uniquingKeysWith: { a, _ in a })
        progress.setTotal(matches.count)
        var items = try await scanner.items(for: matches.map(\.0), progress: progress) { url, size, modified in
            guard let m = meta[url] else { return nil }
            return CleanableItem(url: url, size: size, modified: modified, kind: .appLeftover,
                                 group: m.1, note: m.3, selectedByDefault: m.2)
        }
        items.sort { $0.size > $1.size }
        let modified = try? app.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        items.insert(CleanableItem(url: app.url, name: app.name, size: app.size, modified: modified,
                                   kind: .app, group: "Aplicación", selectedByDefault: true), at: 0)
        return items
    }

    /// Reglas de coincidencia por bundle ID (nombres en minúsculas).
    public static func matchesBundleID(name: String, bundleID bid: String, location: String) -> Bool {
        if name == bid || name.hasPrefix(bid + ".") { return true }  // .plist, .savedState, ByHost, .binarycookies
        switch location {
        case "Library/Group Containers", "Library/LaunchAgents":
            // p. ej. "TEAMID.com.empresa.app" o "group.com.empresa.app"
            return name.hasSuffix("." + bid) || name.contains("." + bid + ".") || name.contains(bid + ".plist")
        default:
            return false
        }
    }
}
