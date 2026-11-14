import Foundation

/// Aggregated statistics over a window of games (by default the latest 20 maps).
/// Every formula is documented in docs/METRICS.md. Missing inputs never become zeros:
/// a metric whose inputs are absent in all games is `nil` ("нет данных").
public struct WindowSummary: Codable, Hashable, Sendable {
    public let games: Int
    public let wins: Int
    public let losses: Int
    /// wins / games × 100.
    public let winRate: Double?
    /// Σ kills / Σ deaths over the window (ratio of sums, not a mean of ratios).
    public let kd: Double?
    /// Σ headshot kills / Σ kills × 100; falls back to the mean of per-game "Headshots %".
    public let headshotPercent: Double?
    public let avgKills: Double?
    public let avgDeaths: Double?
    public let avgAssists: Double?
    /// Σ damage / Σ rounds over games that have both; falls back to the mean of per-game ADR.
    public let adr: Double?
    /// Number of games in the window that carried ADR data.
    public let adrGames: Int
    /// HLTV Rating 1.0 computed on the window totals (see `Rating`).
    public let rating: Double?
    public let ratingGames: Int
    /// Σ kills / Σ rounds.
    public let kpr: Double?

    public static let empty = WindowSummary(games: 0, wins: 0, losses: 0, winRate: nil, kd: nil, headshotPercent: nil, avgKills: nil,
                                            avgDeaths: nil, avgAssists: nil, adr: nil, adrGames: 0, rating: nil, ratingGames: 0, kpr: nil)
}

public enum StatsCalculator {
    public static let windowSize = 20

    public static func summary(of games: [GameRecord]) -> WindowSummary {
        guard !games.isEmpty else { return .empty }
        let n = games.count
        let wins = games.filter(\.isWin).count
        let kills = games.reduce(0) { $0 + $1.kills }
        let deaths = games.reduce(0) { $0 + $1.deaths }
        let assists = games.reduce(0) { $0 + $1.assists }

        // HS%: prefer exact counts.
        let hsGames = games.filter { $0.headshots != nil }
        let hsKills = hsGames.reduce(0) { $0 + $1.kills }
        let headshotPercent: Double?
        if !hsGames.isEmpty, hsKills > 0 {
            headshotPercent = Double(hsGames.reduce(0) { $0 + ($1.headshots ?? 0) }) / Double(hsKills) * 100
        } else {
            headshotPercent = mean(games.compactMap(\.headshotPercent))
        }

        // ADR: round-weighted when damage and rounds are known.
        let dmgGames = games.filter { $0.damage != nil && ($0.rounds ?? 0) > 0 }
        let adrGames = games.filter { $0.adr != nil }
        let adr: Double?
        if !dmgGames.isEmpty, dmgGames.count >= adrGames.count {
            let dmg = dmgGames.reduce(0) { $0 + ($1.damage ?? 0) }
            let rounds = dmgGames.reduce(0) { $0 + ($1.rounds ?? 0) }
            adr = Double(dmg) / Double(rounds)
        } else {
            adr = mean(adrGames.compactMap(\.adr))
        }

        let ratingInput = games.filter { Rating.isComputable($0) }
        let totalRounds = games.compactMap(\.rounds).reduce(0, +)
        let kprGames = games.filter { ($0.rounds ?? 0) > 0 }

        return WindowSummary(
            games: n,
            wins: wins,
            losses: n - wins,
            winRate: Double(wins) / Double(n) * 100,
            kd: deaths > 0 ? Double(kills) / Double(deaths) : (kills > 0 ? Double(kills) : nil),
            headshotPercent: headshotPercent,
            avgKills: Double(kills) / Double(n),
            avgDeaths: Double(deaths) / Double(n),
            avgAssists: Double(assists) / Double(n),
            adr: adr,
            adrGames: max(dmgGames.count, adrGames.count),
            rating: Rating.hltv1(ratingInput),
            ratingGames: ratingInput.count,
            kpr: totalRounds > 0 && !kprGames.isEmpty
                ? Double(kprGames.reduce(0) { $0 + $1.kills }) / Double(kprGames.reduce(0) { $0 + ($1.rounds ?? 0) }) : nil
        )
    }

    /// Rolling-window series for the history charts: one point per game (oldest → newest),
    /// each point summarising the `window` games ending at that game. Points with fewer
    /// than `window` games behind them are omitted.
    public static func rolling(_ gamesNewestFirst: [GameRecord], window: Int = windowSize) -> [RollingPoint] {
        let chrono = Array(gamesNewestFirst.reversed())
        guard chrono.count >= window else { return [] }
        return (window - 1..<chrono.count).map { end in
            let slice = Array(chrono[(end - window + 1)...end])
            let s = summary(of: slice)
            return RollingPoint(gameId: chrono[end].id, date: chrono[end].finishedAt, index: end,
                                winRate: s.winRate, kd: s.kd, headshotPercent: s.headshotPercent, adr: s.adr)
        }
    }

    static func mean(_ xs: [Double]) -> Double? {
        xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    }
}

public struct RollingPoint: Hashable, Sendable, Identifiable {
    public var id: String { gameId }
    public let gameId: String
    public let date: Date
    public let index: Int
    public let winRate: Double?
    public let kd: Double?
    public let headshotPercent: Double?
    public let adr: Double?
}

/// HLTV Rating 1.0 (HLTV.org, 2010):
///   Rating = (KillRating + 0.7 × SurvivalRating + MultiKillRating) / 2.7
///   KillRating = (Kills/Rounds) / 0.679
///   SurvivalRating = ((Rounds − Deaths)/Rounds) / 0.317
///   MultiKillRating = ((1K + 4·2K + 9·3K + 16·4K + 25·5K)/Rounds) / 1.277
/// where nK = number of rounds with exactly n kills. FACEIT gives "Double/Triple/Quadro/Penta Kills"
/// per game, so 1K = Kills − 2·2K − 3·3K − 4·4K − 5·5K.
/// Rating 2.0/3.0 are NOT computable: FACEIT does not expose KAST, trades or per-round data.
public enum Rating {
    public static func isComputable(_ g: GameRecord) -> Bool {
        guard let r = g.rounds, r > 0, g.doubleKills != nil, g.tripleKills != nil, g.quadroKills != nil, g.pentaKills != nil else { return false }
        return singleKillRounds(g) != nil
    }

    static func singleKillRounds(_ g: GameRecord) -> Int? {
        guard let k2 = g.doubleKills, let k3 = g.tripleKills, let k4 = g.quadroKills, let k5 = g.pentaKills else { return nil }
        let k1 = g.kills - 2 * k2 - 3 * k3 - 4 * k4 - 5 * k5
        return k1 >= 0 ? k1 : nil
    }

    public static func hltv1(_ games: [GameRecord]) -> Double? {
        let gs = games.filter(isComputable)
        guard !gs.isEmpty else { return nil }
        var rounds = 0, kills = 0, deaths = 0, mk = 0
        for g in gs {
            rounds += g.rounds ?? 0
            kills += g.kills
            deaths += g.deaths
            mk += (singleKillRounds(g) ?? 0) + 4 * (g.doubleKills ?? 0) + 9 * (g.tripleKills ?? 0)
                + 16 * (g.quadroKills ?? 0) + 25 * (g.pentaKills ?? 0)
        }
        guard rounds > 0 else { return nil }
        let r = Double(rounds)
        let killRating = Double(kills) / r / 0.679
        let survivalRating = Double(max(rounds - deaths, 0)) / r / 0.317
        let multiKillRating = Double(mk) / r / 1.277
        return (killRating + 0.7 * survivalRating + multiKillRating) / 2.7
    }

    public static func hltv1(_ game: GameRecord) -> Double? { hltv1([game]) }
}
