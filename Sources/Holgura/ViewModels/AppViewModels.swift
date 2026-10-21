import SwiftUI
import AppKit
import HolguraCore

// MARK: - Duplicados

@MainActor
final class DuplicatesViewModel: ItemListViewModel {
    @Published var root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
    @Published var minSizeKB: Int = 1024
    @Published var strategy: KeepStrategy = .oldest
    @Published var duplicateGroups: [DuplicateGroup] = []

    var wastedTotal: Int64 { duplicateGroups.reduce(0) { $0 + $1.wasted } }

    func chooseRoot() {
        if let url = Finder.chooseFolder(startingAt: root, message: "Elige la carpeta donde buscar duplicados") {
            root = url
        }
    }

    func scan() {
        let finder = DuplicateFinder()
        let root = self.root
        let minSize = Int64(max(1, minSizeKB)) * 1024
        runScan({ progress in
            try await finder.find(in: root, minSize: minSize, progress: progress)
        }, onResult: { [weak self] groups in
            self?.duplicateGroups = groups
            self?.rebuild()
            self?.applySuggestion()
        })
    }

    private func rebuild() {
        let groups = duplicateGroups.enumerated().map { index, g in
            ItemGroup(name: "Grupo \(index + 1) · \(g.files.count) copias de \(Format.bytes(g.size))",
                      symbol: "doc.on.doc",
                      items: g.files.map { f in
                          CleanableItem(url: f.url, size: f.allocatedSize, modified: f.created ?? f.modified,
                                        kind: .duplicate, group: g.hash, selectedByDefault: false)
                      })
        }
        setGroups(groups, applyDefaults: false)
    }

    /// Marca todas las copias menos la sugerida para conservar.
    func applySuggestion() {
        var newSelection = Set<String>()
        for g in duplicateGroups {
            let keep = g.suggestedKeep(strategy)?.id
            for f in g.files where f.id != keep { newSelection.insert(f.id) }
        }
        selected = newSelection
    }

    func isSuggestedKeep(_ item: CleanableItem) -> Bool {
        guard let g = duplicateGroups.first(where: { $0.hash == item.group }) else { return false }
        return g.suggestedKeep(strategy)?.id == item.id
    }

    /// Nunca permitir mover todas las copias de un grupo.
    override func validateSelection() -> String? {
        for g in duplicateGroups where g.files.allSatisfy({ selected.contains($0.id) }) {
            return "Has marcado todas las copias de «\(g.files.first?.url.lastPathComponent ?? "")». Deja al menos una sin marcar."
        }
        return nil
    }

    override func didFinishCleanup(_ result: CleanupResult) {
        let trashed = Set(result.trashed.map(\.id))
        duplicateGroups = duplicateGroups.compactMap { g in
            var g = g
            g.files.removeAll { trashed.contains($0.id) }
            return g.files.count > 1 ? g : nil
        }
        rebuild()
    }
}

// MARK: - Desinstalador

private struct AppsSnapshot: Codable {
    var date: Date
    var apps: [InstalledApp]
}

@MainActor
final class UninstallerViewModel: ItemListViewModel {
    static let cacheKey = "apps"

    @Published var apps: [InstalledApp] = []
    @Published var selectedApp: InstalledApp?
    @Published var search = ""
    @Published var isLoadingLeftovers = false
    private var leftoversTask: Task<Void, Never>?

    override init() {
        super.init()
        if let cached = ScanCache.shared.load(AppsSnapshot.self, key: Self.cacheKey) {
            apps = cached.apps.filter { FileManager.default.fileExists(atPath: $0.url.path) }
            lastScanDate = cached.date
        }
    }

    var filteredApps: [InstalledApp] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return apps }
        return apps.filter { $0.name.lowercased().contains(q) || ($0.bundleID?.lowercased().contains(q) ?? false) }
    }

    var isRunning: Bool {
        guard let bid = selectedApp?.bundleID else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty
    }

    func scan() {
        let inventory = AppInventory()
        runScan({ progress in
            try await inventory.listApps(progress: progress)
        }, onResult: { [weak self] apps in
            guard let self else { return }
            self.apps = apps
            self.lastScanDate = Date()
            ScanCache.shared.save(AppsSnapshot(date: Date(), apps: apps), key: Self.cacheKey)
            if let current = self.selectedApp, !apps.contains(where: { $0.id == current.id }) {
                self.select(nil)
            }
        })
    }

    func select(_ app: InstalledApp?) {
        selectedApp = app
        setGroups([])
        leftoversTask?.cancel()
        isLoadingLeftovers = false
        guard let app else { return }
        isLoadingLeftovers = true
        let inventory = AppInventory()
        leftoversTask = Task { [weak self] in
            let items = (try? await Task.detached { try await inventory.leftovers(for: app) }.value) ?? []
            guard let self, !Task.isCancelled, self.selectedApp?.id == app.id else { return }
            let grouped = Dictionary(grouping: items, by: \.group)
            let order = ["Aplicación"] + AppInventory.leftoverLocations.map { $0.replacingOccurrences(of: "Library/", with: "") }
            let groups = order.compactMap { name -> ItemGroup? in
                guard let items = grouped[name] else { return nil }
                return ItemGroup(name: name, symbol: name == "Aplicación" ? "app" : "folder", items: items)
            }
            self.setGroups(groups)
            self.isLoadingLeftovers = false
        }
    }

    override func didFinishCleanup(_ result: CleanupResult) {
        if let app = selectedApp, result.trashed.contains(where: { $0.url == app.url }) {
            apps.removeAll { $0.id == app.id }
            ScanCache.shared.save(AppsSnapshot(date: lastScanDate ?? Date(), apps: apps), key: Self.cacheKey)
            selectedApp = nil
        }
    }
}
