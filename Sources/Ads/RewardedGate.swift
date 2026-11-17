import SwiftUI
import UIKit
import GoogleMobileAds

/// Loads one rewarded ad ahead of time. Aperta offers it on the export paywall as a free way to earn one export:
/// the person chooses to watch it, and one export is granted only when the ad was watched to the end.
/// An ad that cannot be shown never unlocks anything (and never blocks the paid options).
@MainActor
final class RewardedGate: NSObject, ObservableObject, FullScreenContentDelegate {
    static let shared = RewardedGate()

    /// True when an ad is loaded and the paywall may offer it.
    @Published private(set) var isReady = false

    private var ad: RewardedAd?
    private var loadedAt: Date?
    private var loading = false
    private let maxAge: TimeInterval = 55 * 60

    private var earned = false
    private var onEarned: (() -> Void)?
    private var onFailed: (() -> Void)?

    private override init() { super.init() }

    private var hasUsableAd: Bool {
        guard ad != nil, let loadedAt else { return false }
        return Date().timeIntervalSince(loadedAt) < maxAge
    }

    /// Call when the app may request ads (after consent and SDK start), and again after each ad.
    func preloadIfPossible() {
        isReady = AdsManager.shared.adsReady && hasUsableAd
        guard AdsManager.shared.adsReady, !loading, !hasUsableAd else { return }
        guard let unitID = AdsConfiguration.rewardedUnitID else { return }
        loading = true
        Task { [weak self] in
            do {
                let loaded = try await RewardedAd.load(with: unitID, request: Request())
                guard let self else { return }
                loaded.fullScreenContentDelegate = self
                self.ad = loaded
                self.loadedAt = Date()
                self.loading = false
                self.isReady = true
            } catch {
                AdsLog.logger.info("Rewarded ad failed to load: \(error.localizedDescription, privacy: .public)")
                self?.loading = false
                self?.isReady = false
            }
        }
    }

    /// Shows the ad. `onEarned` runs only after the ad was watched to the end. `onFailed` runs when no ad could be
    /// shown. Closing the ad early runs neither.
    func show(onEarned: @escaping () -> Void, onFailed: @escaping () -> Void) {
        guard hasUsableAd, let ad, let presenter = AdsPresenter.topViewController() else {
            onFailed()
            preloadIfPossible()
            return
        }
        self.ad = nil
        isReady = false
        earned = false
        self.onEarned = onEarned
        self.onFailed = onFailed
        ad.present(from: presenter) { [weak self] in
            self?.earned = true
        }
    }

    // MARK: FullScreenContentDelegate

    func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        let action = onEarned
        let didEarn = earned
        onEarned = nil
        onFailed = nil
        earned = false
        if didEarn { action?() }
        preloadIfPossible()
    }

    func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        AdsLog.logger.info("Rewarded ad failed to present: \(error.localizedDescription, privacy: .public)")
        let action = onFailed
        onEarned = nil
        onFailed = nil
        earned = false
        action?()
        preloadIfPossible()
    }
}
