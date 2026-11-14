#if os(macOS)
import SwiftUI
import ServiceManagement
import FaceitKit
import FaceitUI

/// Menu-bar presence: keeps the app alive with its window closed so it can keep syncing — including the exact
/// per-match ELO from faceit.com, which only works inside WebKit (widgets can't host it). Widgets then read exact
/// values from the shared database.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let d = model.dashboard {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Fmt.elo(d.profile.elo)).font(Theme.hero(44)).monospacedDigit()
                    DeltaChip(elo: d.elo, size: 12, suffix: "за \(d.elo.windowGames)")
                }
                ResultStrip(games: d.strip, height: 12, spacing: 2)
                HStack(spacing: 14) {
                    Caps("wr \(Fmt.percent(d.summary.winRate))%")
                    Caps("k/d \(Fmt.ratio(d.summary.kd))")
                    Caps("adr \(Fmt.one(d.summary.adr))")
                }
                Caps("обновлено \(Fmt.updated(d.fetchedAt))" + (d.elo.changeIsExact ? " · elo точный" : " · elo ≈"))
            } else {
                Text("Нет данных").font(.system(size: 13, weight: .semibold))
            }
            Divider()
            HStack {
                Button("Открыть") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }
                Button(model.isRefreshing ? "Обновляю…" : "Обновить") { Task { await model.refresh(force: true) } }
                    .disabled(model.isRefreshing)
                Spacer()
                Button("Выйти") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 300)
        .environment(\.colorScheme, .dark)
        .background(Theme.inkDark)
    }
}

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let elo = model.dashboard?.profile.elo {
            Text("\(elo)").monospacedDigit()
        } else {
            Image(systemName: "gauge.with.dots.needle.67percent")
        }
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            LocalStore.shared.log(.warning, "Автозапуск: \(error.localizedDescription)")
        }
    }

    /// Enabled once on first launch (the app is useful mainly in the background); the user can turn it off.
    static func enableOnFirstLaunch() {
        let key = "loginItemInitialized"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        set(true)
    }
}
#endif
