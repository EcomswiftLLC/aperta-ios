import SwiftUI
import UIKit
import GoogleMobileAds

/// Pure rules for when an interstitial may appear, so they can be unit tested.
struct InterstitialPolicy: Equatable {
    /// An interstitial is offered after every second finished export, never the first one of a session.
    static let exportsPerAd = 2
    /// And never more often than this.
    static let minimumGap: TimeInterval = 120

    private(set) var exportsSinceAd = 0
    private(set) var lastShown: Date?

    mutating func exportFinished(now: Date = Date()) -> Bool {
        exportsSinceAd += 1
        guard exportsSinceAd >= Self.exportsPerAd else { return false }
        if let lastShown, now.timeIntervalSince(lastShown) < Self.minimumGap { return false }
        return true
    }

    mutating func didShow(now: Date = Date()) {
        exportsSinceAd = 0
        lastShown = now
    }
}

/// Loads one interstitial ahead of time and shows it after a finished export. Never blocks saving or sharing:
/// the file is already saved when the ad appears, and nothing happens when no ad is ready.
@MainActor
final class InterstitialController: NSObject, ObservableObject, FullScreenContentDelegate {
    static let shared = InterstitialController()

    private var ad: InterstitialAd?
    private var loadedAt: Date?
    private var loading = false
    private var policy = InterstitialPolicy()
    private let maxAge: TimeInterval = 55 * 60

    private override init() { super.init() }

    /// Call when the app may request ads (after consent and SDK start).
    func preloadIfPossible() {
        guard AdsManager.shared.adsReady, !loading else { return }
        if let loadedAt, ad != nil, Date().timeIntervalSince(loadedAt) < maxAge { return }
        guard let unitID = AdsConfiguration.interstitialUnitID else { return }
        loading = true
        Task { [weak self] in
            do {
                let loaded = try await InterstitialAd.load(with: unitID, request: Request())
                guard let self else { return }
                loaded.fullScreenContentDelegate = self
                self.ad = loaded
                self.loadedAt = Date()
                self.loading = false
            } catch {
                AdsLog.logger.info("Interstitial failed to load: \(error.localizedDescription, privacy: .public)")
                self?.loading = false
            }
        }
    }

    /// Call once per finished export (saved or shared).
    func exportFinished() {
        guard AdsManager.shared.adsReady else { return }
        guard policy.exportFinished() else {
            preloadIfPossible()
            return
        }
        guard let ad, let presenter = AdsPresenter.topViewController() else {
            preloadIfPossible()
            return
        }
        policy.didShow()
        self.ad = nil
        ad.present(from: presenter)
    }

    // MARK: FullScreenContentDelegate

    func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        preloadIfPossible()
    }

    func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        AdsLog.logger.info("Interstitial failed to present: \(error.localizedDescription, privacy: .public)")
        preloadIfPossible()
    }
}
