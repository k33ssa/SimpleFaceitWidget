import SwiftUI
import FaceitKit
import FaceitUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// "Диагностика ошибок API": status of every moving part + the shared log of app and widget processes.
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var entries: [LocalStore.LogEntry] = []
    @State private var probe: String?
    @State private var probing = false

    var body: some View {
        Form {
            Section("Состояние") {
                LabeledContent("App Group", value: AppGroup.isShared ? "общий (\(AppGroup.identifier ?? ""))" : "НЕ доступен — виджет не увидит данные")
                LabeledContent("API-ключ", value: model.hasAPIKey ? "есть · \(APIKeyStore.backend.rawValue)" : "нет")
                LabeledContent("Профиль", value: model.settings.nickname ?? "не привязан")
                if let d = model.dashboard {
                    LabeledContent("Данные получены", value: d.fetchedAt.formatted(date: .abbreviated, time: .standard))
                    LabeledContent("Последняя попытка", value: d.lastAttemptAt.formatted(date: .abbreviated, time: .standard))
                    LabeledContent("Ошибка последней попытки", value: d.lastError ?? "нет")
                    LabeledContent("Игр в кэше", value: "\(d.games.count)")
                    LabeledContent("Точных ELO в окне", value: "\(d.elo.observedGames) из \(d.elo.windowGames)")
                }
                LabeledContent("Снимков ELO", value: "\(model.settings.playerId.map { model.repo.store.snapshots(playerId: $0).count } ?? 0)")
                LabeledContent("Интервал обновления", value: "\(model.settings.refreshMinutes) мин")
            }
            Section {
                Button(probing ? "Проверяю…" : "Проверить связь с FACEIT") { runProbe() }.disabled(probing)
                if let probe { Text(probe).font(.system(size: 12, design: .monospaced)) }
            }
            Section {
                ForEach(entries) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(e.level.uppercased()).font(.system(size: 10, weight: .bold))
                                .foregroundStyle(e.level == "error" ? Theme.loss(.dark) : (e.level == "warning" ? Color(hex: 0xF4A100) : .secondary))
                            Text(e.source).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Text(e.date.formatted(date: .numeric, time: .standard)).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Text(e.message).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    }
                }
            } header: {
                HStack {
                    Text("Журнал (приложение и виджеты)")
                    Spacer()
                    Button("Копировать") { copyLog() }
                    Button("Очистить") { model.repo.store.clearLog(); reload() }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.inkDark)
        .navigationTitle("Диагностика")
        .toolbar { ToolbarItem { Button("Обновить журнал", systemImage: "arrow.clockwise") { reload() } } }
        .onAppear(perform: reload)
    }

    func reload() { entries = model.repo.store.logEntries() }

    func runProbe() {
        probing = true
        Task {
            let start = Date()
            let box = LinesBox()
            let client = FaceitAPIClient(apiKey: { APIKeyStore.load() }, maxAttempts: 1, trace: { t in
                box.append("\(t.status.map(String.init) ?? "—") /\(t.path) \(t.durationMs) мс, осталось лимита: \(t.rateLimitRemaining ?? "?")")
            })
            var lines: [String] { get { box.all } }
            do {
                if let pid = model.settings.playerId {
                    let p = try await client.player(id: pid)
                    box.append("OK: \(p.nickname), ELO \(p.games?["cs2"]?.faceit_elo ?? 0)")
                } else {
                    _ = try await client.searchPlayers(nickname: "faceit", limit: 1)
                    box.append("OK")
                }
            } catch {
                box.append("Ошибка: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
            }
            box.append("Всего: \(Int(Date().timeIntervalSince(start) * 1000)) мс")
            probe = lines.joined(separator: "\n")
            model.repo.store.log(.info, "Проверка связи: " + lines.joined(separator: " | "))
            probing = false
            reload()
        }
    }

    final class LinesBox: @unchecked Sendable {
        private var items: [String] = []
        private let lock = NSLock()
        func append(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    func copyLog() {
        let text = entries.map { "\($0.date.ISO8601Format()) [\($0.level)] \($0.source): \($0.message)" }.joined(separator: "\n")
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
