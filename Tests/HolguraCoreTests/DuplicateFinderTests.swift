import XCTest
@testable import HolguraCore

final class DuplicateFinderTests: XCTestCase {
    private var temp: TempDir!
    private var finder: DuplicateFinder!

    override func setUpWithError() throws {
        temp = try TempDir()
        finder = DuplicateFinder(scanner: FileScanner(protected: ProtectedPaths(
            homeDirectory: temp.url.appendingPathComponent("home"), applicationDirectories: [])))
    }

    override func tearDown() {
        temp.cleanUp()
    }

    private func paths(_ groups: [DuplicateGroup]) -> [[String]] {
        groups.map { $0.files.map { $0.url.lastPathComponent }.sorted() }.sorted { $0[0] < $1[0] }
    }

    func testFindsSmallIdenticalFiles() async throws {
        try temp.file("root/a.txt", data: Data("hola mundo".utf8))
        try temp.file("root/sub/a-copia.txt", data: Data("hola mundo".utf8))
        try temp.file("root/b.txt", data: Data("hola MUNDO".utf8))   // mismo tamaño, distinto contenido
        try temp.file("root/c.txt", data: Data("otra cosa".utf8))
        let groups = try await finder.find(in: temp.url.appendingPathComponent("root"))
        XCTAssertEqual(paths(groups), [["a-copia.txt", "a.txt"]])
    }

    func testSameFirst64KBButDifferentTailIsNotDuplicate() async throws {
        var base = Data(repeating: 7, count: DuplicateFinder.partialLength + 10_000)
        try temp.file("root/one.bin", data: base)
        base[base.count - 1] = 8
        try temp.file("root/two.bin", data: base)           // igual inicio, distinto final
        let groups = try await finder.find(in: temp.url.appendingPathComponent("root"))
        XCTAssertTrue(groups.isEmpty, "El SHA-256 completo debe distinguirlos")
    }

    func testLargeIdenticalFilesAndMultipleGroups() async throws {
        let big = Data((0..<300_000).map { UInt8($0 % 251) })
        try temp.file("root/x/big1.bin", data: big)
        try temp.file("root/y/big2.bin", data: big)
        try temp.file("root/z/big3.bin", data: big)
        try temp.file("root/p1.txt", data: Data("pareja".utf8))
        try temp.file("root/p2.txt", data: Data("pareja".utf8))
        let groups = try await finder.find(in: temp.url.appendingPathComponent("root"))
        XCTAssertEqual(paths(groups), [["big1.bin", "big2.bin", "big3.bin"], ["p1.txt", "p2.txt"]])
        let bigGroup = try XCTUnwrap(groups.first { $0.files.count == 3 })
        XCTAssertEqual(bigGroup.size, 300_000)
        XCTAssertGreaterThanOrEqual(bigGroup.wasted, 600_000)
        // Ordenados por espacio recuperable.
        XCTAssertEqual(groups.first?.files.count, 3)
    }

    func testMinSizeAndEmptyFilesAreIgnored() async throws {
        try temp.file("root/e1", data: Data())
        try temp.file("root/e2", data: Data())
        try temp.file("root/s1", data: Data("abc".utf8))
        try temp.file("root/s2", data: Data("abc".utf8))
        let all = try await finder.find(in: temp.url.appendingPathComponent("root"))
        XCTAssertEqual(paths(all), [["s1", "s2"]], "Los archivos vacíos no cuentan como duplicados")
        let filtered = try await finder.find(in: temp.url.appendingPathComponent("root"), minSize: 10)
        XCTAssertTrue(filtered.isEmpty)
    }

    func testSymlinksAndHardLinksAreNotDuplicates() async throws {
        let original = try temp.file("root/original.dat", data: Data(repeating: 1, count: 5000))
        try FileManager.default.createSymbolicLink(at: temp.url.appendingPathComponent("root/link.dat"),
                                                   withDestinationURL: original)
        try FileManager.default.linkItem(at: original, to: temp.url.appendingPathComponent("root/hard.dat"))
        let groups = try await finder.find(in: temp.url.appendingPathComponent("root"))
        XCTAssertTrue(groups.isEmpty)
    }

    func testHiddenFilesAndPackagesAreSkipped() async throws {
        try temp.file("root/.DS_Store", data: Data("x".utf8))
        try temp.file("root/sub/.DS_Store", data: Data("x".utf8))
        try temp.file("root/A.app/Contents/Info.plist", data: Data("plist".utf8))
        try temp.file("root/B.app/Contents/Info.plist", data: Data("plist".utf8))
        let groups = try await finder.find(in: temp.url.appendingPathComponent("root"))
        XCTAssertTrue(groups.isEmpty)
    }

    func testHashMatchesKnownSHA256() throws {
        let f = try temp.file("abc.txt", data: Data("abc".utf8))
        XCTAssertEqual(try DuplicateFinder.hash(of: f, limit: nil),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(try DuplicateFinder.hash(of: f, limit: 1),
                       try DuplicateFinder.hash(of: try temp.file("a.txt", data: Data("a".utf8)), limit: nil))
    }

    func testKeepSuggestions() {
        let now = Date()
        let older = DuplicateFile(url: URL(fileURLWithPath: "/tmp/a/b/c/deep.txt"), size: 1, allocatedSize: 4096,
                                  created: now.addingTimeInterval(-10_000), modified: nil)
        let shorter = DuplicateFile(url: URL(fileURLWithPath: "/tmp/short.txt"), size: 1, allocatedSize: 4096,
                                    created: now, modified: nil)
        let group = DuplicateGroup(hash: "h", size: 1, files: [shorter, older])
        XCTAssertEqual(group.suggestedKeep(.oldest)?.url, older.url)
        XCTAssertEqual(group.suggestedKeep(.shortestPath)?.url, shorter.url)
    }
}

final class ParsingTests: XCTestCase {
    func testBrewCleanupParsing() {
        let output = """
        Would remove: /Users/x/Library/Caches/Homebrew/downloads/abc--wget-1.0.bottle.tar.gz (1.2MB)
        Would remove: /opt/homebrew/Cellar/node/20.1.0 (2,345 files, 60.1MB)
        Would remove: /Users/x/Library/Caches/Homebrew/a file (with parens) (3KB)
        ==> This operation would free approximately 61.3MB of disk space.
        """
        let urls = DeveloperScanner.parseBrewCleanup(output).map(\.path)
        XCTAssertEqual(urls, [
            "/Users/x/Library/Caches/Homebrew/downloads/abc--wget-1.0.bottle.tar.gz",
            "/opt/homebrew/Cellar/node/20.1.0",
            "/Users/x/Library/Caches/Homebrew/a file (with parens)",
        ])
    }

    func testSimctlParsing() {
        let json = """
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-16-0":[{"udid":"ABC","name":"iPhone 14","isAvailable":false,"dataPath":"/tmp/ABC/data"}]}}
        """
        let devices = DeveloperScanner.parseSimctl(Data(json.utf8))
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.runtime, "iOS-16-0")
        XCTAssertEqual(devices.first?.name, "iPhone 14")
    }

    func testLeftoverMatching() {
        let bid = "com.example.editor"
        XCTAssertTrue(AppInventory.matchesBundleID(name: "com.example.editor", bundleID: bid, location: "Library/Caches"))
        XCTAssertTrue(AppInventory.matchesBundleID(name: "com.example.editor.plist", bundleID: bid, location: "Library/Preferences"))
        XCTAssertTrue(AppInventory.matchesBundleID(name: "com.example.editor.savedstate", bundleID: bid, location: "Library/Saved Application State"))
        XCTAssertTrue(AppInventory.matchesBundleID(name: "abcde12345.com.example.editor", bundleID: bid, location: "Library/Group Containers"))
        XCTAssertFalse(AppInventory.matchesBundleID(name: "com.example.editorpro", bundleID: bid, location: "Library/Caches"))
        XCTAssertFalse(AppInventory.matchesBundleID(name: "com.example", bundleID: bid, location: "Library/Caches"))
    }

    func testTreemapCoversAreaWithoutOverlap() {
        let rect = CGRect(x: 0, y: 0, width: 600, height: 400)
        let values: [Double] = [500, 300, 200, 100, 50, 25, 0]
        let rects = TreemapLayout.squarify(values: values, in: rect)
        XCTAssertEqual(rects.count, values.count)
        let total = values.reduce(0, +)
        for (v, r) in zip(values, rects) {
            XCTAssertEqual(Double(r.width * r.height), v / total * 240_000, accuracy: 0.5)
            XCTAssertTrue(rect.insetBy(dx: -0.01, dy: -0.01).contains(r) || r == .zero)
        }
        for i in rects.indices { for j in rects.indices where i < j {
            let overlap = rects[i].intersection(rects[j])
            XCTAssertTrue(overlap.isNull || overlap.width * overlap.height < 0.01)
        } }
    }
}
