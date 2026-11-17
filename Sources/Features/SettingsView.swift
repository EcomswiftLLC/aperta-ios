import SwiftUI
import StoreKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.requestReview) private var requestReview
    @ObservedObject private var ads = AdsManager.shared

    private let privacyURL = URL(string: "https://ecomswiftllc.github.io/aperta/privacy/")!
    private let supportURL = URL(string: "https://ecomswiftllc.github.io/aperta/support/")!

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AP.Space.l) {
                    ToolHeader(title: "Settings", subtitle: "Aperta is free. Your photos never leave your device.")
                    VStack(spacing: 0) {
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
            Text("A complete photo studio that costs nothing and keeps your pictures private.")
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
