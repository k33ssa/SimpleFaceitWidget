import Foundation
import SwiftUI
import AppKit
import FaceitKit
import FaceitUI

// Renders every widget style × size × colour scheme to PNG from REAL data (live FACEIT API),
// running the same StatsRepository pipeline the widgets use, against a throw-away store.
//
//   FACEIT_API_KEY=$(cat ~/.config/faceit/api_key) swift run SnapshotTool --player shmeeel --out ./out [--offline]

var args = CommandLine.arguments.dropFirst()
func arg(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), args.index(after: i) < args.endIndex else { return nil }
    return args[args.index(after: i)]
}
let out = URL(fileURLWithPath: arg("--out") ?? "snapshots")
let nickname = arg("--player") ?? "shmeeel"
let offline = args.contains("--offline")
let iconOnly = args.contains("--icon")
let storeDir = out.appendingPathComponent(".store")
try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
AppGroup.overrideContainer = storeDir

let key = ProcessInfo.processInfo.environment["FACEIT_API_KEY"]
let store = try LocalStore(directory: AppGroup.dataDirectory)
let repo = StatsRepository(store: store, clientFactory: { _ in
    FaceitAPIClient(apiKey: { key }, trace: { t in
        FileHandle.standardError.write("  \(t.status.map(String.init) ?? "ERR") \(t.path) \(t.durationMs)ms \(t.error ?? "")\n".data(using: .utf8)!)
    })
})

if !offline && !iconOnly {
    let found = try await repo.findPlayers(query: nickname)
    guard let p = found.first(where: { $0.nickname.lowercased() == nickname.lowercased() }) ?? found.first else {
        print("player not found"); exit(1)
    }
    repo.link(player: p)
    let outcome = try await repo.refresh(force: true)
    if case .fetched(let d) = outcome {
        print("fetched: elo \(d.profile.elo ?? 0), games \(d.games.count), Δ20 \(d.elo.change ?? 0) exact=\(d.elo.changeIsExact)")
        print("summary: WR \(d.summary.winRate ?? -1) KD \(d.summary.kd ?? -1) HS \(d.summary.headshotPercent ?? -1) ADR \(d.summary.adr ?? -1) rating \(d.summary.rating ?? -1)")
    }
}

@MainActor func render() throws {
    let data = WidgetData.load(store: store)
    let sizes: [WidgetSize] = [.small, .medium, .large]
    for scheme in [ColorScheme.dark, .light] {
        let sheet = VStack(alignment: .leading, spacing: 28) {
            ForEach(WidgetStyle.allCases, id: \.self) { style in
                VStack(alignment: .leading, spacing: 10) {
                    Text(style.title + " — " + style.subtitle).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(scheme == .dark ? Color.white.opacity(0.7) : Color.black.opacity(0.6))
                    HStack(alignment: .top, spacing: 22) {
                        ForEach(sizes, id: \.self) { size in
                            FaceitWidgetPreview(data: data, size: size, style: style)
                        }
                    }
                }
            }
        }
        .padding(32)
        .background(scheme == .dark ? Color(hex: 0x1B1C20) : Color(hex: 0xD9D6D1))
        .environment(\.colorScheme, scheme)

        let r = ImageRenderer(content: sheet)
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "render", code: 1) }
        let url = out.appendingPathComponent("widgets-\(scheme == .dark ? "dark" : "light").png")
        try png.write(to: url)
        print("wrote \(url.path)")
    }
}
/// App icon: level-gauge arc + three result stripes on near-black. `full` = iOS (full bleed), else macOS tile.
@MainActor func renderIcon(full: Bool) throws -> Data {
    let tile = ZStack {
        LinearGradient(colors: [Color(hex: 0x17171B), Color(hex: 0x0B0B0D)], startPoint: .top, endPoint: .bottom)
        RadialGradient(colors: [Theme.orange.opacity(0.45), .clear], center: UnitPoint(x: 0.15, y: 1.05), startRadius: 0, endRadius: 620)
        ZStack {
            ForEach(0..<10, id: \.self) { i in
                GaugeArc(index: i).stroke(i < 8 ? Theme.orange : Color.white.opacity(0.16),
                                          style: StrokeStyle(lineWidth: 46, lineCap: .round))
            }
        }
        .frame(width: 540, height: 540)
        .offset(y: 10)
        HStack(spacing: 26) {
            ForEach([Color(hex: 0x3AD37A), Color(hex: 0xFF4D4D), Color(hex: 0x3AD37A)].indices, id: \.self) { i in
                SlantedBar(slant: 0.5).fill([Color(hex: 0x3AD37A), Color(hex: 0xFF4D4D), Color(hex: 0x3AD37A)][i]).frame(width: 66, height: 190)
            }
        }
        .offset(y: 20)
    }
    let view = Group {
        if full {
            tile.frame(width: 1024, height: 1024)
        } else {
            tile.frame(width: 824, height: 824)
                .clipShape(RoundedRectangle(cornerRadius: 185, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 10)
                .frame(width: 1024, height: 1024)
        }
    }
    let r = ImageRenderer(content: view)
    r.scale = 1
    guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "icon", code: 1) }
    return png
}

struct GaugeArc: Shape {
    let index: Int
    func path(in rect: CGRect) -> Path {
        let per = 27.0, gap = 14.0, a0 = 135.0 + Double(index) * per + gap / 2
        var p = Path()
        p.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2, startAngle: .degrees(a0), endAngle: .degrees(a0 + per - gap), clockwise: false)
        return p
    }
}

if iconOnly {
    try await MainActor.run {
        try renderIcon(full: true).write(to: out.appendingPathComponent("icon-ios.png"))
        try renderIcon(full: false).write(to: out.appendingPathComponent("icon-mac.png"))
    }
    print("icons written"); exit(0)
}
try await MainActor.run { try render() }
