import SwiftUI

@main
struct ApertaApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var ads = AdsManager.shared

    init() {
        APAppearance.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(ads)
                .preferredColorScheme(.dark)
                .tint(AP.Palette.brass)
        }
    }
}

final class AppState: ObservableObject {
    @Published var hasOnboarded: Bool {
        didSet { UserDefaults.standard.set(hasOnboarded, forKey: "ap.hasOnboarded") }
    }

    init() {
        hasOnboarded = UserDefaults.standard.bool(forKey: "ap.hasOnboarded")
    }
}

/// Chooses between the welcome screen and the home screen, and starts ads only after the first frame
/// and only once the person is past the welcome screen. Launch is never blocked by ads.
struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var ads: AdsManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var adsStarted = false

    var body: some View {
        ZStack {
            #if DEBUG
            if let screen = DebugScreens.requested {
                DebugScreens.view(for: screen)
            } else {
                content
            }
            #else
            content
            #endif
        }
        .apScreen()
        .task(id: appState.hasOnboarded) { await startAdsWhenReady() }
        .onChange(of: ads.adsReady) { _, ready in
            if ready { InterstitialController.shared.preloadIfPossible() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if appState.hasOnboarded {
            HomeView().transition(.opacity)
        } else {
            OnboardingView().transition(.opacity)
        }
    }

    private func startAdsWhenReady() async {
        #if DEBUG
        if DebugScreens.requested != nil { return }
        #endif
        guard appState.hasOnboarded, !adsStarted else { return }
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !Task.isCancelled, !adsStarted else { return }
        adsStarted = true
        await ads.start()
    }
}
