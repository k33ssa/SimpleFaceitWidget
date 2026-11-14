import Foundation
import WebKit
import FaceitKit

/// Automatic exact-ELO sync (UNOFFICIAL source, see `EloHistoryEntry`).
///
/// An off-screen WebKit view opens the player's faceit.com page — a normal browser session — and runs the same
/// request the site's own frontend makes (`/api/stats/v1/stats/time/users/{id}/games/cs2`). Verified 14.11.2026:
/// returns 200 with `matchId` (Data API format), `elo` (after the match), `elo_delta`, `date`.
/// Plain URLSession requests get Cloudflare 403; nothing here spoofs or bypasses anything — if the site ever
/// requires an interactive check, the sync fails quietly and the manual sheet (Settings) shows the page.
/// Widgets can't run WebKit; they read the stored exact values from the shared database.
@MainActor
final class EloWebSync: NSObject, WKNavigationDelegate {
    static let shared = EloWebSync()

    private var web: WKWebView?
    private var loadedNick: String?
    private var pageReady: CheckedContinuation<Void, Never>?
    private var running = false

    private let lastSyncKey = "eloWebSyncAt"

    var lastSync: Date? { AppGroup.defaults.object(forKey: lastSyncKey) as? Date }

    /// Runs at most once per refresh interval unless `force`. Returns how many cached games got an exact ELO.
    @discardableResult
    func syncIfNeeded(repo: StatsRepository, force: Bool = false) async -> Int? {
        let settings = AppSettings()
        guard !running, let pid = settings.playerId, let nick = repo.cachedDashboard()?.profile.nickname else { return nil }
        if !force, let last = lastSync, Date().timeIntervalSince(last) < settings.refreshInterval * 0.9 { return nil }
        running = true
        defer { running = false }

        do {
            if loadedNick != nick || web == nil { try await loadPage(nick: nick) }
            let body = try await fetchHistory(pid: pid)
            let entries = EloHistoryEntry.parse(Data(body.utf8))
            guard !entries.isEmpty else {
                repo.store.log(.warning, "Точный ELO с faceit.com: пустой или непонятный ответ")
                return 0
            }
            let matched = repo.importEloHistory(entries)
            AppGroup.defaults.set(Date(), forKey: lastSyncKey)
            return matched
        } catch {
            repo.store.log(.warning, "Точный ELO с faceit.com не получен: \(error.localizedDescription)")
            loadedNick = nil
            return nil
        }
    }

    private func loadPage(nick: String) async throws {
        let w = web ?? WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: {
            let c = WKWebViewConfiguration()
            c.websiteDataStore = .default()   // shared with the manual sheet: one human check (if ever) is remembered
            return c
        }())
        w.navigationDelegate = self
        web = w
        let escaped = nick.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? nick
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            pageReady = c
            w.load(URLRequest(url: URL(string: "https://www.faceit.com/en/players/\(escaped)/stats/cs2")!))
            // Never hang: give up waiting for didFinish after 20 s.
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.resumeReady() }
        }
        try await Task.sleep(nanoseconds: 2_000_000_000)   // let the page settle its own session
        loadedNick = nick
    }

    private func resumeReady() {
        pageReady?.resume()
        pageReady = nil
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.resumeReady() }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.resumeReady() }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.resumeReady() }
    }

    private func fetchHistory(pid: String) async throws -> String {
        guard let web else { throw URLError(.cancelled) }
        let js = """
        const r = await fetch(`/api/stats/v1/stats/time/users/${pid}/games/cs2?page=0&size=100`,
                              { credentials: 'include', headers: { accept: 'application/json' } });
        const t = await r.text();
        return JSON.stringify({ status: r.status, body: t });
        """
        let raw = try await web.callAsyncJavaScript(js, arguments: ["pid": pid], contentWorld: .defaultClient) as? String ?? ""
        struct R: Decodable { let status: Int; let body: String }
        guard let r = try? JSONDecoder().decode(R.self, from: Data(raw.utf8)) else { throw URLError(.cannotParseResponse) }
        guard r.status == 200 else { throw NSError(domain: "faceit.com", code: r.status, userInfo: [NSLocalizedDescriptionKey: "HTTP \(r.status)"]) }
        return r.body
    }
}
