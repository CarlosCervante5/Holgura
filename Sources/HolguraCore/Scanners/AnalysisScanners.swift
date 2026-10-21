import Foundation
import UniformTypeIdentifiers
import CoreGraphics

// MARK: - Tipos de archivo

public enum FileCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case video, audio, image, diskImage, archive, document, app, other

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .video: return "Vídeos"
        case .audio: return "Audio"
        case .image: return "Imágenes"
        case .diskImage: return "Imágenes de disco"
        case .archive: return "Comprimidos"
        case .document: return "Documentos"
        case .app: return "Apps y paquetes"
        case .other: return "Otros"
        }
    }

    public var symbol: String {
        switch self {
        case .video: return "film"
        case .audio: return "waveform"
        case .image: return "photo"
        case .diskImage: return "opticaldisc"
        case .archive: return "doc.zipper"
        case .document: return "doc.richtext"
        case .app: return "app"
        case .other: return "doc"
        }
    }

    public static func of(_ url: URL) -> FileCategory {
        let ext = url.pathExtension.lowercased()
        if ["dmg", "iso", "img", "sparseimage", "sparsebundle", "vmdk", "qcow2", "vdi", "ipsw"].contains(ext) {
            return .diskImage
        }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .diskImage) { return .diskImage }
        if type.conforms(to: .archive) || type.conforms(to: .zip) || type.conforms(to: .gzip) { return .archive }
        if type.conforms(to: .application) || type.conforms(to: .applicationBundle) || type.conforms(to: .package) {
            return .app
        }
        if type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .presentation)
            || type.conforms(to: .spreadsheet) || type.conforms(to: .compositeContent) {
            return .document
        }
        return .other
    }
}

// MARK: - Archivos grandes

public struct LargeFileScanner: Sendable {
    public let scanner: FileScanner
    public let home: URL

    public init(scanner: FileScanner = FileScanner(),
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.scanner = scanner
        self.home = home
    }

    /// Archivos (y paquetes, como una unidad) iguales o mayores que `minSize` dentro de `root`.
    public func scan(root: URL, minSize: Int64, includeLibrary: Bool, progress: ProgressBox) async throws -> [CleanableItem] {
        progress.setPhase("Buscando archivos de más de \(Format.bytes(minSize))…")
        let library = home.appendingPathComponent("Library").standardizedFileURL.path
        let top = scanner.children(of: root, progress: progress).filter {
            includeLibrary || $0.standardizedFileURL.path != library
        }
        progress.setTotal(top.count)
        let scanner = self.scanner
        let lists = try await concurrentMap(top) { url -> [CleanableItem] in
            defer { progress.advance() }
            return try Self.collect(in: url, minSize: minSize, scanner: scanner,
                                    skipPath: includeLibrary ? nil : library, progress: progress)
        }
        return lists.flatMap { $0 }.sorted { $0.size > $1.size }
    }

    static func collect(in url: URL, minSize: Int64, scanner: FileScanner, skipPath: String?,
                        progress: ProgressBox) throws -> [CleanableItem] {
        var result: [CleanableItem] = []
        let keys = FileScanner.resourceKeys + [.contentAccessDateKey]
        func consider(_ item: URL, _ v: URLResourceValues) throws {
            if v.isPackage == true && v.isDirectory == true {
                let size = try scanner.allocatedSize(of: item)
                if size >= minSize { result.append(make(item, size, v.contentModificationDate)) }
            } else if v.isRegularFile == true {
                let size = FileScanner.allocatedSize(v)
                if size >= minSize { result.append(make(item, size, v.contentModificationDate)) }
            }
        }
        guard let rootValues = try? url.resourceValues(forKeys: Set(keys)), rootValues.isSymbolicLink != true else {
            return []
        }
        if rootValues.isDirectory != true || rootValues.isPackage == true {
            progress.visit(url)
            try consider(url, rootValues)
            return result
        }
        let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants],
            errorHandler: { failed, error in
                progress.addIssue(path: failed.path, reason: error.localizedDescription)
                return true
            })
        var count = 0
        while let item = enumerator?.nextObject() as? URL {
            count += 1
            if count & 511 == 0 { try Task.checkCancellation() }
            guard let v = try? item.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { continue }
            if v.isDirectory == true && v.isPackage != true {
                if scanner.protected.isProtected(item) || item.standardizedFileURL.path == skipPath {
                    enumerator?.skipDescendants()
                }
                continue
            }
            if v.isPackage == true && scanner.protected.isProtected(item) { continue }
            progress.visit(item)
            try consider(item, v)
        }
        return result
    }

    static func make(_ url: URL, _ size: Int64, _ modified: Date?) -> CleanableItem {
        let category = FileCategory.of(url)
        return CleanableItem(url: url, size: size, modified: modified, kind: .largeFile,
                             group: category.rawValue, selectedByDefault: false)
    }
}

// MARK: - Descargas y Papelera

public struct DownloadsScanResult: Codable, Sendable {
    public var downloadsTotal: Int64 = 0
    public var items: [CleanableItem] = []
    public var trashSize: Int64?
    public var trashMessage: String?
    public init() {}
}

public struct DownloadsScanner: Sendable {
    public let scanner: FileScanner
    public let home: URL

    public init(scanner: FileScanner = FileScanner(),
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.scanner = scanner
        self.home = home
    }

    public func scan(progress: ProgressBox) async throws -> DownloadsScanResult {
        var result = DownloadsScanResult()
        progress.setPhase("Midiendo Descargas…")
        let downloads = home.appendingPathComponent("Downloads")
        let children = scanner.children(of: downloads, progress: progress)
            .filter { $0.lastPathComponent != ".DS_Store" && $0.lastPathComponent != ".localized" }
        progress.setTotal(children.count + 1)
        result.items = try await scanner.items(for: children, progress: progress) { url, size, modified in
            // Fecha en que llegó a Descargas; si no existe, la de modificación.
            let added = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate
            return CleanableItem(url: url, size: size, modified: added ?? modified, kind: .download,
                                 group: "Descargas", selectedByDefault: false)
        }
        .sorted { $0.size > $1.size }
        result.downloadsTotal = result.items.reduce(0) { $0 + $1.size }

        progress.setPhase("Midiendo la Papelera…")
        let trash = AppPaths.userTrash
        let trashProgress = ProgressBox()
        if (try? FileManager.default.contentsOfDirectory(atPath: trash.path)) == nil {
            result.trashMessage = "Sin permiso para leer la Papelera (requiere Acceso total al disco)."
        } else {
            result.trashSize = try scanner.allocatedSize(of: trash, progress: trashProgress)
            if !trashProgress.issues.isEmpty {
                result.trashMessage = "Algunos elementos de la Papelera no se pudieron medir."
            }
        }
        progress.advance()
        return result
    }
}

// MARK: - Mapa de espacio

public struct SpaceNode: Identifiable, Hashable, Codable, Sendable {
    public let url: URL
    public let name: String
    public let size: Int64
    public let isDirectory: Bool
    public let isPackage: Bool
    public var id: String { url.path }
    public var canDrillDown: Bool { isDirectory && !isPackage }
}

public struct SpaceMapScanner: Sendable {
    public let scanner: FileScanner

    public init(scanner: FileScanner = FileScanner()) {
        self.scanner = scanner
    }

    /// Hijos de `dir` con su tamaño total, ordenados de mayor a menor.
    public func children(of dir: URL, progress: ProgressBox) async throws -> [SpaceNode] {
        progress.setPhase("Midiendo \(Format.abbreviate(dir))…")
        let urls = scanner.children(of: dir, progress: progress)
        progress.setTotal(urls.count)
        let scanner = self.scanner
        let nodes = try await concurrentMap(urls) { url -> SpaceNode in
            defer { progress.advance() }
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey])
            let isLink = v?.isSymbolicLink == true
            let size = try scanner.allocatedSize(of: url, progress: progress)
            return SpaceNode(url: url,
                             name: FileManager.default.displayName(atPath: url.path),
                             size: size,
                             isDirectory: !isLink && v?.isDirectory == true,
                             isPackage: v?.isPackage == true)
        }
        return nodes.sorted { $0.size > $1.size }
    }
}

// MARK: - Treemap

public enum TreemapLayout {
    /// Algoritmo "squarified": devuelve un rectángulo por valor (en el mismo orden).
    /// Los valores deben venir ordenados de mayor a menor para mejores proporciones.
    public static func squarify(values: [Double], in rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: values.count)
        let total = values.reduce(0) { $0 + max(0, $1) }
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { max(0, $0) * scale }
        var remaining = rect
        var i = 0

        func worst(_ row: ArraySlice<Double>, side: Double) -> Double {
            let sum = row.reduce(0, +)
            guard sum > 0, side > 0 else { return .infinity }
            var w = 0.0
            for r in row where r > 0 {
                w = max(w, max(side * side * r / (sum * sum), (sum * sum) / (side * side * r)))
            }
            return w
        }

        while i < areas.count {
            if areas[i] <= 0 { i += 1; continue }
            let side = Double(min(remaining.width, remaining.height))
            var j = i + 1
            var best = worst(areas[i..<j], side: side)
            while j < areas.count, areas[j] > 0 {
                let candidate = worst(areas[i...j], side: side)
                if candidate <= best { best = candidate; j += 1 } else { break }
            }
            let rowArea = areas[i..<j].reduce(0, +)
            if remaining.width >= remaining.height {
                let width = CGFloat(rowArea / Double(remaining.height))
                var y = remaining.minY
                for k in i..<j {
                    let h = CGFloat(areas[k]) / width
                    result[k] = CGRect(x: remaining.minX, y: y, width: width, height: h)
                    y += h
                }
                remaining = CGRect(x: remaining.minX + width, y: remaining.minY,
                                   width: max(0, remaining.width - width), height: remaining.height)
            } else {
                let height = CGFloat(rowArea / Double(remaining.width))
                var x = remaining.minX
                for k in i..<j {
                    let w = CGFloat(areas[k]) / height
                    result[k] = CGRect(x: x, y: remaining.minY, width: w, height: height)
                    x += w
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + height,
                                   width: remaining.width, height: max(0, remaining.height - height))
            }
            i = j
        }
        return result
    }
}
