import SwiftUI
import AppKit
import HolguraCore

enum Module: String, CaseIterable, Identifiable, Hashable {
    case dashboard, junk, developer, largeFiles, downloads, spaceMap, duplicates, uninstaller

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Panel"
        case .junk: return "Basura del sistema"
        case .developer: return "Desarrollador"
        case .largeFiles: return "Archivos grandes"
        case .downloads: return "Descargas y Papelera"
        case .spaceMap: return "Mapa de espacio"
        case .duplicates: return "Duplicados"
        case .uninstaller: return "Desinstalador"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.67percent"
        case .junk: return "sparkles"
        case .developer: return "hammer"
        case .largeFiles: return "scalemass"
        case .downloads: return "arrow.down.circle"
        case .spaceMap: return "square.grid.3x3.square"
        case .duplicates: return "doc.on.doc"
        case .uninstaller: return "xmark.bin"
        }
    }

    var tint: Color {
        switch self {
        case .dashboard: return .accentColor
        case .junk: return .pink
        case .developer: return .orange
        case .largeFiles: return .purple
        case .downloads: return .blue
        case .spaceMap: return .teal
        case .duplicates: return .indigo
        case .uninstaller: return .red
        }
    }
}

/// Categorías que aparecen en la gráfica del Panel.
enum DashboardCategory: String, CaseIterable, Identifiable, Codable {
    case junk, developer, downloads, trash

    var id: String { rawValue }

    var title: String {
        switch self {
        case .junk: return "Basura del sistema"
        case .developer: return "Desarrollador"
        case .downloads: return "Descargas"
        case .trash: return "Papelera"
        }
    }

    var color: Color {
        switch self {
        case .junk: return .pink
        case .developer: return .orange
        case .downloads: return .blue
        case .trash: return .gray
        }
    }

    var module: Module {
        switch self {
        case .junk: return .junk
        case .developer: return .developer
        case .downloads, .trash: return .downloads
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var selection: Module? = .dashboard
    @Published var hasFullDiskAccess = PermissionChecker.hasFullDiskAccess()
    @Published var showPermissionScreen = false
    @Published var disk: DiskUsage? = DiskUsage.current()
    @Published var categoryTotals: [DashboardCategory: Int64] = [:]
    @Published var lastFullScan: Date?

    let junk = JunkViewModel()
    let developer = DeveloperViewModel()
    let largeFiles = LargeFilesViewModel()
    let downloads = DownloadsViewModel()
    let spaceMap = SpaceMapViewModel()
    let duplicates = DuplicatesViewModel()
    let uninstaller = UninstallerViewModel()

    private var activationObserver: NSObjectProtocol?

    init() {
        junk.appState = self
        developer.appState = self
        downloads.appState = self
        showPermissionScreen = !hasFullDiskAccess
        if let cached = ScanCache.shared.load(DashboardSnapshot.self, key: "dashboard") {
            categoryTotals = cached.totals
            lastFullScan = cached.date
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
    }

    func refreshPermissions() {
        hasFullDiskAccess = PermissionChecker.hasFullDiskAccess()
        if hasFullDiskAccess { showPermissionScreen = false }
    }

    func refreshDisk() {
        disk = DiskUsage.current()
    }

    func report(_ category: DashboardCategory, total: Int64) {
        categoryTotals[category] = total
        refreshDisk()
        ScanCache.shared.save(DashboardSnapshot(date: lastFullScan ?? Date(), totals: categoryTotals), key: "dashboard")
    }

    /// Lanza los escaneos que alimentan el Panel.
    func scanAll() {
        refreshDisk()
        lastFullScan = Date()
        junk.scan()
        developer.scan()
        downloads.scan()
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(PermissionChecker.fullDiskAccessSettingsURL)
    }
}

struct DashboardSnapshot: Codable {
    var date: Date
    var totals: [DashboardCategory: Int64]
}
