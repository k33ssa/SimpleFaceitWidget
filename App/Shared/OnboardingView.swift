import SwiftUI
import FaceitKit
import FaceitUI

/// First run: API key (if the build has none) → find and link a FACEIT profile.
/// Also used to switch accounts later.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    var isSwitching = false
    var onDone: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if !model.hasAPIKey { APIKeyForm() }
                else { PlayerSearch(onDone: onDone) }
            }
            .padding(32)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.inkDark)
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Caps("simple faceit", color: Theme.orangeBright)
            Text(isSwitching ? "Сменить профиль" : "Статистика FACEIT\nна рабочем столе")
                .font(.system(size: 34, weight: .heavy).width(.expanded))
                .foregroundStyle(.white)
            Text("ELO, изменение за 20 игр, винрейт, K/D, HS%, ADR и лента последних матчей — в виджетах macOS и iOS.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}

struct APIKeyForm: View {
    @Environment(AppModel.self) private var model
    @State private var key = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Caps("шаг 1 · api-ключ faceit")
            Text("Приложение работает через официальный FACEIT Data API. Создай ключ: developers.faceit.com → App Studio → своё приложение → API Keys (тип Server side) и вставь сюда. Ключ хранится в связке ключей / защищённом контейнере приложения и никуда не отправляется, кроме FACEIT.")
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
            Link("Открыть developers.faceit.com", destination: URL(string: "https://developers.faceit.com/")!)
                .font(.system(size: 13, weight: .semibold))
            SecureField("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx", text: $key)
                .textFieldStyle(.plain)
                .font(.system(size: 15, design: .monospaced))
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06)))
                .onSubmit(save)
            if let error { Text(error).font(.system(size: 13)).foregroundStyle(Theme.loss(.dark)) }
            Button(action: save) {
                HStack { if busy { ProgressView().controlSize(.small) }; Text("Проверить и сохранить") }
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy)
        }
    }

    func save() {
        busy = true
        Task {
            error = await model.saveKey(key)
            busy = false
        }
    }
}

struct PlayerSearch: View {
    @Environment(AppModel.self) private var model
    var onDone: (() -> Void)?
    @State private var query = ""
    @State private var results: [PlayerProfile] = []
    @State private var error: String?
    @State private var busy = false
    @State private var linking: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Caps("найди свой профиль")
            HStack {
                TextField("Ник на FACEIT", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17, weight: .semibold))
                    .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                #endif
                    .onSubmit(search)
                if busy { ProgressView().controlSize(.small) }
                Button("Найти", action: search).disabled(query.count < 2 || busy)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06)))
            Text("Точный ник ищется с учётом регистра; ниже — похожие профили из поиска FACEIT.")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
            if let error { Text(error).font(.system(size: 13)).foregroundStyle(Theme.loss(.dark)) }
            ForEach(results) { p in
                Button { link(p) } label: { PlayerRow(player: p, busy: linking == p.playerId) }
                    .buttonStyle(.plain)
            }
        }
    }

    func search() {
        guard query.count >= 2 else { return }
        busy = true; error = nil
        Task {
            do {
                results = try await model.repo.findPlayers(query: query)
                if results.isEmpty { error = "Никого не нашли. Проверь ник." }
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            busy = false
        }
    }

    func link(_ p: PlayerProfile) {
        linking = p.playerId
        Task {
            await model.link(p)
            linking = nil
            onDone?()
        }
    }
}

struct PlayerRow: View {
    let player: PlayerProfile
    var busy = false
    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: player.avatarURL) { img in img.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.08) }
                .frame(width: 40, height: 40).clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(player.nickname).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                Caps([player.country?.uppercased(), player.skillLevel.map { "lvl \($0)" }, player.elo.map { "\($0) elo" }]
                        .compactMap { $0 }.joined(separator: " · "))
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) } else { Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.4)) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.05)))
        .contentShape(Rectangle())
    }
}
