import SwiftUI
import FaceitKit
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Widget visual styles (all three are selectable in the widget's "Edit widget" configuration).
public enum WidgetStyle: String, CaseIterable, Codable, Sendable {
    case arena, pulse, rank

    public var title: String {
        switch self {
        case .arena: return "Arena"
        case .pulse: return "Pulse"
        case .rank: return "Rank"
        }
    }

    public var subtitle: String {
        switch self {
        case .arena: return "Арт карты последнего матча"
        case .pulse: return "Светящаяся кривая ELO"
        case .rank: return "Кольцо уровня и оранжевый срез"
        }
    }
}

public enum WidgetSize: Sendable { case small, medium, large }

/// Everything a widget layout needs, resolved from the shared cache (no network).
public struct WidgetData {
    public enum State { case ok, noAccount, empty(String?) }

    public let state: State
    public let dashboard: Dashboard?
    public let mapArt: Image?
    public let avatar: Image?
    public let now: Date
    public let refreshMinutes: Int

    public init(state: State, dashboard: Dashboard?, mapArt: Image?, avatar: Image?, now: Date, refreshMinutes: Int) {
        self.state = state; self.dashboard = dashboard; self.mapArt = mapArt; self.avatar = avatar
        self.now = now; self.refreshMinutes = refreshMinutes
    }

    /// Reads the cached dashboard and images from the App Group.
    public static func load(store: LocalStore = .shared, now: Date = Date()) -> WidgetData {
        let settings = AppSettings()
        guard settings.playerId != nil else {
            return WidgetData(state: .noAccount, dashboard: nil, mapArt: nil, avatar: nil, now: now, refreshMinutes: settings.refreshMinutes)
        }
        guard let d = store.loadDashboard(), d.profile.playerId == settings.playerId else {
            return WidgetData(state: .empty(nil), dashboard: nil, mapArt: nil, avatar: nil, now: now, refreshMinutes: settings.refreshMinutes)
        }
        let map = d.games.first.flatMap { store.loadMapArt($0.map) }.flatMap { Image(data: $0) }
        let avatar = store.loadAvatar().flatMap { Image(data: $0) }
        return WidgetData(state: .ok, dashboard: d, mapArt: map, avatar: avatar, now: now, refreshMinutes: settings.refreshMinutes)
    }

    public static func error(_ message: String?, refreshMinutes: Int = AppSettings.defaultRefresh) -> WidgetData {
        WidgetData(state: .empty(message), dashboard: nil, mapArt: nil, avatar: nil, now: Date(), refreshMinutes: refreshMinutes)
    }

    /// Data is older than two refresh intervals (the system postponed refreshes or FACEIT failed).
    public var isStale: Bool {
        guard let d = dashboard else { return false }
        return now.timeIntervalSince(d.fetchedAt) > Double(refreshMinutes * 60 * 2)
    }
}

public extension Image {
    /// Decodes and downsamples image bytes (widgets have a tight memory budget).
    init?(data: Data, maxPixel: CGFloat = 900) {
        #if canImport(AppKit)
        guard let img = NSImage(data: data) else { return nil }
        let size = img.size
        let scale = min(1, maxPixel / max(size.width, size.height, 1))
        if scale < 1 {
            let target = NSSize(width: size.width * scale, height: size.height * scale)
            let resized = NSImage(size: target)
            resized.lockFocus()
            img.draw(in: NSRect(origin: .zero, size: target))
            resized.unlockFocus()
            self.init(nsImage: resized)
        } else {
            self.init(nsImage: img)
        }
        #else
        guard let img = UIImage(data: data) else { return nil }
        let size = img.size
        let scale = min(1, maxPixel / max(size.width, size.height, 1))
        if scale < 1 {
            let target = CGSize(width: size.width * scale, height: size.height * scale)
            let r = UIGraphicsImageRenderer(size: target)
            self.init(uiImage: r.image { _ in img.draw(in: CGRect(origin: .zero, size: target)) })
        } else {
            self.init(uiImage: img)
        }
        #endif
    }
}
