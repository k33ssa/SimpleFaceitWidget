import Foundation

// Wire types for the official FACEIT Data API v4 (https://open.faceit.com/data/v4).
// Only fields confirmed by the swagger spec or by our own recorded responses
// (Tests/FaceitKitTests/Fixtures, recorded 2026-11-14) are declared. See docs/API_RESEARCH.md.

/// `GET /players?nickname=&game=cs2`, `GET /players/{player_id}` → schema `Player`.
public struct PlayerDTO: Codable, Sendable {
    public let player_id: String
    public let nickname: String
    public let avatar: String?
    public let country: String?
    public let faceit_url: String?
    public let games: [String: GameDetailDTO]?
}

/// `Player.games["cs2"]` → schema `GameDetail`.
public struct GameDetailDTO: Codable, Sendable {
    public let faceit_elo: Int?
    public let skill_level: Int?
    public let region: String?
    public let game_player_name: String?
}

/// `GET /search/players` → `UsersSearchList`.
public struct PlayerSearchListDTO: Codable, Sendable {
    public let items: [PlayerSearchItemDTO]
}

public struct PlayerSearchItemDTO: Codable, Sendable {
    public let player_id: String
    public let nickname: String
    public let avatar: String?
    public let country: String?
    public let verified: Bool?
    public let games: [GameUserSearchDTO]?
}

/// The spec says: "we return SkillLevel as string even if it is an int".
public struct GameUserSearchDTO: Codable, Sendable {
    public let name: String
    public let skill_level: JSONValue?
}

/// `GET /players/{id}/games/{game_id}/stats` → `PlayerStatsForMatchesList`.
public struct PlayerGameStatsListDTO: Codable, Sendable {
    public let items: [PlayerGameStatsItemDTO]
}

public struct PlayerGameStatsItemDTO: Codable, Sendable {
    public let stats: [String: JSONValue]
}

/// `GET /players/{id}/stats/{game_id}` → `PlayerStats`.
public struct PlayerLifetimeStatsDTO: Codable, Sendable {
    public let player_id: String?
    public let lifetime: [String: JSONValue]?
    public let segments: [SegmentDTO]?
}

public struct SegmentDTO: Codable, Sendable {
    public let type: String?
    public let mode: String?
    public let label: String?
    public let img_small: String?
    public let stats: [String: JSONValue]?
}

/// `GET /matches/{match_id}` → `Match`.
public struct MatchDTO: Codable, Sendable {
    public let match_id: String
    public let competition_name: String?
    public let competition_type: String?
    public let calculate_elo: Bool?
    public let best_of: Int?
    public let started_at: Int?
    public let finished_at: Int?
    public let status: String?
    public let faceit_url: String?
    public let results: MatchResultsDTO?
    public let teams: [String: FactionDTO]?
    /// Free-form in the spec; live responses carry `voting.map.entities[{guid, name, image_lg, image_sm}]`
    /// and `voting.map.pick[]`. Decoded loosely so a shape change never breaks the match decode.
    public let voting: JSONValue?

    /// Map art by map id ("de_mirage" → image URL), from `voting.map.entities`.
    public var mapImages: [String: URL] {
        guard let entities = voting?.object?["map"]?.object?["entities"]?.array else { return [:] }
        var out: [String: URL] = [:]
        for e in entities {
            guard let o = e.object, let guid = o["guid"]?.string,
                  let raw = o["image_lg"]?.string ?? o["image_sm"]?.string, let url = URL(string: raw) else { continue }
            out[guid] = url
        }
        return out
    }
}

public struct MatchResultsDTO: Codable, Sendable {
    public let winner: String?
    public let score: [String: Int]?
}

public struct FactionDTO: Codable, Sendable {
    public let faction_id: String?
    public let name: String?
    public let avatar: String?
    public let roster: [RosterDTO]?
    public let stats: FactionStatsDTO?
}

public struct RosterDTO: Codable, Sendable {
    public let player_id: String
    public let nickname: String
    public let avatar: String?
    public let game_skill_level: Int?
}

public struct FactionStatsDTO: Codable, Sendable {
    /// Undocumented in the spec; empirically the team's average ELO at match creation.
    public let rating: Int?
    /// Pre-match win probability of the faction (0…1).
    public let winProbability: Double?
}

/// `GET /matches/{match_id}/stats` → `MatchStats`.
public struct MatchStatsDTO: Codable, Sendable {
    public let rounds: [RoundStatsDTO]
}

public struct RoundStatsDTO: Codable, Sendable {
    public let match_round: String?
    public let round_stats: [String: JSONValue]?
    public let teams: [TeamStatsDTO]
}

public struct TeamStatsDTO: Codable, Sendable {
    public let team_id: String
    public let team_stats: [String: JSONValue]?
    public let players: [PlayerMatchStatsDTO]
}

public struct PlayerMatchStatsDTO: Codable, Sendable {
    public let player_id: String
    public let nickname: String
    public let player_stats: [String: JSONValue]
}

/// FACEIT error envelopes observed live (2026-11-14):
/// `{"errors":[{"message":…,"code":"err_f0","http_status":403}]}` and
/// `{"error":"invalid_token","error_description":"Token was not recognised"}`.
struct FaceitErrorEnvelopeDTO: Decodable {
    struct Item: Decodable { let message: String?; let code: String? }
    let errors: [Item]?
    let error: String?
    let error_description: String?

    var summary: String? {
        if let e = errors?.first { return [e.code, e.message].compactMap { $0 }.joined(separator: ": ") }
        if let error { return [error, error_description].compactMap { $0 }.joined(separator: ": ") }
        return nil
    }
}
