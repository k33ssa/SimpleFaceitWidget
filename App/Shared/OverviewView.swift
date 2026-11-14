import SwiftUI
import FaceitKit
import FaceitUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let error = model.lastError ?? model.dashboard?.lastError {
                    ErrorBanner(text: error)
                }
                if let d = model.dashboard {
                    HeroCard(d: d)
                    StatsGrid(d: d)
                    EloCoverageCard(d: d)
                    if let l = d.lifetime { LifetimeCard(l: l) }
                } else if model.isRefreshing {
                    ProgressView("Загружаю статистику…").frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    ContentUnavailableView("Нет данных", systemImage: "chart.bar.xaxis",
                                           description: Text("Нажми «Обновить», чтобы загрузить статистику."))
                }
            }
            .padding(20)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.inkDark)
        .navigationTitle("Обзор")
        .toolbar { ToolbarItem { RefreshButton() } }
        .refreshable { await model.refresh(force: true) }
    }
}

struct ErrorBanner: View {
    let text: String
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(hex: 0xF4A100))
            VStack(alignment: .leading, spacing: 4) {
                Text("Последнее обновление не удалось").font(.system(size: 13, weight: .bold))
                Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Button("Диагностика") { model.section = .diagnostics }.font(.system(size: 12, weight: .semibold))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0xF4A100).opacity(0.12)))
    }
}

struct HeroCard: View {
    let d: Dashboard
    @Environment(AppModel.self) private var model

    var mapArt: Image? { d.games.first.flatMap { model.repo.store.loadMapArt($0.map) }.flatMap { Image(data: $0, maxPixel: 1600) } }
    var avatar: Image? { model.repo.store.loadAvatar().flatMap { Image(data: $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Group { if let a = avatar { a.resizable().scaledToFill() } else { Color.white.opacity(0.1) } }
                    .frame(width: 44, height: 44).clipShape(Circle())
                    .overlay(Circle().stroke(Theme.level(d.profile.skillLevel), lineWidth: 2))
                VStack(alignment: .leading, spacing: 3) {
                    Text(d.profile.nickname).font(.system(size: 20, weight: .heavy).width(.expanded))
                    Caps([d.profile.country?.uppercased(), d.regionCaps.map { "рейтинг " + $0 } ?? d.profile.region, "lvl \(d.profile.skillLevel ?? 0)"].compactMap { $0 }.joined(separator: " · "),
                         color: Theme.level(d.profile.skillLevel))
                }
                Spacer()
                if let url = d.profile.profileURL {
                    Link(destination: url) { Image(systemName: "arrow.up.right.square").font(.system(size: 18)) }
                        .help("Профиль на faceit.com")
                }
            }
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(Fmt.elo(d.profile.elo))
                        .font(Theme.hero(120)).monospacedDigit()
                        .contentTransition(.numericText(value: Double(d.profile.elo ?? 0)))
                        .frame(height: 104)
                    HStack(spacing: 10) {
                        DeltaChip(elo: d.elo, size: 15, suffix: "за \(d.elo.windowGames) игр")
                        if let n = LevelRanges.toNext(elo: d.profile.elo, level: d.profile.skillLevel) {
                            Caps("до lvl \((d.profile.skillLevel ?? 0) + 1) — \(n)", size: 10.5)
                        }
                    }
                }
                Spacer()
                ZStack {
                    LevelGauge(level: d.profile.skillLevel, elo: d.profile.elo, lineWidth: 9)
                    VStack(spacing: 2) {
                        Text("\(d.profile.skillLevel ?? 0)").font(Theme.wide(34, weight: .black))
                        Caps("level")
                    }
                }
                .frame(width: 130, height: 130)
            }
            .padding(.top, 18)
            HStack {
                Caps("\(d.summary.wins) W — \(d.summary.losses) L · старые → новые")
                Spacer()
                Caps("обновлено \(Fmt.updated(d.fetchedAt))")
            }
            .padding(.top, 22).padding(.bottom, 8)
            HStack(spacing: 4) {
                ForEach(d.strip) { g in
                    Button { model.section = .games; model.openedGameId = g.id } label: {
                        SlantedBar().fill(g.isWin ? Theme.win(.dark) : Theme.loss(.dark))
                            .opacity(g.id == d.games.first?.id ? 1 : 0.8)
                            .frame(height: 26)
                    }
                    .buttonStyle(.plain)
                    .help("\(g.mapName) \(g.teamScore ?? 0):\(g.opponentScore ?? 0) · \(g.kills)-\(g.deaths)")
                }
            }
        }
        .padding(24)
        .background {
            MapBackdrop(image: mapArt).environment(\.colorScheme, .dark)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

struct StatsGrid: View {
    let d: Dashboard
    let cols = [GridItem(.adaptive(minimum: 150), spacing: 12)]
    var body: some View {
        LazyVGrid(columns: cols, spacing: 12) {
            Tile(label: "win rate", value: Fmt.percent(d.summary.winRate), unit: "%", note: "\(d.summary.wins) W · \(d.summary.losses) L")
            Tile(label: "k/d", value: Fmt.ratio(d.summary.kd), note: "Σ убийств / Σ смертей")
            Tile(label: "headshots", value: Fmt.percent(d.summary.headshotPercent), unit: "%", note: "доля убийств в голову")
            Tile(label: "adr", value: Fmt.one(d.summary.adr), note: d.summary.adrGames < d.summary.games ? "по \(d.summary.adrGames) из \(d.summary.games) игр" : "урон за раунд")
            Tile(label: "avg kills", value: Fmt.one(d.summary.avgKills), note: "за карту")
            Tile(label: "avg deaths", value: Fmt.one(d.summary.avgDeaths), note: "за карту")
            Tile(label: "rating 1.0", value: Fmt.ratio(d.summary.rating), note: "формула HLTV 1.0")
            Tile(label: "kpr", value: Fmt.ratio(d.summary.kpr), note: "убийств за раунд")
        }
    }
}

struct Tile: View {
    let label: String
    let value: String
    var unit: String? = nil
    var note: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Caps(label)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value).font(Theme.value(32)).monospacedDigit()
                if let unit, value != "—" { Text(unit).font(Theme.value(18)) }
            }
            if let note { Text(note).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.05)))
    }
}

struct EloCoverageCard: View {
    let d: Dashboard
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caps("точность изменения elo")
            if d.elo.changeIsExact {
                Text("Изменение за \(d.elo.windowGames) игр точное: ELO по каждому матчу взят из статистики faceit.com и сохранённых снимков.")
                    .font(.system(size: 13))
                if let adj = d.elo.offMatchAdjustment {
                    Text("Из них \(Fmt.signed(adj)) — изменение вне матчей (например, возврат ELO за матч с нарушителем).")
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                }
            } else {
                Text("Официальный API FACEIT не отдаёт ELO по матчам. Точно известно \(d.elo.observedGames) из \(d.elo.windowGames) игр (по снимкам ELO, которые приложение сохраняет при каждом обновлении); остальное — оценка по шансу на победу (≈). Можно подтянуть точную историю с faceit.com в настройках.")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.75))
                Button("Загрузить точную историю ELO") { model.section = .settings }
                    .font(.system(size: 13, weight: .semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.04)))
    }
}

struct LifetimeCard: View {
    let l: LifetimeSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Caps("за всё время (faceit lifetime)")
            HStack(spacing: 28) {
                mini("матчи", l.matches.map(String.init) ?? "—")
                mini("win rate", l.winRate.map { "\(Int($0))%" } ?? "—")
                mini("k/d", Fmt.ratio(l.kd))
                mini("hs", l.headshotPercent.map { "\(Int($0))%" } ?? "—")
                mini("adr", Fmt.one(l.adr))
                mini("лучшая серия", l.longestWinStreak.map(String.init) ?? "—")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.04)))
    }
    func mini(_ l: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 3) { Caps(l, size: 8.5); Text(v).font(Theme.value(18)).monospacedDigit() }
    }
}
