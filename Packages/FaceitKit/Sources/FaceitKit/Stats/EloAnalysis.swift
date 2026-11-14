import Foundation

/// How a number about ELO was obtained.
public enum EloSource: String, Codable, Sendable {
    /// Difference of two observed `faceit_elo` values with exactly this game between them.
    case exact
    /// Part of an observed total over several games; split between them by estimate.
    case constrained
    /// Estimated from the pre-match win probability (no observation covers this game).
    case estimated
    /// The match did not affect ELO (`calculate_elo == false`).
    case unrated
}

public struct EloGamePoint: Codable, Hashable, Sendable, Identifiable {
    public var id: String { gameId }
    public let gameId: String
    public let finishedAt: Date
    /// ELO right after this game.
    public let eloAfter: Int
    /// `eloAfter` is an observed value (snapshot), not reconstructed.
    public let eloAfterObserved: Bool
    /// ELO gained/lost in this game.
    public let delta: Int
    public let source: EloSource
}

/// ELO change over the window and per-game ELO reconstruction.
public struct EloAnalysis: Codable, Hashable, Sendable {
    /// Newest first, one per game in the window.
    public let points: [EloGamePoint]
    /// ELO now minus ELO before the oldest game of the window.
    public let change: Int?
    /// `change` is fully based on observed values.
    public let changeIsExact: Bool
    /// How many of the window's games are covered by observed values
    /// (from the newest game back to the oldest snapshot inside the window).
    public let observedGames: Int
    public let windowGames: Int
    /// Current ELO minus ELO right after the newest game, when both are known and differ:
    /// ELO changed outside matches (returned after a cheater ban, compensation…). Included in `change`.
    public var offMatchAdjustment: Int? = nil

    public static let empty = EloAnalysis(points: [], change: nil, changeIsExact: false, observedGames: 0, windowGames: 0)
}

/// Reconstructs ELO per game.
///
/// The official Data API has **no per-match ELO** (verified against the swagger and live responses,
/// docs/API_RESEARCH.md §7). Exact values come only from our own snapshots of `games.cs2.faceit_elo`:
/// a snapshot taken when game *g* was the newest finished game equals ELO right after *g*.
///   • two snapshots with exactly one game between them → exact delta of that game;
///   • several games between them → exact total, split by estimate (`constrained`);
///   • no snapshot behind a game → estimate `K·(result − p)`, K = 50, p = pre-match win probability
///     of the player's faction from `GET /matches/{id}` (`teams.*.stats.winProbability`).
/// K = 50 is an empirical community finding, not an official FACEIT constant; since 2025 FACEIT also adds
/// a small individual-performance component for levels 1–9, so estimates are marked "≈" in the UI.
public enum EloAnalyzer {
    public static let kFactor = 50.0

    /// - Parameters:
    ///   - games: newest first; should contain at least `window + 1` games for an exact window boundary.
    ///   - currentElo: `faceit_elo` observed together with `games` (anchor for the newest game).
    ///   - snapshots: any order; snapshots of other players must be filtered out by the caller.
    ///   - matchInfos: by match id; used for win probability and `calculate_elo`.
    public static func analyze(games: [GameRecord], currentElo: Int?, snapshots: [EloSnapshot],
                               matchInfos: [String: MatchInfo], window: Int = StatsCalculator.windowSize) -> EloAnalysis {
        guard let currentElo, !games.isEmpty else { return .empty }
        let n = min(window, games.count)

        // 1. Anchors: index → observed ELO right after games[index].
        var anchors: [Int: Int] = [0: currentElo]
        let indexById = Dictionary(games.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        // Per game: a match record from faceit.com wins; otherwise the latest snapshot
        // (an earlier one may predate FACEIT finishing the ELO update).
        var bestByGame: [String: EloSnapshot] = [:]
        for s in snapshots {
            guard let gid = s.latestGameId else { continue }
            if let prev = bestByGame[gid] {
                if prev.isMatchRecord && !s.isMatchRecord { continue }
                if prev.isMatchRecord == s.isMatchRecord && prev.takenAt >= s.takenAt { continue }
            }
            bestByGame[gid] = s
        }
        var newestFromRecord: Int?
        for (gid, s) in bestByGame {
            guard let idx = indexById[gid] else { continue }
            if idx == 0 {
                // The newest game: only a per-match record may replace "current ELO" (snapshots of it ARE current ELO).
                if s.isMatchRecord { anchors[0] = s.elo; newestFromRecord = s.elo }
            } else {
                anchors[idx] = s.elo
            }
        }

        // 2. Per-game estimates.
        func estimate(_ g: GameRecord) -> (Double, Bool) {   // (delta, rated)
            let info = matchInfos[g.matchId]
            if info?.calculateElo == false { return (0, false) }
            let p = info?.playerWinProbability ?? 0.5
            return (kFactor * ((g.isWin ? 1 : 0) - p), true)
        }

        // 3. Walk segments between anchors (lower index = newer).
        var deltas = [Int](repeating: 0, count: games.count)
        var sources = [EloSource](repeating: .estimated, count: games.count)
        let sortedAnchors = anchors.keys.sorted()
        for (k, a) in sortedAnchors.enumerated() {
            let b = k + 1 < sortedAnchors.count ? sortedAnchors[k + 1] : nil
            let end = b ?? games.count               // games a..<end belong to this segment
            let est = (a..<end).map { estimate(games[$0]) }
            if let b {
                let total = anchors[a]! - anchors[b]!
                if b - a == 1 {
                    deltas[a] = total
                    sources[a] = est[0].1 ? .exact : (total == 0 ? .unrated : .exact)
                } else {
                    // Distribute the observed total over rated games, proportionally to the estimate's shape.
                    let rated = (a..<b).filter { est[$0 - a].1 }
                    var assigned = (a..<b).map { est[$0 - a].1 ? Int(est[$0 - a].0.rounded()) : 0 }
                    var residual = total - assigned.reduce(0, +)
                    if !rated.isEmpty {
                        var i = 0
                        while residual != 0 {
                            let idx = rated[i % rated.count] - a
                            assigned[idx] += residual > 0 ? 1 : -1
                            residual += residual > 0 ? -1 : 1
                            i += 1
                        }
                    }
                    for (off, idx) in (a..<b).enumerated() {
                        deltas[idx] = assigned[off]
                        sources[idx] = est[off].1 ? .constrained : .unrated
                    }
                }
            } else {
                for (off, idx) in (a..<end).enumerated() {
                    deltas[idx] = Int(est[off].0.rounded())
                    sources[idx] = est[off].1 ? .estimated : .unrated
                }
            }
        }

        // 4. ELO after each game, walking back from the newest.
        var eloAfter = [Int](repeating: 0, count: games.count)
        eloAfter[0] = anchors[0] ?? currentElo
        for i in 1..<max(games.count, 1) where i < games.count {
            eloAfter[i] = anchors[i] ?? (eloAfter[i - 1] - deltas[i - 1])
        }

        let points = (0..<n).map { i in
            EloGamePoint(gameId: games[i].id, finishedAt: games[i].finishedAt, eloAfter: eloAfter[i],
                         eloAfterObserved: anchors[i] != nil, delta: deltas[i], source: sources[i])
        }

        // 5. Change over the window = ELO now − ELO after the game just before the window.
        let change: Int
        let exact: Bool
        if n < games.count {
            change = currentElo - eloAfter[n]
            exact = anchors[n] != nil
        } else {
            // Fewer games than the window + 1: the boundary is "before the oldest known game".
            change = currentElo - (eloAfter[n - 1] - deltas[n - 1])
            exact = false
        }
        let deepestAnchor = sortedAnchors.last { $0 <= n } ?? 0
        var result = EloAnalysis(points: points, change: change, changeIsExact: exact,
                                 observedGames: min(deepestAnchor, n), windowGames: n)
        if let rec = newestFromRecord, rec != currentElo { result.offMatchAdjustment = currentElo - rec }
        return result
    }
}
