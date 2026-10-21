import SwiftUI
import AppKit
import HolguraCore

enum Finder {
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func openTrash() {
        NSWorkspace.shared.open(AppPaths.userTrash)
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Selector de carpeta. Devuelve `nil` si se cancela.
    @MainActor
    static func chooseFolder(startingAt url: URL? = nil, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = message
        panel.prompt = "Elegir"
        panel.directoryURL = url
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct FileIcon: View {
    let url: URL
    var size: CGFloat = 24

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

struct ModuleHeader<Trailing: View>: View {
    let module: Module
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: module.symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(module.tint.gradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(module.title).font(.title2.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

struct ScanProgressView: View {
    let progress: ProgressSnapshot
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(progress.phase.isEmpty ? "Escaneando…" : progress.phase)
                    .font(.headline)
                Spacer()
                Text("\(progress.visited.formatted()) archivos")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Button("Cancelar", role: .cancel, action: onCancel)
            }
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Text(progress.currentPath.isEmpty ? " " : Format.abbreviate(progress.currentPath))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 20)
    }
}

struct IssuesDisclosure: View {
    let issues: [ScanIssue]
    @State private var expanded = false

    var body: some View {
        if !issues.isEmpty {
            DisclosureGroup(isExpanded: $expanded) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(issues.prefix(300)) { issue in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(Format.abbreviate(issue.path)).font(.caption.monospaced())
                                Text(issue.reason).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        if issues.count > 300 {
                            Text("… y \(issues.count - 300) más").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            } label: {
                Label("\(issues.count) rutas no accesibles se saltaron", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            .padding(.horizontal, 20)
        }
    }
}

struct StatusBanner: View {
    let message: String?

    var body: some View {
        if let message {
            Label(message, systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
        }
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var symbol: String = "internaldrive"
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}
