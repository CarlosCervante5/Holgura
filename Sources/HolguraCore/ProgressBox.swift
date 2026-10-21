import Foundation

/// Estado de progreso compartido entre el escaneo (en segundo plano) y la UI (que lo consulta periódicamente).
public final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var phase = ""
    private var currentURL: URL?
    private var visited = 0
    private var completed = 0
    private var total = 0
    private var issueList: [ScanIssue] = []

    public init() {}

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        phase = ""; currentURL = nil; visited = 0; completed = 0; total = 0; issueList = []
    }

    public func setPhase(_ text: String) {
        lock.lock(); phase = text; lock.unlock()
    }

    public func visit(_ url: URL) {
        lock.lock(); visited += 1; currentURL = url; lock.unlock()
    }

    public func setTotal(_ n: Int) {
        lock.lock(); total = n; completed = 0; lock.unlock()
    }

    public func advance(_ n: Int = 1) {
        lock.lock(); completed += n; lock.unlock()
    }

    public func addIssue(path: String, reason: String) {
        lock.lock(); issueList.append(ScanIssue(path: path, reason: reason)); lock.unlock()
    }

    public var issues: [ScanIssue] {
        lock.lock(); defer { lock.unlock() }
        var seen = Set<String>()
        return issueList.filter { seen.insert($0.path).inserted }
    }

    public func snapshot() -> ProgressSnapshot {
        lock.lock(); defer { lock.unlock() }
        return ProgressSnapshot(phase: phase,
                                currentPath: currentURL?.path ?? "",
                                visited: visited,
                                completed: completed,
                                total: total,
                                issueCount: issueList.count)
    }
}

public struct ProgressSnapshot: Sendable, Equatable {
    public var phase: String
    public var currentPath: String
    public var visited: Int
    public var completed: Int
    public var total: Int
    public var issueCount: Int

    public static let empty = ProgressSnapshot(phase: "", currentPath: "", visited: 0, completed: 0, total: 0, issueCount: 0)

    /// Fracción completada, o `nil` si el total no se conoce.
    public var fraction: Double? {
        total > 0 ? min(1, Double(completed) / Double(total)) : nil
    }
}
