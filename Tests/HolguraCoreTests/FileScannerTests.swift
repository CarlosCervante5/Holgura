import XCTest
@testable import HolguraCore

final class FileScannerTests: XCTestCase {
    private var temp: TempDir!
    private var scanner: FileScanner!

    override func setUpWithError() throws {
        temp = try TempDir()
        scanner = FileScanner(protected: ProtectedPaths(homeDirectory: temp.url.appendingPathComponent("home"),
                                                         applicationDirectories: []))
    }

    override func tearDown() {
        temp.cleanUp()
    }

    private func allocated(_ url: URL) throws -> Int64 {
        let v = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
    }

    func testSingleFileUsesAllocatedSize() throws {
        let f = try temp.file("one.bin", bytes: 10)
        let size = try scanner.allocatedSize(of: f)
        XCTAssertEqual(size, try allocated(f))
        // Un archivo de 10 bytes ocupa al menos un bloque en disco.
        XCTAssertGreaterThanOrEqual(size, 10)
    }

    func testDirectoryIsSumOfFiles() throws {
        let files = [
            try temp.file("d/a.bin", bytes: 100_000),
            try temp.file("d/sub/b.bin", bytes: 250_000),
            try temp.file("d/sub/deeper/c.bin", bytes: 1),
            try temp.file("d/.hidden", bytes: 5_000),
        ]
        let expected = try files.reduce(Int64(0)) { $0 + (try allocated($1)) }
        let size = try scanner.allocatedSize(of: temp.url.appendingPathComponent("d"))
        XCTAssertEqual(size, expected)
        XCTAssertGreaterThanOrEqual(size, 355_001)
    }

    func testSymlinksAreNotFollowed() throws {
        let big = try temp.file("outside/big.bin", bytes: 2_000_000)
        let d = try temp.dir("withlink")
        try temp.file("withlink/small.bin", bytes: 10)
        try FileManager.default.createSymbolicLink(at: d.appendingPathComponent("link"),
                                                   withDestinationURL: big.deletingLastPathComponent())
        let size = try scanner.allocatedSize(of: d)
        XCTAssertLessThan(size, 1_000_000, "El contenido apuntado por el symlink no debe contarse")
    }

    func testPackagesAreCountedAsWhole() throws {
        try temp.file("p/Thing.app/Contents/MacOS/thing", bytes: 300_000)
        let size = try scanner.allocatedSize(of: temp.url.appendingPathComponent("p"))
        XCTAssertGreaterThanOrEqual(size, 300_000)
    }

    func testProtectedSubfolderIsSkipped() throws {
        let home = temp.url.appendingPathComponent("home")
        try temp.file("home/Library/Caches/ok.bin", bytes: 10_000)
        try temp.file("home/Library/Keychains/secret.bin", bytes: 3_000_000)
        let size = try scanner.allocatedSize(of: home.appendingPathComponent("Library"))
        XCTAssertLessThan(size, 1_000_000)
        XCTAssertGreaterThanOrEqual(size, 10_000)
    }

    func testParallelItemsMatchSequentialSizes() async throws {
        var urls: [URL] = []
        for i in 0..<12 {
            try temp.file("many/item\(i)/f.bin", bytes: 4096 * (i + 1))
            urls.append(temp.url.appendingPathComponent("many/item\(i)"))
        }
        let progress = ProgressBox()
        let items = try await scanner.items(for: urls, progress: progress) { url, size, date in
            CleanableItem(url: url, size: size, modified: date, kind: .other)
        }
        XCTAssertEqual(items.count, 12)
        for item in items {
            XCTAssertEqual(item.size, try scanner.allocatedSize(of: item.url))
        }
        XCTAssertEqual(progress.snapshot().completed, 12)
    }

    func testUnreadableFolderIsReportedNotFatal() throws {
        let locked = try temp.dir("mixed/locked")
        try temp.file("mixed/locked/x.bin", bytes: 10)
        try temp.file("mixed/open.bin", bytes: 50_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let progress = ProgressBox()
        let size = try scanner.allocatedSize(of: temp.url.appendingPathComponent("mixed"), progress: progress)
        XCTAssertGreaterThanOrEqual(size, 50_000)
        XCTAssertTrue(progress.issues.contains { $0.path.hasSuffix("locked") })
    }

    func testCancellationStopsScan() async throws {
        for i in 0..<3000 { try temp.file("lots/f\(i)", bytes: 1) }
        let root = temp.url.appendingPathComponent("lots")
        let task = Task.detached { [scanner] in
            try scanner!.allocatedSize(of: root)
        }
        task.cancel()
        do {
            _ = try await task.value
            // Si terminó antes de cancelarse también es válido; lo importante es que no se cuelgue.
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
