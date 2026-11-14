import Foundation

/// Shared container of the app and its widget extension.
///
/// The App Group identifier is platform specific and is read from the `FSAppGroupIdentifier`
/// key of the running bundle's Info.plist (set by project.yml):
///   • macOS: `<TEAM_ID>.com.k33ssa.simplefaceit` (team-prefixed, needs no provisioning profile)
///   • iOS:   `group.com.k33ssa.simplefaceit`
public enum AppGroup {
    public static var identifier: String? {
        Bundle.main.object(forInfoDictionaryKey: "FSAppGroupIdentifier") as? String
    }

    /// Overridable for tests and the snapshot tool.
    nonisolated(unsafe) public static var overrideContainer: URL?

    public static var containerURL: URL {
        if let o = overrideContainer { return o }
        if let id = identifier, let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) {
            return url
        }
        // Fallback (no entitlement, e.g. `swift run`): per-user Application Support.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SimpleFaceitWidget", isDirectory: true)
    }

    public static var isShared: Bool {
        guard overrideContainer == nil, let id = identifier else { return false }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) != nil
    }

    public static var dataDirectory: URL {
        let dir = containerURL.appendingPathComponent("FaceitData", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var defaults: UserDefaults {
        if overrideContainer == nil, let id = identifier, let d = UserDefaults(suiteName: id) { return d }
        return .standard
    }
}

/// Cross-process mutual exclusion (app + several widget processes) via `flock(2)` on a file
/// inside the shared container. Used so that only one process refreshes at a time.
public final class FileLock: @unchecked Sendable {
    private let url: URL
    private var fd: Int32 = -1

    public init(url: URL) { self.url = url }

    /// Tries to acquire the lock for up to `timeout` seconds without blocking a thread.
    public func acquire(timeout: TimeInterval) async -> Bool {
        fd = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true }
            if Date() >= deadline { close(fd); fd = -1; return false }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}
