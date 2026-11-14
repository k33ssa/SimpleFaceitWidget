import SwiftUI
import WidgetKit
import FaceitKit
import FaceitUI

enum DeepLink {
    static let scheme = "faceitstats"
    static var dashboard: URL { URL(string: "\(scheme)://dashboard")! }
    static func game(_ g: GameRecord) -> URL {
        var c = URLComponents()
        c.scheme = scheme; c.host = "game"; c.queryItems = [URLQueryItem(name: "id", value: g.id)]
        return c.url!
    }
}

enum AppSection: String, Hashable, CaseIterable, Identifiable {
    case overview, games, charts, settings, diagnostics
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "Обзор"
        case .games: return "Матчи"
        case .charts: return "Графики"
        case .settings: return "Настройки"
        case .diagnostics: return "Диагностика"
        }
    }
    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.67percent"
        case .games: return "list.bullet.rectangle"
        case .charts: return "chart.xyaxis.line"
        case .settings: return "gearshape"
        case .diagnostics: return "stethoscope"
        }
    }
}

@MainActor @Observable
final class AppModel {
    var dashboard: Dashboard?
    var isRefreshing = false
    var lastError: String?
    var hasAPIKey = false
    var isLinked = false
    var section: AppSection = .overview
    var openedGameId: String?
    var settings = AppSettings()

    let repo = StatsRepository.shared
    private var autoTask: Task<Void, Never>?

    init() {
        bootstrapKey()
        hasAPIKey = APIKeyStore.load() != nil
        isLinked = settings.playerId != nil
        dashboard = repo.cachedDashboard()
    }

    /// Personal builds may embed a key via Config/Secrets.xcconfig → Info.plist `FSBundledAPIKey`.
    /// It is copied once into secure storage; an explicitly saved key always wins.
    private func bootstrapKey() {
        guard APIKeyStore.load() == nil,
              let k = Bundle.main.object(forInfoDictionaryKey: "FSBundledAPIKey") as? String,
              !k.trimmingCharacters(in: .whitespaces).isEmpty, !k.hasPrefix("$(") else { return }
        APIKeyStore.save(k)
        repo.store.log(.info, "API-ключ из сборки сохранён в \(APIKeyStore.backend.rawValue)")
    }

    var windowGames: [GameRecord] { dashboard?.window ?? [] }

    func refresh(force: Bool) async {
        guard isLinked, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let outcome = try await repo.refresh(force: force)
            switch outcome {
            case .fetched(let d):
                dashboard = d
                WidgetCenter.shared.reloadAllTimelines()
            case .cached(let d):
                dashboard = d
            }
            lastError = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            dashboard = repo.cachedDashboard()
        }
    }

    /// While the app is open, refresh on the user's interval (the widgets refresh on their own).
    func startAutoRefresh() {
        autoTask?.cancel()
        autoTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(force: false)
                let minutes = self?.settings.refreshMinutes ?? AppSettings.defaultRefresh
                try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
            }
        }
    }

    func stopAutoRefresh() { autoTask?.cancel() }

    func saveKey(_ key: String) async -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Ключ пустой" }
        // Verify with one cheap request before saving.
        let probe = FaceitAPIClient(apiKey: { trimmed }, maxAttempts: 2)
        do {
            _ = try await probe.searchPlayers(nickname: "faceit", limit: 1)
        } catch let e as FaceitAPIError {
            if case .invalidAPIKey = e { return e.errorDescription }
            if case .forbidden = e { return e.errorDescription }
            // Network problems: save anyway, the key may be fine.
        } catch {}
        let backend = APIKeyStore.save(trimmed)
        repo.store.log(.info, "API-ключ сохранён (\(backend.rawValue))")
        hasAPIKey = true
        return nil
    }

    func deleteKey() {
        APIKeyStore.delete()
        hasAPIKey = false
        repo.store.log(.info, "API-ключ удалён")
    }

    func link(_ player: PlayerProfile) async {
        repo.link(player: player)
        isLinked = true
        dashboard = nil
        await refresh(force: true)
        WidgetCenter.shared.reloadAllTimelines()
    }

    func unlink() {
        repo.unlink()
        isLinked = false
        dashboard = nil
        WidgetCenter.shared.reloadAllTimelines()
    }

    func setRefreshMinutes(_ m: Int) {
        settings.refreshMinutes = m
        WidgetCenter.shared.reloadAllTimelines()
        startAutoRefresh()
    }

    func handle(url: URL) {
        guard url.scheme == DeepLink.scheme else { return }
        switch url.host {
        case "game":
            let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
            section = .games
            openedGameId = id
        default:
            section = .overview
        }
    }

    func game(id: String) -> GameRecord? { dashboard?.games.first { $0.id == id } }

    func reloadFromCache() {
        dashboard = repo.cachedDashboard()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
