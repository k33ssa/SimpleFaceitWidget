import Foundation

/// Everything the app and widgets persist, in the shared container:
///   • `faceit.sqlite` — ELO snapshots, cached match info / match stats, diagnostics log;
///   • `dashboard.json` — the last computed `Dashboard` (what widgets render);
///   • `avatar.img` — the player's avatar bytes (widgets cannot load remote images).
public final class LocalStore: @unchecked Sendable {
    public static let shared: LocalStore = {
        do { return try LocalStore(directory: AppGroup.dataDirectory) }
        catch { fatalError("Cannot open local store: \(error)") }
    }()

    let db: SQLiteDB
    public let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        db = try SQLiteDB(url: directory.appendingPathComponent("faceit.sqlite"))
        try db.exec("""
        CREATE TABLE IF NOT EXISTS elo_snapshot(
            player_id TEXT NOT NULL, taken_at REAL NOT NULL, elo INTEGER NOT NULL,
            latest_game_id TEXT, latest_finished REAL);
        CREATE INDEX IF NOT EXISTS elo_snapshot_player ON elo_snapshot(player_id, taken_at);
        CREATE TABLE IF NOT EXISTS match_info(
            match_id TEXT NOT NULL, player_id TEXT NOT NULL, json BLOB NOT NULL, fetched_at REAL NOT NULL,
            PRIMARY KEY(match_id, player_id));
        CREATE TABLE IF NOT EXISTS match_stats(
            match_id TEXT PRIMARY KEY, json BLOB NOT NULL, fetched_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS log(
            id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, level TEXT NOT NULL, source TEXT NOT NULL, message TEXT NOT NULL);
        """)
    }

    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }()
    private let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()

    // MARK: Dashboard

    var dashboardURL: URL { directory.appendingPathComponent("dashboard.json") }
    public var avatarURL: URL { directory.appendingPathComponent("avatar.img") }

    public func loadDashboard() -> Dashboard? {
        guard let data = try? Data(contentsOf: dashboardURL) else { return nil }
        return try? decoder.decode(Dashboard.self, from: data)
    }

    public func saveDashboard(_ d: Dashboard) throws {
        try encoder.encode(d).write(to: dashboardURL, options: .atomic)
    }

    public func clearAccountData() {
        try? FileManager.default.removeItem(at: dashboardURL)
        try? FileManager.default.removeItem(at: avatarURL)
    }

    public func loadAvatar() -> Data? { try? Data(contentsOf: avatarURL) }

    /// Local copy of a map's artwork ("de_mirage" → maps/de_mirage.img). Widgets read it directly.
    public func mapArtURL(_ map: String) -> URL {
        let dir = directory.appendingPathComponent("maps", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = map.filter { $0.isLetter || $0.isNumber || $0 == "_" }
        return dir.appendingPathComponent("\(safe).img")
    }

    public func loadMapArt(_ map: String) -> Data? { try? Data(contentsOf: mapArtURL(map)) }
    public func saveAvatar(_ data: Data) { try? data.write(to: avatarURL, options: .atomic) }

    // MARK: ELO snapshots

    public func addSnapshot(_ s: EloSnapshot, playerId: String) throws {
        // Skip exact duplicates of the latest snapshot to keep the table small,
        // but always move its timestamp forward (proves the value is still current).
        if let last = snapshots(playerId: playerId, limit: 1).first,
           last.elo == s.elo, last.latestGameId == s.latestGameId {
            try db.run("UPDATE elo_snapshot SET taken_at=? WHERE player_id=? AND taken_at=?",
                       [.double(s.takenAt.timeIntervalSince1970), .text(playerId), .double(last.takenAt.timeIntervalSince1970)])
            return
        }
        try db.run("INSERT INTO elo_snapshot(player_id, taken_at, elo, latest_game_id, latest_finished) VALUES(?,?,?,?,?)", [
            .text(playerId), .double(s.takenAt.timeIntervalSince1970), .int(Int64(s.elo)),
            s.latestGameId.map { .text($0) } ?? .null,
            s.latestGameFinishedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
        ])
    }

    /// Newest first.
    public func snapshots(playerId: String, limit: Int = 5000) -> [EloSnapshot] {
        let rows = (try? db.query(
            "SELECT taken_at, elo, latest_game_id, latest_finished FROM elo_snapshot WHERE player_id=? ORDER BY taken_at DESC LIMIT ?",
            [.text(playerId), .int(Int64(limit))])) ?? []
        return rows.compactMap { r in
            guard let t = r[0].double, let e = r[1].int else { return nil }
            return EloSnapshot(takenAt: Date(timeIntervalSince1970: t), elo: e, latestGameId: r[2].text,
                               latestFinished: r[3].double.map { Date(timeIntervalSince1970: $0) })
        }
    }

    // MARK: Match info / stats cache (immutable once a match is finished)

    public func matchInfos(playerId: String, ids: [String]) -> [String: MatchInfo] {
        guard !ids.isEmpty else { return [:] }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let rows = (try? db.query("SELECT json FROM match_info WHERE player_id=? AND match_id IN (\(marks))",
                                  [.text(playerId)] + ids.map { .text($0) })) ?? []
        var out: [String: MatchInfo] = [:]
        for r in rows {
            if let d = r[0].blob, let m = try? decoder.decode(MatchInfo.self, from: d) { out[m.matchId] = m }
        }
        return out
    }

    public func saveMatchInfo(_ m: MatchInfo, playerId: String) {
        guard let d = try? encoder.encode(m) else { return }
        _ = try? db.run("INSERT OR REPLACE INTO match_info(match_id, player_id, json, fetched_at) VALUES(?,?,?,?)",
                        [.text(m.matchId), .text(playerId), .blob(d), .double(Date().timeIntervalSince1970)])
    }

    public func matchStats(id: String) -> MatchStatsDTO? {
        guard let row = (try? db.query("SELECT json FROM match_stats WHERE match_id=?", [.text(id)]))?.first,
              let d = row[0].blob else { return nil }
        return try? JSONDecoder().decode(MatchStatsDTO.self, from: d)
    }

    public func saveMatchStats(_ s: MatchStatsDTO, id: String) {
        guard let d = try? JSONEncoder().encode(s) else { return }
        _ = try? db.run("INSERT OR REPLACE INTO match_stats(match_id, json, fetched_at) VALUES(?,?,?)",
                        [.text(id), .blob(d), .double(Date().timeIntervalSince1970)])
    }

    // MARK: Diagnostics log (ring buffer)

    public enum LogLevel: String, Sendable { case info, warning, error }

    public struct LogEntry: Identifiable, Hashable, Sendable {
        public let id: Int
        public let date: Date
        public let level: String
        public let source: String
        public let message: String
    }

    public func log(_ level: LogLevel, _ message: String, source: String = ProcessKind.current.rawValue) {
        _ = try? db.run("INSERT INTO log(ts, level, source, message) VALUES(?,?,?,?)",
                        [.double(Date().timeIntervalSince1970), .text(level.rawValue), .text(source), .text(message)])
        _ = try? db.run("DELETE FROM log WHERE id <= (SELECT MAX(id) FROM log) - 600")
    }

    public func logEntries(limit: Int = 300) -> [LogEntry] {
        let rows = (try? db.query("SELECT id, ts, level, source, message FROM log ORDER BY id DESC LIMIT ?", [.int(Int64(limit))])) ?? []
        return rows.compactMap { r in
            guard let id = r[0].int, let ts = r[1].double else { return nil }
            return LogEntry(id: id, date: Date(timeIntervalSince1970: ts), level: r[2].text ?? "", source: r[3].text ?? "", message: r[4].text ?? "")
        }
    }

    public func clearLog() { _ = try? db.run("DELETE FROM log") }

    public func wipeAll() {
        _ = try? db.run("DELETE FROM elo_snapshot")
        _ = try? db.run("DELETE FROM match_info")
        _ = try? db.run("DELETE FROM match_stats")
        clearAccountData()
    }
}

private extension EloSnapshot {
    init(takenAt: Date, elo: Int, latestGameId: String?, latestFinished: Date?) {
        self.init(takenAt: takenAt, elo: elo, latestGameFinishedAt: latestFinished, latestGameId: latestGameId)
    }
}

/// Which process wrote a log line.
public enum ProcessKind: String, Sendable {
    case app, widget, tool
    public static var current: ProcessKind {
        let path = Bundle.main.bundlePath
        if path.hasSuffix(".appex") { return .widget }
        if path.hasSuffix(".app") { return .app }
        return .tool
    }
}
