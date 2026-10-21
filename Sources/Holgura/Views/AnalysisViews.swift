import SwiftUI
import HolguraCore

// MARK: - Archivos grandes

struct LargeFilesView: View {
    @ObservedObject var model: LargeFilesViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ModuleHeader(module: .largeFiles, subtitle: subtitle) {
                Button {
                    model.scan()
                } label: {
                    Label("Buscar", systemImage: "magnifyingglass")
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
                .frame(maxWidth: 220, alignment: .leading)
                HStack(spacing: 4) {
                    Text("Mayores de")
                    TextField("MB", value: $model.minSizeMB, format: .number)
                        .frame(width: 64)
                        .multilineTextAlignment(.trailing)
                    Text("MB")
                }
                Toggle("Incluir ~/Library", isOn: $model.includeLibrary)
                Spacer()
                Picker("Antigüedad", selection: $model.ageFilter) {
                    ForEach(AgeFilter.allCases) { Text($0.label).tag($0) }
                }
                .frame(width: 200)
                Picker("Tipo", selection: $model.typeFilter) {
                    Text("Todos").tag(FileCategory?.none)
                    ForEach(FileCategory.allCases) { Label($0.label, systemImage: $0.symbol).tag(FileCategory?.some($0)) }
                }
                .frame(width: 190)
            }
            .padding(.horizontal, 20)

            if model.isScanning {
                ScanProgressView(progress: model.progress, onCancel: model.cancelScan)
            }
            StatusBanner(message: model.statusMessage)
            IssuesDisclosure(issues: model.issues)

            if model.visibleGroups.isEmpty && !model.isScanning {
                ContentUnavailableView(model.lastScanDate == nil ? "Busca archivos grandes" : "Nada coincide con los filtros",
                                       systemImage: Module.largeFiles.symbol,
                                       description: Text("Elige una carpeta y un tamaño mínimo. Los paquetes (.app, bibliotecas) cuentan como un único elemento."))
                    .frame(maxHeight: .infinity)
            } else {
                GroupedItemList(model: model)
            }
            CleanupBar(model: model)
        }
        .cleanupFlow(model)
    }

    private var subtitle: String {
        var parts = ["Archivos pesados en la carpeta elegida"]
        if !model.allItems.isEmpty {
            parts.append("\(model.allItems.count) archivos · \(Format.bytes(model.totalSize))")
        }
        if let date = model.lastScanDate { parts.append("escaneado " + Format.relative(date)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Descargas y Papelera

struct DownloadsView: View {
    @ObservedObject var model: DownloadsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ModuleHeader(module: .downloads, subtitle: subtitle) {
                Button {
                    model.scan()
                } label: {
                    Label(model.lastScanDate == nil ? "Escanear" : "Volver a escanear", systemImage: "arrow.clockwise")
                }
                .disabled(model.isScanning)
            }

            HStack(spacing: 12) {
                StatTile(title: "Descargas", value: Format.bytes(model.result.downloadsTotal),
                         symbol: "arrow.down.circle", tint: .blue)
                StatTile(title: "Más de \(model.olderThanDays) días", value: Format.bytes(model.oldItemsSize),
                         symbol: "clock", tint: .orange)
                HStack {
                    StatTile(title: "Papelera",
                             value: model.result.trashSize.map(Format.bytes) ?? "—",
                             symbol: "trash", tint: .gray)
                    Button("Abrir Papelera") { Finder.openTrash() }
                }
            }
            .padding(.horizontal, 20)
            if let msg = model.result.trashMessage {
                Text(msg).font(.caption).foregroundStyle(.orange).padding(.horizontal, 20)
            }

            HStack {
                Stepper(value: $model.olderThanDays, in: 0...3650, step: 7) {
                    Text("Mostrar descargas de más de \(model.olderThanDays) días")
                }
                Spacer()
                Text("Holgura nunca vacía la Papelera: hazlo tú desde Finder cuando estés seguro.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)

            if model.isScanning {
                ScanProgressView(progress: model.progress, onCancel: model.cancelScan)
            }
            StatusBanner(message: model.statusMessage)
            IssuesDisclosure(issues: model.issues)

            if model.visibleGroups.isEmpty && !model.isScanning {
                ContentUnavailableView(model.lastScanDate == nil ? "Escanea tus Descargas" : "No hay descargas tan antiguas",
                                       systemImage: Module.downloads.symbol)
                    .frame(maxHeight: .infinity)
            } else {
                GroupedItemList(model: model)
            }
            CleanupBar(model: model)
        }
        .cleanupFlow(model)
    }

    private var subtitle: String {
        var parts = ["~/Downloads y tamaño de la Papelera"]
        if let date = model.lastScanDate { parts.append("escaneado " + Format.relative(date)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Mapa de espacio

struct SpaceMapView: View {
    @ObservedObject var model: SpaceMapViewModel
    @State private var mode: Mode = .treemap
    @State private var hovered: SpaceNode?

    enum Mode: String, CaseIterable, Identifiable {
        case treemap = "Mapa"
        case list = "Lista"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ModuleHeader(module: .spaceMap, subtitle: "Navega por tus carpetas ordenadas por tamaño (solo lectura)") {
                Menu {
                    Button("Carpeta de inicio") { model.setRoot(FileManager.default.homeDirectoryForCurrentUser) }
                    Button("Disco completo (/)") { model.setRoot(URL(fileURLWithPath: "/")) }
                    Divider()
                    Button("Elegir carpeta…") { model.chooseRoot() }
                } label: {
                    Label("Analizar", systemImage: "folder")
                }
                .fixedSize()
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.isScanning)
                .help("Volver a medir esta carpeta")
            }

            HStack(spacing: 6) {
                Button {
                    model.goUp()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(model.path.isEmpty)
                breadcrumbs
                Spacer()
                Text(Format.bytes(model.currentTotal)).monospacedDigit().foregroundStyle(.secondary)
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
            }
            .padding(.horizontal, 20)

            if model.isScanning {
                ScanProgressView(progress: model.progress, onCancel: model.cancelScan)
            }
            StatusBanner(message: model.statusMessage)
            IssuesDisclosure(issues: model.issues)

            if model.nodes.isEmpty && !model.isScanning {
                ContentUnavailableView {
                    Label("Mapa de espacio", systemImage: Module.spaceMap.symbol)
                } description: {
                    Text("Mide una carpeta para ver qué ocupa espacio. Haz clic en una carpeta para entrar.")
                } actions: {
                    Button("Analizar carpeta de inicio") { model.setRoot(model.root) }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxHeight: .infinity)
            } else if mode == .treemap {
                TreemapView(nodes: model.nodes, hovered: $hovered, onOpen: model.open)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                hoverBar
            } else {
                SpaceList(nodes: model.nodes, total: model.currentTotal, onOpen: model.open)
            }
        }
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                Button(Format.abbreviate(model.root)) { model.goTo(index: -1) }
                    .buttonStyle(.borderless)
                ForEach(Array(model.path.enumerated()), id: \.offset) { index, url in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Button(url.lastPathComponent) { model.goTo(index: index) }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    private var hoverBar: some View {
        HStack {
            if let node = hovered {
                FileIcon(url: node.url, size: 16)
                Text(Format.abbreviate(node.url)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(Format.bytes(node.size)).monospacedDigit()
            } else {
                Text("Pasa el ratón sobre un bloque para ver detalles · clic para entrar · clic secundario para Finder")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }
}

private struct TreemapView: View {
    let nodes: [SpaceNode]
    @Binding var hovered: SpaceNode?
    let onOpen: (SpaceNode) -> Void

    private static let palette: [Color] = [.teal, .blue, .indigo, .purple, .pink, .orange, .green, .cyan, .mint, .brown]

    var body: some View {
        GeometryReader { geo in
            let shown = Array(nodes.filter { $0.size > 0 }.prefix(80))
            let rects = TreemapLayout.squarify(values: shown.map { Double($0.size) },
                                               in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, node in
                    let rect = rects[index].insetBy(dx: 1, dy: 1)
                    if rect.width > 1 && rect.height > 1 {
                        let color = Self.palette[index % Self.palette.count]
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(color.opacity(hovered == node ? 0.95 : (node.canDrillDown ? 0.75 : 0.45)).gradient)
                            .overlay(alignment: .topLeading) {
                                if rect.width > 70 && rect.height > 34 {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(node.name).font(.caption.weight(.semibold)).lineLimit(1)
                                        Text(Format.bytes(node.size)).font(.caption2).monospacedDigit()
                                    }
                                    .foregroundStyle(.white)
                                    .padding(5)
                                }
                            }
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                            .onHover { inside in
                                if inside { hovered = node } else if hovered == node { hovered = nil }
                            }
                            .onTapGesture { onOpen(node) }
                            .contextMenu {
                                Button("Mostrar en Finder") { Finder.reveal(node.url) }
                                Button("Copiar ruta") { Finder.copyToPasteboard(node.url.path) }
                            }
                            .help("\(node.name) · \(Format.bytes(node.size))")
                    }
                }
            }
        }
    }
}

private struct SpaceList: View {
    let nodes: [SpaceNode]
    let total: Int64
    let onOpen: (SpaceNode) -> Void

    var body: some View {
        List(nodes) { node in
            HStack(spacing: 10) {
                FileIcon(url: node.url, size: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(node.name).lineLimit(1)
                    GeometryReader { geo in
                        Capsule().fill(Color.teal.opacity(0.25))
                            .overlay(alignment: .leading) {
                                Capsule().fill(Color.teal)
                                    .frame(width: geo.size.width * CGFloat(Double(node.size) / Double(max(total, 1))))
                            }
                    }
                    .frame(height: 5)
                }
                Text(Format.bytes(node.size)).monospacedDigit().frame(width: 90, alignment: .trailing)
                Button {
                    Finder.reveal(node.url)
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Mostrar en Finder")
                Image(systemName: "chevron.right")
                    .foregroundStyle(node.canDrillDown ? Color.secondary : Color.clear)
            }
            .contentShape(Rectangle())
            .onTapGesture { onOpen(node) }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }
}
