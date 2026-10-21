import Foundation

/// Único punto de la app que modifica el disco: mueve elementos a la Papelera con
/// `FileManager.trashItem`. Nunca borra (`removeItem`/`rm`) y registra cada acción.
public final class TrashService: @unchecked Sendable {
    public static let shared = TrashService()

    private let protected: ProtectedPaths
    private let logger: CleanupLogger
    private let fileManager: FileManager

    public init(protected: ProtectedPaths = .default,
                logger: CleanupLogger = .shared,
                fileManager: FileManager = .default) {
        self.protected = protected
        self.logger = logger
        self.fileManager = fileManager
    }

    /// Elimina elementos repetidos y los que ya están contenidos en otro elemento de la lista.
    public static func normalized(_ items: [CleanableItem]) -> [CleanableItem] {
        var unique: [String: CleanableItem] = [:]
        for item in items { unique[item.url.standardizedFileURL.path] = item }
        let paths = Set(unique.keys)
        return unique.filter { path, _ in
            var parent = (path as NSString).deletingLastPathComponent
            while parent != "/" && !parent.isEmpty {
                if paths.contains(parent) { return false }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return true
        }
        .map(\.value)
        .sorted { $0.url.path < $1.url.path }
    }

    public func moveToTrash(_ items: [CleanableItem], progress: ProgressBox? = nil) async -> CleanupResult {
        var result = CleanupResult()
        // Primero se descartan los rechazados, para que una carpeta crítica no "absorba" su contenido.
        var allowed: [CleanableItem] = []
        for item in items {
            if let reason = protected.trashRefusalReason(for: item.url) {
                result.failures.append(CleanupFailure(item: item, reason: reason))
                logger.log(action: "RECHAZADO", path: item.url.path, size: item.size, detail: reason)
            } else {
                allowed.append(item)
            }
        }
        let list = Self.normalized(allowed)
        progress?.setTotal(list.count)
        for item in list {
            if Task.isCancelled { break }
            progress?.visit(item.url)
            defer { progress?.advance() }

            // attributesOfItem no sigue symlinks: detecta también enlaces rotos.
            guard (try? fileManager.attributesOfItem(atPath: item.url.path)) != nil else {
                result.failures.append(CleanupFailure(item: item, reason: "Ya no existe"))
                continue
            }
            do {
                var resulting: NSURL?
                try fileManager.trashItem(at: item.url, resultingItemURL: &resulting)
                result.trashed.append(item)
                logger.log(action: "PAPELERA", path: item.url.path, size: item.size,
                           detail: (resulting as URL?)?.path)
            } catch {
                result.failures.append(CleanupFailure(item: item, reason: error.localizedDescription))
                logger.log(action: "ERROR", path: item.url.path, size: item.size, detail: error.localizedDescription)
            }
        }
        return result
    }
}
