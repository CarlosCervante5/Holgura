import Foundation
import CryptoKit

public struct DuplicateFile: Identifiable, Hashable, Codable, Sendable {
    public let url: URL
    /// Tamaño lógico (bytes del contenido).
    public let size: Int64
    /// Tamaño real en disco.
    public let allocatedSize: Int64
    public let created: Date?
    public let modified: Date?
    public var id: String { url.path }
}

public struct DuplicateGroup: Identifiable, Hashable, Codable, Sendable {
    public let hash: String
    public let size: Int64
    public var files: [DuplicateFile]
    public var id: String { hash }

    /// Espacio recuperable si se conserva una sola copia.
    public var wasted: Int64 {
        files.dropFirst().reduce(0) { $0 + $1.allocatedSize }
    }

    public func suggestedKeep(_ strategy: KeepStrategy) -> DuplicateFile? {
        files.min(by: { strategy.prefers($0, over: $1) })
    }
}

public enum KeepStrategy: String, CaseIterable, Codable, Sendable, Identifiable {
    case oldest
    case shortestPath

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .oldest: return "Conservar el más antiguo"
        case .shortestPath: return "Conservar el de ruta más corta"
        }
    }

    /// `true` si `a` debería conservarse antes que `b`.
    func prefers(_ a: DuplicateFile, over b: DuplicateFile) -> Bool {
        let da = a.created ?? a.modified ?? .distantFuture
        let db = b.created ?? b.modified ?? .distantFuture
        let la = (a.url.pathComponents.count, a.url.path.count)
        let lb = (b.url.pathComponents.count, b.url.path.count)
        switch self {
        case .oldest:
            if da != db { return da < db }
            if la != lb { return la < lb }
        case .shortestPath:
            if la != lb { return la < lb }
            if da != db { return da < db }
        }
        return a.url.path < b.url.path
    }
}

/// Detección de duplicados en tres pasos: tamaño → hash parcial (primeros 64 KB) → SHA-256 completo.
public struct DuplicateFinder: Sendable {
    public static let partialLength = 64 * 1024
    public let scanner: FileScanner

    public init(scanner: FileScanner = FileScanner()) {
        self.scanner = scanner
    }

    public func find(in root: URL, minSize: Int64 = 1, progress: ProgressBox = ProgressBox()) async throws -> [DuplicateGroup] {
        // 1. Recorrer y agrupar por tamaño.
        progress.setPhase("Recorriendo archivos…")
        let candidates = try collectFiles(in: root, minSize: max(1, minSize), progress: progress)
        let bySize = Dictionary(grouping: candidates, by: \.size).values.filter { $0.count > 1 }
        let sameSize = bySize.flatMap { Self.uniqueInodes($0) }
        let sizeGroups = Dictionary(grouping: sameSize, by: \.size).values.filter { $0.count > 1 }

        // 2. Hash parcial.
        let toPartial = sizeGroups.flatMap { $0 }
        progress.setPhase("Comparando el inicio de \(toPartial.count) archivos…")
        progress.setTotal(toPartial.count)
        let partials = try await concurrentMap(toPartial) { file -> (DuplicateFile, String?) in
            defer { progress.advance() }
            progress.visit(file.url)
            return (file, try? Self.hash(of: file.url, limit: Self.partialLength))
        }
        let partialHash = Dictionary(partials.compactMap { f, h in h.map { (f.id, $0) } },
                                     uniquingKeysWith: { a, _ in a })
        let partialGroups = Dictionary(grouping: partials.compactMap { f, h in h.map { (f, "\(f.size)-\($0)") } },
                                       by: \.1)
            .values.map { $0.map(\.0) }.filter { $0.count > 1 }

        // 3. SHA-256 completo (si el archivo cabe en 64 KB, el hash parcial ya es el completo).
        let toFull = partialGroups.flatMap { $0 }.filter { $0.size > Int64(Self.partialLength) }
        progress.setPhase("Verificando \(toFull.count) archivos con SHA-256…")
        progress.setTotal(toFull.count)
        let fulls = try await concurrentMap(toFull) { file -> (String, String?) in
            defer { progress.advance() }
            progress.visit(file.url)
            return (file.id, try? Self.hash(of: file.url, limit: nil))
        }
        let fullHash = Dictionary(fulls.compactMap { id, h in h.map { (id, $0) } }, uniquingKeysWith: { a, _ in a })

        var groups: [DuplicateGroup] = []
        for group in partialGroups {
            let keyed: [(DuplicateFile, String)] = group.compactMap { file in
                if file.size <= Int64(Self.partialLength) {
                    return partialHash[file.id].map { (file, $0) }
                }
                return fullHash[file.id].map { (file, $0) }
            }
            for (hash, members) in Dictionary(grouping: keyed, by: \.1) where members.count > 1 {
                let files = members.map(\.0).sorted { $0.url.path < $1.url.path }
                groups.append(DuplicateGroup(hash: hash, size: files[0].size, files: files))
            }
        }
        return groups.sorted { $0.wasted > $1.wasted }
    }

    func collectFiles(in root: URL, minSize: Int64, progress: ProgressBox) throws -> [DuplicateFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
                                      .fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                                      .creationDateKey, .contentModificationDateKey]
        let keySet = Set(keys)
        var files: [DuplicateFile] = []
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                progress.addIssue(path: url.path, reason: error.localizedDescription)
                return true
            })
        var count = 0
        while let url = enumerator?.nextObject() as? URL {
            count += 1
            if count & 511 == 0 { try Task.checkCancellation() }
            guard let v = try? url.resourceValues(forKeys: keySet), v.isSymbolicLink != true else { continue }
            if v.isDirectory == true {
                if scanner.protected.isProtected(url) { enumerator?.skipDescendants() }
                continue
            }
            guard v.isRegularFile == true, let size = v.fileSize, Int64(size) >= minSize else { continue }
            progress.visit(url)
            files.append(DuplicateFile(url: url,
                                       size: Int64(size),
                                       allocatedSize: FileScanner.allocatedSize(v),
                                       created: v.creationDate,
                                       modified: v.contentModificationDate))
        }
        return files
    }

    /// Descarta enlaces duros (mismo inodo): no ocupan espacio extra.
    static func uniqueInodes(_ files: [DuplicateFile]) -> [DuplicateFile] {
        var seen = Set<String>()
        return files.filter { file in
            var st = stat()
            guard lstat(file.url.path, &st) == 0 else { return false }
            return seen.insert("\(st.st_dev):\(st.st_ino)").inserted
        }
    }

    /// SHA-256 del archivo (o de sus primeros `limit` bytes), leyendo por bloques.
    public static func hash(of url: URL, limit: Int?) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = limit ?? Int.max
        let chunk = 1 << 20
        while remaining > 0 {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: min(chunk, remaining)) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
            remaining -= data.count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
