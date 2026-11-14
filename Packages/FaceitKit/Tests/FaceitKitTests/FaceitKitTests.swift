import Foundation
import Testing
@testable import FaceitKit

// Fixtures are REAL responses of the official Data API for player "shmeeel", recorded 2026-11-14.

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

func fixtureGames() throws -> [GameRecord] {
    let list = try JSONDecoder().decode(PlayerGameStatsListDTO.self, from: fixture("games_stats"))
    return list.items.compactMap { GameRecord(stats: $0.stats) }
}

func game(_ id: String, win: Bool, minutesAgo: Double, match: String? = nil) -> GameRecord {
    GameRecord(matchId: match ?? id, matchRound: 1, finishedAt: Date(timeIntervalSince1970: 1_800_000_000 - minutesAgo * 60),
               map: "de_mirage", result: win ? .win : .loss, teamScore: win ? 13 : 9, opponentScore: win ? 9 : 13, rounds: 22,
               kills: 20, deaths: 15, assists: 4, headshots: 10, headshotPercent: 50, kdRatio: 1.33, krRatio: 0.9, adr: 90,
               damage: 1980, mvps: 2, doubleKills: 3, tripleKills: 1, quadroKills: 0, pentaKills: 0, bestOf: 1)
}

@Suite struct JSONValueTests {
    @Test func coercesStringsAndNumbers() throws {
        let v = try JSONDecoder().decode([String: JSONValue].self, from: Data(#"{"a":"81.94","b":1794610768000,"c":"","d":"x","e":"1"}"#.utf8))
        #expect(v.double("a") == 81.94)
        #expect(v.double("b") == 1794610768000)
        #expect(v.double("c") == nil)      // empty string is "no data", never 0
        #expect(v.double("d") == nil)
        #expect(v.int("e") == 1)
        #expect(v.double("missing") == nil)
    }
}

@Suite struct ParsingTests {
    @Test func playerProfile() throws {
        let p = PlayerProfile(dto: try JSONDecoder().decode(PlayerDTO.self, from: fixture("player")))
        #expect(p.nickname == "shmeeel")
        #expect(p.elo == 1571)
        #expect(p.skillLevel == 8)
        #expect(p.region == "EU")
        #expect(p.profileURL?.absoluteString.contains("{lang}") == false)
    }

    @Test func gameRecordsFromRealResponse() throws {
        let games = try fixtureGames()
        #expect(games.count == 30)
        let g = games[0]
        #expect(g.matchId == "1-4b73a796-b81a-4c05-9f4c-7fc4fb2f0773")
        #expect(g.result == .win)
        // "Score": "7 / 13", "Final Score": "13" → our team 13, opponent 7.
        #expect(g.teamScore == 13)
        #expect(g.opponentScore == 7)
        #expect(g.kills == 8 && g.deaths == 14)
        #expect(g.adr == 39.6)
        #expect(g.mapName == "Anubis")
        // A loss where the faction-ordered score starts with the winner: "13 / 8", Final Score 8.
        #expect(games[2].result == .loss && games[2].teamScore == 8 && games[2].opponentScore == 13)
    }

    @Test func recordWithoutEssentialKeysIsSkipped() {
        #expect(GameRecord(stats: ["Match Id": .string("x"), "Result": .string("1")]) == nil)
    }

    @Test func matchInfoFindsPlayersFaction() throws {
        let dto = try JSONDecoder().decode(MatchDTO.self, from: fixture("match"))
        let info = MatchInfo(dto: dto, playerId: "73772170-dd92-4053-a056-4958d6709528")
        #expect(info.playerFaction == "faction2")
        #expect(info.playerWinProbability == 0.5)
        #expect(info.calculateElo == true)
        #expect(info.mapImages?["de_anubis"] != nil)
    }

    @Test func lifetime() throws {
        let dto = try JSONDecoder().decode(PlayerLifetimeStatsDTO.self, from: fixture("lifetime"))
        let l = LifetimeSummary(lifetime: try #require(dto.lifetime))
        #expect(l.matches == 1105)
        #expect(l.kd == 1.03)
    }

    @Test func unofficialEloHistory() {
        let json = #"[{"matchId":"m1","date":1794610768000,"elo":"1571","elo_delta":"25"},{"matchId":"m2","date":1794607844000},{"date":1}]"#
        let e = EloHistoryEntry.parse(Data(json.utf8))
        #expect(e.count == 1)
        #expect(e[0].elo == 1571 && e[0].delta == 25)
        #expect(EloHistoryEntry.parse(Data("<html>".utf8)).isEmpty)
    }
}

@Suite struct StatsTests {
    /// Expected values computed independently (Python) from the same fixture.
    @Test func windowSummaryMatchesIndependentCalculation() throws {
        let s = StatsCalculator.summary(of: Array(try fixtureGames().prefix(20)))
        #expect(s.games == 20 && s.wins == 8 && s.losses == 12)
        #expect(s.winRate == 40)
        #expect(abs((s.kd ?? 0) - 370.0 / 372.0) < 1e-9)        // Σkills / Σdeaths
        #expect(abs((s.headshotPercent ?? 0) - 47.027) < 0.01)
        #expect(abs((s.adr ?? 0) - 86.658) < 0.01)               // Σdamage / Σrounds
        #expect(s.avgKills == 18.5 && s.avgDeaths == 18.6)
        #expect(abs((s.rating ?? 0) - 1.0376) < 0.001)
        #expect(s.ratingGames == 20)
    }

    @Test func emptyWindowHasNoNumbers() {
        let s = StatsCalculator.summary(of: [])
        #expect(s.winRate == nil && s.kd == nil && s.adr == nil)
    }

    @Test func adrMissingInOldGamesIsNotZero() {
        let g = GameRecord(matchId: "a", matchRound: 1, finishedAt: Date(), map: "de_nuke", result: .win, teamScore: 13, opponentScore: 5,
                           rounds: 18, kills: 10, deaths: 5, assists: 0, headshots: 5, headshotPercent: 50, kdRatio: 2, krRatio: 0.55,
                           adr: nil, damage: nil, mvps: nil, doubleKills: nil, tripleKills: nil, quadroKills: nil, pentaKills: nil, bestOf: 1)
        let s = StatsCalculator.summary(of: [g])
        #expect(s.adr == nil && s.adrGames == 0)
        #expect(s.rating == nil)       // multi-kill data missing → rating not computable
    }

    @Test func hltvRatingReference() {
        // Average-performance reference: KPR 0.679, survival 0.317, RMK 1.277 → rating 1.0 by construction.
        // 100 rounds, 68 kills (all single-kill rounds except multi-kills chosen to give RMK≈1.28), 68.3 deaths.
        let g = GameRecord(matchId: "r", matchRound: 1, finishedAt: Date(), map: "x", result: .win, teamScore: nil, opponentScore: nil,
                           rounds: 100, kills: 68, deaths: 68, assists: 0, headshots: nil, headshotPercent: nil, kdRatio: nil, krRatio: nil,
                           adr: nil, damage: nil, mvps: nil, doubleKills: 12, tripleKills: 2, quadroKills: 0, pentaKills: 0, bestOf: 1)
        let r = Rating.hltv1(g)!
        // KPR .68/.679 + .7·(.32/.317) + RMK (38+48+18)/100=1.04/1.277 → (1.0015+0.7066+0.8144)/2.7 = 0.934
        #expect(abs(r - 0.934) < 0.002)
    }

    @Test func rollingSeries() throws {
        let games = try fixtureGames()
        let r = StatsCalculator.rolling(games, window: 20)
        #expect(r.count == games.count - 19)
        #expect(r.last?.winRate == 40)     // newest window equals the summary
    }
}

@Suite struct EloAnalyzerTests {
    // 4 games newest first: W, L, W, L (+ one boundary game).
    let games = [game("g0", win: true, minutesAgo: 10), game("g1", win: false, minutesAgo: 50), game("g2", win: true, minutesAgo: 90),
                 game("g3", win: false, minutesAgo: 130), game("g4", win: true, minutesAgo: 170)]

    @Test func estimateOnlyUsesWinProbability() {
        let infos = ["g0": info("g0", p: 0.6), "g1": info("g1", p: 0.4)]
        let a = EloAnalyzer.analyze(games: games, currentElo: 1500, snapshots: [], matchInfos: infos, window: 4)
        // g0 win p=.6 → +20; g1 loss p=.4 → −20; g2 win (no info, p=.5) → +25; g3 loss → −25.
        #expect(a.points.map(\.delta) == [20, -20, 25, -25])
        #expect(a.points.map(\.source) == [.estimated, .estimated, .estimated, .estimated])
        #expect(a.change == 0)
        #expect(a.changeIsExact == false)
        #expect(a.points.map(\.eloAfter) == [1500, 1480, 1500, 1475])
    }

    @Test func snapshotsMakeDeltasExact() {
        let snaps = [snap("g1", 1478), snap("g2", 1503), snap("g3", 1479), snap("g4", 1500)]
        let a = EloAnalyzer.analyze(games: games, currentElo: 1500, snapshots: snaps, matchInfos: [:], window: 4)
        #expect(a.points.map(\.delta) == [22, -25, 24, -21])
        #expect(a.points.allSatisfy { $0.source == .exact })
        #expect(a.change == 0)          // 1500 now − 1500 after g4 (the game before the window)
        #expect(a.changeIsExact)
        #expect(a.observedGames == 4)
    }

    @Test func gapBetweenSnapshotsIsConstrained() {
        // Observed: after g3 = 1460 → now 1500 (+40 over 3 games g0..g2).
        let a = EloAnalyzer.analyze(games: games, currentElo: 1500, snapshots: [snap("g3", 1460)], matchInfos: [:], window: 4)
        let d = a.points.map(\.delta)
        #expect(d[0] + d[1] + d[2] == 40)
        #expect(a.points[0..<3].allSatisfy { $0.source == .constrained })
        #expect(a.points[3].source == .estimated)
        #expect(a.points[3].eloAfter == 1460)
        #expect(a.changeIsExact == false)
    }

    @Test func unratedMatchesDoNotMoveElo() {
        var infos = ["g1": info("g1", p: 0.5, rated: false)]
        infos["g0"] = info("g0", p: 0.5)
        let a = EloAnalyzer.analyze(games: games, currentElo: 1500, snapshots: [], matchInfos: infos, window: 2)
        #expect(a.points[1].delta == 0)
        #expect(a.points[1].source == .unrated)
    }

    @Test func latestSnapshotPerGameWins() {
        let early = EloSnapshot(takenAt: Date(timeIntervalSince1970: 100), elo: 1400, latestGameFinishedAt: nil, latestGameId: "g1#1")
        let late = EloSnapshot(takenAt: Date(timeIntervalSince1970: 200), elo: 1478, latestGameFinishedAt: nil, latestGameId: "g1#1")
        let a = EloAnalyzer.analyze(games: games, currentElo: 1500, snapshots: [late, early], matchInfos: [:], window: 4)
        #expect(a.points[1].eloAfter == 1478)
        #expect(a.points[0].delta == 22 && a.points[0].source == .exact)
    }

    /// Real case 14.11.2026: faceit.com says ELO after the newest match was 2400 (−13), profile says 2419 now
    /// (+19 returned outside matches). The newest game must show −13, the window change includes the +19.
    @Test func matchRecordsWinAndOffMatchAdjustment() {
        let recs = [rec("g0", 2400), rec("g1", 2413), rec("g2", 2414), rec("g3", 2413), rec("g4", 2412)]
        let mine = EloSnapshot(takenAt: Date(), elo: 2419, latestGameFinishedAt: nil, latestGameId: "g0#1")
        let a = EloAnalyzer.analyze(games: games, currentElo: 2419, snapshots: recs + [mine], matchInfos: [:], window: 4)
        #expect(a.points.map(\.delta) == [-13, -1, 1, 1])
        #expect(a.points[0].eloAfter == 2400)
        #expect(a.offMatchAdjustment == 19)
        #expect(a.change == 2419 - 2412)
        #expect(a.changeIsExact)
    }

    func rec(_ gameId: String, _ elo: Int) -> EloSnapshot {
        EloSnapshot(takenAt: Date(timeIntervalSince1970: 1), elo: elo, latestGameFinishedAt: nil, latestGameId: "\(gameId)#1", isMatchRecord: true)
    }

    @Test func fewerGamesThanWindow() {
        let a = EloAnalyzer.analyze(games: Array(games.prefix(2)), currentElo: 1000, snapshots: [], matchInfos: [:], window: 20)
        #expect(a.windowGames == 2)
        #expect(a.change == 0)   // +25 −25
    }

    @Test func noEloNoAnalysis() {
        #expect(EloAnalyzer.analyze(games: games, currentElo: nil, snapshots: [], matchInfos: [:]).change == nil)
    }

    func info(_ id: String, p: Double, rated: Bool = true) -> MatchInfo {
        MatchInfo(matchId: id, calculateElo: rated, competitionName: nil, faceitURL: nil, playerFaction: "faction1",
                  playerWinProbability: p, playerTeamAvgElo: nil, opponentTeamAvgElo: nil, teams: [])
    }

    func snap(_ gameId: String, _ elo: Int) -> EloSnapshot {
        EloSnapshot(takenAt: Date(), elo: elo, latestGameFinishedAt: nil, latestGameId: "\(gameId)#1")
    }
}
