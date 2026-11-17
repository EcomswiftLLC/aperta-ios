import SwiftUI
import StoreKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.requestReview) private var requestReview
    @ObservedObject private var ads = AdsManager.shared
    @EnvironmentObject private var exportStore: ExportStore
    @State private var restoreMessage: String?

    private let privacyURL = URL(string: "https://ecomswiftllc.github.io/aperta/privacy/")!
    private let supportURL = URL(string: "https://ecomswiftllc.github.io/aperta/support/")!

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AP.Space.l) {
                    ToolHeader(title: "Settings", subtitle: "Editing is free. Your photos never leave your device.")
                    VStack(spacing: 0) {
                        APHairline()
                        exportsRow
                        APHairline()
                        Button {
                            restore()
                        } label: {
                            rowLabel("Restore purchases", symbol: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .disabled(exportStore.isBusy)
                        .accessibilityHint(Text("Checks the App Store for a Premium purchase on this Apple Account"))
                        APHairline()
                        if ads.privacyOptionsRequired {
                            row("Ad privacy choices", symbol: "hand.raised") { ads.presentPrivacyOptions() }
                            APHairline()
                        }
                        row("Rate Aperta", symbol: "star") { requestReview() }
                        APHairline()
                        link("Support", symbol: "questionmark.circle", url: supportURL)
                        APHairline()
                        link("Privacy policy", symbol: "lock", url: privacyURL)
                        APHairline()
                        link("Email us", symbol: "envelope", url: URL(string: "mailto:support@ecomswiftllc.com")!)
                        APHairline()
                    }
                    if let restoreMessage {
                        Text(restoreMessage)
                            .font(AP.Font.callout)
                            .foregroundStyle(AP.Palette.paper)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Version \(version)")
                        .font(AP.Font.caption)
                        .foregroundStyle(AP.Palette.mist)
                }
                .padding(.horizontal, AP.Space.m)
                .padding(.bottom, AP.Space.xl)
            }
            .apScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(AP.Palette.brass)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// What each save or share costs, and what is left.
    private var exportsRow: some View {
        HStack(spacing: AP.Space.m) {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 17))
                .foregroundStyle(AP.Palette.brass)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your exports").font(AP.Font.body).foregroundStyle(AP.Palette.paper)
                Text(exportsDetail).font(AP.Font.caption).foregroundStyle(AP.Palette.mist)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.vertical, 14)
        .frame(minHeight: 48)
        .accessibilityElement(children: .combine)
    }

    private var exportsDetail: String {
        if exportStore.isPremium { return "Premium is active. Exports have no limit." }
        let count = exportStore.credits
        if count == 1 { return "1 export left from export packs" }
        if count > 1 { return "\(count) exports left from export packs" }
        return "No exports left. Each save or share asks for a pack or Premium."
    }

    private func restore() {
        restoreMessage = nil
        Task {
            switch await exportStore.restore() {
            case .premiumActive:
                restoreMessage = "Premium is active again."
            case .nothingFound:
                restoreMessage = "No Premium purchase was found for this Apple Account. Export packs are used up and cannot be restored."
            case .failed:
                restoreMessage = "Purchases could not be restored right now. Check your connection and try again."
            }
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    private func row(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { rowLabel(title, symbol: symbol) }
            .buttonStyle(.plain)
    }

    private func link(_ title: String, symbol: String, url: URL) -> some View {
        Link(destination: url) { rowLabel(title, symbol: symbol) }
    }

    private func rowLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: AP.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(AP.Palette.brass)
                .frame(width: 28)
            Text(title).font(AP.Font.body).foregroundStyle(AP.Palette.paper)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AP.Palette.mist)
        }
        .padding(.vertical, 14)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }
}

struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: AP.Space.xl)
            ApertureMark(lineWidth: 1.5)
                .frame(width: 96, height: 96)
                .rotationEffect(.degrees(appeared ? 0 : -60))
                .padding(.bottom, AP.Space.l)
            Text("Welcome to\nAperta.")
                .apDisplay(50)
                .lineSpacing(-2)
            Text("A complete photo studio that keeps your pictures private. Editing is free. Saving and sharing use an export that you can buy.")
                .font(AP.Font.body)
                .foregroundStyle(AP.Palette.mist)
                .padding(.top, AP.Space.m)
                .frame(maxWidth: 340, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                APHairline()
                line("slider.horizontal.3", "Edit with precise dials", "Light, colour, crop, filters, text and more.")
                APHairline()
                line("person.crop.circle.dashed", "Remove backgrounds", "Found on your device, in a second.")
                APHairline()
                line("lock", "Private by design", "Photos are never uploaded.")
                APHairline()
            }
            .padding(.top, AP.Space.xl)
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.3)) { appState.hasOnboarded = true }
            } label: {
                Text("Get started")
            }
            .buttonStyle(.apPrimaryWide)
            .padding(.bottom, AP.Space.l)
        }
        .padding(.horizontal, AP.Space.l)
        .apScreen()
        .onAppear {
            if reduceMotion { appeared = true } else { withAnimation(.easeOut(duration: 1.4)) { appeared = true } }
        }
    }

    private func line(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: AP.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 19))
                .foregroundStyle(AP.Palette.brass)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(AP.Font.headline).foregroundStyle(AP.Palette.paper)
                Text(detail).font(AP.Font.callout).foregroundStyle(AP.Palette.mist)
            }
            Spacer()
        }
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }
}
