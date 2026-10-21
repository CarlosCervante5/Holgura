import Foundation
import XCTest

/// Carpeta temporal aislada para cada prueba. Nunca se usan rutas reales del usuario.
final class TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HolguraTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    func file(_ relative: String, bytes: Int, fill: UInt8 = 0x41) throws -> URL {
        try file(relative, data: Data(repeating: fill, count: bytes))
    }

    @discardableResult
    func file(_ relative: String, data: Data) throws -> URL {
        let target = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
        return target
    }

    @discardableResult
    func dir(_ relative: String) throws -> URL {
        let target = url.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    /// Limpieza de la carpeta temporal de la propia prueba (no es código de la app).
    func cleanUp() {
        try? FileManager.default.removeItem(at: url)
    }
}
