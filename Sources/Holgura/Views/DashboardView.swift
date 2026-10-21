import SwiftUI
import Charts
import HolguraCore

private struct Slice: Identifiable {
    let id: String
    let title: String
    let bytes: Int64
    let color: Color
}

struct DashboardView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ModuleHeader(module: .dashboard, subtitle: subtitle) {
                    ScanAllButton(junk: state.junk, developer: state.developer, downloads: state.downloads) { state.scanAll() }
                }

                if !state.hasFullDiskAccess {
                    permissionBanner
                }

                if let disk = state.disk {
                    diskSection(disk)
                }

                categoriesSection
            }
            .padding(.bottom, 24)
        }
        .onAppear { state.refreshDisk() }
    }

    private var subtitle: String {
        if let date = state.lastFullScan {
            return "Último escaneo \(Format.relative(date))"
        }
        return "Analiza tu Mac y libera espacio de forma segura"
    }

    private var permissionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.lock.fill").foregroundStyle(.orange).font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sin Acceso total al disco").font(.headline)
                Text("Algunas carpetas de ~/Library se saltarán y los resultados serán parciales.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Ver cómo activarlo") { state.showPermissionScreen = true }
        }
        .padding(14)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 20)
    }

    private func slices(for disk: DiskUsage) -> [Slice] {
        var result: [Slice] = []
        var categorized: Int64 = 0
        for category in DashboardCategory.allCases {
            let bytes = state.categoryTotals[category] ?? 0
            guard bytes > 0 else { continue }
            categorized += bytes
            result.append(Slice(id: category.rawValue, title: category.title, bytes: bytes, color: category.color))
        }
        let other = max(0, disk.used - categorized)
        result.append(Slice(id: "other", title: "Otros datos", bytes: other, color: .secondary.opacity(0.55)))
        result.append(Slice(id: "free", title: "Libre", bytes: disk.available, color: .green.opacity(0.75)))
        return result
    }

    private func diskSection(_ disk: DiskUsage) -> some View {
        let data = slices(for: disk)
        return HStack(alignment: .center, spacing: 28) {
            Chart(data) { slice in
                SectorMark(angle: .value("Bytes", slice.bytes),
                           innerRadius: .ratio(0.62),
                           angularInset: 1.2)
                    .cornerRadius(3)
                    .foregroundStyle(slice.color)
            }
            .chartLegend(.hidden)
            .frame(width: 230, height: 230)
            .overlay {
                VStack(spacing: 2) {
                    Text(Format.bytes(disk.available))
                        .font(.title2.weight(.bold)).monospacedDigit()
                    Text("libres").font(.caption).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                Text(disk.volumeName).font(.title3.weight(.semibold))
                HStack(spacing: 12) {
                    StatTile(title: "Total", value: Format.bytes(disk.total), symbol: "internaldrive", tint: .secondary)
                    StatTile(title: "Usado", value: Format.bytes(disk.used), symbol: "chart.pie", tint: .orange)
                    StatTile(title: "Libre", value: Format.bytes(disk.available), symbol: "checkmark.circle", tint: .green)
                }
                ProgressView(value: Double(disk.used), total: Double(max(disk.total, 1)))
                    .tint(Double(disk.used) / Double(max(disk.total, 1)) > 0.9 ? .red : .accentColor)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(data) { slice in
                        HStack(spacing: 8) {
                            Circle().fill(slice.color).frame(width: 9, height: 9)
                            Text(slice.title)
                            Spacer()
                            Text(Format.bytes(slice.bytes)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
            }
        }
        .padding(20)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 20)
    }

    private var categoriesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Lo que se puede revisar").font(.headline).padding(.horizontal, 20)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                ForEach(Module.allCases.filter { $0 != .dashboard }) { module in
                    Button {
                        state.selection = module
                    } label: {
                        ModuleCard(module: module, bytes: total(for: module))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func total(for module: Module) -> Int64? {
        let values = DashboardCategory.allCases.filter { $0.module == module }.compactMap { state.categoryTotals[$0] }
        return values.isEmpty ? nil : values.reduce(0, +)
    }
}

private struct ModuleCard: View {
    let module: Module
    let bytes: Int64?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: module.symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(module.tint.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(module.title).fontWeight(.medium)
                Text(bytes.map(Format.bytes) ?? "Sin escanear")
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }
}

/// Observa los módulos para saber si el escaneo global sigue en curso.
private struct ScanAllButton: View {
    @ObservedObject var junk: JunkViewModel
    @ObservedObject var developer: DeveloperViewModel
    @ObservedObject var downloads: DownloadsViewModel
    let action: () -> Void

    var body: some View {
        let busy = junk.isScanning || developer.isScanning || downloads.isScanning
        HStack(spacing: 10) {
            if busy {
                ProgressView().controlSize(.small)
                Text(statusText).font(.callout).foregroundStyle(.secondary)
            }
            Button(action: action) {
                Label(busy ? "Escaneando…" : "Escanear todo", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(busy)
        }
    }

    private var statusText: String {
        var names: [String] = []
        if junk.isScanning { names.append("basura") }
        if developer.isScanning { names.append("desarrollador") }
        if downloads.isScanning { names.append("descargas") }
        return "Escaneando " + names.joined(separator: ", ")
    }
}
