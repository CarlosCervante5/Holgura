import Foundation

/// Lista negra de rutas que la app jamás escanea ni mueve a la Papelera.
///
/// Dos niveles:
/// - `reason(for:)`: rutas protegidas (y todo su contenido). No se escanean ni se tocan.
/// - `trashRefusalReason(for:)`: lo anterior, más carpetas críticas que pueden escanearse
///   pero que nunca deben moverse ellas mismas (p. ej. `~`, `~/Library/Caches`, `/Applications`).
public struct ProtectedPaths: Sendable {
    public let homePath: String
    public let applicationDirectories: [String]
    private let absolutePrefixes: [String]
    private let criticalExact: Set<String>
    private let appleAppCache = AppleAppCache()

    public static let `default` = ProtectedPaths()

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                applicationDirectories: [URL]? = nil) {
        let home = homeDirectory.standardizedFileURL.path.lowercased()
        self.homePath = home

        let appDirs = applicationDirectories?.map { $0.standardizedFileURL.path }
            ?? ["/Applications", homeDirectory.appendingPathComponent("Applications").standardizedFileURL.path]
        self.applicationDirectories = appDirs.map { $0.lowercased() }

        self.absolutePrefixes = [
            "/system",
            "/usr",
            "/bin",
            "/sbin",
            "/private/var/db",
            "/var/db",
            "/library/apple",
            "/system/applications",
            home + "/library/keychains",
            home + "/library/mobile documents",
            home + "/library/mail",
            home + "/library/messages",
        ]

        var critical: Set<String> = [
            "/", "/applications", "/library", "/users", "/private", "/private/var", "/private/tmp",
            "/tmp", "/var", "/volumes", "/opt", "/opt/homebrew", "/cores", "/network",
        ]
        let homeChildren = [
            "", "library", "library/caches", "library/logs", "library/application support",
            "library/preferences", "library/preferences/byhost", "library/containers", "library/group containers",
            "library/saved application state", "library/launchagents", "library/developer",
            "library/developer/xcode", "library/developer/xcode/deriveddata", "library/developer/xcode/archives",
            "library/developer/xcode/ios devicesupport", "library/developer/coresimulator",
            "library/httpstorages", "library/webkit", "library/cookies",
            "applications", "desktop", "documents", "downloads", "movies", "music", "pictures", "public",
            ".trash", ".npm", ".gradle", ".yarn",
        ]
        for child in homeChildren {
            critical.insert(child.isEmpty ? home : home + "/" + child)
        }
        for dir in self.applicationDirectories { critical.insert(dir) }
        let tmp = FileManager.default.temporaryDirectory.standardizedFileURL.path.lowercased()
        critical.insert(tmp)
        critical.insert(URL(fileURLWithPath: tmp).resolvingSymlinksInPath().path.lowercased())
        self.criticalExact = critical
    }

    /// `true` si la ruta (o un ancestro) está en la lista negra.
    public func isProtected(_ url: URL) -> Bool {
        reason(for: url) != nil
    }

    /// Motivo por el que la ruta está protegida, o `nil` si no lo está.
    public func reason(for url: URL) -> String? {
        for path in candidatePaths(url) {
            if let r = check(path) { return r }
        }
        return nil
    }

    /// Motivo por el que este elemento no puede moverse a la Papelera, o `nil` si se puede.
    public func trashRefusalReason(for url: URL) -> String? {
        if let r = reason(for: url) { return r }
        for path in candidatePaths(url) where criticalExact.contains(path.lowercased()) {
            return "Carpeta crítica: no se puede mover completa"
        }
        return nil
    }

    // MARK: - Internos

    /// Rutas a comprobar (conservando mayúsculas): la estandarizada y la de ancestros resueltos.
    private func candidatePaths(_ url: URL) -> [String] {
        var std = url.standardizedFileURL.path
        if std.count > 1 && std.hasSuffix("/") { std.removeLast() }
        // Resolver symlinks de los ancestros (p. ej. /var → /private/var), sin seguir el propio elemento.
        var resolved = std
        if std != "/" {
            let parent = url.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath()
            resolved = parent.appendingPathComponent(url.lastPathComponent).path
            if resolved.count > 1 && resolved.hasSuffix("/") { resolved.removeLast() }
        }
        return std == resolved ? [std] : [std, resolved]
    }

    private func check(_ originalPath: String) -> String? {
        let path = originalPath.lowercased()
        for prefix in absolutePrefixes where path == prefix || path.hasPrefix(prefix + "/") {
            return "Ruta protegida (\(prefix))"
        }
        let components = path.split(separator: "/")
        if components.contains(where: { $0.hasSuffix(".photoslibrary") }) {
            return "Biblioteca de Fotos protegida"
        }
        for dir in applicationDirectories where path.hasPrefix(dir + "/") {
            // Mismo número de caracteres en minúsculas: recortamos sobre la ruta original.
            let rel = originalPath.dropFirst(dir.count + 1).split(separator: "/")
            guard let appIndex = rel.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else { continue }
            let appPath = String(originalPath.prefix(dir.count)) + "/" + rel[...appIndex].joined(separator: "/")
            if appleAppCache.isAppleApp(path: appPath) {
                return "Aplicación de Apple protegida"
            }
        }
        return nil
    }
}

/// Caché (thread-safe) de qué bundles son de Apple, para no leer Info.plist repetidamente.
final class AppleAppCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: Bool] = [:]

    func isAppleApp(path: String) -> Bool {
        lock.lock()
        if let cached = cache[path] { lock.unlock(); return cached }
        lock.unlock()

        let plist = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        var result = false
        if let dict = NSDictionary(contentsOf: plist),
           let bid = dict["CFBundleIdentifier"] as? String {
            result = bid.lowercased().hasPrefix("com.apple.")
        }
        lock.lock()
        cache[path] = result
        lock.unlock()
        return result
    }
}
