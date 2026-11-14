import SwiftUI
import FaceitKit
import FaceitUI

struct GamesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let games = model.dashboard?.games ?? []
        List {
            Section {
                ForEach(games.prefix(StatsCalculator.windowSize)) { g in
                    NavigationLink(value: g.id) { GameRow(g: g, elo: model.dashboard?.eloPoint(for: g)) }
                }
            } header: { Caps("последние 20 · от новых к старым") }
            if games.count > StatsCalculator.windowSize {
                Section {
                    ForEach(games.dropFirst(StatsCalculator.windowSize)) { g in
                        NavigationLink(value: g.id) { GameRow(g: g, elo: nil) }
                    }
                } header: { Caps("ранее") }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.inkDark)
        .navigationTitle("Матчи")
        .navigationDestination(for: String.self) { id in
            if let g = model.game(id: id) { GameDetailView(g: g) }
        }
        .navigationDestination(item: $model.openedGameId) { id in
            if let g = model.game(id: id) { GameDetailView(g: g) } else { Text("Матч не найден в кэше") }
        }
        .toolbar { ToolbarItem { RefreshButton() } }
        .refreshable { await model.refresh(force: true) }
    }
}


struct GameRow: View {
    let g: GameRecord
    let elo: EloGamePoint?

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(g.isWin ? Theme.win(.dark) : Theme.loss(.dark)).frame(width: 4, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(g.mapName).font(.system(size: 15, weight: .bold))
                    Text("\(g.teamScore.map(String.init) ?? "?"):\(g.opponentScore.map(String.init) ?? "?")")
                        .font(Theme.value(15)).monospacedDigit()
                        .foregroundStyle(g.isWin ? Theme.win(.dark) : Theme.loss(.dark))
                }
                Caps(g.finishedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Locale(identifier: "ru_RU"))))
            }
            Spacer()
            stat("k-d-a", "\(g.kills)-\(g.deaths)-\(g.assists)")
            stat("adr", Fmt.one(g.adr))
            stat("rtg", Fmt.ratio(Rating.hltv1(g)))
            if let elo {
                VStack(alignment: .trailing, spacing: 2) {
                    Caps("elo")
                    Text((elo.source == .exact ? "" : "≈") + Fmt.signed(elo.delta))
                        .font(Theme.value(15)).monospacedDigit()
                        .foregroundStyle(elo.delta > 0 ? Theme.win(.dark) : (elo.delta < 0 ? Theme.loss(.dark) : .white.opacity(0.5)))
                }
                .frame(width: 54, alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
    }

    func stat(_ l: String, _ v: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Caps(l, size: 8.5)
            Text(v).font(Theme.value(14)).monospacedDigit()
        }
        .frame(minWidth: 44, alignment: .trailing)
    }
}

struct GameDetailView: View {
    let g: GameRecord
    @Environment(AppModel.self) private var model
    @State private var stats: MatchStatsDTO?
    @State private var info: MatchInfo?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                playerBlock
                if let mine = myStats { extendedBlock(mine) }
                if let round = round { scoreboard(round) }
                if let error { ErrorBanner(text: error) }
            }
            .padding(20)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.inkDark)
        .navigationTitle(g.mapName)
        .task(id: g.id) { await load() }
    }

    var round: RoundStatsDTO? {
        stats?.rounds.first { ($0.match_round.flatMap(Int.init) ?? 1) == g.matchRound } ?? stats?.rounds.first
    }

    var myStats: [String: JSONValue]? {
        guard let pid = model.dashboard?.profile.playerId else { return nil }
        return round?.teams.flatMap(\.players).first { $0.player_id == pid }?.player_stats
    }

    func load() async {
        do {
            async let s = model.repo.matchStats(matchId: g.matchId)
            async let i = model.repo.matchInfo(matchId: g.matchId)
            stats = try await s
            info = try await i
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    var header: some View {
        let art = model.repo.store.loadMapArt(g.map).flatMap { Image(data: $0, maxPixel: 1600) }
        let elo = model.dashboard?.eloPoint(for: g)
        return VStack(alignment: .leading, spacing: 8) {
            Caps([g.finishedAt.formatted(.dateTime.day().month(.wide).year().hour().minute().locale(Locale(identifier: "ru_RU"))),
                  info?.competitionName].compactMap { $0 }.joined(separator: " · "))
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(g.isWin ? "ПОБЕДА" : "ПОРАЖЕНИЕ")
                    .font(Theme.wide(26, weight: .black))
                    .foregroundStyle(g.isWin ? Theme.win(.dark) : Theme.loss(.dark))
                Text("\(g.teamScore.map(String.init) ?? "?") : \(g.opponentScore.map(String.init) ?? "?")")
                    .font(Theme.hero(52)).monospacedDigit()
            }
            if let elo {
                HStack(spacing: 8) {
                    Text("ELO \(Fmt.signed(elo.delta)) → \(elo.eloAfter)").font(Theme.value(18)).monospacedDigit()
                    Caps(sourceText(elo.source))
                }
            }
            HStack(spacing: 16) {
                if let p = info?.playerWinProbability { Caps("шанс победы до матча \(Int((p * 100).rounded()))%") }
                if let a = info?.playerTeamAvgElo, let b = info?.opponentTeamAvgElo { Caps("рейтинг команд \(a) vs \(b)") }
            }
            if let url = info?.faceitURL {
                Link("Комната матча на faceit.com", destination: url).font(.system(size: 13, weight: .semibold))
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { MapBackdrop(image: art).environment(\.colorScheme, .dark) }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    func sourceText(_ s: EloSource) -> String {
        switch s {
        case .exact: return "точно (по снимкам elo)"
        case .constrained: return "сумма точная, раскладка по играм — оценка"
        case .estimated: return "оценка по шансу на победу"
        case .unrated: return "матч без изменения elo"
        }
    }

    var playerBlock: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
            Tile(label: "kills", value: "\(g.kills)")
            Tile(label: "deaths", value: "\(g.deaths)")
            Tile(label: "assists", value: "\(g.assists)")
            Tile(label: "k/d", value: Fmt.ratio(g.kdRatio))
            Tile(label: "k/r", value: Fmt.ratio(g.krRatio))
            Tile(label: "hs", value: Fmt.percent(g.headshotPercent), unit: "%")
            Tile(label: "adr", value: Fmt.one(g.adr))
            Tile(label: "rating 1.0", value: Fmt.ratio(Rating.hltv1(g)))
            Tile(label: "mvp", value: g.mvps.map(String.init) ?? "—")
            Tile(label: "2k / 3k", value: "\(g.doubleKills.map(String.init) ?? "—") / \(g.tripleKills.map(String.init) ?? "—")")
            Tile(label: "4k / 5k", value: "\(g.quadroKills.map(String.init) ?? "—") / \(g.pentaKills.map(String.init) ?? "—")")
            Tile(label: "раунды", value: g.rounds.map(String.init) ?? "—")
        }
    }

    /// Extended per-match keys exist only in `GET /matches/{id}/stats` (names confirmed in our recorded response).
    func extendedBlock(_ s: [String: JSONValue]) -> some View {
        let rows: [(String, String)] = [
            ("first kills", s.string("First Kills") ?? "—"),
            ("entry", "\(s.string("Entry Wins") ?? "—")/\(s.string("Entry Count") ?? "—")"),
            ("клатчи 1v1", "\(s.string("1v1Wins") ?? "—")/\(s.string("1v1Count") ?? "—")"),
            ("клатчи 1v2", "\(s.string("1v2Wins") ?? "—")/\(s.string("1v2Count") ?? "—")"),
            ("урон гранатами", s.string("Utility Damage") ?? "—"),
            ("ослеплено", s.string("Enemies Flashed") ?? "—"),
            ("снайпер", s.string("Sniper Kills") ?? "—"),
            ("пистолет", s.string("Pistol Kills") ?? "—"),
        ]
        return VStack(alignment: .leading, spacing: 10) {
            Caps("подробно (faceit match stats)")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                ForEach(rows, id: \.0) { Tile(label: $0.0, value: $0.1) }
            }
        }
    }

    func scoreboard(_ r: RoundStatsDTO) -> some View {
        let pid = model.dashboard?.profile.playerId
        return VStack(alignment: .leading, spacing: 14) {
            Caps("составы")
            ForEach(r.teams, id: \.team_id) { t in
                VStack(spacing: 0) {
                    HStack {
                        Text(t.team_stats?.string("Team") ?? "Команда").font(.system(size: 13, weight: .bold))
                        Spacer()
                        Text(t.team_stats?.string("Final Score") ?? "").font(Theme.value(18))
                    }
                    .padding(.bottom, 8)
                    ForEach(t.players.sorted { ($0.player_stats.int("Kills") ?? 0) > ($1.player_stats.int("Kills") ?? 0) }, id: \.player_id) { p in
                        let s = p.player_stats
                        HStack {
                            Text(p.nickname).font(.system(size: 13, weight: p.player_id == pid ? .heavy : .regular))
                                .foregroundStyle(p.player_id == pid ? Theme.orangeBright : .white)
                            Spacer()
                            Group {
                                Text("\(s.string("Kills") ?? "—")-\(s.string("Deaths") ?? "—")-\(s.string("Assists") ?? "—")").frame(width: 70, alignment: .trailing)
                                Text(s.string("K/D Ratio") ?? "—").frame(width: 40, alignment: .trailing)
                                Text(s.string("ADR") ?? "—").frame(width: 46, alignment: .trailing)
                                Text((s.string("Headshots %") ?? "—") + "%").frame(width: 42, alignment: .trailing)
                            }
                            .font(.system(size: 12, weight: .semibold).width(.condensed)).monospacedDigit()
                        }
                        .padding(.vertical, 5)
                        Divider().opacity(0.3)
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.04)))
            }
        }
    }
}
