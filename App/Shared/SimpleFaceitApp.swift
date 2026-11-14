import SwiftUI
import FaceitKit
import FaceitUI
#if os(iOS)
import BackgroundTasks
#endif

@main
struct SimpleFaceitApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    static let backgroundTaskId = "com.k33ssa.simplefaceit.refresh"

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.orangeBright)
                .onOpenURL { model.handle(url: $0) }
                .onChange(of: phase) { _, p in
                    if p == .active { model.startAutoRefresh() } else { model.stopAutoRefresh() }
                    #if os(iOS)
                    if p == .background { Self.scheduleBackgroundRefresh(minutes: model.settings.refreshMinutes) }
                    #endif
                }
                .task { model.startAutoRefresh() }
            #if os(macOS)
                .frame(minWidth: 860, minHeight: 600)
            #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Обновить") { Task { await model.refresh(force: true) } }
                    .keyboardShortcut("r")
            }
        }
        #endif
        #if os(iOS)
        .backgroundTask(.appRefresh(Self.backgroundTaskId)) {
            // Keeps the shared cache (and exact ELO snapshots) fresh while the app is closed.
            _ = try? await StatsRepository.shared.refresh(force: false)
            Self.scheduleBackgroundRefresh(minutes: AppSettings().refreshMinutes)
        }
        #endif
    }

    #if os(iOS)
    static func scheduleBackgroundRefresh(minutes: Int) {
        let req = BGAppRefreshTaskRequest(identifier: backgroundTaskId)
        req.earliestBeginDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
        try? BGTaskScheduler.shared.submit(req)
    }
    #endif
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if !model.hasAPIKey || !model.isLinked {
                OnboardingView()
            } else {
                MainView()
            }
        }
        .background(Theme.inkDark)
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        #if os(macOS)
        NavigationSplitView {
            List(AppSection.allCases, selection: Binding(get: { model.section }, set: { if let s = $0 { model.section = s } })) { s in
                Label(s.title, systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) { SidebarFooter().padding(12) }
        } detail: {
            NavigationStack { content(model.section) }
        }
        #else
        TabView(selection: $model.section) {
            ForEach([AppSection.overview, .games, .charts, .settings], id: \.self) { s in
                NavigationStack { content(s) }
                    .tabItem { Label(s.title, systemImage: s.icon) }
                    .tag(s)
            }
        }
        #endif
    }

    @ViewBuilder func content(_ s: AppSection) -> some View {
        switch s {
        case .overview: OverviewView()
        case .games: GamesView()
        case .charts: ChartsView()
        case .settings: SettingsView()
        case .diagnostics: DiagnosticsView()
        }
    }
}

struct SidebarFooter: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let d = model.dashboard {
            VStack(alignment: .leading, spacing: 4) {
                Caps(d.profile.nickname, color: .white.opacity(0.8))
                Caps("обновлено \(Fmt.updated(d.fetchedAt))")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Toolbar refresh button with progress.
struct RefreshButton: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Button {
            Task { await model.refresh(force: true) }
        } label: {
            if model.isRefreshing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
        }
        .help("Обновить сейчас")
        .disabled(model.isRefreshing)
    }
}
