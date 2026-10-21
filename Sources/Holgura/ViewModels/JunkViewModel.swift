import SwiftUI
import HolguraCore

struct GroupsSnapshot: Codable {
    var date: Date
    var groups: [ItemGroup]
}

extension ItemListViewModel {
    /// Quita del caché los elementos que ya no existen.
    static func existing(_ groups: [ItemGroup]) -> [ItemGroup] {
        groups.compactMap { g in
            let items = g.items.filter { FileManager.default.fileExists(atPath: $0.url.path) }
            return items.isEmpty ? nil : ItemGroup(name: g.name, symbol: g.symbol, items: items)
        }
    }
}

@MainActor
final class JunkViewModel: ItemListViewModel {
    static let cacheKey = "junk"
    weak var appState: AppState?

    override init() {
        super.init()
        if let cached = ScanCache.shared.load(GroupsSnapshot.self, key: Self.cacheKey) {
            setGroups(Self.existing(cached.groups))
            lastScanDate = cached.date
        }
    }

    func scan() {
        let scanner = JunkScanner()
        runScan({ progress in
            try await scanner.scan(progress: progress)
        }, onResult: { [weak self] groups in
            self?.setGroups(groups)
            self?.lastScanDate = Date()
            self?.persist()
        })
    }

    private func persist() {
        ScanCache.shared.save(GroupsSnapshot(date: lastScanDate ?? Date(), groups: groups), key: Self.cacheKey)
        appState?.report(.junk, total: totalSize)
    }

    override func didFinishCleanup(_ result: CleanupResult) {
        persist()
    }

}
