import SwiftUI
import HolguraCore

private struct DeveloperSnapshot: Codable {
    var date: Date
    var result: DeveloperScanResult
    var nodeModules: [CleanableItem]
}

@MainActor
final class DeveloperViewModel: ItemListViewModel {
    static let cacheKey = "developer"
    weak var appState: AppState?

    @Published var result = DeveloperScanResult()
    @Published var nodeModules: [CleanableItem] = []
    @Published var isDeletingSimulators = false
    @Published var simulatorMessage: String?

    @Published var nodeModulesRootPath: String = UserDefaults.standard.string(forKey: "nodeModulesRoot") ?? "" {
        didSet { UserDefaults.standard.set(nodeModulesRootPath, forKey: "nodeModulesRoot") }
    }
    @Published var staleDays: Int = (UserDefaults.standard.object(forKey: "nodeModulesStaleDays") as? Int) ?? 90 {
        didSet { UserDefaults.standard.set(staleDays, forKey: "nodeModulesStaleDays") }
    }

    var nodeModulesRoot: URL? {
        nodeModulesRootPath.isEmpty ? nil : URL(fileURLWithPath: nodeModulesRootPath)
    }

    override init() {
        super.init()
        if let cached = ScanCache.shared.load(DeveloperSnapshot.self, key: Self.cacheKey) {
            var r = cached.result
            r.groups = Self.existing(r.groups)
            result = r
            nodeModules = cached.nodeModules.filter { FileManager.default.fileExists(atPath: $0.url.path) }
            lastScanDate = cached.date
            rebuildGroups(applyDefaults: true)
        }
    }

    private func rebuildGroups(applyDefaults: Bool) {
        var all = result.groups
        if !nodeModules.isEmpty {
            all.append(ItemGroup(name: DeveloperScanner.nodeModulesGroup, symbol: "shippingbox.fill", items: nodeModules))
        }
        setGroups(all, applyDefaults: applyDefaults)
    }

    func scan() {
        let scanner = DeveloperScanner()
        runScan({ progress in
            try await scanner.scan(progress: progress)
        }, onResult: { [weak self] result in
            guard let self else { return }
            self.result = result
            self.lastScanDate = Date()
            let previous = self.selected
            self.rebuildGroups(applyDefaults: true)
            // Conservar la selección previa de node_modules.
            let nodeIDs = Set(self.nodeModules.map(\.id))
            self.selected.formUnion(previous.intersection(nodeIDs))
            self.persist()
        })
    }

    func chooseNodeModulesRoot() {
        let start = nodeModulesRoot ?? FileManager.default.homeDirectoryForCurrentUser
        if let url = Finder.chooseFolder(startingAt: start, message: "Elige la carpeta donde guardas tus proyectos") {
            nodeModulesRootPath = url.path
        }
    }

    func scanNodeModules() {
        guard let root = nodeModulesRoot else { return }
        let scanner = DeveloperScanner()
        let days = staleDays
        runScan({ progress in
            try await scanner.scanNodeModules(root: root, staleDays: days, progress: progress)
        }, onResult: { [weak self] items in
            guard let self else { return }
            self.nodeModules = items
            let previous = self.selected.subtracting(items.map(\.id))
            self.rebuildGroups(applyDefaults: false)
            self.selected = previous.union(items.filter(\.selectedByDefault).map(\.id))
            self.persist()
        })
    }

    /// Re-selecciona node_modules según el umbral de días actual.
    func applyStaleFilter() {
        for item in nodeModules {
            let days = Format.daysSince(item.modified) ?? 0
            if days >= staleDays { selected.insert(item.id) } else { selected.remove(item.id) }
        }
    }

    func deleteUnavailableSimulators() {
        let devices = result.simulators
        isDeletingSimulators = true
        simulatorMessage = nil
        Task {
            do {
                let r = try await DeveloperScanner.deleteUnavailableSimulators(devices: devices)
                if r.succeeded {
                    simulatorMessage = "Se eliminaron \(devices.count) simuladores no disponibles."
                    result.simulators = []
                } else {
                    simulatorMessage = "simctl devolvió un error: \(r.stderr)"
                }
            } catch {
                simulatorMessage = error.localizedDescription
            }
            isDeletingSimulators = false
            persist()
        }
    }

    override func didFinishCleanup(_ result: CleanupResult) {
        let trashed = Set(result.trashed.map(\.id))
        self.result.groups = self.result.groups.compactMap { g in
            let items = g.items.filter { !trashed.contains($0.id) }
            return items.isEmpty ? nil : ItemGroup(name: g.name, symbol: g.symbol, items: items)
        }
        nodeModules.removeAll { trashed.contains($0.id) }
        persist()
    }

    private func persist() {
        ScanCache.shared.save(DeveloperSnapshot(date: lastScanDate ?? Date(), result: result, nodeModules: nodeModules),
                              key: Self.cacheKey)
        appState?.report(.developer, total: totalSize)
    }

}
