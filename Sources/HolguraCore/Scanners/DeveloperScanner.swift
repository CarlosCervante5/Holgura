import Foundation

public struct SimulatorDevice: Identifiable, Hashable, Codable, Sendable {
    public let udid: String
    public let name: String
    public let runtime: String
    public let dataPath: String?
    public var size: Int64
    public var id: String { udid }
}

public struct DeveloperScanResult: Codable, Sendable {
    public var groups: [ItemGroup] = []
    public var simulators: [SimulatorDevice] = []
    public var simctlAvailable = false
    public var brewOutput: String?
    public var brewAvailable = false
    public var dockerOutput: String?
    public var dockerMessage: String?

    public init() {}
}

/// Xcode, cachés de gestores de paquetes, Homebrew, simuladores, Docker y node_modules.
public struct DeveloperScanner: Sendable {
    public let scanner: FileScanner
    public let home: URL

    public init(scanner: FileScanner = FileScanner(),
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.scanner = scanner
        self.home = home
    }

    public static let xcodeDerivedDataGroup = "Xcode · DerivedData"
    public static let xcodeArchivesGroup = "Xcode · Archives"
    public static let deviceSupportGroup = "Xcode · Device Support"
    public static let packageCachesGroup = "Cachés de paquetes"
    public static let brewGroup = "Homebrew · brew cleanup -n"
    public static let nodeModulesGroup = "node_modules"

    /// Cachés conocidas: nombre visible y ruta relativa al home.
    static let packageCaches: [(String, String)] = [
        ("npm", ".npm/_cacache"),
        ("Yarn (v1)", "Library/Caches/Yarn"),
        ("Yarn (Berry)", ".yarn/berry/cache"),
        ("pnpm store", "Library/pnpm/store"),
        ("pnpm (caché)", "Library/Caches/pnpm"),
        ("pip", "Library/Caches/pip"),
        ("Homebrew (descargas)", "Library/Caches/Homebrew"),
        ("CocoaPods", "Library/Caches/CocoaPods"),
        ("Gradle", ".gradle/caches"),
        ("node-gyp", "Library/Caches/node-gyp"),
    ]

    public func scan(progress: ProgressBox) async throws -> DeveloperScanResult {
        var result = DeveloperScanResult()

        // Herramientas externas en paralelo con el cálculo de tamaños.
        async let brew = brewPreview()
        async let docker = dockerUsage()
        async let sims = unavailableSimulators(progress: progress)

        progress.setPhase("Revisando Xcode y cachés de desarrollo…")
        let xcode = home.appendingPathComponent("Library/Developer/Xcode")
        var targets: [(URL, String, ItemKind, Bool, String?)] = []

        for url in scanner.children(of: xcode.appendingPathComponent("DerivedData"), progress: progress) {
            targets.append((url, Self.xcodeDerivedDataGroup, .derivedData, true, nil))
        }
        // Archives/<fecha>/<nombre>.xcarchive
        for day in scanner.children(of: xcode.appendingPathComponent("Archives"), progress: progress) {
            for archive in scanner.children(of: day, progress: progress) where archive.pathExtension == "xcarchive" {
                targets.append((archive, Self.xcodeArchivesGroup, .xcodeArchive, false,
                                "Necesario para simbolizar crashes de versiones publicadas"))
            }
        }
        for platform in scanner.children(of: xcode, progress: progress)
        where platform.lastPathComponent.hasSuffix("DeviceSupport") {
            for version in scanner.children(of: platform, progress: progress, includeHidden: false) {
                targets.append((version, Self.deviceSupportGroup, .deviceSupport, true,
                                platform.lastPathComponent + " · se vuelve a generar al conectar el dispositivo"))
            }
        }
        for (_, rel) in Self.packageCaches {
            let url = home.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: url.path) {
                targets.append((url, Self.packageCachesGroup, .packageCache, true, nil))
            }
        }

        progress.setTotal(targets.count)
        let meta = Dictionary(targets.map { ($0.0, $0) }, uniquingKeysWith: { a, _ in a })
        let names = Dictionary(Self.packageCaches.map { (home.appendingPathComponent($0.1), $0.0) },
                               uniquingKeysWith: { a, _ in a })
        let items = try await scanner.items(for: targets.map(\.0), progress: progress) { url, size, modified in
            guard size > 0, let m = meta[url] else { return nil }
            return CleanableItem(url: url, name: names[url] ?? url.lastPathComponent, size: size,
                                 modified: modified, kind: m.2, group: m.1, note: m.4, selectedByDefault: m.3)
        }

        let symbols = [Self.xcodeDerivedDataGroup: "hammer", Self.xcodeArchivesGroup: "archivebox",
                       Self.deviceSupportGroup: "iphone", Self.packageCachesGroup: "shippingbox"]
        var groups = Dictionary(grouping: items, by: \.group).map { name, items in
            ItemGroup(name: name, symbol: symbols[name] ?? "folder", items: items.sorted { $0.size > $1.size })
        }

        progress.setPhase("Consultando Homebrew, Docker y simuladores…")
        let brewResult = await brew
        result.brewAvailable = brewResult.available
        result.brewOutput = brewResult.output
        if !brewResult.items.isEmpty {
            groups.append(ItemGroup(name: Self.brewGroup, symbol: "mug", items: brewResult.items))
        }
        let dockerResult = await docker
        result.dockerOutput = dockerResult.output
        result.dockerMessage = dockerResult.message
        let simResult = await sims
        result.simctlAvailable = simResult.available
        result.simulators = simResult.devices

        result.groups = groups.sorted { $0.totalSize > $1.totalSize }
        return result
    }

    // MARK: - Homebrew

    /// Ejecuta `brew cleanup -n` (solo previsualización) y convierte lo listado en elementos
    /// que se moverán a la Papelera en lugar de borrarse.
    func brewPreview() async -> (available: Bool, output: String?, items: [CleanableItem]) {
        guard ShellRunner.locate("brew") != nil else { return (false, nil, []) }
        do {
            let r = try await ShellRunner.run("brew", ["cleanup", "-n"], timeout: 180)
            let output = (r.stdout + (r.stderr.isEmpty ? "" : "\n" + r.stderr))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let urls = Self.parseBrewCleanup(r.stdout)
            let items = try await scanner.items(for: urls) { url, size, modified in
                guard size > 0 else { return nil }
                return CleanableItem(url: url, size: size, modified: modified, kind: .brewCleanup,
                                     group: Self.brewGroup, selectedByDefault: false)
            }
            return (true, output.isEmpty ? "Nada que limpiar según Homebrew." : output,
                    items.sorted { $0.size > $1.size })
        } catch {
            return (true, error.localizedDescription, [])
        }
    }

    /// Extrae las rutas de líneas `Would remove: /ruta (detalle)`.
    public static func parseBrewCleanup(_ text: String) -> [URL] {
        var urls: [URL] = []
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("Would remove: ") else { continue }
            var rest = line.dropFirst("Would remove: ".count)
            if let paren = rest.range(of: " (", options: .backwards) {
                rest = rest[..<paren.lowerBound]
            }
            let path = String(rest).trimmingCharacters(in: .whitespaces)
            if path.hasPrefix("/") { urls.append(URL(fileURLWithPath: path)) }
        }
        return urls
    }

    // MARK: - Docker

    func dockerUsage() async -> (output: String?, message: String?) {
        guard ShellRunner.locate("docker") != nil else {
            return (nil, "Docker no está instalado (o no se encontró el comando «docker»).")
        }
        do {
            let r = try await ShellRunner.run("docker", ["system", "df"], timeout: 30)
            if r.succeeded { return (r.stdout.trimmingCharacters(in: .whitespacesAndNewlines), nil) }
            return (nil, "Docker no respondió. ¿Está abierto Docker Desktop?\n" + r.stderr)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    // MARK: - Simuladores

    func unavailableSimulators(progress: ProgressBox) async -> (available: Bool, devices: [SimulatorDevice]) {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else { return (false, []) }
        do {
            let r = try await ShellRunner.run(executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                                              ["simctl", "list", "devices", "unavailable", "--json"], timeout: 60)
            guard r.succeeded else { return (false, []) }
            var devices = Self.parseSimctl(Data(r.stdout.utf8))
            for i in devices.indices {
                if let path = devices[i].dataPath {
                    // dataPath apunta a .../<UDID>/data; medimos la carpeta del dispositivo.
                    let deviceDir = URL(fileURLWithPath: path).deletingLastPathComponent()
                    devices[i].size = (try? scanner.allocatedSize(of: deviceDir, progress: progress)) ?? 0
                }
            }
            return (true, devices.sorted { $0.size > $1.size })
        } catch {
            return (false, [])
        }
    }

    public static func parseSimctl(_ data: Data) -> [SimulatorDevice] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let byRuntime = json["devices"] as? [String: [[String: Any]]] else { return [] }
        var result: [SimulatorDevice] = []
        for (runtime, list) in byRuntime {
            let runtimeName = runtime.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
            for d in list {
                guard let udid = d["udid"] as? String else { continue }
                result.append(SimulatorDevice(udid: udid,
                                              name: d["name"] as? String ?? udid,
                                              runtime: runtimeName,
                                              dataPath: d["dataPath"] as? String,
                                              size: 0))
            }
        }
        return result
    }

    /// `xcrun simctl delete unavailable`. Lo borra simctl (no pasa por la Papelera),
    /// por eso la UI lo confirma aparte y se registra en el log.
    public static func deleteUnavailableSimulators(devices: [SimulatorDevice],
                                                   logger: CleanupLogger = .shared) async throws -> ShellResult {
        let r = try await ShellRunner.run(executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                                          ["simctl", "delete", "unavailable"], timeout: 300)
        for d in devices {
            logger.log(action: r.succeeded ? "SIMCTL-DELETE" : "SIMCTL-ERROR",
                       path: d.dataPath ?? d.udid, size: d.size, detail: "\(d.name) (\(d.runtime))")
        }
        return r
    }

    // MARK: - node_modules

    /// Busca carpetas `node_modules` dentro de `root` (sin entrar en ellas ni en paquetes).
    /// La fecha de cada elemento es la última modificación del proyecto (excluyendo node_modules).
    public func scanNodeModules(root: URL, staleDays: Int, progress: ProgressBox) async throws -> [CleanableItem] {
        progress.setPhase("Buscando node_modules en \(Format.abbreviate(root))…")
        var found: [URL] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants],
            errorHandler: { url, error in
                progress.addIssue(path: url.path, reason: error.localizedDescription)
                return true
            })
        var count = 0
        while let url = enumerator?.nextObject() as? URL {
            count += 1
            if count & 255 == 0 { try Task.checkCancellation() }
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.isDirectory == true, v.isSymbolicLink != true else { continue }
            progress.visit(url)
            let name = url.lastPathComponent
            if name == "node_modules" {
                found.append(url)
                enumerator?.skipDescendants()
            } else if name == ".git" || name == ".Trash" || (name == "Library" && url.deletingLastPathComponent().standardizedFileURL.path == home.standardizedFileURL.path)
                        || scanner.protected.isProtected(url) {
                enumerator?.skipDescendants()
            }
        }

        progress.setPhase("Calculando tamaño de \(found.count) carpetas node_modules…")
        progress.setTotal(found.count)
        let items = try await scanner.items(for: found, progress: progress) { url, size, _ in
            let project = url.deletingLastPathComponent()
            let projectDate = Self.projectModificationDate(project)
            let days = Format.daysSince(projectDate) ?? 0
            return CleanableItem(url: url,
                                 name: project.lastPathComponent + "/node_modules",
                                 size: size,
                                 modified: projectDate,
                                 kind: .nodeModules,
                                 group: Self.nodeModulesGroup,
                                 note: "Proyecto sin cambios hace \(days) días",
                                 selectedByDefault: days >= staleDays)
        }
        return items.sorted { $0.size > $1.size }
    }

    /// Fecha más reciente entre los elementos de primer nivel del proyecto (sin node_modules).
    static func projectModificationDate(_ project: URL) -> Date? {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: project, includingPropertiesForKeys: [.contentModificationDateKey], options: [])) ?? []
        let dates = entries
            .filter { $0.lastPathComponent != "node_modules" && $0.lastPathComponent != ".DS_Store" }
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        return dates.max()
            ?? (try? project.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    }
}
