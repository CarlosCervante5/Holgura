# Holgura

App nativa de macOS (Swift + SwiftUI, macOS 14+) de código abierto para analizar y liberar espacio en disco de forma segura. No tiene dependencias de terceros.

> ⚠️ Holgura mueve archivos a la Papelera. Revisa siempre la pantalla de confirmación antes de aceptar. Se ofrece sin garantía (ver [LICENSE](LICENSE)).

## Compilar

Requisitos: Xcode 15 o superior (probado con Xcode 27).

```bash
./scripts/build-app.sh            # Release → dist/Holgura.app (ícono + firma ad-hoc, sin sandbox)
```

Otros comandos:

```bash
xcodebuild -scheme Holgura -destination 'platform=macOS' build    # compilar (Debug)
xcodebuild test -scheme Holgura -destination 'platform=macOS'     # pruebas unitarias
```

Es un Swift Package (`Package.swift`). La lógica está en `Sources/HolguraCore`, que es testeable y no depende de la UI. La app SwiftUI (MVVM) está en `Sources/Holgura` y las pruebas en `Tests/HolguraCoreTests`. Las pruebas usan solo carpetas temporales con archivos de prueba.

## Acceso total al disco

Sin este permiso macOS oculta parte de `~/Library`: esas rutas se saltan y se informan como “no accesibles”.

1. Abre `dist/Holgura.app`. Si no tiene acceso, verás una pantalla con el botón **Abrir Ajustes del Sistema**.
2. En **Privacidad y seguridad › Acceso total al disco**, activa **Holgura**. Si no aparece, pulsa **+** y elige `dist/Holgura.app`.
3. Vuelve a Holgura. Se comprueba sola al recuperar el foco; si no cambia, cierra y vuelve a abrir la app.

> La firma es ad-hoc, así que **cada vez que recompiles** macOS puede tratarla como una app nueva. Si el acceso “desaparece”, quítala de la lista y vuelve a añadirla. Te conviene mover la app a `~/Applications` para que la ruta no cambie.

## Reglas de seguridad

- **Nunca se borra nada**: todo se mueve a la Papelera con `FileManager.trashItem`. El código no usa `removeItem` ni `rm` (la única excepción son las pruebas, que limpian su propia carpeta temporal).
- Los escaneos son de solo lectura. Antes de mover nada aparece siempre una **pantalla de revisión** con cada elemento, su ruta y su tamaño, y hay que confirmarla.
- No usa `sudo` ni pide contraseña. `ShellRunner` bloquea `sudo`, `su`, `rm`, `osascript` y otros.
- Cada acción se registra en `~/Library/Application Support/Holgura/cleanup.log` con fecha, acción, tamaño, ruta y destino en la Papelera.
- Las rutas sin permiso se saltan y se informan; el escaneo no falla por ellas.
- No sigue symlinks. Los paquetes (`.app`…) cuentan como una unidad en los listados.
- Para deshacer una limpieza: `scripts/restore-from-log.sh "<fecha-hora>"` muestra qué se restauraría y `--run` lo devuelve a su sitio (con `mv -n`, sin sobrescribir).

### Rutas que nunca toca (ni escanea)

| Ruta | Motivo |
|---|---|
| `/System`, `/usr`, `/bin`, `/sbin` | Sistema |
| `/private/var/db` (`/var/db`) | Bases de datos del sistema |
| `/Library/Apple`, `/System/Applications` | Apple |
| `~/Library/Keychains` | Llaveros |
| `~/Library/Mobile Documents` | iCloud Drive |
| `~/Library/Mail`, `~/Library/Messages` | Correo y Mensajes |
| `*.photoslibrary` (en cualquier sitio) | Bibliotecas de Fotos |
| Apps con bundle id `com.apple.*` en `/Applications` y `~/Applications` | Apps de Apple |

Además, hay carpetas críticas que se pueden escanear pero **nunca moverse enteras**: `/`, `~`, `~/Library`, `~/Library/Caches`, `~/Downloads`, `~/Documents`, `~/Desktop`, `/Applications`, `~/.Trash`, la carpeta temporal, etc. Sí se puede mover su contenido. El filtro está en `Sources/HolguraCore/ProtectedPaths.swift` y cubierto por `ProtectedPathsTests`.

## Qué revisa cada módulo

| Módulo | Qué muestra | Qué puede mover a la Papelera |
|---|---|---|
| **Panel** | Espacio total, usado y libre (`volumeAvailableCapacityForImportantUsage`), dona por categoría, “Escanear todo” | — |
| **Basura del sistema** | `~/Library/Caches`, `~/Library/Logs` y temporales del usuario con más de 24 h, agrupados por app | Lo que marques. Las cachés `com.apple.*` vienen desmarcadas, y algunas sensibles (iCloud/CloudKit) se excluyen |
| **Desarrollador** | Xcode: `DerivedData`, `Archives` (desmarcados), `*DeviceSupport`. Cachés de npm, Yarn, pnpm, pip, Homebrew, CocoaPods, Gradle y node-gyp. `node_modules` en la carpeta que elijas, con la fecha de la última modificación del proyecto | Lo que marques. De `brew cleanup -n` solo se usa la previsualización: lo listado se mueve a la Papelera y **nunca** se ejecuta `brew cleanup` |
| ↳ Simuladores | `xcrun simctl list devices unavailable` con su tamaño | Con una confirmación aparte, `xcrun simctl delete unavailable`. **Esto lo hace Xcode y no pasa por la Papelera** (lo pediste así); queda en el log |
| ↳ Docker | `docker system df` | Nada: solo sugiere `docker system prune` para que lo copies |
| **Archivos grandes** | Archivos (o paquetes) mayores que un umbral (500 MB por defecto) en la carpeta elegida, con filtro por antigüedad y tipo, y “Mostrar en Finder” | Lo que marques (todo viene desmarcado) |
| **Descargas y Papelera** | Tamaño de `~/Downloads`, elementos con más de N días (según la fecha en que llegaron) y tamaño de la Papelera | Descargas marcadas. **La Papelera nunca se vacía**; solo hay un botón para abrirla |
| **Mapa de espacio** | Treemap o lista navegable de carpetas por tamaño | Nada (solo lectura) |
| **Duplicados** | Archivos idénticos comparados por tamaño, luego hash de los primeros 64 KB y al final SHA-256 completo. Sugiere conservar el más antiguo o el de ruta más corta | Las copias que marques. Nunca deja mover todas las copias de un grupo |
| **Desinstalador** | Apps de `/Applications` y `~/Applications` (sin las de Apple) y sus restos por bundle id en Application Support, Caches, Preferences, Containers, Group Containers, Saved Application State, LaunchAgents, HTTPStorages, WebKit, Logs y Cookies | La app y los restos marcados. Las coincidencias solo por nombre vienen desmarcadas |

El último escaneo de cada módulo se guarda en `~/Library/Application Support/Holgura/cache/` y se muestra al abrir la app. Los elementos que ya no existen se descartan.

## Contribuir

Los issues y pull requests son bienvenidos. Antes de enviar cambios:

```bash
xcodebuild test -scheme Holgura -destination 'platform=macOS'
```

Toda limpieza debe seguir pasando por `TrashService` (solo `trashItem`, con la lista negra de `ProtectedPaths`). Las pruebas nuevas deben usar carpetas temporales, nunca rutas reales.

## Licencia

[MIT](LICENSE). Holgura no tiene ninguna relación con otras apps de limpieza ni con sus fabricantes.
