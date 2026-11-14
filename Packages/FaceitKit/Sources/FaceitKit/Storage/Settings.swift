import Foundation

/// User settings shared through the App Group `UserDefaults` suite.
public struct AppSettings: Sendable {
    private var d: UserDefaults { AppGroup.defaults }
    public init() {}

    /// Allowed refresh intervals (minutes). WidgetKit treats the timeline date as a *hint*:
    /// the system may refresh later than asked, never in real time.
    public static let refreshOptions = [15, 30, 60, 120, 240]
    public static let defaultRefresh = 30

    public var playerId: String? {
        get { d.string(forKey: "playerId") }
        nonmutating set { d.set(newValue, forKey: "playerId") }
    }

    public var nickname: String? {
        get { d.string(forKey: "nickname") }
        nonmutating set { d.set(newValue, forKey: "nickname") }
    }

    public var refreshMinutes: Int {
        get {
            let v = d.integer(forKey: "refreshMinutes")
            return AppSettings.refreshOptions.contains(v) ? v : AppSettings.defaultRefresh
        }
        nonmutating set { d.set(newValue, forKey: "refreshMinutes") }
    }

    public var refreshInterval: TimeInterval { TimeInterval(refreshMinutes * 60) }
}
