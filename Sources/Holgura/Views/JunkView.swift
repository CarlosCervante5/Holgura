import SwiftUI
import HolguraCore

struct JunkView: View {
    @ObservedObject var model: JunkViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ModuleHeader(module: .junk, subtitle: subtitle) {
                Button {
                    model.scan()
                } label: {
                    Label(model.groups.isEmpty ? "Escanear" : "Volver a escanear", systemImage: "arrow.clockwise")
                }
                .disabled(model.isScanning)
            }
            if model.isScanning {
                ScanProgressView(progress: model.progress, onCancel: model.cancelScan)
            }
            StatusBanner(message: model.statusMessage)
            IssuesDisclosure(issues: model.issues)

            if model.groups.isEmpty && !model.isScanning {
                ContentUnavailableView {
                    Label("Sin resultados todavía", systemImage: Module.junk.symbol)
                } description: {
                    Text("Revisa ~/Library/Caches, ~/Library/Logs y los temporales de tu usuario.")
                } actions: {
                    Button("Escanear") { model.scan() }.buttonStyle(.borderedProminent)
                }
                .frame(maxHeight: .infinity)
            } else {
                GroupedItemList(model: model)
            }
            CleanupBar(model: model)
        }
        .cleanupFlow(model)
    }

    private var subtitle: String {
        var parts = ["Cachés, registros y temporales agrupados por app"]
        if !model.groups.isEmpty { parts.append(Format.bytes(model.totalSize) + " encontrados") }
        if let date = model.lastScanDate { parts.append("escaneado " + Format.relative(date)) }
        return parts.joined(separator: " · ")
    }
}
