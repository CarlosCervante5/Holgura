import SwiftUI
import HolguraCore

enum AgeFilter: Int, CaseIterable, Identifiable {
    case any = 0, month = 30, quarter = 90, half = 180, year = 365, twoYears = 730

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .any: return "Cualquier fecha"
        case .month: return "Más de 30 días"
        case .quarter: return "Más de 3 meses"
        case .half: return "Más de 6 meses"
        case .year: return "Más de 1 año"
        case .twoYears: return "Más de 2 años"
        }
    }
}

// MARK: - Archivos grandes

private struct LargeFilesSnapshot: Codable {
    var date: Date
    var root: URL
    var minSizeMB: Int
    var items: [CleanableItem]
}

@MainActor
final class LargeFilesViewModel: ItemListViewModel {
    static let cacheKey = "largeFiles"

    @Published var root: URL = FileManager.default.homeDirectoryForCurrentUser
    @Published var minSizeMB: Int = 500
    @Published var includeLibrary = false
    @Published var ageFilter: AgeFilter = .any
    @Published var typeFilter: FileCategory?

    override init() {
        super.init()
        if let cached = ScanCache.shared.load(LargeFilesSnapshot.self, key: Self.cacheKey) {
            root = cached.root
            minSizeMB = cached.minSizeMB
            lastScanDate = cached.date
            apply(cached.items.filter { FileManager.default.fileExists(atPath: $0.url.path) })
        }
    }

    private func apply(_ items: [CleanableItem]) {
        let grouped = Dictionary(grouping: items) { FileCategory(rawValue: $0.group) ?? .other }
        let groups = FileCategory.allCases.compactMap { cat -> ItemGroup? in
            guard let items = grouped[cat], !items.isEmpty else { return nil }
            return ItemGroup(name: cat.label, symbol: cat.symbol, items: items.sorted { $0.size > $1.size })
        }
        setGroups(groups.sorted { $0.totalSize > $1.totalSize })
    }

    override func isVisible(_ item: CleanableItem) -> Bool {
        if let typeFilter, item.group != typeFilter.rawValue { return false }
        if ageFilter != .any {
            guard let days = Format.daysSince(item.modified), days >= ageFilter.rawValue else { return false }
        }
        return true
    }

    func chooseRoot() {
        if let url = Finder.chooseFolder(startingAt: root, message: "Elige la carpeta donde buscar archivos grandes") {
            root = url
        }
    }

    func scan() {
        let scanner = LargeFileScanner()
        let root = self.root
        let minSize = Int64(max(1, minSizeMB)) * 1_000_000
        let includeLibrary = self.includeLibrary
        runScan({ progress in
            try await scanner.scan(root: root, minSize: minSize, includeLibrary: includeLibrary, progress: progress)
        }, onResult: { [weak self] items in
            self?.apply(items)
            self?.lastScanDate = Date()
            self?.persist()
        })
    }

    private func persist() {
        ScanCache.shared.save(LargeFilesSnapshot(date: lastScanDate ?? Date(), root: root, minSizeMB: minSizeMB,
                                                 items: allItems), key: Self.cacheKey)
    }

    override func didFinishCleanup(_ result: CleanupResult) { persist() }
}

// MARK: - Descargas y Papelera

private struct DownloadsSnapshot: Codable {
    var date: Date
    var result: DownloadsScanResult
}

@MainActor
final class DownloadsViewModel: ItemListViewModel {
    static let cacheKey = "downloads"
    weak var appState: AppState?

    @Published var result = DownloadsScanResult()
    @Published var olderThanDays: Int = (UserDefaults.standard.object(forKey: "downloadsOlderThan") as? Int) ?? 30 {
        didSet { UserDefaults.standard.set(olderThanDays, forKey: "downloadsOlderThan") }
    }

    override init() {
        super.init()
        if let cached = ScanCache.shared.load(DownloadsSnapshot.self, key: Self.cacheKey) {
            var r = cached.result
            r.items = r.items.filter { FileManager.default.fileExists(atPath: $0.url.path) }
            result = r
            lastScanDate = cached.date
            setGroups([ItemGroup(name: "Descargas", symbol: "arrow.down.circle", items: r.items)])
        }
    }

    override func isVisible(_ item: CleanableItem) -> Bool {
        (Format.daysSince(item.modified) ?? Int.max) >= olderThanDays
    }

    var oldItemsSize: Int64 {
        allItems.filter(isVisible).reduce(0) { $0 + $1.size }
    }

    func scan() {
        let scanner = DownloadsScanner()
        runScan({ progress in
            try await scanner.scan(progress: progress)
        }, onResult: { [weak self] result in
            guard let self else { return }
            self.result = result
            self.lastScanDate = Date()
            self.setGroups([ItemGroup(name: "Descargas", symbol: "arrow.down.circle", items: result.items)])
            self.persist()
        })
    }

    private func persist() {
        result.items = allItems
        result.downloadsTotal = totalSize
        ScanCache.shared.save(DownloadsSnapshot(date: lastScanDate ?? Date(), result: result), key: Self.cacheKey)
        appState?.report(.downloads, total: result.downloadsTotal)
        if let trash = result.trashSize { appState?.report(.trash, total: trash) }
    }

    override func didFinishCleanup(_ result: CleanupResult) {
        // Lo movido ahora está en la Papelera.
        if let trash = self.result.trashSize { self.result.trashSize = trash + result.bytes }
        persist()
    }
}

// MARK: - Mapa de espacio

@MainActor
final class SpaceMapViewModel: ModuleViewModel {
    @Published var root: URL = FileManager.default.homeDirectoryForCurrentUser
    @Published var path: [URL] = []
    @Published var nodes: [SpaceNode] = []
    private var cache: [String: [SpaceNode]] = [:]

    var current: URL { path.last ?? root }
    var currentTotal: Int64 { nodes.reduce(0) { $0 + $1.size } }

    func setRoot(_ url: URL) {
        root = url
        path = []
        cache = [:]
        load(url)
    }

    func chooseRoot() {
        if let url = Finder.chooseFolder(startingAt: root, message: "Elige la carpeta que quieres analizar") {
            setRoot(url)
        }
    }

    func open(_ node: SpaceNode) {
        guard node.canDrillDown else { return }
        path.append(node.url)
        load(node.url)
    }

    func goTo(index: Int) {
        // index -1 = raíz
        if index < 0 { path = [] } else { path = Array(path.prefix(index + 1)) }
        load(current)
    }

    func goUp() {
        guard !path.isEmpty else { return }
        path.removeLast()
        load(current)
    }

    func refresh() {
        cache[current.path] = nil
        load(current)
    }

    func load(_ url: URL) {
        if let cached = cache[url.path] {
            nodes = cached
            return
        }
        nodes = []
        let scanner = SpaceMapScanner()
        runScan({ progress in
            try await scanner.children(of: url, progress: progress)
        }, onResult: { [weak self] nodes in
            guard let self else { return }
            self.cache[url.path] = nodes
            if self.current == url { self.nodes = nodes }
        })
    }
}
