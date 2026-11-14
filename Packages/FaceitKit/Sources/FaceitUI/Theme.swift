import SwiftUI
import FaceitKit

/// Visual language "SimpleFaceit": near-black canvas, one FACEIT-orange accent, compressed heavy numerals,
/// expanded tracked caps. Light variants keep the same structure on a warm off-white.
public enum Theme {
    // MARK: Palette
    public static let orange = Color(hex: 0xFF5500)
    public static let orangeBright = Color(hex: 0xFF6A1A)
    public static let orangeLight = Color(hex: 0xE24A00)     // on light backgrounds (contrast)
    public static let orangeDeep = Color(hex: 0xC43C00)
    public static let curveLine = Color(hex: 0xFFB27A)

    public static let inkDark = Color(hex: 0x0B0B0D)
    public static let inkDarker = Color(hex: 0x09090B)
    public static let paper = Color(hex: 0xF4F2EF)
    public static let onOrange = Color(hex: 0x1A0800)

    public static func win(_ s: ColorScheme) -> Color { s == .dark ? Color(hex: 0x3AD37A) : Color(hex: 0x1E9E58) }
    public static func loss(_ s: ColorScheme) -> Color { s == .dark ? Color(hex: 0xFF4D4D) : Color(hex: 0xD93636) }
    public static func accent(_ s: ColorScheme) -> Color { s == .dark ? orangeBright : orangeLight }
    public static func canvas(_ s: ColorScheme) -> Color { s == .dark ? inkDark : paper }
    public static func primary(_ s: ColorScheme) -> Color { s == .dark ? .white : Color(hex: 0x121216) }
    public static func secondary(_ s: ColorScheme) -> Color { s == .dark ? .white.opacity(0.55) : Color(hex: 0x14141A).opacity(0.55) }
    public static func tertiary(_ s: ColorScheme) -> Color { s == .dark ? .white.opacity(0.14) : Color(hex: 0x14141A).opacity(0.10) }

    /// FACEIT skill level colour coding (1 grey-white, 2–3 green, 4–7 yellow, 8–9 orange, 10 red).
    public static func level(_ level: Int?) -> Color {
        switch level ?? 0 {
        case 1: return Color(hex: 0xEEEEEE)
        case 2...3: return Color(hex: 0x1CE400)
        case 4...7: return Color(hex: 0xFFC800)
        case 8...9: return Color(hex: 0xFF6309)
        case 10...: return Color(hex: 0xFE1F00)
        default: return .gray
        }
    }

    // MARK: Type

    /// Hero numerals: SF Pro Compressed Black.
    public static func hero(_ size: CGFloat) -> Font { .system(size: size, weight: .black).width(.compressed) }
    /// Secondary numerals: SF Pro Condensed Heavy.
    public static func value(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy).width(.condensed) }
    /// Big expanded figures (Rank style).
    public static func wide(_ size: CGFloat, weight: Font.Weight = .heavy) -> Font { .system(size: size, weight: weight).width(.expanded) }
    /// Tracked caps labels.
    public static func caps(_ size: CGFloat = 9.5) -> Font { .system(size: size, weight: .semibold).width(.expanded) }
}

/// Tracked uppercase label.
public struct Caps: View {
    let text: String
    var size: CGFloat = 9.5
    var color: Color?
    @Environment(\.colorScheme) private var scheme

    public init(_ text: String, size: CGFloat = 9.5, color: Color? = nil) {
        self.text = text; self.size = size; self.color = color
    }

    public var body: some View {
        Text(text.uppercased())
            .font(Theme.caps(size))
            .tracking(size * 0.13)
            .foregroundStyle(color ?? Theme.secondary(scheme))
            .lineLimit(1)
    }
}

public extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

// MARK: - Formatting

public enum Fmt {
    public static func elo(_ v: Int?) -> String { v.map(String.init) ?? "—" }

    public static func percent(_ v: Double?) -> String { v.map { String(Int($0.rounded())) } ?? "—" }

    public static func ratio(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.2f", v)
    }

    public static func one(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.1f", v)
    }

    /// "+37", "−101", "±0" (true minus sign).
    public static func signed(_ v: Int) -> String {
        if v > 0 { return "+\(v)" }
        if v < 0 { return "−\(-v)" }
        return "±0"
    }

    /// Last-update stamp: "02:40" today, "вчера 23:10", "12 нояб. 18:05" otherwise.
    public static func updated(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let time = d.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        if cal.isDate(d, inSameDayAs: now) { return time }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "вчера \(time)" }
        return d.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "ru_RU"))) + " " + time
    }

    public static func relative(_ d: Date, now: Date = Date()) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: now)
    }
}

// MARK: - Levels

/// CS2 ELO ranges per FACEIT skill level (FACEIT support article "FACEIT CS2 Elo and skill levels";
/// the level itself always comes from the API — this is only used for the "to next level" progress).
public enum LevelRanges {
    public static let lower: [Int: Int] = [1: 100, 2: 501, 3: 751, 4: 901, 5: 1051, 6: 1201, 7: 1351, 8: 1531, 9: 1751, 10: 2001]

    /// Progress inside the current level, 0…1 (nil for level 10 or unknown).
    public static func progress(elo: Int?, level: Int?) -> Double? {
        guard let elo, let level, level < 10, let lo = lower[level], let hi = lower[level + 1] else { return nil }
        return min(max(Double(elo - lo) / Double(hi - lo), 0), 1)
    }

    public static func toNext(elo: Int?, level: Int?) -> Int? {
        guard let elo, let level, level < 10, let hi = lower[level + 1] else { return nil }
        return max(hi - elo, 0)
    }
}
