import Foundation

/// Tipo de elemento que puede limpiarse.
public enum ItemKind: String, Codable, Sendable, CaseIterable {
    case cache
    case log
    case temp
    case derivedData
    case xcodeArchive
    case deviceSupport
    case nodeModules
    case packageCache
    case brewCleanup
    case largeFile
    case download
    case duplicate
    case app
    case appLeftover
    case other

    public var label: String {
        switch self {
        case .cache: return "Caché"
        case .log: return "Registro"
        case .temp: return "Temporal"
        case .derivedData: return "DerivedData"
        case .xcodeArchive: return "Archivo de Xcode"
        case .deviceSupport: return "Device Support"
        case .nodeModules: return "node_modules"
        case .packageCache: return "Caché de paquetes"
        case .brewCleanup: return "Homebrew"
        case .largeFile: return "Archivo grande"
        case .download: return "Descarga"
        case .duplicate: return "Duplicado"
        case .app: return "Aplicación"
        case .appLeftover: return "Resto de app"
        case .other: return "Otro"
        }
    }
}

/// Un archivo o carpeta que el usuario puede decidir mover a la Papelera.
public struct CleanableItem: Identifiable, Hashable, Codable, Sendable {
    public let url: URL
    public var name: String
    /// Tamaño real en disco (bytes asignados).
    public var size: Int64
    public var modified: Date?
    public var kind: ItemKind
    public var group: String
    public var note: String?
    public var selectedByDefault: Bool

    public var id: String { url.path }

    public init(url: URL,
                name: String? = nil,
                size: Int64,
                modified: Date? = nil,
                kind: ItemKind,
                group: String = "",
                note: String? = nil,
                selectedByDefault: Bool = true) {
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.size = size
        self.modified = modified
        self.kind = kind
        self.group = group
        self.note = note
        self.selectedByDefault = selectedByDefault
    }
}

/// Agrupación de elementos (por app, por ubicación, etc.).
public struct ItemGroup: Identifiable, Hashable, Codable, Sendable {
    public var name: String
    public var symbol: String
    public var items: [CleanableItem]

    public var id: String { name }
    public var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    public init(name: String, symbol: String = "folder", items: [CleanableItem]) {
        self.name = name
        self.symbol = symbol
        self.items = items
    }
}

/// Ruta que no se pudo leer durante un escaneo.
public struct ScanIssue: Identifiable, Hashable, Codable, Sendable {
    public let path: String
    public let reason: String
    public var id: String { path }

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public struct CleanupFailure: Identifiable, Hashable, Sendable {
    public let item: CleanableItem
    public let reason: String
    public var id: String { item.id }
}

public struct CleanupResult: Sendable {
    public var trashed: [CleanableItem] = []
    public var failures: [CleanupFailure] = []
    public var bytes: Int64 { trashed.reduce(0) { $0 + $1.size } }

    public init() {}
}

public enum AppPaths {
    public static let appName = "Holgura"

    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true)
    }

    public static var userTrash: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
    }
}
