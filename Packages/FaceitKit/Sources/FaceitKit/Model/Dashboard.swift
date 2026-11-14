import Foundation

/// Lifetime figures from `GET /players/{id}/stats/cs2` (`lifetime` dictionary).
public struct LifetimeSummary: Codable, Hashable, Sendable {
    public let matches: Int?
    public let wins: Int?
    public let winRate: Double?
    public let kd: Double?
    public let headshotPercent: Double?
    public let adr: Double?
    public let longestWinStreak: Int?
    public let currentWinStreak: Int?

    public init(lifetime l: [String: JSONValue]) {
        matches = l.int("Matches")
        wins = l.int("Wins")
        winRate = l.double("Win Rate %")
        kd = l.double("Average K/D Ratio")
        headshotPercent = l.double("Average Headshots %")
        adr = l.double("ADR")
        longestWinStreak = l.int("Longest Win Streak")
        currentWinStreak = l.int("Current Win Streak")
    }
}

/// Everything a widget or the app's overview needs, computed in one refresh and cached in the
/// App Group container. Widgets only ever *read* this (or trigger the same refresh).
public struct Dashboard: Codable, Hashable, Sendable {
    public var profile: PlayerProfile
    /// Up to 100 latest games, newest first.
    public var games: [GameRecord]
    /// Summary of the latest `StatsCalculator.windowSize` games.
    public var summary: WindowSummary
    public var elo: EloAnalysis
    public var lifetime: LifetimeSummary?
    /// When the data was last fetched successfully from FACEIT.
    public var fetchedAt: Date
    /// Last refresh attempt (successful or not) and its error, if it failed.
    public var lastAttemptAt: Date
    public var lastError: String?
    /// Avatar URL the cached avatar image was downloaded from.
    public var avatarSource: URL?

    public init(profile: PlayerProfile, games: [GameRecord], summary: WindowSummary, elo: EloAnalysis, lifetime: LifetimeSummary?,
                fetchedAt: Date, lastAttemptAt: Date, lastError: String?, avatarSource: URL?) {
        self.profile = profile; self.games = games; self.summary = summary; self.elo = elo; self.lifetime = lifetime
        self.fetchedAt = fetchedAt; self.lastAttemptAt = lastAttemptAt; self.lastError = lastError; self.avatarSource = avatarSource
    }

    /// The window games, newest first.
    public var window: [GameRecord] { Array(games.prefix(StatsCalculator.windowSize)) }

    /// The window games in display order: **oldest on the left, newest on the right**.
    public var strip: [GameRecord] { Array(window.reversed()) }

    public func eloPoint(for game: GameRecord) -> EloGamePoint? { elo.points.first { $0.gameId == game.id } }

    /// Builds a dashboard from raw data (pure; used by the repository and by tests).
    public static func build(profile: PlayerProfile, games: [GameRecord], snapshots: [EloSnapshot], matchInfos: [String: MatchInfo],
                             lifetime: LifetimeSummary?, fetchedAt: Date, avatarSource: URL?) -> Dashboard {
        let window = Array(games.prefix(StatsCalculator.windowSize))
        return Dashboard(
            profile: profile,
            games: games,
            summary: StatsCalculator.summary(of: window),
            elo: EloAnalyzer.analyze(games: games, currentElo: profile.elo, snapshots: snapshots, matchInfos: matchInfos),
            lifetime: lifetime,
            fetchedAt: fetchedAt,
            lastAttemptAt: fetchedAt,
            lastError: nil,
            avatarSource: avatarSource
        )
    }
}
