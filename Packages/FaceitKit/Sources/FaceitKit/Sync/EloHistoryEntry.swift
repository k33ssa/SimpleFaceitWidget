import Foundation

/// One entry of faceit.com's own per-match ELO history.
///
/// ⚠️ UNOFFICIAL: this is the website frontend's endpoint
/// `GET https://www.faceit.com/api/stats/v1/stats/time/users/{player_id}/games/cs2?page=&size=`
/// (not part of the Data API). It sits behind Cloudflare and answers 403 to non-browser clients
/// (checked 2026-11-14), so the app requests it only from inside a WebKit view on faceit.com —
/// i.e. as the site itself does, in the user's own browser session. Field names are taken from a working
/// open-source client (LilStick/4esElo `packages/faceit/src/eloHistory.ts`): `matchId`, `date` (epoch ms),
/// `elo` (ELO after the match, string), `elo_delta` (string). Unranked entries have no `elo`.
public struct EloHistoryEntry: Hashable, Sendable {
    public let matchId: String
    public let date: Date
    public let elo: Int
    public let delta: Int?

    /// Parses the raw JSON array. Unknown shapes produce an empty result, never a crash.
    public static func parse(_ data: Data) -> [EloHistoryEntry] {
        guard let arr = try? JSONDecoder().decode([JSONValue].self, from: data) else { return [] }
        return arr.compactMap { v in
            guard let o = v.object, let mid = o["matchId"]?.string, !mid.isEmpty,
                  let ms = o["date"]?.double, let elo = o["elo"]?.int, elo > 0 else { return nil }
            return EloHistoryEntry(matchId: mid, date: Date(timeIntervalSince1970: ms / 1000), elo: elo, delta: o["elo_delta"]?.int)
        }
    }
}
