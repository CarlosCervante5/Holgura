import SwiftUI
import HolguraCore

struct DeveloperView: View {
    @ObservedObject var model: DeveloperViewModel
    @State private var tab: Tab = .caches
    @State private var confirmSimulators = false

    enum Tab: String, CaseIterable, Identifiable {
        case caches = "Xcode y cachés"
        case node = "node_modules"
        case simulators = "Simuladores"
        case brew = "Homebrew"
        case docker = "Docker"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ModuleHeader(module: .developer, subtitle: subtitle) {
                Button {
                    model.scan()
                } label: {
                    Label(model.result.groups.isEmpty ? "Escanear" : "Volver a escanear", systemImage: "arrow.clockwise")
                }
                .disabled(model.isScanning)
            }
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)

            if model.isScanning {
                ScanProgressView(progress: model.progress, onCancel: model.cancelScan)
            }
            StatusBanner(message: model.statusMessage)
            IssuesDisclosure(issues: model.issues)

            Group {
                switch tab {
                case .caches: cachesTab
                case .node: nodeTab
                case .simulators: simulatorsTab
                case .brew: brewTab
                case .docker: dockerTab
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            CleanupBar(model: model)
        }
        .cleanupFlow(model)
        .alert("¿Eliminar simuladores no disponibles?", isPresented: $confirmSimulators) {
            Button("Cancelar", role: .cancel) {}
            Button("Eliminar \(model.result.simulators.count) simuladores", role: .destructive) {
                model.deleteUnavailableSimulators()
            }
        } message: {
            Text("Se ejecutará «xcrun simctl delete unavailable». Esta acción la realiza Xcode y NO pasa por la Papelera: los datos de esos simuladores (\(Format.bytes(model.result.simulators.reduce(0) { $0 + $1.size }))) no se podrán recuperar. Quedará registrada en el log.")
        }
    }

    private var subtitle: String {
        var parts = ["Xcode, node_modules, cachés de paquetes, Homebrew y Docker"]
        if let date = model.lastScanDate { parts.append("escaneado " + Format.relative(date)) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Pestañas

    @ViewBuilder
    private var cachesTab: some View {
        let groups = model.visibleGroups.filter { $0.name != DeveloperScanner.nodeModulesGroup }
        if groups.isEmpty && !model.isScanning {
            emptyState("Escanea para ver DerivedData, Archives, Device Support y cachés de npm, Yarn, pnpm, pip, Homebrew, CocoaPods y Gradle.")
        } else {
            FilteredGroupList(model: model, groups: groups)
        }
    }

    private var nodeTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                Text(model.nodeModulesRoot.map(Format.abbreviate) ?? "Elige tu carpeta de proyectos")
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(model.nodeModulesRoot == nil ? .secondary : .primary)
                Button("Cambiar…") { model.chooseNodeModulesRoot() }
                Spacer()
                Stepper(value: $model.staleDays, in: 0...3650, step: 30) {
                    Text("Seleccionar proyectos sin cambios en \(model.staleDays) días o más")
                        .font(.callout)
                }
                .onChange(of: model.staleDays) { model.applyStaleFilter() }
                Button("Buscar node_modules") { model.scanNodeModules() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.nodeModulesRoot == nil || model.isScanning)
            }
            .padding(.horizontal, 20)

            let groups = model.visibleGroups.filter { $0.name == DeveloperScanner.nodeModulesGroup }
            if groups.isEmpty && !model.isScanning {
                emptyState("Holgura busca carpetas node_modules dentro de la carpeta elegida y muestra cuándo se modificó cada proyecto por última vez, para que limpies los antiguos (se recuperan con npm install).")
            } else {
                FilteredGroupList(model: model, groups: groups)
            }
        }
    }

    private var simulatorsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.result.simctlAvailable && model.lastScanDate != nil {
                emptyState("No se encontró simctl (Xcode o las Command Line Tools no están configurados).")
            } else if model.result.simulators.isEmpty {
                emptyState(model.lastScanDate == nil
                           ? "Escanea para buscar simuladores no disponibles."
                           : "No hay simuladores no disponibles. 🎉")
            } else {
                List(model.result.simulators) { sim in
                    HStack {
                        Image(systemName: "iphone.gen3.slash").foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(sim.name)
                            Text("\(sim.runtime) · \(sim.udid)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Format.bytes(sim.size)).monospacedDigit()
                    }
                }
                .listStyle(.inset)
                HStack {
                    Text("Total: \(Format.bytes(model.result.simulators.reduce(0) { $0 + $1.size }))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model.isDeletingSimulators { ProgressView().controlSize(.small) }
                    Button("Eliminar no disponibles…") { confirmSimulators = true }
                        .disabled(model.isDeletingSimulators)
                }
                .padding(.horizontal, 20)
            }
            if let message = model.simulatorMessage {
                Text(message).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 20)
            }
        }
    }

    private var brewTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.result.brewAvailable {
                emptyState(model.lastScanDate == nil ? "Escanea para ejecutar «brew cleanup -n»." : "Homebrew no está instalado.")
            } else {
                Text("Salida de «brew cleanup -n» (solo previsualización). Los archivos listados aparecen en la pestaña «Xcode y cachés» para moverlos a la Papelera; Holgura no ejecuta «brew cleanup».")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                CommandOutput(text: model.result.brewOutput ?? "")
                SuggestedCommand(command: "brew cleanup")
            }
        }
    }

    private var dockerTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let output = model.result.dockerOutput {
                Text("Uso de disco de Docker («docker system df»). Holgura no ejecuta comandos de limpieza de Docker; si quieres liberar espacio, revisa y ejecuta tú mismo:")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                CommandOutput(text: output)
                SuggestedCommand(command: "docker system prune")
                SuggestedCommand(command: "docker builder prune")
            } else {
                emptyState(model.result.dockerMessage ?? "Escanea para consultar el uso de Docker.")
            }
        }
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(30)
    }
}

/// Lista agrupada que muestra solo algunos grupos del modelo.
private struct FilteredGroupList: View {
    @ObservedObject var model: ItemListViewModel
    let groups: [ItemGroup]
    @State private var expanded: Set<String> = []

    var body: some View {
        List {
            ForEach(groups) { group in
                DisclosureGroup(isExpanded: Binding(
                    get: { expanded.contains(group.id) },
                    set: { if $0 { expanded.insert(group.id) } else { expanded.remove(group.id) } })
                ) {
                    ForEach(group.items) { item in
                        ItemRow(item: item, isSelected: model.selected.contains(item.id), toggle: { model.toggle(item) })
                    }
                } label: {
                    GroupHeader(group: group, model: model)
                }
            }
        }
        .listStyle(.inset)
        .onAppear { expanded = Set(groups.map(\.id)) }
    }
}

struct CommandOutput: View {
    let text: String

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxHeight: 260)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 20)
    }
}

struct SuggestedCommand: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack {
            Image(systemName: "terminal").foregroundStyle(.secondary)
            Text(command).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Spacer()
            Button(copied ? "Copiado" : "Copiar") {
                Finder.copyToPasteboard(command)
                copied = true
            }
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 20)
    }
}
