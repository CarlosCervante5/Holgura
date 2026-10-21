import SwiftUI
import HolguraCore

struct ItemRow: View {
    let item: CleanableItem
    let isSelected: Bool
    let toggle: () -> Void
    var badge: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in toggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            FileIcon(url: item.url)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name).lineLimit(1)
                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.green.opacity(0.18), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                Text(Format.abbreviate(item.url))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let note = item.note {
                    Text(note).font(.caption2).foregroundStyle(.orange).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(Format.date(item.modified))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
            Text(Format.bytes(item.size))
                .monospacedDigit()
                .frame(width: 84, alignment: .trailing)
            Button {
                Finder.reveal(item.url)
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Mostrar en Finder")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Mostrar en Finder") { Finder.reveal(item.url) }
            Button("Copiar ruta") { Finder.copyToPasteboard(item.url.path) }
        }
    }
}

/// Lista agrupada con casillas por elemento y por grupo.
struct GroupedItemList: View {
    @ObservedObject var model: ItemListViewModel
    var badge: (CleanableItem) -> String? = { _ in nil }
    @State private var expanded: Set<String> = []

    var body: some View {
        let groups = model.visibleGroups
        List {
            ForEach(groups) { group in
                DisclosureGroup(isExpanded: Binding(
                    get: { expanded.contains(group.id) },
                    set: { if $0 { expanded.insert(group.id) } else { expanded.remove(group.id) } })
                ) {
                    ForEach(group.items) { item in
                        ItemRow(item: item,
                                isSelected: model.selected.contains(item.id),
                                toggle: { model.toggle(item) },
                                badge: badge(item))
                    }
                } label: {
                    GroupHeader(group: group, model: model)
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .onAppear {
            if groups.count <= 3 { expanded = Set(groups.map(\.id)) }
        }
    }
}

struct GroupHeader: View {
    let group: ItemGroup
    @ObservedObject var model: ItemListViewModel

    var body: some View {
        let ids = group.items.map(\.id)
        let count = ids.filter { model.selected.contains($0) }.count
        let state: Bool? = count == 0 ? false : (count == ids.count ? true : nil)
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { state ?? false },
                set: { model.setGroup(group, selected: $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .overlay {
                    if state == nil {
                        Image(systemName: "minus").font(.system(size: 9, weight: .heavy)).allowsHitTesting(false)
                    }
                }
            Image(systemName: group.symbol).foregroundStyle(.secondary).frame(width: 22)
            Text(group.name).fontWeight(.medium).lineLimit(1)
            Text("\(group.items.count)").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(Format.bytes(group.totalSize)).monospacedDigit().fontWeight(.medium)
        }
    }
}

/// Barra inferior con el resumen de la selección y el botón que abre la revisión.
struct CleanupBar: View {
    @ObservedObject var model: ItemListViewModel
    var actionTitle = "Revisar y mover a la Papelera…"

    var body: some View {
        let items = model.selectedItems
        HStack {
            if model.isCleaning {
                ProgressView().controlSize(.small)
                Text("Moviendo a la Papelera…").foregroundStyle(.secondary)
            } else {
                Text(items.isEmpty
                     ? "Nada seleccionado"
                     : "\(items.count) elementos seleccionados · \(Format.bytes(model.selectedSize))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Seleccionar todo") { model.selectAllVisible(true) }
                .disabled(model.allItems.isEmpty)
            Button("Ninguno") { model.selectAllVisible(false) }
                .disabled(items.isEmpty)
            Button(actionTitle) { model.beginReview() }
                .buttonStyle(.borderedProminent)
                .disabled(items.isEmpty || model.isCleaning || model.isScanning)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

/// Pantalla de revisión obligatoria antes de mover nada a la Papelera.
struct ReviewSheet: View {
    let items: [CleanableItem]
    let onConfirm: () -> Void
    let onCancel: () -> Void
    private let protected = ProtectedPaths.default

    var body: some View {
        let list = TrashService.normalized(items)
        let total = list.reduce(Int64(0)) { $0 + $1.size }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "trash")
                    .font(.title)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Revisar antes de limpiar").font(.title2.weight(.semibold))
                    Text("Se moverán \(list.count) elementos (\(Format.bytes(total))) a la Papelera.")
                        .font(.headline)
                    Text("Nada se borra: podrás recuperarlos desde la Papelera hasta que la vacíes.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            List(list) { item in
                HStack(spacing: 10) {
                    FileIcon(url: item.url, size: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).lineLimit(1)
                        Text(Format.abbreviate(item.url))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                        if let reason = protected.trashRefusalReason(for: item.url) {
                            Text("Se omitirá: \(reason)").font(.caption2).foregroundStyle(.red)
                        }
                    }
                    Spacer()
                    Text(Format.bytes(item.size)).monospacedDigit()
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            HStack {
                Spacer()
                Button("Cancelar", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Mover \(list.count) elementos a la Papelera", action: onConfirm)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 720, minHeight: 440, idealHeight: 540)
    }
}

struct CleanupResultSheet: View {
    let result: CleanupResult
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: result.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(result.failures.isEmpty ? .green : .orange)
            Text("\(Format.bytes(result.bytes)) recuperados")
                .font(.largeTitle.weight(.semibold))
                .monospacedDigit()
            Text("\(result.trashed.count) elementos se movieron a la Papelera. El espacio se libera por completo al vaciarla.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if !result.failures.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(result.failures.count) elementos no se pudieron mover:").font(.headline)
                    List(result.failures) { failure in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Format.abbreviate(failure.item.url)).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                            Text(failure.reason).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .listStyle(.bordered)
                    .frame(minHeight: 100, maxHeight: 200)
                }
            }
            HStack {
                Button("Abrir Papelera") { Finder.openTrash() }
                Spacer()
                Button("Listo", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

extension View {
    /// Conecta la revisión y el resultado de limpieza de un `ItemListViewModel`.
    func cleanupFlow(_ model: ItemListViewModel) -> some View {
        modifier(CleanupFlowModifier(model: model))
    }
}

private struct CleanupFlowModifier: ViewModifier {
    @ObservedObject var model: ItemListViewModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(
                get: { model.reviewItems != nil },
                set: { if !$0 { model.reviewItems = nil } })
            ) {
                ReviewSheet(items: model.reviewItems ?? [],
                            onConfirm: { model.confirmCleanup() },
                            onCancel: { model.reviewItems = nil })
            }
            .sheet(isPresented: Binding(
                get: { model.cleanupResult != nil },
                set: { if !$0 { model.cleanupResult = nil } })
            ) {
                if let result = model.cleanupResult {
                    CleanupResultSheet(result: result) { model.cleanupResult = nil }
                }
            }
    }
}
