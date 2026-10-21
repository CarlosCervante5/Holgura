import Foundation

/// Motor de escaneo de solo lectura. Nunca sigue symlinks y salta las rutas protegidas.
public struct FileScanner: Sendable {
    public let protected: ProtectedPaths

    public static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isRegularFileKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .contentModificationDateKey,
    ]
    static let resourceKeySet = Set(resourceKeys)

    public init(protected: ProtectedPaths = .default) {
        self.protected = protected
    }

    /// Tamaño real en disco de un archivo, según `totalFileAllocatedSize`.
    public static func allocatedSize(_ values: URLResourceValues?) -> Int64 {
        guard let values else { return 0 }
        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }

    /// Tamaño real en disco de un archivo o carpeta (recursivo, incluyendo el contenido de paquetes).
    /// Las rutas inaccesibles se registran en `progress` y se saltan.
    public func allocatedSize(of url: URL, progress: ProgressBox? = nil) throws -> Int64 {
        if protected.isProtected(url) { return 0 }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: Self.resourceKeySet)
        } catch {
            progress?.addIssue(path: url.path, reason: error.localizedDescription)
            return 0
        }
        if values.isSymbolicLink == true || values.isDirectory != true {
            progress?.visit(url)
            return Self.allocatedSize(values)
        }

        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Self.resourceKeys,
            options: [],
            errorHandler: { failedURL, error in
                progress?.addIssue(path: failedURL.path, reason: error.localizedDescription)
                return true
            })
        guard let enumerator else {
            progress?.addIssue(path: url.path, reason: "No se pudo leer la carpeta")
            return 0
        }

        var total: Int64 = 0
        var count = 0
        for case let child as URL in enumerator {
            count += 1
            if count & 511 == 0 { try Task.checkCancellation() }
            let v = try? child.resourceValues(forKeys: Self.resourceKeySet)
            if v?.isDirectory == true && v?.isSymbolicLink != true {
                if protected.isProtected(child) { enumerator.skipDescendants() }
                continue
            }
            progress?.visit(child)
            total += Self.allocatedSize(v)
        }
        return total
    }

    /// Hijos directos de una carpeta (sin seguir symlinks). Registra el error si no se puede leer.
    public func children(of dir: URL, progress: ProgressBox? = nil, includeHidden: Bool = true) -> [URL] {
        do {
            let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
            let urls = try FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: Self.resourceKeys, options: options)
            return urls.filter { !protected.isProtected($0) }
        } catch {
            if FileManager.default.fileExists(atPath: dir.path) {
                progress?.addIssue(path: dir.path, reason: error.localizedDescription)
            }
            return []
        }
    }

    /// Calcula en paralelo el tamaño de cada URL y la convierte en `CleanableItem`.
    public func items(for urls: [URL],
                      progress: ProgressBox? = nil,
                      make: @escaping @Sendable (URL, Int64, Date?) -> CleanableItem?) async throws -> [CleanableItem] {
        let results = try await concurrentMap(urls) { url -> CleanableItem? in
            let size = try self.allocatedSize(of: url, progress: progress)
            progress?.advance()
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return make(url, size, modified)
        }
        return results.compactMap { $0 }
    }
}

/// `map` concurrente con un número máximo de tareas simultáneas (TaskGroup). Respeta la cancelación.
public func concurrentMap<T: Sendable, R: Sendable>(
    _ items: [T],
    maxConcurrent: Int = max(2, ProcessInfo.processInfo.activeProcessorCount),
    _ transform: @escaping @Sendable (T) async throws -> R
) async throws -> [R] {
    if items.isEmpty { return [] }
    return try await withThrowingTaskGroup(of: (Int, R).self) { group in
        var results = [R?](repeating: nil, count: items.count)
        var next = 0
        let initial = min(maxConcurrent, items.count)
        while next < initial {
            let index = next
            let item = items[index]
            group.addTask { (index, try await transform(item)) }
            next += 1
        }
        while let (index, value) = try await group.next() {
            results[index] = value
            try Task.checkCancellation()
            if next < items.count {
                let i = next
                let item = items[i]
                group.addTask { (i, try await transform(item)) }
                next += 1
            }
        }
        return results.map { $0! }
    }
}
