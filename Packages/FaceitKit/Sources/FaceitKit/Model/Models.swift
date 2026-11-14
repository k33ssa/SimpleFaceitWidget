import Foundation

public struct PlayerProfile: Codable, Hashable, Sendable, Identifiable {
    public var id: String { playerId }
    public let playerId: String
    public let nickname: String
    public let avatarURL: URL?
    public let country: String?
    public let profileURL: URL?
    /// `games.cs2.faceit_elo`; nil if the player has no CS2 profile.
    public let elo: Int?
    public let skillLevel: Int?
    public let region: String?

    public init(playerId: String, nickname: String, avatarURL: URL?, country: String?, profileURL: URL?, elo: Int?, skillLevel: Int?, region: String?) {
        self.playerId = playerId; self.nickname = nickname; self.avatarURL = avatarURL; self.country = country
        self.profileURL = profileURL; self.elo = elo; self.skillLevel = skillLevel; self.region = region
    }

    public init(dto: PlayerDTO) {
        let cs2 = dto.games?[FaceitAPIClient.game]
        self.init(
            playerId: dto.player_id,
            nickname: dto.nickname,
            avatarURL: dto.avatar.flatMap { $0.isEmpty ? nil : URL(string: $0) },
            country: dto.country,
            // faceit_url carries a "{lang}" placeholder.
            profileURL: dto.faceit_url.flatMap { URL(string: $0.replacingOccurrences(of: "{lang}", with: "en")) },
            elo: cs2?.faceit_elo,
            skillLevel: cs2?.skill_level,
            region: cs2?.region
        )
    }
}

public enum GameResult: String, Codable, Sendable { case win, loss }

/// One map played by the player — one item of `GET /players/{id}/games/cs2/stats`.
/// A BO3 match produces several records with the same `matchId` and different `matchRound`.
public struct GameRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(matchId)#\(matchRound)" }
    public let matchId: String
    public let matchRound: Int
    public let finishedAt: Date
    public let map: String
    public let result: GameResult
    /// Rounds won by the player's team / by the opponent (from "Final Score" and "Score").
    public let teamScore: Int?
    public let opponentScore: Int?
    public let rounds: Int?
    public let kills: Int
    public let deaths: Int
    public let assists: Int
    public let headshots: Int?
    public let headshotPercent: Double?
    public let kdRatio: Double?
    public let krRatio: Double?
    /// Present only for games after ~June 2024.
    public let adr: Double?
    public let damage: Int?
    public let mvps: Int?
    public let doubleKills: Int?
    public let tripleKills: Int?
    public let quadroKills: Int?
    public let pentaKills: Int?
    public let bestOf: Int?

    public var isWin: Bool { result == .win }

    /// "de_mirage" → "Mirage".
    public var mapName: String { GameRecord.prettyMap(map) }

    public static func prettyMap(_ raw: String) -> String {
        var s = raw
        if s.hasPrefix("de_") || s.hasPrefix("cs_") { s.removeFirst(3) }
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    public init(matchId: String, matchRound: Int, finishedAt: Date, map: String, result: GameResult, teamScore: Int?, opponentScore: Int?,
                rounds: Int?, kills: Int, deaths: Int, assists: Int, headshots: Int?, headshotPercent: Double?, kdRatio: Double?, krRatio: Double?,
                adr: Double?, damage: Int?, mvps: Int?, doubleKills: Int?, tripleKills: Int?, quadroKills: Int?, pentaKills: Int?, bestOf: Int?) {
        self.matchId = matchId; self.matchRound = matchRound; self.finishedAt = finishedAt; self.map = map; self.result = result
        self.teamScore = teamScore; self.opponentScore = opponentScore; self.rounds = rounds; self.kills = kills; self.deaths = deaths
        self.assists = assists; self.headshots = headshots; self.headshotPercent = headshotPercent; self.kdRatio = kdRatio; self.krRatio = krRatio
        self.adr = adr; self.damage = damage; self.mvps = mvps; self.doubleKills = doubleKills; self.tripleKills = tripleKills
        self.quadroKills = quadroKills; self.pentaKills = pentaKills; self.bestOf = bestOf
    }

    /// Parses one `stats` dictionary. Returns nil if any of the essential keys
    /// (`Match Id`, `Match Finished At`, `Result`, `Kills`, `Deaths`) is missing — such a record is skipped, never zero-filled.
    public init?(stats s: [String: JSONValue]) {
        guard let matchId = s.string("Match Id"),
              let finishedMs = s.double("Match Finished At"),
              let resultRaw = s.int("Result"),
              let kills = s.int("Kills"),
              let deaths = s.int("Deaths")
        else { return nil }

        // "Score" is "a / b" in faction order, "Final Score" is the player's team score.
        var teamScore = s.int("Final Score")
        var opponentScore: Int?
        if let score = s.string("Score") {
            let parts = score.split(separator: "/").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2, let a = parts[0], let b = parts[1] {
                if let t = teamScore {
                    opponentScore = (t == a) ? b : (t == b ? a : nil)
                } else {
                    // Fall back to the result: the winner has the larger score.
                    teamScore = resultRaw == 1 ? max(a, b) : min(a, b)
                    opponentScore = resultRaw == 1 ? min(a, b) : max(a, b)
                }
            }
        }

        self.init(
            matchId: matchId,
            matchRound: s.int("Match Round") ?? 1,
            finishedAt: Date(timeIntervalSince1970: finishedMs / 1000),
            map: s.string("Map") ?? "unknown",
            result: resultRaw == 1 ? .win : .loss,
            teamScore: teamScore,
            opponentScore: opponentScore,
            rounds: s.int("Rounds"),
            kills: kills,
            deaths: deaths,
            assists: s.int("Assists") ?? 0,
            headshots: s.int("Headshots"),
            headshotPercent: s.double("Headshots %"),
            kdRatio: s.double("K/D Ratio"),
            krRatio: s.double("K/R Ratio"),
            adr: s.double("ADR"),
            damage: s.int("Damage"),
            mvps: s.int("MVPs"),
            doubleKills: s.int("Double Kills"),
            tripleKills: s.int("Triple Kills"),
            quadroKills: s.int("Quadro Kills"),
            pentaKills: s.int("Penta Kills"),
            bestOf: s.int("Best Of")
        )
    }
}

/// What we keep from `GET /matches/{id}` — needed for the ELO estimate and the match screen.
public struct MatchInfo: Codable, Hashable, Sendable {
    public let matchId: String
    public let calculateElo: Bool?
    public let competitionName: String?
    public let faceitURL: URL?
    /// Faction of our player ("faction1"/"faction2"), nil if not found in rosters.
    public let playerFaction: String?
    public let playerWinProbability: Double?
    public let playerTeamAvgElo: Int?
    public let opponentTeamAvgElo: Int?
    public let teams: [Team]
    /// Map art from `voting.map.entities` (official match endpoint), by map id.
    public var mapImages: [String: URL]? = nil

    public struct Team: Codable, Hashable, Sendable {
        public let faction: String
        public let name: String?
        public let avgElo: Int?
        public let winProbability: Double?
        public let players: [Member]
    }

    public struct Member: Codable, Hashable, Sendable {
        public let playerId: String
        public let nickname: String
        public let skillLevel: Int?
    }

    public init(matchId: String, calculateElo: Bool?, competitionName: String?, faceitURL: URL?, playerFaction: String?,
                playerWinProbability: Double?, playerTeamAvgElo: Int?, opponentTeamAvgElo: Int?, teams: [Team]) {
        self.matchId = matchId; self.calculateElo = calculateElo; self.competitionName = competitionName; self.faceitURL = faceitURL
        self.playerFaction = playerFaction; self.playerWinProbability = playerWinProbability
        self.playerTeamAvgElo = playerTeamAvgElo; self.opponentTeamAvgElo = opponentTeamAvgElo; self.teams = teams
    }

    public init(dto: MatchDTO, playerId: String) {
        let teams = (dto.teams ?? [:]).sorted { $0.key < $1.key }.map { key, f in
            Team(faction: key, name: f.name, avgElo: f.stats?.rating, winProbability: f.stats?.winProbability,
                 players: (f.roster ?? []).map { Member(playerId: $0.player_id, nickname: $0.nickname, skillLevel: $0.game_skill_level) })
        }
        let mine = teams.first { $0.players.contains { $0.playerId == playerId } }
        let other = teams.first { $0.faction != mine?.faction }
        self.init(
            matchId: dto.match_id,
            calculateElo: dto.calculate_elo,
            competitionName: dto.competition_name,
            faceitURL: dto.faceit_url.flatMap { URL(string: $0.replacingOccurrences(of: "{lang}", with: "en")) },
            playerFaction: mine?.faction,
            playerWinProbability: mine?.winProbability,
            playerTeamAvgElo: mine?.avgElo,
            opponentTeamAvgElo: mine == nil ? nil : other?.avgElo,
            teams: teams
        )
        self.mapImages = dto.mapImages
    }
}

/// ELO observed at a moment in time (`games.cs2.faceit_elo` at fetch time) together with
/// the newest finished game known at that moment. This is the only *exact* ELO source.
public struct EloSnapshot: Codable, Hashable, Sendable {
    public let takenAt: Date
    public let elo: Int
    /// `Match Finished At` of the newest game in the same refresh (nil if no games yet).
    public let latestGameFinishedAt: Date?
    public let latestGameId: String?
    /// `true` when the value is faceit.com's own per-match ELO ("ELO right after this match"). Such values win over
    /// our snapshots: a snapshot can include later off-match changes (e.g. ELO returned after a cheater ban).
    public var isMatchRecord: Bool = false

    public init(takenAt: Date, elo: Int, latestGameFinishedAt: Date?, latestGameId: String?, isMatchRecord: Bool = false) {
        self.takenAt = takenAt; self.elo = elo; self.latestGameFinishedAt = latestGameFinishedAt; self.latestGameId = latestGameId
        self.isMatchRecord = isMatchRecord
    }
}
