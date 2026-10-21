import SwiftUI
import HolguraCore

struct RootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationSplitView {
            List(selection: $state.selection) {
                Section {
                    sidebarRow(.dashboard)
                }
                Section("Limpieza") {
                    sidebarRow(.junk)
                    sidebarRow(.developer)
                    sidebarRow(.downloads)
                }
                Section("Análisis") {
                    sidebarRow(.largeFiles)
                    sidebarRow(.duplicates)
                    sidebarRow(.spaceMap)
                }
                Section("Apps") {
                    sidebarRow(.uninstaller)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .safeAreaInset(edge: .bottom) {
                PermissionStatusFooter()
            }
        } detail: {
            Group {
                if state.showPermissionScreen {
                    PermissionView()
                } else {
                    detail(for: state.selection ?? .dashboard)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func sidebarRow(_ module: Module) -> some View {
        Label {
            Text(module.title)
        } icon: {
            Image(systemName: module.symbol).foregroundStyle(module.tint)
        }
        .tag(module)
    }

    @ViewBuilder
    private func detail(for module: Module) -> some View {
        switch module {
        case .dashboard:
            DashboardView()
        case .junk:
            JunkView(model: state.junk)
        case .developer:
            DeveloperView(model: state.developer)
        case .largeFiles:
            LargeFilesView(model: state.largeFiles)
        case .downloads:
            DownloadsView(model: state.downloads)
        case .spaceMap:
            SpaceMapView(model: state.spaceMap)
        case .duplicates:
            DuplicatesView(model: state.duplicates)
        case .uninstaller:
            UninstallerView(model: state.uninstaller)
        }
    }
}

struct PermissionStatusFooter: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Button {
            state.showPermissionScreen = !state.hasFullDiskAccess
            if state.hasFullDiskAccess { state.refreshPermissions() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: state.hasFullDiskAccess ? "lock.open.fill" : "lock.fill")
                    .foregroundStyle(state.hasFullDiskAccess ? .green : .orange)
                Text(state.hasFullDiskAccess ? "Acceso total al disco" : "Sin acceso total al disco")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(state.hasFullDiskAccess ? "Holgura puede leer todo tu Mac" : "Haz clic para ver cómo darle acceso")
    }
}
