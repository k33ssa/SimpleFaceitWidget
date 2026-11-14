import Foundation

public enum RefreshError: Error, LocalizedError, Sendable {
    case noAccount
    case busy
    case api(FaceitAPIError)
    case storage(String)

    public var errorDescription: String? {
        switch self {
        case .noAccount: return "FACEIT-профиль не привязан."
        case .busy: return "Обновление уже идёт в другом процессе."
        case .api(let e): return e.errorDescription
        case .storage(let m): return "Ошибка локального хранилища: \(m)"
        }
    }
}

public enum RefreshOutcome: Sendable {
    /// New data was fetched from FACEIT.
    case fetched(Dashboard)
    /// The cache was fresh enough (or another process had just refreshed); no requests were made.
    case cached(Dashboard)
}

/// The single entry point for getting data — used identically by the app and by every widget.
///
/// Deduplication: a refresh is skipped while the cache is younger than the user's refresh interval;
/// concurrent refreshes from several processes are serialised by a `FileLock`, and the cache is
/// re-checked after acquiring it, so N widgets reloading at once produce one set of requests.
public final class StatsRepository: @unchecked Sendable {
    public static let shared = StatsRepository()

    public let store: LocalStore
    private let settings = AppSettings()
    private let clientFactory: @Sendable (LocalStore) -> FaceitAPIClient

    /// Games fetched per refresh: 100 (one request) — 20 for the window plus history for the charts.
    public static let gamesToFetch = 100
    /// Forced refreshes closer than this to the previous fetch reuse the cache.
    public static let minimumForcedSpacing: TimeInterval = 20

    private let imageSession: URLSession

    public init(store: LocalStore = .shared, imageSession: URLSession = .shared,
                clientFactory: (@Sendable (LocalStore) -> FaceitAPIClient)? = nil) {
        self.store = store
        self.imageSession = imageSession
        self.clientFactory = clientFactory ?? { store in
            FaceitAPIClient(apiKey: { APIKeyStore.load() }, trace: { t in
                if let e = t.error {
                    store.log(t.status.map { $0 >= 500 || $0 == 429 } ?? true ? .warning : .error,
                              "\(t.path) → \(t.status.map(String.init) ?? "—") (попытка \(t.attempt), \(t.durationMs) мс): \(e)")
                }
            })
        }
    }

    public var client: FaceitAPIClient { clientFactory(store) }

    public func cachedDashboard() -> Dashboard? {
        guard let d = store.loadDashboard(), d.profile.playerId == settings.playerId else { return nil }
        return d
    }

    private func isFresh(_ d: Dashboard, force: Bool, now: Date) -> Bool {
        let age = now.timeIntervalSince(d.fetchedAt)
        if force { return age < Self.minimumForcedSpacing }
        // 10 % slack so a timeline reload slightly ahead of schedule still reuses the cache.
        return age < settings.refreshInterval * 0.9
    }

    @discardableResult
    public func refresh(force: Bool = false, now: Date = Date()) async throws -> RefreshOutcome {
        guard let playerId = settings.playerId else { throw RefreshError.noAccount }

        if let d = cachedDashboard(), isFresh(d, force: force, now: now) { return .cached(d) }

        let lock = FileLock(url: store.directory.appendingPathComponent("refresh.lock"))
        guard await lock.acquire(timeout: 30) else {
            if let d = cachedDashboard() { return .cached(d) }
            throw RefreshError.busy
        }
        defer { lock.release() }

        // Another process may have refreshed while we were waiting.
        if let d = cachedDashboard(), isFresh(d, force: force, now: Date()) { return .cached(d) }

        do {
            let d = try await fetch(playerId: playerId)
            return .fetched(d)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            store.log(.error, "Обновление не удалось: \(message)")
            if var d = cachedDashboard() {
                d.lastAttemptAt = Date()
                d.lastError = message
                try? store.saveDashboard(d)
            }
            if let e = error as? FaceitAPIError { throw RefreshError.api(e) }
            throw error
        }
    }

    private func fetch(playerId: String) async throws -> Dashboard {
        let client = self.client
        let started = Date()

        async let playerTask = client.player(id: playerId)
        async let gamesTask = client.recentGameStats(playerId: playerId, limit: Self.gamesToFetch)
        async let lifetimeTask: PlayerLifetimeStatsDTO? = try? client.lifetimeStats(playerId: playerId)

        let player = PlayerProfile(dto: try await playerTask)
        guard player.elo != nil else { throw FaceitAPIError.noCS2Profile }
        let games = try await gamesTask.compactMap { GameRecord(stats: $0.stats) }
            .sorted { $0.finishedAt > $1.finishedAt }
        let lifetime = await lifetimeTask?.lifetime.map(LifetimeSummary.init)
        let fetchedAt = Date()

        // Exact ELO observation for the newest game.
        if let elo = player.elo {
            try? store.addSnapshot(EloSnapshot(takenAt: fetchedAt, elo: elo, latestGameFinishedAt: games.first?.finishedAt,
                                               latestGameId: games.first?.id), playerId: playerId)
        }

        // Match info (win probability, calculate_elo) for the window + 1 boundary game. Cached forever.
        let needed = Array(Set(games.prefix(StatsCalculator.windowSize + 1).map(\.matchId)))
        var infos = store.matchInfos(playerId: playerId, ids: needed)
        let missing = needed.filter { infos[$0] == nil }
        if !missing.isEmpty {
            let fetched = await fetchMatchInfos(missing, playerId: playerId, client: client)
            for m in fetched { store.saveMatchInfo(m, playerId: playerId); infos[m.matchId] = m }
        }

        await downloadMapArt(games: Array(games.prefix(StatsCalculator.windowSize)), infos: infos)

        let previous = store.loadDashboard()
        var avatarSource = previous?.profile.playerId == playerId ? previous?.avatarSource : nil
        if let url = player.avatarURL, url != avatarSource || store.loadAvatar() == nil {
            if let (data, resp) = try? await imageSession.data(from: url),
               (resp as? HTTPURLResponse)?.statusCode == 200, data.count < 2_000_000 {
                store.saveAvatar(data)
                avatarSource = url
            }
        } else if player.avatarURL == nil {
            try? FileManager.default.removeItem(at: store.avatarURL)
            avatarSource = nil
        }

        let dashboard = Dashboard.build(profile: player, games: games, snapshots: store.snapshots(playerId: playerId),
                                        matchInfos: infos, lifetime: lifetime, fetchedAt: fetchedAt, avatarSource: avatarSource)
        do { try store.saveDashboard(dashboard) } catch { throw RefreshError.storage(error.localizedDescription) }
        settings.nickname = player.nickname

        let ms = Int(Date().timeIntervalSince(started) * 1000)
        store.log(.info, "Обновлено: ELO \(player.elo ?? 0), игр \(games.count), новых матчей \(missing.count), \(ms) мс")
        return dashboard
    }

    /// Fetches `/matches/{id}` with limited concurrency (FACEIT allows ~20 req/s). Failures are
    /// tolerated: a game without match info is estimated with p = 0.5 and retried next refresh.
    private func fetchMatchInfos(_ ids: [String], playerId: String, client: FaceitAPIClient) async -> [MatchInfo] {
        var result: [MatchInfo] = []
        let chunks = stride(from: 0, to: ids.count, by: 4).map { Array(ids[$0..<min($0 + 4, ids.count)]) }
        for chunk in chunks {
            await withTaskGroup(of: MatchInfo?.self) { group in
                for id in chunk {
                    group.addTask {
                        guard let dto = try? await client.match(id: id), dto.status == nil || dto.status == "FINISHED" else { return nil }
                        return MatchInfo(dto: dto, playerId: playerId)
                    }
                }
                for await m in group { if let m { result.append(m) } }
            }
        }
        return result
    }

    /// Downloads artwork of maps played in the window that we don't have yet (once per map).
    private func downloadMapArt(games: [GameRecord], infos: [String: MatchInfo]) async {
        var urls: [String: URL] = [:]
        for info in infos.values { for (k, v) in info.mapImages ?? [:] { urls[k] = v } }
        let maps = Set(games.map(\.map)).filter { store.loadMapArt($0) == nil }
        for map in maps {
            guard let url = urls[map],
                  let (data, resp) = try? await imageSession.data(from: url),
                  (resp as? HTTPURLResponse)?.statusCode == 200, data.count < 3_000_000 else { continue }
            try? data.write(to: store.mapArtURL(map), options: .atomic)
        }
    }

    /// Rebuilds the dashboard from cached data only (no network) — after importing exact ELO history.
    @discardableResult
    public func recomputeFromCache() -> Dashboard? {
        guard var d = cachedDashboard() else { return nil }
        let pid = d.profile.playerId
        let ids = Array(Set(d.games.prefix(StatsCalculator.windowSize + 1).map(\.matchId)))
        let rebuilt = Dashboard.build(profile: d.profile, games: d.games, snapshots: store.snapshots(playerId: pid),
                                      matchInfos: store.matchInfos(playerId: pid, ids: ids), lifetime: d.lifetime,
                                      fetchedAt: d.fetchedAt, avatarSource: d.avatarSource)
        d.elo = rebuilt.elo
        try? store.saveDashboard(d)
        return d
    }

    /// Stores exact per-game ELO (from faceit.com's own stats, see `EloHistoryEntry`) as anchors.
    /// Returns how many games of the cached history received an exact value.
    @discardableResult
    public func importEloHistory(_ entries: [EloHistoryEntry]) -> Int {
        guard let d = cachedDashboard() else { return 0 }
        let pid = d.profile.playerId
        var matched = 0
        let byMatch = Dictionary(grouping: entries, by: \.matchId)
        for g in d.games {
            guard let candidates = byMatch[g.matchId], !candidates.isEmpty else { continue }
            let best = candidates.min { abs($0.date.timeIntervalSince(g.finishedAt)) < abs($1.date.timeIntervalSince(g.finishedAt)) }!
            try? store.addSnapshot(EloSnapshot(takenAt: best.date.addingTimeInterval(1), elo: best.elo,
                                               latestGameFinishedAt: g.finishedAt, latestGameId: g.id), playerId: pid)
            matched += 1
        }
        store.log(.info, "Импорт истории ELO с faceit.com: \(entries.count) записей, совпало игр \(matched)")
        recomputeFromCache()
        return matched
    }

    // MARK: Account

    /// Exact nickname lookup (case-sensitive on FACEIT), then substring search as a fallback.
    public func findPlayers(query: String) async throws -> [PlayerProfile] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        let client = self.client
        var out: [PlayerProfile] = []
        do {
            out.append(PlayerProfile(dto: try await client.player(nickname: q)))
        } catch FaceitAPIError.notFound {
        }
        let found = try await client.searchPlayers(nickname: q, limit: 10)
        for item in found where !out.contains(where: { $0.playerId == item.player_id }) {
            let level = item.games?.first { $0.name == FaceitAPIClient.game }?.skill_level?.int
            out.append(PlayerProfile(playerId: item.player_id, nickname: item.nickname,
                                     avatarURL: item.avatar.flatMap { $0.isEmpty ? nil : URL(string: $0) },
                                     country: item.country, profileURL: nil, elo: nil, skillLevel: level, region: nil))
        }
        return out
    }

    /// Links a profile and clears data of the previous one. ELO snapshots are kept per player id,
    /// so switching back to a previous account keeps its exact ELO history.
    public func link(player: PlayerProfile) {
        if settings.playerId != player.playerId { store.clearAccountData() }
        settings.playerId = player.playerId
        settings.nickname = player.nickname
        store.log(.info, "Привязан профиль \(player.nickname)")
    }

    public func unlink() {
        settings.playerId = nil
        settings.nickname = nil
        store.clearAccountData()
        store.log(.info, "Профиль отвязан")
    }

    /// Detailed per-player stats of a match (cached forever once fetched).
    public func matchStats(matchId: String) async throws -> MatchStatsDTO {
        if let s = store.matchStats(id: matchId) { return s }
        let s = try await client.matchStats(id: matchId)
        store.saveMatchStats(s, id: matchId)
        return s
    }

    public func matchInfo(matchId: String) async throws -> MatchInfo? {
        guard let pid = settings.playerId else { return nil }
        if let m = store.matchInfos(playerId: pid, ids: [matchId])[matchId] { return m }
        let m = MatchInfo(dto: try await client.match(id: matchId), playerId: pid)
        store.saveMatchInfo(m, playerId: pid)
        return m
    }
}
