import Foundation

/// Own backend (server/, Cloudflare Worker). When configured, the app and widgets talk to it instead of FACEIT:
/// it proxies the official Data API (the FACEIT key lives only on the server) and returns exact per-match ELO
/// recorded by polling every minute. Read from Info.plist `FSServerURL` / `FSAppToken` (Config/Secrets.xcconfig).
public enum ServerConfig {
    nonisolated(unsafe) public static var override: (url: URL, token: String)?

    public static var current: (url: URL, token: String)? {
        if let o = override { return o }
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "FSServerURL") as? String,
              !raw.isEmpty, !raw.hasPrefix("$("), let url = URL(string: raw),
              let token = Bundle.main.object(forInfoDictionaryKey: "FSAppToken") as? String,
              !token.isEmpty, !token.hasPrefix("$(") else { return nil }
        return (url, token)
    }

    public static var isConfigured: Bool { current != nil }
}

/// One exact ELO record from the server: ELO right after `gameId`. `gap` = number of games since the previous
/// record (1 → this game's delta is exact).
public struct ServerEloRecord: Decodable, Sendable {
    public let game_id: String
    public let match_id: String
    public let elo: Int
    public let recorded_at: Double
    public let gap: Int
}

public struct ServerEloResponse: Decodable, Sendable {
    public let playerId: String
    public let currentElo: Int?
    public let trackingSince: Double?
    public let records: [ServerEloRecord]
}
