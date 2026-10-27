import MWDATCore
import SwiftUI

@main
struct ProperDaveApp: App {
    @StateObject private var model = AppModel()

    init() { WearablesBootstrap.configureIfNeeded() }

    var body: some Scene {
        WindowGroup {
            TabView {
                HomeView()
                    .tabItem { Label("Home", systemImage: "house") }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                #if DEBUG
                NavigationStack { LogView() }
                    .tabItem { Label("Log", systemImage: "list.bullet.rectangle") }
                #endif
            }
            .environmentObject(model)
            .environmentObject(model.log)
            .environmentObject(model.session)
            .onAppear {
                #if DEBUG
                DebugNotifier.requestAuthorization()
                #endif
            }
            .onOpenURL { url in
                guard URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
                else { return }
                Task { _ = try? await Wearables.shared.handleUrl(url) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in
                #if DEBUG
                model.session.pauseForDebugLog()
                model.showLogSheet = true
                #endif
            }
            .sheet(isPresented: $model.showLogSheet, onDismiss: { model.dismissLogSheet() }) {
                NavigationStack { LogView() }
                    .environmentObject(model)
                    .environmentObject(model.log)
                    .environmentObject(model.session)
            }
            .alert(model.criticalTitle, isPresented: criticalPresented) {
                Button("View debug log") { model.viewLogFromCritical() }
                Button("Continue", role: .cancel) { model.criticalError = nil }
            } message: {
                Text(model.criticalError?.description ?? "")
            }
        }
    }

    private var criticalPresented: Binding<Bool> {
        Binding(get: { model.criticalError != nil }, set: { if !$0 { model.criticalError = nil } })
    }
}
