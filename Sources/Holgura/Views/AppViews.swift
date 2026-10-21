import SwiftUI
import HolguraCore

// MARK: - Duplicados

struct DuplicatesView: View {
    @ObservedObject var model: DuplicatesViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ModuleHeader(module: .duplicates, subtitle: subtitle) {
                Button {
                    model.scan()
                } label: {
                    Label("Buscar duplicados", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isScanning)
            }

            HStack(spacing: 14) {
                Button {
                    model.chooseRoot()
                } label: {
                    Label(Format.abbreviate(model.root), systemImage: "folder")
                        .lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: 260, alignment: .leading)
                HStack(spacing: 4) {
                    Text("Tamaño mínimo")
                    TextField("KB", value: $model.minSizeKB, format: .number)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                    Text("KB")
                }
                Spacer()
                Picker("Sugerencia", selection: $model.strategy) {
                    ForEach(KeepStrategy.allCases) { Text($0.label).tag($0) }
                }
                .frame(width: 290)
                Button("Aplicar sugerencia") { model.applySuggestion() }
                    .disabled(model.duplicateGroups.isEmpty)
            }
            .padding(.horizontal, 20)

            if model.isScanning {
                ScanProgressView(progress: model.progress, onCancel: model.cancelScan)
            }
            StatusBanner(message: model.statusMessage)
            IssuesDisclosure(issues: model.issues)

            if model.groups.isEmpty && !model.isScanning {
                ContentUnavailableView(model.lastScanDate == nil ? "Busca archivos duplicados" : "No se encontraron duplicados",
                                       systemImage: Module.duplicates.symbol,
                                       description: Text("Se comparan por tamaño, luego los primeros 64 KB y por último el SHA-256 completo. Tú decides qué copia conservar."))
                    .frame(maxHeight: .infinity)
            } else {
                GroupedItemList(model: model) { item in
                    model.isSuggestedKeep(item) ? "Sugerido conservar" : nil
                }
            }
            CleanupBar(model: model)
        }
        .cleanupFlow(model)
    }

    private var subtitle: String {
        if model.duplicateGroups.isEmpty { return "Archivos idénticos en la carpeta elegida" }
        return "\(model.duplicateGroups.count) grupos · \(Format.bytes(model.wastedTotal)) recuperables"
    }
}

// MARK: - Desinstalador

struct UninstallerView: View {
    @ObservedObject var model: UninstallerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: .uninstaller, subtitle: subtitle) {
                Button {
                    model.scan()
                } label: {
                    Label(model.apps.isEmpty ? "Buscar apps" : "Actualizar", systemImage: "arrow.clockwise")
                }
                .disabled(model.isScanning)
            }
            if model.isScanning {
                ScanProgressView(progress: model.progress, onCancel: model.cancelScan)
                    .padding(.bottom, 8)
            }
            StatusBanner(message: model.statusMessage)

            HSplitView {
                appList
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
                detail
                    .frame(minWidth: 420, maxWidth: .infinity)
            }
        }
        .cleanupFlow(model)
        .onAppear {
            if model.apps.isEmpty && !model.isScanning { model.scan() }
        }
    }

    private var subtitle: String {
        var parts = ["Apps de /Applications y ~/Applications (excepto las de Apple)"]
        if !model.apps.isEmpty { parts.append("\(model.apps.count) apps") }
        return parts.joined(separator: " · ")
    }

    private var appList: some View {
        VStack(spacing: 0) {
            TextField("Buscar", text: $model.search)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            List(model.filteredApps, selection: Binding(
                get: { model.selectedApp?.id },
                set: { id in model.select(model.apps.first { $0.id == id }) })
            ) { app in
                HStack(spacing: 10) {
                    FileIcon(url: app.url, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name).lineLimit(1)
                        Text(app.version.map { "v\($0)" } ?? (app.bundleID ?? ""))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(Format.bytes(app.size)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
                .tag(app.id)
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let app = model.selectedApp {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    FileIcon(url: app.url, size: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(.title2.weight(.semibold))
                        Text(app.bundleID ?? "Sin bundle identifier").font(.callout.monospaced()).foregroundStyle(.secondary)
                        Text(Format.abbreviate(app.url)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text(Format.bytes(model.totalSize)).font(.title3.weight(.semibold)).monospacedDigit()
                        Text("app + restos").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)

                if model.isRunning {
                    Label("La app está abierta. Ciérrala antes de desinstalarla.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 20)
                }

                if model.isLoadingLeftovers && model.groups.isEmpty {
                    ProgressView("Buscando restos por bundle identifier…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    GroupedItemList(model: model)
                        .id(app.id)
                }
                CleanupBar(model: model, actionTitle: "Desinstalar (mover a la Papelera)…")
            }
        } else {
            ContentUnavailableView("Elige una app",
                                   systemImage: "app.dashed",
                                   description: Text("Verás la app y sus restos en Application Support, Caches, Preferences, Containers, Group Containers, Saved Application State y LaunchAgents antes de mover nada."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
