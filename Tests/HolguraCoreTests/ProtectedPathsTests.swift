import XCTest
@testable import HolguraCore

final class ProtectedPathsTests: XCTestCase {
    private var temp: TempDir!
    private var home: URL!
    private var apps: URL!
    private var paths: ProtectedPaths!

    override func setUpWithError() throws {
        temp = try TempDir()
        home = try temp.dir("home")
        apps = try temp.dir("Applications")
        paths = ProtectedPaths(homeDirectory: home, applicationDirectories: [apps])
    }

    override func tearDown() {
        temp.cleanUp()
    }

    func testSystemPrefixesAreProtected() {
        for path in ["/System", "/System/Library/Fonts", "/usr", "/usr/local/bin/brew", "/bin/ls", "/sbin",
                     "/private/var/db/receipts", "/var/db/x", "/Library/Apple/System", "/System/Applications/Notes.app"] {
            XCTAssertTrue(paths.isProtected(URL(fileURLWithPath: path)), path)
        }
    }

    func testPrefixMatchRequiresWholeComponent() {
        XCTAssertFalse(paths.isProtected(URL(fileURLWithPath: "/usrdata/file")))
        XCTAssertFalse(paths.isProtected(URL(fileURLWithPath: "/binaries")))
        XCTAssertFalse(paths.isProtected(home.appendingPathComponent("Library/MailCache")))
    }

    func testCaseInsensitive() {
        XCTAssertTrue(paths.isProtected(URL(fileURLWithPath: "/SYSTEM/library")))
        XCTAssertTrue(paths.isProtected(home.appendingPathComponent("library/KEYCHAINS/login.keychain-db")))
    }

    func testDotDotCannotEscapeIntoProtected() {
        let sneaky = URL(fileURLWithPath: "/Users/../System/Library")
        XCTAssertTrue(paths.isProtected(sneaky))
    }

    func testHomeSensitiveFolders() {
        for rel in ["Library/Keychains", "Library/Keychains/login.keychain-db",
                    "Library/Mobile Documents/com~apple~CloudDocs/doc.txt",
                    "Library/Mail/V10", "Library/Messages/chat.db"] {
            XCTAssertTrue(paths.isProtected(home.appendingPathComponent(rel)), rel)
        }
    }

    func testRegularUserPathsAreNotProtected() {
        for rel in ["Library/Caches/com.example.app", "Library/Logs/app.log", "Downloads/file.zip",
                    "Projects/web/node_modules"] {
            XCTAssertFalse(paths.isProtected(home.appendingPathComponent(rel)), rel)
        }
    }

    func testPhotosLibraryAnywhere() {
        XCTAssertTrue(paths.isProtected(home.appendingPathComponent("Pictures/Photos Library.photoslibrary")))
        XCTAssertTrue(paths.isProtected(home.appendingPathComponent("Pictures/Old.PhotosLibrary/database/x.db")))
        XCTAssertTrue(paths.isProtected(URL(fileURLWithPath: "/Volumes/Ext/Archive.photoslibrary")))
    }

    func testAppleAppsInApplicationsAreProtected() throws {
        try makeApp(named: "Safari", bundleID: "com.apple.Safari")
        try makeApp(named: "Thing", bundleID: "com.example.thing")
        try makeApp(named: "Utilities/Tool", bundleID: "com.apple.tool")

        XCTAssertTrue(paths.isProtected(apps.appendingPathComponent("Safari.app")))
        XCTAssertTrue(paths.isProtected(apps.appendingPathComponent("Safari.app/Contents/MacOS/Safari")))
        XCTAssertTrue(paths.isProtected(apps.appendingPathComponent("Utilities/Tool.app")))
        XCTAssertFalse(paths.isProtected(apps.appendingPathComponent("Thing.app")))
    }

    func testCriticalFoldersCannotBeTrashedButChildrenCan() {
        XCTAssertNotNil(paths.trashRefusalReason(for: home))
        XCTAssertNotNil(paths.trashRefusalReason(for: home.appendingPathComponent("Library/Caches")))
        XCTAssertNotNil(paths.trashRefusalReason(for: home.appendingPathComponent("Downloads")))
        XCTAssertNotNil(paths.trashRefusalReason(for: URL(fileURLWithPath: "/")))
        XCTAssertNotNil(paths.trashRefusalReason(for: apps))
        XCTAssertNil(paths.trashRefusalReason(for: home.appendingPathComponent("Library/Caches/com.example.app")))
        XCTAssertNil(paths.trashRefusalReason(for: home.appendingPathComponent("Downloads/old.dmg")))
    }

    func testSymlinkedAncestorIsResolved() throws {
        // Un enlace dentro de la carpeta temporal que apunta a /System.
        let link = temp.url.appendingPathComponent("link-to-system")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/System"))
        XCTAssertTrue(paths.isProtected(link.appendingPathComponent("Library")))
    }

    func testTrashServiceRefusesProtectedPathsWithoutTouchingDisk() async throws {
        let logDir = try temp.dir("log")
        let service = TrashService(protected: paths, logger: CleanupLogger(directory: logDir))
        let items = [
            CleanableItem(url: URL(fileURLWithPath: "/System/Library"), size: 1, kind: .other),
            CleanableItem(url: home.appendingPathComponent("Library/Keychains"), size: 1, kind: .other),
            CleanableItem(url: home, size: 1, kind: .other),
        ]
        let result = await service.moveToTrash(items)
        XCTAssertTrue(result.trashed.isEmpty)
        XCTAssertEqual(result.failures.count, 3)
        let log = try String(contentsOf: logDir.appendingPathComponent("cleanup.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("RECHAZADO"))
        XCTAssertTrue(log.contains("/System/Library"))
    }

    func testNormalizedRemovesNestedItems() {
        let a = CleanableItem(url: URL(fileURLWithPath: "/tmp/x/a"), size: 10, kind: .other)
        let b = CleanableItem(url: URL(fileURLWithPath: "/tmp/x/a/b"), size: 5, kind: .other)
        let c = CleanableItem(url: URL(fileURLWithPath: "/tmp/x/ab"), size: 5, kind: .other)
        let result = TrashService.normalized([b, a, c, a])
        XCTAssertEqual(result.map(\.url.path), ["/tmp/x/a", "/tmp/x/ab"])
    }

    private func makeApp(named name: String, bundleID: String) throws {
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": name]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try temp.file("Applications/\(name).app/Contents/Info.plist", data: data)
    }
}
