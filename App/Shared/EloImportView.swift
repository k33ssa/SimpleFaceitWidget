import SwiftUI
import WebKit
import FaceitKit
import FaceitUI

/// Loads faceit.com in a WebKit view (the user's own browser session) and asks the site's own stats
/// endpoint for per-match ELO — exactly the request the faceit.com frontend makes. Nothing is bypassed:
/// if the site shows a check, the user completes it in the visible page and presses "Повторить".
struct EloImportView: View {
    var onClose: () -> Void
    @Environment(AppModel.self) private var model
    @State private var status = "Открываю faceit.com…"
    @State private var busy = false
    @State private var done = false
    @State private var webView = WKWebView(frame: .zero, configuration: {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = .default()
        return c
    }())

    var profileURL: URL {
        let nick = model.dashboard?.profile.nickname ?? model.settings.nickname ?? ""
        return URL(string: "https://www.faceit.com/en/players/\(nick.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? nick)/stats/cs2")!
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    if busy { ProgressView().controlSize(.small) }
                    Text(status).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Повторить") { Task { await fetch() } }.disabled(busy)
                }
                .padding(12)
                .background(.white.opacity(0.05))
                WebViewHost(webView: webView, url: profileURL, onLoaded: { Task { await fetch() } })
            }
            .navigationTitle("История ELO с faceit.com")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(done ? "Готово" : "Закрыть", action: onClose) } }
        }
    }

    @MainActor func fetch() async {
        guard let pid = model.settings.playerId, !busy else { return }
        busy = true
        defer { busy = false }
        status = "Запрашиваю историю ELO…"
        let js = """
        const urls = [
          `/api/stats/v1/stats/time/users/${pid}/games/cs2?page=0&size=100`,
          `https://api.faceit.com/stats/v1/stats/time/users/${pid}/games/cs2?page=0&size=100`
        ];
        for (const u of urls) {
          try {
            const r = await fetch(u, { credentials: 'include', headers: { 'accept': 'application/json' } });
            const t = await r.text();
            if (r.ok && t.trim().startsWith('[')) return JSON.stringify({ ok: true, status: r.status, body: t });
            var last = JSON.stringify({ ok: false, status: r.status, body: t.slice(0, 200) });
          } catch (e) { var last = JSON.stringify({ ok: false, status: 0, body: String(e) }); }
        }
        return last;
        """
        do {
            let raw = try await webView.callAsyncJavaScript(js, arguments: ["pid": pid], contentWorld: .defaultClient) as? String ?? ""
            struct R: Decodable { let ok: Bool; let status: Int; let body: String }
            guard let r = try? JSONDecoder().decode(R.self, from: Data(raw.utf8)) else {
                status = "Непонятный ответ сайта. Если на странице проверка — пройди её и нажми «Повторить»."
                return
            }
            guard r.ok else {
                status = "Сайт ответил \(r.status). Если на странице проверка или вход — пройди и нажми «Повторить»."
                model.repo.store.log(.warning, "История ELO с faceit.com: HTTP \(r.status)")
                return
            }
            let entries = EloHistoryEntry.parse(Data(r.body.utf8))
            let matched = model.repo.importEloHistory(entries)
            model.reloadFromCache()
            done = true
            status = "Готово: \(entries.count) записей ELO, совпало с \(matched) играми. Изменение за 20 игр пересчитано."
        } catch {
            status = "Страница ещё не готова (\(error.localizedDescription)). Нажми «Повторить»."
        }
    }
}

#if os(macOS)
struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    let url: URL
    let onLoaded: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onLoaded: onLoaded) }
    func makeNSView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView
    let url: URL
    let onLoaded: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onLoaded: onLoaded) }
    func makeUIView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif

final class Coordinator: NSObject, WKNavigationDelegate {
    let onLoaded: () -> Void
    private var fired = false
    init(onLoaded: @escaping () -> Void) { self.onLoaded = onLoaded }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Only on the real site (not on an interstitial check page).
        guard !fired, let host = webView.url?.host, host.hasSuffix("faceit.com"),
              !(webView.title ?? "").isEmpty else { return }
        fired = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.onLoaded() }
    }
}
