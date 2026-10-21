import SwiftUI
import HolguraCore

/// Base de los view models con escaneo cancelable y progreso consultado periódicamente.
@MainActor
class ModuleViewModel: ObservableObject {
    @Published var isScanning = false
    @Published var progress = ProgressSnapshot.empty
    @Published var issues: [ScanIssue] = []
    @Published var lastScanDate: Date?
    @Published var statusMessage: String?

    let progressBox = ProgressBox()
    private var scanTask: Task<Void, Never>?

    /// Ejecuta `work` en segundo plano. `onResult` corre en el hilo principal.
    func runScan<R: Sendable>(_ work: @escaping @Sendable (ProgressBox) async throws -> R,
                              onResult: @escaping (R) -> Void) {
        scanTask?.cancel()
        let box = progressBox
        box.reset()
        isScanning = true
        issues = []
        statusMessage = nil
        progress = .empty

        scanTask = Task { [weak self] in
            let poller = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.progress = box.snapshot()
                    try? await Task.sleep(for: .milliseconds(120))
                }
            }
            let worker = Task.detached(priority: .userInitiated) { try await work(box) }
            do {
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                try Task.checkCancellation()
                onResult(result)
                self?.lastScanDate = Date()
            } catch is CancellationError {
                self?.statusMessage = "Escaneo cancelado."
            } catch {
                self?.statusMessage = error.localizedDescription
            }
            poller.cancel()
            self?.progress = box.snapshot()
            self?.issues = box.issues
            self?.isScanning = false
        }
    }

    func cancelScan() {
        scanTask?.cancel()
    }
}

/// View model para módulos que listan elementos seleccionables y los mueven a la Papelera.
@MainActor
class ItemListViewModel: ModuleViewModel {
    @Published var groups: [ItemGroup] = []
    @Published var selected: Set<String> = []
    @Published var reviewItems: [CleanableItem]?
    @Published var cleanupResult: CleanupResult?
    @Published var isCleaning = false

    var allItems: [CleanableItem] { groups.flatMap(\.items) }

    /// Los módulos con filtros lo sobrescriben: solo lo visible cuenta como seleccionado.
    func isVisible(_ item: CleanableItem) -> Bool { true }

    var visibleGroups: [ItemGroup] {
        groups.compactMap { group in
            let items = group.items.filter(isVisible)
            return items.isEmpty ? nil : ItemGroup(name: group.name, symbol: group.symbol, items: items)
        }
    }

    var selectedItems: [CleanableItem] {
        allItems.filter { selected.contains($0.id) && isVisible($0) }
    }

    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var totalSize: Int64 { allItems.reduce(0) { $0 + $1.size } }

    func setGroups(_ newGroups: [ItemGroup], applyDefaults: Bool = true) {
        groups = newGroups
        if applyDefaults {
            selected = Set(allItems.filter(\.selectedByDefault).map(\.id))
        } else {
            let ids = Set(allItems.map(\.id))
            selected = selected.intersection(ids)
        }
    }

    func toggle(_ item: CleanableItem) {
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }

    func setGroup(_ group: ItemGroup, selected on: Bool) {
        let ids = group.items.map(\.id)
        if on { selected.formUnion(ids) } else { selected.subtract(ids) }
    }

    func selectAllVisible(_ on: Bool) {
        let ids = allItems.filter(isVisible).map(\.id)
        if on { selected.formUnion(ids) } else { selected.subtract(ids) }
    }

    /// Valida la selección antes de mostrar la revisión. Devuelve un mensaje si no se puede continuar.
    func validateSelection() -> String? { nil }

    func beginReview() {
        if let message = validateSelection() {
            statusMessage = message
            return
        }
        let items = selectedItems
        guard !items.isEmpty else { return }
        reviewItems = items
    }

    func confirmCleanup() {
        guard let items = reviewItems else { return }
        reviewItems = nil
        isCleaning = true
        Task {
            let result = await TrashService.shared.moveToTrash(items)
            let trashedIDs = Set(result.trashed.map(\.id))
            // Quitar lo movido (y lo que estaba dentro de carpetas movidas).
            let trashedPaths = result.trashed.map { $0.url.standardizedFileURL.path }
            groups = groups.compactMap { group in
                let remaining = group.items.filter { item in
                    let path = item.url.standardizedFileURL.path
                    return !trashedIDs.contains(item.id) && !trashedPaths.contains { path.hasPrefix($0 + "/") }
                }
                return remaining.isEmpty ? nil : ItemGroup(name: group.name, symbol: group.symbol, items: remaining)
            }
            selected.subtract(trashedIDs)
            isCleaning = false
            cleanupResult = result
            didFinishCleanup(result)
        }
    }

    /// Gancho para que cada módulo persista su estado o actualice el Panel.
    func didFinishCleanup(_ result: CleanupResult) {}
}
