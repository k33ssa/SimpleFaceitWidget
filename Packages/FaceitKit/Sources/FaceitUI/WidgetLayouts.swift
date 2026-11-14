import SwiftUI
import WidgetKit
import FaceitKit

/// Widget content (drawn inside the system content margins). The background is a separate view
/// (`FaceitWidgetBackground`) so the widget can hand it to `containerBackground(for: .widget)`.
public struct FaceitWidgetContent<Accessory: View>: View {
    let data: WidgetData
    let size: WidgetSize
    let style: WidgetStyle
    let accessory: Accessory
    let gameURL: ((GameRecord) -> URL?)?

    public init(data: WidgetData, size: WidgetSize, style: WidgetStyle,
                gameURL: ((GameRecord) -> URL?)? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.data = data; self.size = size; self.style = style; self.gameURL = gameURL; self.accessory = accessory()
    }

    public var body: some View {
        switch data.state {
        case .noAccount:
            MessageView(icon: "person.crop.circle.badge.plus", title: "Привяжи профиль", text: "Открой приложение и найди свой FACEIT-ник", size: size)
        case .empty(let message):
            MessageView(icon: "arrow.triangle.2.circlepath", title: "Нет данных", text: message ?? "Статистика появится после первого обновления", size: size)
        case .ok:
            if let d = data.dashboard {
                switch style {
                case .arena: ArenaLayout(d: d, data: data, size: size, accessory: accessory, gameURL: gameURL)
                case .pulse: PulseLayout(d: d, data: data, size: size, accessory: accessory, gameURL: gameURL)
                case .rank: RankLayout(d: d, data: data, size: size, accessory: accessory, gameURL: gameURL)
                }
            }
        }
    }
}

public extension FaceitWidgetContent where Accessory == EmptyView {
    init(data: WidgetData, size: WidgetSize, style: WidgetStyle, gameURL: ((GameRecord) -> URL?)? = nil) {
        self.init(data: data, size: size, style: style, gameURL: gameURL) { EmptyView() }
    }
}

public struct FaceitWidgetBackground: View {
    let data: WidgetData
    let size: WidgetSize
    let style: WidgetStyle
    @Environment(\.colorScheme) private var scheme

    public init(data: WidgetData, size: WidgetSize, style: WidgetStyle) { self.data = data; self.size = size; self.style = style }

    public var body: some View {
        if case .ok = data.state, let d = data.dashboard {
            switch style {
            case .arena:
                MapBackdrop(image: data.mapArt, horizontal: size != .small)
            case .pulse:
                ZStack {
                    scheme == .dark ? Theme.inkDarker : Theme.paper
                    EloCurve(analysis: d.elo, games: d.strip, band: Self.pulseBand(size), lineWidth: size == .small ? 1.5 : 1.8,
                             showDots: size != .small)
                }
            case .rank:
                ZStack {
                    scheme == .dark ? Color(hex: 0x0C0C0F) : Theme.paper
                    RankSlash(size: size)
                }
            }
        } else {
            Theme.canvas(scheme)
        }
    }

    static func pulseBand(_ s: WidgetSize) -> ClosedRange<CGFloat> {
        switch s {
        case .small: return 0.60...0.84
        case .medium: return 0.55...0.82
        case .large: return 0.36...0.60
        }
    }
}

/// Convenience for previews / snapshots: background + content with simulated system margins.
public struct FaceitWidgetPreview: View {
    let data: WidgetData
    let size: WidgetSize
    let style: WidgetStyle
    public init(data: WidgetData, size: WidgetSize, style: WidgetStyle) { self.data = data; self.size = size; self.style = style }

    public static func dimensions(_ s: WidgetSize) -> CGSize {
        switch s {
        case .small: return CGSize(width: 170, height: 170)
        case .medium: return CGSize(width: 364, height: 170)
        case .large: return CGSize(width: 364, height: 382)
        }
    }

    public var body: some View {
        let dim = Self.dimensions(size)
        ZStack {
            FaceitWidgetBackground(data: data, size: size, style: style)
            FaceitWidgetContent(data: data, size: size, style: style)
                .padding(16)
        }
        .frame(width: dim.width, height: dim.height)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

// MARK: - Shared bits

/// Hero number with trimmed line box so compressed numerals sit tight against neighbours.
struct Hero: View {
    let value: Int?
    let size: CGFloat
    var color: Color?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(Fmt.elo(value))
            .font(Theme.hero(size))
            .monospacedDigit()
            .foregroundStyle(color ?? Theme.primary(scheme))
            .contentTransition(.numericText(value: Double(value ?? 0)))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            // Natural line height first (a clamped height proposal makes Text truncate), then trim the box.
            .fixedSize(horizontal: false, vertical: true)
            .frame(height: size * 0.84)
            .widgetAccentable()
            .accessibilityLabel("ELO \(Fmt.elo(value))")
    }
}

struct InlineStat: View {
    let label: String
    let value: String
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        HStack(spacing: 4) {
            Caps(label)
            Text(value).font(.system(size: 11.5, weight: .heavy).width(.condensed)).monospacedDigit()
                .foregroundStyle(Theme.primary(scheme))
        }
        .lineLimit(1)
    }
}

struct MessageView: View {
    let icon: String
    let title: String
    let text: String
    let size: WidgetSize
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).font(.system(size: size == .small ? 22 : 26, weight: .semibold))
                .foregroundStyle(Theme.accent(scheme))
            Spacer(minLength: 0)
            Text(title).font(.system(size: size == .small ? 15 : 17, weight: .bold).width(.expanded))
                .foregroundStyle(Theme.primary(scheme))
            Text(text).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.secondary(scheme))
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

extension Dashboard {
    var wl: String { "\(summary.wins) W — \(summary.losses) L" }
    var levelCaps: String { "LVL \(profile.skillLevel.map(String.init) ?? "—")" }
}

// MARK: - Arena

struct ArenaLayout<Accessory: View>: View {
    let d: Dashboard
    let data: WidgetData
    let size: WidgetSize
    let accessory: Accessory
    let gameURL: ((GameRecord) -> URL?)?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch size {
        case .small: small
        case .medium: medium
        case .large: large
        }
    }

    var levelColor: Color { scheme == .dark ? Theme.level(d.profile.skillLevel) : Theme.orangeLight }

    var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Caps(d.levelCaps, color: levelColor)
                Spacer(minLength: 4)
                UpdatedStamp(data: data)
            }
            Spacer(minLength: 2)
            Hero(value: d.profile.elo, size: 60)
            HStack(spacing: 6) {
                DeltaChip(elo: d.elo, size: 11)
                Caps("\(Fmt.percent(d.summary.winRate))% WR", size: 9.5, color: Theme.primary(scheme).opacity(0.75))
            }
            .padding(.top, 6)
            Spacer(minLength: 8)
            ResultStrip(games: d.strip, height: 13, spacing: 2)
        }
    }

    var statsGrid: some View {
        Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 10) {
            GridRow {
                StatCell("win rate", Fmt.percent(d.summary.winRate), unit: "%", size: 21, alignment: .trailing)
                StatCell("k/d", Fmt.ratio(d.summary.kd), size: 21, alignment: .trailing)
            }
            GridRow {
                StatCell("hs", Fmt.percent(d.summary.headshotPercent), unit: "%", size: 21, alignment: .trailing)
                StatCell("adr", Fmt.one(d.summary.adr), size: 21, alignment: .trailing)
            }
        }
    }

    var medium: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Caps(d.profile.nickname, color: Theme.primary(scheme).opacity(0.8))
                Caps("· " + d.levelCaps, color: levelColor)
                Spacer(minLength: 4)
                UpdatedStamp(data: data)
                accessory
            }
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 7) {
                    Hero(value: d.profile.elo, size: 66)
                    DeltaChip(elo: d.elo, size: 11.5, suffix: "за \(d.elo.windowGames) игр")
                }
                Spacer(minLength: 0)
                statsGrid
            }
            .padding(.top, 8)
            Spacer(minLength: 4)
            HStack {
                Caps(d.wl)
                Spacer()
                Caps("сейчас ›", color: Theme.primary(scheme).opacity(0.85))
            }
            .padding(.bottom, 6)
            ResultStrip(games: d.strip, height: 14, gameURL: gameURL)
        }
    }

    var large: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Group {
                    if let a = data.avatar { a.resizable().scaledToFill() } else { Theme.tertiary(scheme) }
                }
                .frame(width: 30, height: 30)
                .clipShape(Circle())
                .overlay(Circle().stroke(levelColor, lineWidth: 1.5))
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.profile.nickname).font(.system(size: 14, weight: .bold).width(.expanded))
                        .foregroundStyle(Theme.primary(scheme)).lineLimit(1)
                    Caps([d.levelCaps, d.profile.region].compactMap { $0 }.joined(separator: " · "), color: levelColor)
                }
                Spacer(minLength: 4)
                UpdatedStamp(data: data)
                accessory
            }
            HStack(alignment: .bottom, spacing: 10) {
                Hero(value: d.profile.elo, size: 88)
                VStack(alignment: .leading, spacing: 5) {
                    DeltaChip(elo: d.elo, size: 12.5)
                    Caps("за \(d.elo.windowGames) игр" + (d.elo.changeIsExact ? "" : " · оценка"))
                }
                .padding(.bottom, 6)
            }
            .padding(.top, 12)
            EloCurve(analysis: d.elo, games: d.strip, band: 0.08...0.92, lineWidth: 1.8)
                .frame(height: 62)
                .padding(.top, 10)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    StatCell("win rate", Fmt.percent(d.summary.winRate), unit: "%", size: 20)
                    StatCell("k/d", Fmt.ratio(d.summary.kd), size: 20)
                    StatCell("hs", Fmt.percent(d.summary.headshotPercent), unit: "%", size: 20)
                }
                GridRow {
                    StatCell("adr", Fmt.one(d.summary.adr), size: 20)
                    StatCell("avg k / d", "\(Fmt.one(d.summary.avgKills)) / \(Fmt.one(d.summary.avgDeaths))", size: 20)
                    StatCell("rating 1.0", Fmt.ratio(d.summary.rating), size: 20)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
            Spacer(minLength: 6)
            HStack {
                Caps(d.wl)
                Spacer()
                Caps("сейчас ›", color: Theme.primary(scheme).opacity(0.85))
            }
            .padding(.bottom, 6)
            ResultStrip(games: d.strip, height: 16, gameURL: gameURL)
        }
    }
}

// MARK: - Pulse

struct PulseLayout<Accessory: View>: View {
    let d: Dashboard
    let data: WidgetData
    let size: WidgetSize
    let accessory: Accessory
    let gameURL: ((GameRecord) -> URL?)?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch size {
        case .small: small
        case .medium: medium
        case .large: large
        }
    }

    var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Caps("elo · " + d.levelCaps)
                Spacer(minLength: 4)
                UpdatedStamp(data: data)
            }
            Hero(value: d.profile.elo, size: 52).padding(.top, 6)
            HStack(spacing: 6) {
                DeltaChip(elo: d.elo, size: 10.5)
                Caps("\(Fmt.percent(d.summary.winRate))% WR", color: Theme.primary(scheme).opacity(0.75))
            }
            .padding(.top, 5)
            Spacer(minLength: 0)
            ResultStrip(games: d.strip, height: 5, spacing: 2)
        }
    }

    var winBlock: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Caps("win rate")
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(Fmt.percent(d.summary.winRate)).font(Theme.value(30))
                Text("%").font(Theme.value(17))
            }
            .foregroundStyle(Theme.primary(scheme))
            Caps(d.wl.replacingOccurrences(of: " — ", with: " · "))
        }
    }

    var medium: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Caps("elo · " + d.profile.nickname)
                    HStack(alignment: .center, spacing: 10) {
                        Hero(value: d.profile.elo, size: 58)
                        DeltaChip(elo: d.elo, size: 11.5)
                    }
                }
                Spacer(minLength: 4)
                winBlock
                accessory
            }
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                InlineStat(label: "k/d", value: Fmt.ratio(d.summary.kd))
                Spacer(minLength: 6)
                InlineStat(label: "hs", value: Fmt.percent(d.summary.headshotPercent) + "%")
                Spacer(minLength: 6)
                InlineStat(label: "adr", value: Fmt.one(d.summary.adr))
                Spacer(minLength: 6)
                InlineStat(label: "rtg", value: Fmt.ratio(d.summary.rating))
                Spacer(minLength: 6)
                UpdatedStamp(data: data)
            }
        }
    }

    var large: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Caps("elo · " + d.profile.nickname + " · " + d.levelCaps)
                    Hero(value: d.profile.elo, size: 84)
                    DeltaChip(elo: d.elo, size: 12.5, suffix: "за \(d.elo.windowGames) игр")
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 6) { UpdatedStamp(data: data); accessory }
                    winBlock
                }
            }
            Spacer(minLength: 0)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    StatCell("k/d", Fmt.ratio(d.summary.kd), size: 20)
                    StatCell("hs", Fmt.percent(d.summary.headshotPercent), unit: "%", size: 20)
                    StatCell("adr", Fmt.one(d.summary.adr), size: 20)
                }
                GridRow {
                    StatCell("avg kills", Fmt.one(d.summary.avgKills), size: 20)
                    StatCell("avg deaths", Fmt.one(d.summary.avgDeaths), size: 20)
                    StatCell("rating 1.0", Fmt.ratio(d.summary.rating), size: 20)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 12)
            ResultStrip(games: d.strip, height: 12, gameURL: gameURL)
        }
    }
}

// MARK: - Rank

struct RankSlash: View {
    let size: WidgetSize
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let fill = LinearGradient(colors: [Theme.orange, scheme == .dark ? Theme.orangeDeep : Theme.orange.opacity(0.92)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        switch size {
        case .small:
            ZStack {
                Polygon(points: [CGPoint(x: 0.55, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 0.66)]).fill(fill)
                Polygon(points: [CGPoint(x: 0.48, y: 0), CGPoint(x: 0.52, y: 0), CGPoint(x: 1, y: 0.71), CGPoint(x: 1, y: 0.77)])
                    .fill(Theme.orange.opacity(0.22))
            }
        case .medium:
            ZStack {
                SlashShape(topX: 0.645, bottomX: 0.505).fill(fill)
                Polygon(points: [CGPoint(x: 0.6, y: 0), CGPoint(x: 0.625, y: 0), CGPoint(x: 0.485, y: 1), CGPoint(x: 0.46, y: 1)])
                    .fill(Theme.orange.opacity(0.22))
            }
        case .large:
            ZStack {
                Polygon(points: [CGPoint(x: 0.6, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 0.46), CGPoint(x: 0.45, y: 0.46)]).fill(fill)
                Polygon(points: [CGPoint(x: 0.555, y: 0), CGPoint(x: 0.58, y: 0), CGPoint(x: 0.43, y: 0.46), CGPoint(x: 0.405, y: 0.46)])
                    .fill(Theme.orange.opacity(0.22))
            }
        }
    }
}

/// Polygon with vertices in unit coordinates.
struct Polygon: Shape {
    let points: [CGPoint]
    func path(in r: CGRect) -> Path {
        var p = Path()
        guard let f = points.first else { return p }
        p.move(to: CGPoint(x: r.minX + f.x * r.width, y: r.minY + f.y * r.height))
        for pt in points.dropFirst() { p.addLine(to: CGPoint(x: r.minX + pt.x * r.width, y: r.minY + pt.y * r.height)) }
        p.closeSubpath()
        return p
    }
}

struct RankLayout<Accessory: View>: View {
    let d: Dashboard
    let data: WidgetData
    let size: WidgetSize
    let accessory: Accessory
    let gameURL: ((GameRecord) -> URL?)?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch size {
        case .small: small
        case .medium: medium
        case .large: large
        }
    }

    var deltaColor: Color {
        let c = d.elo.change ?? 0
        return c > 0 ? Theme.win(scheme) : (c < 0 ? Theme.loss(scheme) : Theme.secondary(scheme))
    }

    func gauge(_ side: CGFloat, hero: CGFloat, line: CGFloat) -> some View {
        ZStack {
            LevelGauge(level: d.profile.skillLevel, elo: d.profile.elo, lineWidth: line)
            VStack(spacing: 1) {
                Hero(value: d.profile.elo, size: hero)
                Caps(d.levelCaps, size: max(8, hero * 0.24))
            }
            .padding(.top, hero * 0.12)
        }
        .frame(width: side, height: side)
    }

    var deltaWide: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(d.elo.change.map(Fmt.signed) ?? "—")
                .font(Theme.wide(size == .small ? 15 : (size == .medium ? 22 : 26)))
                .monospacedDigit()
            if !d.elo.changeIsExact { Text("≈").font(.system(size: size == .small ? 11 : 15, weight: .semibold)).opacity(0.65) }
        }
        .foregroundStyle(deltaColor)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    var toNext: String {
        if let n = LevelRanges.toNext(elo: d.profile.elo, level: d.profile.skillLevel), let l = d.profile.skillLevel {
            return "до lvl \(l + 1) — \(n)"
        }
        return d.profile.skillLevel == 10 ? "max level" : ""
    }

    /// Two-line "to next level" for narrow columns.
    @ViewBuilder var toNextStack: some View {
        if let n = LevelRanges.toNext(elo: d.profile.elo, level: d.profile.skillLevel), let l = d.profile.skillLevel {
            VStack(alignment: .leading, spacing: 2) {
                Caps("до lvl \(l + 1)", size: 8.5)
                Text("\(n)").font(Theme.value(15)).monospacedDigit().foregroundStyle(Theme.primary(scheme))
            }
        } else if d.profile.skillLevel == 10 {
            Caps("max level", size: 8.5)
        }
    }

    var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                gauge(86, hero: 27, line: 5.5).offset(x: -4, y: -4)
                Spacer(minLength: 0)
                UpdatedStamp(data: data, color: Theme.onOrange.opacity(0.75))
            }
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                deltaWide
                Caps("\(Fmt.percent(d.summary.winRate))% WR", color: Theme.primary(scheme).opacity(0.8))
            }
            .padding(.bottom, 8)
            ResultStrip(games: d.strip, height: 12, spacing: 2)
        }
    }

    var onOrangeBlock: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Caps("win rate", color: Theme.onOrange.opacity(0.65))
            Text("\(Fmt.percent(d.summary.winRate))%").font(Theme.wide(34)).foregroundStyle(Theme.onOrange)
                .lineLimit(1).minimumScaleFactor(0.7)
            Caps("k/d · hs · adr", color: Theme.onOrange.opacity(0.65)).padding(.top, 6)
            Text("\(Fmt.ratio(d.summary.kd)) · \(Fmt.percent(d.summary.headshotPercent))% · \(Fmt.one(d.summary.adr))")
                .font(.system(size: 13, weight: .heavy).width(.condensed)).monospacedDigit()
                .foregroundStyle(Theme.onOrange)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    var medium: some View {
        GeometryReader { geo in
            let w = geo.size.width
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    gauge(88, hero: 31, line: 6)
                    VStack(alignment: .leading, spacing: 3) {
                        Caps("за \(d.elo.windowGames) игр", size: 8.5)
                        deltaWide
                        toNextStack.padding(.top, 5)
                    }
                    .frame(width: 84, alignment: .leading)
                    .padding(.top, 6)
                    Spacer(minLength: 0)
                    onOrangeBlock.padding(.top, 2)
                }
                Spacer(minLength: 0)
                HStack(alignment: .bottom) {
                    ResultStrip(games: d.strip, height: 14, spacing: 2, gameURL: gameURL)
                        .frame(width: w * 0.47)
                    Spacer()
                    HStack(spacing: 6) {
                        UpdatedStamp(data: data, color: Theme.onOrange.opacity(0.75))
                        accessory
                    }
                }
            }
        }
    }

    var large: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                gauge(140, hero: 43, line: 8)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 10) {
                    HStack(spacing: 6) { UpdatedStamp(data: data, color: Theme.onOrange.opacity(0.75)); accessory }
                    onOrangeBlock
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                deltaWide
                Caps("за \(d.elo.windowGames) игр")
                Spacer(minLength: 4)
                Caps(toNext, color: Theme.primary(scheme).opacity(0.8))
            }
            .padding(.top, 22)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    StatCell("avg kills", Fmt.one(d.summary.avgKills), size: 20)
                    StatCell("avg deaths", Fmt.one(d.summary.avgDeaths), size: 20)
                    StatCell("rating 1.0", Fmt.ratio(d.summary.rating), size: 20)
                }
                GridRow {
                    StatCell("wins", "\(d.summary.wins)", size: 20)
                    StatCell("losses", "\(d.summary.losses)", size: 20)
                    StatCell("matches", d.lifetime?.matches.map(String.init) ?? "—", size: 20)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 16)
            Spacer(minLength: 6)
            ResultStrip(games: d.strip, height: 16, gameURL: gameURL)
        }
    }
}
