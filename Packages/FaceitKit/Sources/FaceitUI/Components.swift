import SwiftUI
import FaceitKit

// MARK: - Result strip

/// The last 20 games as slanted bars: **oldest on the left, newest on the right**.
/// Older games fade slightly; the newest one glows. Fewer than 20 games → empty slots on the left.
public struct ResultStrip: View {
    let games: [GameRecord]        // display order (oldest → newest)
    var height: CGFloat = 14
    var spacing: CGFloat = 3
    var slots: Int = StatsCalculator.windowSize
    var gameURL: ((GameRecord) -> URL?)? = nil
    @Environment(\.colorScheme) private var scheme

    public init(games: [GameRecord], height: CGFloat = 14, spacing: CGFloat = 3, slots: Int = StatsCalculator.windowSize,
                gameURL: ((GameRecord) -> URL?)? = nil) {
        self.games = games; self.height = height; self.spacing = spacing; self.slots = slots; self.gameURL = gameURL
    }

    public var body: some View {
        let shown = Array(games.suffix(slots))
        let empty = max(slots - shown.count, 0)
        HStack(spacing: spacing) {
            ForEach(0..<empty, id: \.self) { _ in
                SlantedBar().fill(Theme.tertiary(scheme)).frame(height: height)
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, g in
                bar(g, index: i, count: shown.count)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Последние \(shown.count) игр, от старых к новым")
        .accessibilityValue("\(shown.filter(\.isWin).count) побед, \(shown.filter { !$0.isWin }.count) поражений")
    }

    @ViewBuilder private func bar(_ g: GameRecord, index: Int, count: Int) -> some View {
        let color = g.isWin ? Theme.win(scheme) : Theme.loss(scheme)
        let newest = index == count - 1
        let fade = count > 1 ? 0.55 + 0.4 * Double(index) / Double(count - 1) : 1
        let shape = SlantedBar()
            .fill(color.opacity(newest ? 1 : fade))
            .frame(height: height)
            .shadow(color: newest && scheme == .dark ? color.opacity(0.9) : .clear, radius: 4)
        if let url = gameURL?(g) {
            Link(destination: url) { shape }
        } else {
            shape
        }
    }
}

/// Parallelogram leaning right, like a speed stripe.
public struct SlantedBar: Shape {
    public var slant: CGFloat = 0.28
    public init(slant: CGFloat = 0.28) { self.slant = slant }
    public func path(in r: CGRect) -> Path {
        let dx = min(r.height * slant, r.width * 0.45)
        var p = Path()
        p.move(to: CGPoint(x: r.minX + dx, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - dx, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - ELO change chip

public struct DeltaChip: View {
    let elo: EloAnalysis
    var size: CGFloat = 12
    var suffix: String? = nil
    var filled = true
    @Environment(\.colorScheme) private var scheme

    public init(elo: EloAnalysis, size: CGFloat = 12, suffix: String? = nil, filled: Bool = true) {
        self.elo = elo; self.size = size; self.suffix = suffix; self.filled = filled
    }

    public var body: some View {
        let change = elo.change ?? 0
        let color = change > 0 ? Theme.win(scheme) : (change < 0 ? Theme.loss(scheme) : Theme.secondary(scheme))
        HStack(spacing: size * 0.3) {
            if elo.change != nil {
                Image(systemName: change > 0 ? "arrowtriangle.up.fill" : (change < 0 ? "arrowtriangle.down.fill" : "equal"))
                    .font(.system(size: size * 0.62, weight: .black))
                Text(change == 0 ? "0" : "\(abs(change))")
                    .font(.system(size: size, weight: .bold).width(.condensed))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(change)))
                if !elo.changeIsExact {
                    Text("≈").font(.system(size: size * 0.9, weight: .semibold)).opacity(0.7)
                }
            } else {
                Text("—").font(.system(size: size, weight: .bold))
            }
            if let suffix {
                Text(suffix).font(.system(size: size * 0.92, weight: .medium)).foregroundStyle(Theme.secondary(scheme))
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, filled ? size * 0.6 : 0)
        .padding(.vertical, filled ? size * 0.22 : 0)
        .background(filled ? Capsule().fill(color.opacity(scheme == .dark ? 0.18 : 0.13)) : nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Изменение ELO за \(elo.windowGames) игр: \(elo.change.map(Fmt.signed) ?? "нет данных")\(elo.changeIsExact ? "" : ", оценка")")
    }
}

// MARK: - Stat cell

public struct StatCell: View {
    let label: String
    let value: String
    var unit: String? = nil
    var size: CGFloat = 22
    var alignment: HorizontalAlignment = .leading
    var valueColor: Color? = nil
    var labelColor: Color? = nil
    @Environment(\.colorScheme) private var scheme

    public init(_ label: String, _ value: String, unit: String? = nil, size: CGFloat = 22, alignment: HorizontalAlignment = .leading,
                valueColor: Color? = nil, labelColor: Color? = nil) {
        self.label = label; self.value = value; self.unit = unit; self.size = size; self.alignment = alignment
        self.valueColor = valueColor; self.labelColor = labelColor
    }

    public var body: some View {
        VStack(alignment: alignment, spacing: 3) {
            Caps(label, size: max(8.5, size * 0.42), color: labelColor)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value).font(Theme.value(size)).monospacedDigit()
                if let unit, value != "—" {
                    Text(unit).font(Theme.value(size * 0.58))
                }
            }
            .foregroundStyle(valueColor ?? Theme.primary(scheme))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Level gauge

/// Ten-segment 270° gauge: full segments up to the current level, the current one filled by
/// progress to the next level, in the level's colour.
public struct LevelGauge: View {
    let level: Int?
    let elo: Int?
    var lineWidth: CGFloat = 7
    @Environment(\.colorScheme) private var scheme

    public init(level: Int?, elo: Int?, lineWidth: CGFloat = 7) {
        self.level = level; self.elo = elo; self.lineWidth = lineWidth
    }

    public var body: some View {
        let color = Theme.level(level)
        let lvl = level ?? 0
        let progress = LevelRanges.progress(elo: elo, level: level) ?? (lvl >= 10 ? 1 : 0)
        ZStack {
            ForEach(0..<10, id: \.self) { i in
                let seg = GaugeSegment(index: i, fraction: 1)
                seg.stroke(Theme.tertiary(scheme), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                if i < lvl - 1 || (lvl >= 10 && i == 9) {
                    seg.stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                } else if i == lvl - 1 {
                    // Current level: whole segment dimmed + progress part bright.
                    seg.stroke(color.opacity(0.35), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    GaugeSegment(index: i, fraction: max(progress, 0.08))
                        .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                }
            }
        }
        .padding(lineWidth / 2)
        .accessibilityLabel("Уровень \(lvl)")
    }
}

struct GaugeSegment: Shape {
    let index: Int
    let fraction: Double
    func path(in rect: CGRect) -> Path {
        let start = 135.0, sweep = 270.0, per = sweep / 10, gap = 9.0
        let a0 = start + Double(index) * per + gap / 2
        let a1 = a0 + (per - gap) * fraction
        var p = Path()
        p.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: min(rect.width, rect.height) / 2,
                 startAngle: .degrees(a0), endAngle: .degrees(a1), clockwise: false)
        return p
    }
}

// MARK: - ELO curve

/// ELO after each game of the window (oldest → newest), drawn as a glowing line over a fading area.
/// The curve occupies the band `band` (fractions of the height) so it never collides with the text.
public struct EloCurve: View {
    let analysis: EloAnalysis
    let games: [GameRecord]     // display order oldest → newest
    var band: ClosedRange<CGFloat> = 0.45...0.82
    var inset: CGFloat = 0
    var lineWidth: CGFloat = 1.8
    var showDots = true
    var fillToBottom = true
    @Environment(\.colorScheme) private var scheme

    public init(analysis: EloAnalysis, games: [GameRecord], band: ClosedRange<CGFloat> = 0.45...0.82, inset: CGFloat = 0,
                lineWidth: CGFloat = 1.8, showDots: Bool = true, fillToBottom: Bool = true) {
        self.analysis = analysis; self.games = games; self.band = band; self.inset = inset
        self.lineWidth = lineWidth; self.showDots = showDots; self.fillToBottom = fillToBottom
    }

    /// Values oldest → newest: ELO before the oldest game, then after each game.
    var values: [Double] {
        let pts = analysis.points.reversed()
        guard let first = pts.first else { return [] }
        return [Double(first.eloAfter - first.delta)] + pts.map { Double($0.eloAfter) }
    }

    public var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            if pts.count >= 2 {
                let line = Path { p in p.addLines(pts) }
                let area = Path { p in
                    p.move(to: CGPoint(x: pts[0].x, y: geo.size.height))
                    p.addLines(pts)
                    p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: geo.size.height))
                    p.closeSubpath()
                }
                let accent = scheme == .dark ? Theme.orange : Theme.orangeLight
                if fillToBottom {
                    area.fill(LinearGradient(colors: [accent.opacity(scheme == .dark ? 0.42 : 0.22), accent.opacity(0)],
                                             startPoint: .top, endPoint: .bottom))
                }
                if scheme == .dark {
                    line.stroke(Theme.orangeBright.opacity(0.65), style: StrokeStyle(lineWidth: lineWidth * 3, lineCap: .round, lineJoin: .round))
                        .blur(radius: 3)
                }
                line.stroke(scheme == .dark ? Theme.curveLine : Theme.orangeLight,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                if showDots {
                    ForEach(Array(games.suffix(pts.count - 1).enumerated()), id: \.element.id) { i, g in
                        let pt = pts[i + 1]
                        let last = i == pts.count - 2
                        Circle()
                            .fill(g.isWin ? Theme.win(scheme) : Theme.loss(scheme))
                            .frame(width: last ? lineWidth * 4.4 : lineWidth * 2.8, height: last ? lineWidth * 4.4 : lineWidth * 2.8)
                            .shadow(color: last ? (g.isWin ? Theme.win(scheme) : Theme.loss(scheme)) : .clear, radius: 4)
                            .position(pt)
                    }
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("График ELO за последние игры")
    }

    func points(in size: CGSize) -> [CGPoint] {
        let v = values
        guard v.count >= 2, let lo = v.min(), let hi = v.max() else { return [] }
        let span = max(hi - lo, 20)       // flat histories don't explode into noise
        let mid = (hi + lo) / 2
        let top = size.height * band.lowerBound, bottom = size.height * band.upperBound
        let w = size.width - inset * 2
        return v.enumerated().map { i, e in
            let x = inset + w * CGFloat(i) / CGFloat(v.count - 1)
            let norm = (e - (mid - span / 2)) / span
            return CGPoint(x: x, y: bottom - CGFloat(norm) * (bottom - top))
        }
    }
}

// MARK: - Map backdrop

/// Map artwork darkened and lit with an orange glow from the bottom-left corner.
public struct MapBackdrop: View {
    let image: Image?
    var horizontal = true
    @Environment(\.colorScheme) private var scheme

    public init(image: Image?, horizontal: Bool = true) { self.image = image; self.horizontal = horizontal }

    public var body: some View {
        ZStack {
            Theme.canvas(scheme)
            if let image {
                // Overlay on a flexible clear view so the artwork never drives the layout size.
                Color.clear.overlay(
                    image.resizable().scaledToFill()
                        .saturation(scheme == .dark ? 0.75 : 0)
                        .brightness(scheme == .dark ? -0.12 : 0.25)
                        .opacity(scheme == .dark ? 0.75 : 0.32)
                )
                .clipped()
            }
            if horizontal {
                LinearGradient(stops: [
                    .init(color: Theme.canvas(scheme), location: 0.16),
                    .init(color: Theme.canvas(scheme).opacity(0.84), location: 0.48),
                    .init(color: Theme.canvas(scheme).opacity(scheme == .dark ? 0.3 : 0.5), location: 1),
                ], startPoint: .leading, endPoint: .trailing)
            } else {
                LinearGradient(stops: [
                    .init(color: Theme.canvas(scheme).opacity(scheme == .dark ? 0.35 : 0.3), location: 0),
                    .init(color: Theme.canvas(scheme), location: 0.84),
                ], startPoint: .top, endPoint: .bottom)
            }
            RadialGradient(colors: [Theme.orange.opacity(scheme == .dark ? 0.5 : 0.24), Theme.orange.opacity(0)],
                           center: UnitPoint(x: 0, y: 1.15), startRadius: 0, endRadius: horizontal ? 260 : 150)
        }
    }
}

// MARK: - Rank slash

/// Diagonal orange slab (Rank style) — top edge starts at `topX`, bottom edge at `bottomX` (fractions of width).
public struct SlashShape: Shape {
    var topX: CGFloat
    var bottomX: CGFloat
    public init(topX: CGFloat, bottomX: CGFloat) { self.topX = topX; self.bottomX = bottomX }
    public func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + r.width * topX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + r.width * bottomX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Update stamp

public struct UpdatedStamp: View {
    let data: WidgetData
    var color: Color? = nil
    @Environment(\.colorScheme) private var scheme

    public init(data: WidgetData, color: Color? = nil) { self.data = data; self.color = color }

    public var body: some View {
        if let d = data.dashboard {
            HStack(spacing: 3) {
                if data.isStale || d.lastError != nil {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color(hex: 0xF4A100))
                }
                Caps(Fmt.updated(d.fetchedAt, now: data.now), color: color)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Обновлено \(Fmt.updated(d.fetchedAt, now: data.now))" + (d.lastError != nil ? ", последнее обновление не удалось" : ""))
        }
    }
}
