import SwiftUI
import WidgetKit
import FaceitKit
import FaceitUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var switching = false
    @State private var replacingKey = false
    @State private var importing = false
    @State private var confirmUnlink = false

    var body: some View {
        Form {
            Section("Профиль") {
                if let d = model.dashboard {
                    PlayerRow(player: d.profile)
                }
                Button("Сменить аккаунт…") { switching = true }
                Button("Отвязать профиль", role: .destructive) { confirmUnlink = true }
            }

            Section {
                Picker("Частота обновления", selection: Binding(get: { model.settings.refreshMinutes }, set: { model.setRefreshMinutes($0) })) {
                    ForEach(AppSettings.refreshOptions, id: \.self) { m in
                        Text(m < 60 ? "\(m) мин" : "\(m / 60) ч").tag(m)
                    }
                }
                Button("Обновить сейчас") { Task { await model.refresh(force: true) } }
            } header: { Text("Обновление") } footer: {
                Text("Виджеты обновляются сами, даже когда приложение закрыто, — но расписание задаёт система: WidgetKit воспринимает интервал как пожелание и может обновить позже (при экономии энергии, редком просмотре виджета). В реальном времени виджеты не обновляются. Несколько виджетов не дублируют запросы — данные берутся из общего кэша.")
            }

            Section {
                ForEach(WidgetStyle.allCases, id: \.self) { s in
                    LabeledContent(s.title, value: s.subtitle)
                }
            } header: { Text("Стили виджетов") } footer: {
                Text("Стиль выбирается у каждого виджета отдельно: правый клик (на iPhone — долгое нажатие) по виджету → «Изменить виджет» → «Стиль».")
            }

            Section {
                Button("Загрузить точную историю ELO с faceit.com…") { importing = true }
            } header: { Text("Точная история ELO") } footer: {
                Text("Официальный API не отдаёт ELO по матчам. Эта функция открывает faceit.com внутри приложения (как обычный браузер — если сайт покажет проверку, пройди её сам) и берёт ELO после каждого матча из статистики самого сайта. Это неофициальный источник: если он перестанет работать, приложение продолжит считать по своим снимкам и оценке.")
            }

            Section {
                LabeledContent("Хранилище ключа", value: APIKeyStore.backend.rawValue)
                Button("Заменить API-ключ…") { replacingKey = true }
                Button("Удалить API-ключ", role: .destructive) { model.deleteKey() }
            } header: { Text("API-ключ FACEIT") }

            Section("Данные") {
                Button("Пересчитать из кэша") { model.reloadFromCache() }
                #if os(iOS)
                NavigationLink("Диагностика") { DiagnosticsView() }
                #endif
            }

            Section {
                Text("SimpleFaceitWidget не связан с FACEIT. Данные — FACEIT Data API.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.inkDark)
        .navigationTitle("Настройки")
        .sheet(isPresented: $switching) {
            NavigationStack {
                ScrollView { PlayerSearch(onDone: { switching = false }).padding(24) }
                    .background(Theme.inkDark)
                    .navigationTitle("Сменить аккаунт")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { switching = false } } }
            }
            .frame(minWidth: 480, minHeight: 520)
        }
        .sheet(isPresented: $replacingKey) {
            NavigationStack {
                ScrollView { ReplaceKeyForm(onDone: { replacingKey = false }).padding(24) }
                    .background(Theme.inkDark)
                    .navigationTitle("API-ключ")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { replacingKey = false } } }
            }
            .frame(minWidth: 480, minHeight: 360)
        }
        .sheet(isPresented: $importing) {
            EloImportView(onClose: { importing = false })
                .frame(minWidth: 760, minHeight: 620)
        }
        .confirmationDialog("Отвязать профиль?", isPresented: $confirmUnlink) {
            Button("Отвязать", role: .destructive) { model.unlink() }
        } message: { Text("Кэш статистики удалится. Сохранённые снимки ELO останутся — при повторной привязке они пригодятся.") }
    }
}

struct ReplaceKeyForm: View {
    @Environment(AppModel.self) private var model
    var onDone: () -> Void
    @State private var key = ""
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SecureField("Новый ключ", text: $key)
                .textFieldStyle(.plain).font(.system(size: 15, design: .monospaced))
                .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06)))
            if let error { Text(error).foregroundStyle(Theme.loss(.dark)).font(.system(size: 13)) }
            Button("Проверить и сохранить") {
                busy = true
                Task {
                    error = await model.saveKey(key)
                    busy = false
                    if error == nil { onDone() }
                }
            }
            .buttonStyle(.borderedProminent).disabled(busy)
        }
    }
}
