import Foundation

// MARK: - Registro de limpieza

/// Registro local de cada acción de limpieza: `~/Library/Application Support/Holgura/cleanup.log`.
public final class CleanupLogger: @unchecked Sendable {
    public static let shared = CleanupLogger(directory: AppPaths.supportDirectory)

    public let fileURL: URL
    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("cleanup.log")
    }

    public func log(action: String, path: String, size: Int64?, detail: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        var fields = [formatter.string(from: Date()), action]
        if let size {
            fields.append("\(size) bytes (\(Format.bytes(size)))")
        } else {
            fields.append("-")
        }
        fields.append(path)
        if let detail, !detail.isEmpty { fields.append(detail) }
        let line = fields.joined(separator: "\t") + "\n"

        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}

// MARK: - Caché del último escaneo

public final class ScanCache: @unchecked Sendable {
    public static let shared = ScanCache(directory: AppPaths.supportDirectory.appendingPathComponent("cache", isDirectory: true))

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func save<T: Encodable>(_ value: T, key: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(value)
            try data.write(to: directory.appendingPathComponent(key + ".json"), options: .atomic)
        } catch {
            // La caché es opcional: si falla, simplemente no se guarda.
        }
    }

    public func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(key + ".json")) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Disco

public struct DiskUsage: Codable, Sendable, Equatable {
    public var volumeName: String
    public var total: Int64
    public var available: Int64
    public var used: Int64 { max(0, total - available) }

    public static func current(for url: URL = FileManager.default.homeDirectoryForCurrentUser) -> DiskUsage? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                         .volumeAvailableCapacityKey, .volumeLocalizedNameKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity else { return nil }
        let available = values.volumeAvailableCapacityForImportantUsage
            ?? Int64(values.volumeAvailableCapacity ?? 0)
        return DiskUsage(volumeName: values.volumeLocalizedName ?? "Macintosh HD",
                         total: Int64(total),
                         available: available)
    }
}

// MARK: - Permisos

public enum PermissionChecker {
    public static let fullDiskAccessSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// Detecta Acceso total al disco intentando abrir (solo lectura) archivos protegidos por TCC.
    public static func hasFullDiskAccess() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let probes = [
            "/Library/Application Support/com.apple.TCC/TCC.db",
            home + "/Library/Application Support/com.apple.TCC/TCC.db",
            home + "/Library/Safari/Bookmarks.plist",
        ]
        for path in probes where FileManager.default.fileExists(atPath: path) {
            if let handle = FileHandle(forReadingAtPath: path) {
                try? handle.close()
                return true
            }
            return false
        }
        // Último recurso: listar una carpeta protegida.
        let safari = home + "/Library/Safari"
        return (try? FileManager.default.contentsOfDirectory(atPath: safari)) != nil
    }
}

// MARK: - Formato

public enum Format {
    public static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    /// Ruta abreviada con `~`.
    public static func abbreviate(_ url: URL) -> String {
        abbreviate(url.path)
    }

    public static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es")
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "es")
        f.unitsStyle = .full
        return f
    }()

    public static func date(_ date: Date?) -> String {
        guard let date else { return "—" }
        return dateFormatter.string(from: date)
    }

    public static func relative(_ date: Date?) -> String {
        guard let date else { return "nunca" }
        if abs(date.timeIntervalSinceNow) < 60 { return "hace un momento" }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    public static func daysSince(_ date: Date?) -> Int? {
        guard let date else { return nil }
        return Calendar.current.dateComponents([.day], from: date, to: Date()).day
    }
}
