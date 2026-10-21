import SwiftUI
import HolguraCore

struct PermissionView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(Color.orange.gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Holgura necesita Acceso total al disco")
                            .font(.title.weight(.semibold))
                        Text("Sin él, macOS oculta parte de ~/Library y los tamaños saldrán incompletos.")
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("¿Por qué?").font(.headline)
                    bullet("Las cachés, contenedores y datos de otras apps en ~/Library están protegidos por macOS.")
                    bullet("Sin acceso, esas carpetas se saltan y se reportan como «no accesibles».")
                    bullet("Holgura solo lee para escanear. Lo único que modifica es lo que tú confirmas mover a la Papelera.")
                    bullet("Nunca usa sudo, nunca pide tu contraseña y nunca toca las rutas del sistema protegidas.")
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Cómo darle acceso").font(.headline)
                    step(1, "Pulsa «Abrir Ajustes del Sistema».")
                    step(2, "En Privacidad y seguridad › Acceso total al disco, activa Holgura (o añádela con «+»).")
                    step(3, "Vuelve aquí: el acceso se comprueba automáticamente. Si no cambia, cierra y abre Holgura.")
                }

                HStack(spacing: 12) {
                    Button {
                        state.openFullDiskAccessSettings()
                    } label: {
                        Label("Abrir Ajustes del Sistema", systemImage: "gearshape")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button("Comprobar de nuevo") { state.refreshPermissions() }
                        .controlSize(.large)

                    Spacer()

                    Button("Continuar sin acceso total") { state.showPermissionScreen = false }
                        .buttonStyle(.link)
                }

                if state.hasFullDiskAccess {
                    Label("¡Listo! Holgura ya tiene Acceso total al disco.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
            }
            .padding(36)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.secondary)
            Text(text)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))
            Text(text)
        }
    }
}
