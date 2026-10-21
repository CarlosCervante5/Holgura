import Foundation
import AppKit

/// Cachés de usuario, registros y temporales, agrupados por app.
public struct JunkScanner: Sendable {
    public let scanner: FileScanner
    public let home: URL

    /// Cachés que se muestran en el módulo Desarrollador (para no contarlas dos veces).
    public static let developerCacheNames: Set<String> = [
        "homebrew", "pip", "yarn", "cocoapods", "pnpm", "org.carthage.carthagekit", "node-gyp",
    ]

    /// Cachés que es mejor no tocar aunque estén en ~/Library/Caches.
    static let skippedCacheNames: Set<String> = [
        "com.apple.bird", "cloudkit", "com.apple.akd", "com.apple.ap.adprivacyd", "familycircle",
        "com.apple.homed", "com.apple.containermanagerd", "holgura",
    ]

    public init(scanner: FileScanner = FileScanner(),
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.scanner = scanner
        self.home = home
    }

    public func scan(progress: ProgressBox) async throws -> [ItemGroup] {
        progress.setPhase("Buscando cachés, registros y temporales…")
        let caches = home.appendingPathComponent("Library/Caches")
        let logs = home.appendingPathComponent("Library/Logs")
        let temp = FileManager.default.temporaryDirectory

        var candidates: [(URL, ItemKind)] = []
        for url in scanner.children(of: caches, progress: progress) {
            let name = url.lastPathComponent.lowercased()
            if Self.developerCacheNames.contains(name) || Self.skippedCacheNames.contains(name) { continue }
            candidates.append((url, .cache))
        }
        for url in scanner.children(of: logs, progress: progress) {
            candidates.append((url, .log))
        }
        // Solo temporales que no se han tocado en las últimas 24 h (pueden estar en uso).
        let dayAgo = Date().addingTimeInterval(-86_400)
        for url in scanner.children(of: temp, progress: progress) {
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if let modified, modified > dayAgo { continue }
            candidates.append((url, .temp))
        }

        progress.setPhase("Calculando tamaños…")
        progress.setTotal(candidates.count)
        let kinds = Dictionary(candidates.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        let items = try await scanner.items(for: candidates.map(\.0), progress: progress) { url, size, modified in
            guard size > 0, let kind = kinds[url] else { return nil }
            let name = url.lastPathComponent
            let isApple = name.lowercased().hasPrefix("com.apple.")
            let group: String
            switch kind {
            case .temp: group = "Archivos temporales"
            default: group = AppNameResolver.displayName(for: name)
            }
            return CleanableItem(url: url,
                                 name: "\(name) · \(kind.label)",
                                 size: size,
                                 modified: modified,
                                 kind: kind,
                                 group: group,
                                 note: isApple ? "Datos de Apple: se regeneran, pero revisa antes de borrar" : nil,
                                 selectedByDefault: !isApple)
        }

        let grouped = Dictionary(grouping: items, by: \.group)
        return grouped.map { name, items in
            let symbol: String
            if name == "Archivos temporales" { symbol = "clock.arrow.circlepath" }
            else if items.allSatisfy({ $0.kind == .log }) { symbol = "doc.text" }
            else { symbol = "tray.full" }
            return ItemGroup(name: name, symbol: symbol, items: items.sorted { $0.size > $1.size })
        }
        .sorted { $0.totalSize > $1.totalSize }
    }
}

/// Convierte nombres tipo `com.google.Chrome` en el nombre visible de la app, si está instalada.
public enum AppNameResolver {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String] = [:]

    public static func displayName(for folderName: String) -> String {
        lock.lock()
        if let cached = cache[folderName] { lock.unlock(); return cached }
        lock.unlock()

        var result = folderName
        let looksLikeBundleID = folderName.split(separator: ".").count >= 3 && !folderName.contains(" ")
        if looksLikeBundleID {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: folderName) {
                result = FileManager.default.displayName(atPath: appURL.path)
                    .replacingOccurrences(of: ".app", with: "")
            } else {
                result = folderName
            }
        }
        lock.lock()
        cache[folderName] = result
        lock.unlock()
        return result
    }
}
