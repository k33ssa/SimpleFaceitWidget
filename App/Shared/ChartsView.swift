import SwiftUI
import Charts
import FaceitKit
import FaceitUI

struct ChartsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let d = model.dashboard {
                    EloChart(d: d)
                    let rolling = StatsCalculator.rolling(d.games)
                    if rolling.isEmpty {
                        Text("Для истории нужно больше 20 игр.").foregroundStyle(.white.opacity(0.5))
                    } else {
                        RollingChart(title: "win rate · скользящие 20 игр", unit: "%", points: rolling, value: \.winRate, color: Theme.win(.dark), domain: 0...100)
                        RollingChart(title: "k/d · скользящие 20 игр", unit: "", points: rolling, value: \.kd, color: Theme.orangeBright, domain: nil)
                        RollingChart(title: "headshots % · скользящие 20 игр", unit: "%", points: rolling, value: \.headshotPercent, color: Color(hex: 0x66A7FF), domain: nil)
                        RollingChart(title: "adr · скользящие 20 игр", unit: "", points: rolling, value: \.adr, color: Color(hex: 0xD357FE), domain: nil)
                    }
                    SnapshotHistory(playerId: d.profile.playerId)
                }
            }
            .padding(20)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.inkDark)
        .navigationTitle("Графики")
        .toolbar { ToolbarItem { RefreshButton() } }
    }
}

struct ChartCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Caps(title)
            if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)) }
            content
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white.opacity(0.04)))
    }
}

/// ELO after each of the last 20 games. Filled dots = observed values, hollow = reconstructed (estimate).
struct EloChart: View {
    let d: Dashboard
    var body: some View {
        let pts = Array(d.elo.points.reversed())
        let gamesById = Dictionary(uniqueKeysWithValues: d.games.map { ($0.id, $0) })
        ChartCard(title: "elo · последние \(pts.count) игр",
                  subtitle: d.elo.changeIsExact ? "Все значения — сохранённые снимки ELO." :
                    "Заполненные точки — точные значения, полые — восстановлены по оценке (≈).") {
            Chart {
                ForEach(Array(pts.enumerated()), id: \.element.id) { i, p in
                    LineMark(x: .value("Игра", i + 1), y: .value("ELO", p.eloAfter))
                        .foregroundStyle(Theme.curveLine)
                        .interpolationMethod(.monotone)
                    AreaMark(x: .value("Игра", i + 1), yStart: .value("min", (pts.map(\.eloAfter).min() ?? 0) - 20), yEnd: .value("ELO", p.eloAfter))
                        .foregroundStyle(LinearGradient(colors: [Theme.orange.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    let win = gamesById[p.gameId]?.isWin ?? false
                    PointMark(x: .value("Игра", i + 1), y: .value("ELO", p.eloAfter))
                        .symbol {
                            Circle()
                                .strokeBorder(win ? Theme.win(.dark) : Theme.loss(.dark), lineWidth: 2)
                                .background(Circle().fill(p.eloAfterObserved || p.source == .exact ? (win ? Theme.win(.dark) : Theme.loss(.dark)) : Theme.inkDark))
                                .frame(width: 9, height: 9)
                        }
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis { AxisMarks(values: .stride(by: 5)) }
            .frame(height: 220)
        }
    }
}

struct RollingChart: View {
    let title: String
    let unit: String
    let points: [RollingPoint]
    let value: KeyPath<RollingPoint, Double?>
    let color: Color
    let domain: ClosedRange<Double>?

    var body: some View {
        let data = points.compactMap { p in p[keyPath: value].map { (p.index, p.date, $0) } }
        ChartCard(title: title, subtitle: data.last.map { "Сейчас: \(String(format: "%.2f", $0.2))\(unit)" }) {
            Chart {
                ForEach(data, id: \.0) { item in
                    LineMark(x: .value("Дата", item.1), y: .value(title, item.2))
                        .foregroundStyle(color)
                        .interpolationMethod(.monotone)
                }
            }
            .modifier(YDomain(domain: domain))
            .frame(height: 160)
        }
    }
}

struct YDomain: ViewModifier {
    let domain: ClosedRange<Double>?
    func body(content: Content) -> some View {
        if let domain { content.chartYScale(domain: domain) } else { content.chartYScale(domain: .automatic(includesZero: false)) }
    }
}

/// Raw ELO snapshots stored by the app — the exact source over time.
struct SnapshotHistory: View {
    let playerId: String
    @Environment(AppModel.self) private var model
    var body: some View {
        let snaps = Array(model.repo.store.snapshots(playerId: playerId, limit: 500).reversed())
        if snaps.count >= 2 {
            ChartCard(title: "сохранённые снимки elo", subtitle: "\(snaps.count) точек с \(snaps.first!.takenAt.formatted(date: .abbreviated, time: .omitted))") {
                Chart(Array(snaps.enumerated()), id: \.offset) { _, s in
                    LineMark(x: .value("Время", s.takenAt), y: .value("ELO", s.elo))
                        .foregroundStyle(Theme.orangeBright)
                        .interpolationMethod(.stepEnd)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 140)
            }
        }
    }
}
