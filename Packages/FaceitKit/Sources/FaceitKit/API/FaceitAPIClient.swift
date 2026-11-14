import Foundation

public enum FaceitAPIError: Error, Equatable, Sendable, LocalizedError {
    case missingAPIKey
    /// 400 `invalid_token`, 401 — the key was rejected.
    case invalidAPIKey(String?)
    /// 403 — key valid but not allowed (or missing header).
    case forbidden(String?)
    case notFound(String?)
    /// 429 after all retries.
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int, String?)
    case http(status: Int, String?)
    case network(String)
    case decoding(String)
    case noCS2Profile

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Не задан API-ключ FACEIT."
        case .invalidAPIKey(let m): return "FACEIT отклонил API-ключ" + Self.suffix(m)
        case .forbidden(let m): return "Нет доступа (403)" + Self.suffix(m)
        case .notFound(let m): return "Не найдено (404)" + Self.suffix(m)
        case .rateLimited(let r): return "Превышен лимит запросов FACEIT" + (r.map { ", повтор через \(Int($0)) с" } ?? "")
        case .server(let s, let m): return "Сервер FACEIT ответил \(s)" + Self.suffix(m)
        case .http(let s, let m): return "Ошибка HTTP \(s)" + Self.suffix(m)
        case .network(let m): return "Нет связи с FACEIT: \(m)"
        case .decoding(let m): return "Не удалось разобрать ответ FACEIT: \(m)"
        case .noCS2Profile: return "У игрока нет профиля CS2 на FACEIT."
        }
    }

    /// Whether repeating the same request later can succeed.
    public var isTransient: Bool {
        switch self {
        case .rateLimited, .server, .network: return true
        default: return false
        }
    }

    private static func suffix(_ m: String?) -> String { m.map { ": \($0)" } ?? "." }
}

/// One finished HTTP exchange, for the diagnostics screen.
public struct APITrace: Sendable {
    public let path: String
    public let status: Int?
    public let durationMs: Int
    public let attempt: Int
    public let error: String?
    public let rateLimitRemaining: String?
}

/// Thin client over the official FACEIT Data API v4.
/// Retries transient failures (network, 5xx, 429) with exponential backoff and honours
/// `Retry-After` / `ratelimit-reset`. Never retries 4xx other than 429.
public final class FaceitAPIClient: @unchecked Sendable {
    public static let baseURL = URL(string: "https://open.faceit.com/data/v4/")!
    public static let game = "cs2"

    private let session: URLSession
    private let apiKey: @Sendable () -> String?
    private let maxAttempts: Int
    private let trace: (@Sendable (APITrace) -> Void)?
    private let sleeper: @Sendable (TimeInterval) async throws -> Void

    public init(
        session: URLSession = FaceitAPIClient.defaultSession(),
        apiKey: @escaping @Sendable () -> String?,
        maxAttempts: Int = 3,
        trace: (@Sendable (APITrace) -> Void)? = nil,
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) {
        self.session = session
        self.apiKey = apiKey
        self.maxAttempts = max(1, maxAttempts)
        self.trace = trace
        self.sleeper = sleeper
    }

    public static func defaultSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 40
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpAdditionalHeaders = ["Accept": "application/json"]
        return URLSession(configuration: c)
    }

    // MARK: Endpoints (all present in the official swagger, see docs/API_RESEARCH.md)

    /// Exact (case-sensitive) nickname lookup.
    public func player(nickname: String) async throws -> PlayerDTO {
        try await get("players", query: ["nickname": nickname, "game": Self.game])
    }

    public func player(id: String) async throws -> PlayerDTO {
        try await get("players/\(id)", query: [:])
    }

    /// Substring search (no ELO in the response).
    public func searchPlayers(nickname: String, limit: Int = 20) async throws -> [PlayerSearchItemDTO] {
        let list: PlayerSearchListDTO = try await get(
            "search/players", query: ["nickname": nickname, "game": Self.game, "offset": "0", "limit": String(min(max(limit, 1), 100))])
        return list.items
    }

    /// Per-map stats of the player's latest games, newest first. `limit` ≤ 100.
    public func recentGameStats(playerId: String, limit: Int) async throws -> [PlayerGameStatsItemDTO] {
        let list: PlayerGameStatsListDTO = try await get(
            "players/\(playerId)/games/\(Self.game)/stats", query: ["offset": "0", "limit": String(min(max(limit, 1), 100))])
        return list.items
    }

    /// Position in the region's ELO ranking: `GET /rankings/games/cs2/regions/{region}/players/{player_id}` → `position`.
    public func regionPosition(region: String, playerId: String) async throws -> Int? {
        struct R: Decodable { let position: Int? }
        let r: R = try await get("rankings/games/\(Self.game)/regions/\(region)/players/\(playerId)", query: ["limit": "1"])
        return (r.position ?? 0) > 0 ? r.position : nil
    }

    public func lifetimeStats(playerId: String) async throws -> PlayerLifetimeStatsDTO {
        try await get("players/\(playerId)/stats/\(Self.game)", query: [:])
    }

    public func match(id: String) async throws -> MatchDTO {
        try await get("matches/\(id)", query: [:])
    }

    public func matchStats(id: String) async throws -> MatchStatsDTO {
        try await get("matches/\(id)/stats", query: [:])
    }

    // MARK: Transport

    func get<T: Decodable>(_ path: String, query: [String: String]) async throws -> T {
        let data = try await getData(path, query: query)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw FaceitAPIError.decoding(String(describing: error).prefix(300).description)
        }
    }

    func getData(_ path: String, query: [String: String]) async throws -> Data {
        guard let key = apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw FaceitAPIError.missingAPIKey
        }
        var comps = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: comps.url!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        var lastError: FaceitAPIError = .network("unknown")
        for attempt in 1...maxAttempts {
            let start = Date()
            do {
                let (data, response) = try await session.data(for: request)
                let http = response as! HTTPURLResponse
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                let remaining = http.value(forHTTPHeaderField: "ratelimit-remaining")
                if (200..<300).contains(http.statusCode) {
                    trace?(APITrace(path: path, status: http.statusCode, durationMs: ms, attempt: attempt, error: nil, rateLimitRemaining: remaining))
                    return data
                }
                let message = (try? JSONDecoder().decode(FaceitErrorEnvelopeDTO.self, from: data))?.summary
                let error = Self.map(status: http.statusCode, message: message, headers: http)
                trace?(APITrace(path: path, status: http.statusCode, durationMs: ms, attempt: attempt, error: error.errorDescription, rateLimitRemaining: remaining))
                lastError = error
                guard error.isTransient, attempt < maxAttempts else { throw error }
                try await sleeper(Self.backoff(attempt: attempt, error: error))
            } catch let error as FaceitAPIError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                let mapped = FaceitAPIError.network((error as NSError).localizedDescription)
                trace?(APITrace(path: path, status: nil, durationMs: ms, attempt: attempt, error: mapped.errorDescription, rateLimitRemaining: nil))
                lastError = mapped
                if (error as? URLError)?.code == .cancelled { throw CancellationError() }
                guard attempt < maxAttempts else { throw mapped }
                try await sleeper(Self.backoff(attempt: attempt, error: mapped))
            }
        }
        throw lastError
    }

    static func map(status: Int, message: String?, headers: HTTPURLResponse) -> FaceitAPIError {
        switch status {
        case 400 where (message ?? "").contains("invalid_token"): return .invalidAPIKey(message)
        case 401: return .invalidAPIKey(message)
        case 403: return .forbidden(message)
        case 404: return .notFound(message)
        case 429:
            let retry = headers.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                ?? headers.value(forHTTPHeaderField: "ratelimit-reset").flatMap(Double.init)
            return .rateLimited(retryAfter: retry)
        case 500...599: return .server(status: status, message)
        default: return .http(status: status, message)
        }
    }

    static func backoff(attempt: Int, error: FaceitAPIError) -> TimeInterval {
        if case .rateLimited(let r?) = error { return min(max(r, 1), 30) }
        let base = pow(2.0, Double(attempt - 1)) * 0.8   // 0.8 s, 1.6 s, 3.2 s …
        return base + Double.random(in: 0...0.3)
    }
}
