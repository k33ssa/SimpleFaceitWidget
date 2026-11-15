import WidgetKit
import SwiftUI
import AppIntents
import FaceitKit
import FaceitUI

// MARK: - Configuration (style picker in "Edit widget")
#if !CLT_BUILD

enum StyleOption: String, AppEnum {
    case arena, pulse, rank

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Стиль"
    static var caseDisplayRepresentations: [StyleOption: DisplayRepresentation] = [
        .arena: DisplayRepresentation(title: "Arena", subtitle: "Арт карты последнего матча"),
        .pulse: DisplayRepresentation(title: "Pulse", subtitle: "Светящаяся кривая ELO"),
        .rank: DisplayRepresentation(title: "Rank", subtitle: "Кольцо уровня и оранжевый срез"),
    ]

    var style: WidgetStyle { WidgetStyle(rawValue: rawValue) ?? .arena }
}

struct StyleIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Стиль виджета"
    static var description = IntentDescription("Выбери оформление виджета FACEIT.")

    @Parameter(title: "Стиль", default: .arena)
    var style: StyleOption

    // On a free Apple account the widget can't share the app's App Group, so it can't see the linked profile.
    // In that case the user types the nickname here (ignored when the shared container is available, e.g. macOS).
    @Parameter(title: "Ник FACEIT (только iPhone без App Group)")
    var nickname: String?

    init() {}
    init(style: StyleOption) { self.style = style }
}

/// Interactive refresh button (macOS 14 / iOS 17). Runs in the widget process, goes through the same
/// deduplicated repository (a tap within 20 s of the last fetch reuses the cache).
struct RefreshStatsIntent: AppIntent {
    static var title: LocalizedStringResource = "Обновить статистику FACEIT"
    static var isDiscoverable = false

    func perform() async throws -> some IntentResult {
        _ = try? await StatsRepository.shared.refresh(force: true)
        return .result()
    }
}

#endif

// MARK: - Timeline

struct FaceitEntry: TimelineEntry {
    let date: Date
    let data: WidgetData
    let style: WidgetStyle
}

/// Shared timeline logic for both configurations.
enum TimelineLogic {
    static func entry(style: WidgetStyle) -> FaceitEntry {
        // Real cached data if there is any; never invented numbers.
        FaceitEntry(date: Date(), data: WidgetData.load(), style: style)
    }

    static func timeline(style: WidgetStyle, nickname: String? = nil) async -> Timeline<FaceitEntry> {
        let repo = StatsRepository.shared
        // Without a shared container the widget is on its own: resolve the configured nickname to a player id here.
        if !AppGroup.isShared, let nick = nickname?.trimmingCharacters(in: .whitespacesAndNewlines), !nick.isEmpty {
            await ensureLinked(nick: nick, repo: repo)
        }
        do {
            // Fresh cache (another widget or the app refreshed recently) → no network at all.
            try await repo.refresh(force: false)
        } catch RefreshError.noAccount {
        } catch {
            // Error is recorded in the cache/log; the widget keeps showing the last good data with a ⚠︎.
        }
        let data = WidgetData.load()
        let interval = TimeInterval(AppSettings().refreshMinutes * 60)
        // Ask to be reloaded when the cache becomes stale. The system treats this as a hint.
        let base = data.dashboard?.fetchedAt ?? Date()
        let next = max(base.addingTimeInterval(interval), Date().addingTimeInterval(5 * 60))
        return Timeline(entries: [FaceitEntry(date: Date(), data: data, style: style)], policy: .after(next))
    }

    /// Resolves nickname → player id once (cached in the widget's own defaults) and links it, so the shared
    /// refresh path works unchanged. Only used on iOS free-account builds (no App Group).
    static func ensureLinked(nick: String, repo: StatsRepository) async {
        let settings = AppSettings()
        let key = "widgetNick"
        if settings.playerId != nil, UserDefaults.standard.string(forKey: key) == nick.lowercased() { return }
        let found = (try? await repo.findPlayers(query: nick)) ?? []
        guard let p = found.first(where: { $0.nickname.lowercased() == nick.lowercased() }) ?? found.first else { return }
        repo.link(player: p)
        UserDefaults.standard.set(nick.lowercased(), forKey: key)
    }
}

#if !CLT_BUILD
struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> FaceitEntry { TimelineLogic.entry(style: .arena) }
    func snapshot(for configuration: StyleIntent, in context: Context) async -> FaceitEntry {
        TimelineLogic.entry(style: configuration.style.style)
    }
    func timeline(for configuration: StyleIntent, in context: Context) async -> Timeline<FaceitEntry> {
        await TimelineLogic.timeline(style: configuration.style.style, nickname: configuration.nickname)
    }
}
#else
struct StaticProvider: TimelineProvider {
    let style: WidgetStyle
    func placeholder(in context: Context) -> FaceitEntry { TimelineLogic.entry(style: style) }
    func getSnapshot(in context: Context, completion: @escaping (FaceitEntry) -> Void) { completion(TimelineLogic.entry(style: style)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<FaceitEntry>) -> Void) {
        Task { completion(await TimelineLogic.timeline(style: style)) }
    }
}
#endif

// MARK: - View

struct FaceitWidgetEntryView: View {
    let entry: FaceitEntry
    @Environment(\.widgetFamily) private var family

    var size: WidgetSize {
        switch family {
        case .systemSmall: return .small
        case .systemLarge, .systemExtraLarge: return .large
        default: return .medium
        }
    }

    var body: some View {
        FaceitWidgetContent(data: entry.data, size: size, style: entry.style,
                            gameURL: size == .small ? nil : { DeepLinks.game($0) }) {
            #if !CLT_BUILD
            if size != .small, case .ok = entry.data.state {
                Button(intent: RefreshStatsIntent()) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(entry.style == .rank ? Theme.onOrange.opacity(0.75) : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Обновить")
            }
            #endif
        }
        .containerBackground(for: .widget) {
            FaceitWidgetBackground(data: entry.data, size: size, style: entry.style)
        }
        .widgetURL(DeepLinks.dashboard)
    }
}

enum DeepLinks {
    static var dashboard: URL { URL(string: "faceitstats://dashboard")! }
    static func game(_ g: GameRecord) -> URL? {
        var c = URLComponents()
        c.scheme = "faceitstats"; c.host = "game"; c.queryItems = [URLQueryItem(name: "id", value: g.id)]
        return c.url
    }
}

// MARK: - Widget

#if !CLT_BUILD
struct FaceitStatsWidget: Widget {
    let kind = "FaceitStatsWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: StyleIntent.self, provider: Provider()) { entry in
            FaceitWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("FACEIT")
        .description("ELO, изменение за 20 игр, винрейт и последние матчи.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct FaceitWidgetBundle: WidgetBundle {
    var body: some Widget { FaceitStatsWidget() }
}
#else
/// One widget per style (picked in the widget gallery).
func styledConfiguration(_ style: WidgetStyle) -> some WidgetConfiguration {
        StaticConfiguration(kind: "FaceitStatsWidget." + style.rawValue, provider: StaticProvider(style: style)) { entry in
            FaceitWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("FACEIT · " + style.title)
        .description(style.subtitle + ". ELO, изменение за 20 игр, винрейт и последние матчи.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
}

struct ArenaWidget: Widget { var body: some WidgetConfiguration { styledConfiguration(.arena) } }
struct PulseWidget: Widget { var body: some WidgetConfiguration { styledConfiguration(.pulse) } }
struct RankWidget: Widget { var body: some WidgetConfiguration { styledConfiguration(.rank) } }

@main
struct FaceitWidgetBundle: WidgetBundle {
    var body: some Widget {
        ArenaWidget()
        PulseWidget()
        RankWidget()
    }
}
#endif
