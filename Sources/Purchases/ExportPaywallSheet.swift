import SwiftUI

/// The sheets an export button can show: the choices when no export is available, and the system share sheet.
enum ExportPresentation: Identifiable {
    case paywall
    case share([URL])

    var id: String {
        switch self {
        case .paywall: return "paywall"
        case .share: return "share"
        }
    }
}

private struct ExportSheetHost: ViewModifier {
    @Binding var sheet: ExportPresentation?
    /// Runs after a purchase or restore made an export available, once the paywall is gone.
    let onUnlocked: () -> Void
    /// Reports whether the share sheet really completed (a destination was chosen and finished).
    let onShareFinished: (Bool) -> Void

    func body(content: Content) -> some View {
        content.sheet(item: $sheet) { which in
            switch which {
            case .paywall:
                ExportPaywallSheet(onUnlocked: {
                    sheet = nil
                    Task { @MainActor in
                        // Let the paywall finish closing before the next system dialog opens.
                        try? await Task.sleep(nanoseconds: 450_000_000)
                        onUnlocked()
                    }
                })
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            case .share(let urls):
                ShareSheet(urls: urls, onFinish: { completed in
                    sheet = nil
                    onShareFinished(completed)
                })
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
            }
        }
    }
}

extension View {
    /// Attach once to the view that owns an export button.
    func exportSheets(_ sheet: Binding<ExportPresentation?>, onUnlocked: @escaping () -> Void, onShareFinished: @escaping (Bool) -> Void) -> some View {
        modifier(ExportSheetHost(sheet: sheet, onUnlocked: onUnlocked, onShareFinished: onShareFinished))
    }
}

/// The choices shown when saving or sharing needs an export pack or Premium.
/// Prices come from the store. Nothing here unlocks anything by itself: a purchase must be verified first.
struct ExportPaywallSheet: View {
    @EnvironmentObject private var store: ExportStore
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 30

    let onUnlocked: () -> Void
    @State private var status: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AP.Space.l) {
                ApertureMark(lineWidth: 1.3)
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: AP.Space.s) {
                    Text("Save or share your work")
                        .apDisplay(titleSize)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("Editing and previewing are free. Saving a photo to your library or sharing a file uses one export.")
                        .font(AP.Font.body)
                        .foregroundStyle(AP.Palette.mist)
                        .fixedSize(horizontal: false, vertical: true)
                }

                choices

                if let status {
                    Text(status)
                        .font(AP.Font.callout)
                        .foregroundStyle(AP.Palette.paper)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(AP.Space.m)
                        .background(RoundedRectangle(cornerRadius: AP.Radius.control, style: .continuous).fill(AP.Palette.graphite))
                        .accessibilityIdentifier("export.paywall.status")
                }

                VStack(spacing: AP.Space.xs) {
                    Button(action: restore) {
                        HStack(spacing: AP.Space.s) {
                            if store.isRestoring { ProgressView().tint(AP.Palette.brass) }
                            Text("Restore purchases")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.apQuiet)
                    .disabled(store.isBusy)
                    .accessibilityIdentifier("export.paywall.restore")

                    Button { dismiss() } label: {
                        Text("Not now").foregroundStyle(AP.Palette.mist).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.apQuiet)
                    .accessibilityIdentifier("export.paywall.notnow")
                }

                Text("Export packs are used up one export at a time. Premium is a single purchase with no limit, and Restore purchases brings it back on a new device.")
                    .font(AP.Font.caption)
                    .foregroundStyle(AP.Palette.mist)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, AP.Space.l)
            .padding(.top, AP.Space.xl)
            .padding(.bottom, AP.Space.l)
        }
        .apScreen()
        .preferredColorScheme(.dark)
        .task {
            if store.catalogState == .idle || store.catalogState == .unavailable {
                await store.loadProducts()
            }
        }
    }

    // MARK: Choices

    @ViewBuilder
    private var choices: some View {
        switch store.catalogState {
        case .idle, .loading:
            HStack(spacing: AP.Space.m) {
                ProgressView().tint(AP.Palette.brass)
                Text("Checking prices")
                    .font(AP.Font.body)
                    .foregroundStyle(AP.Palette.paper)
            }
            .padding(.vertical, AP.Space.m)
            .accessibilityElement(children: .combine)

        case .unavailable:
            VStack(alignment: .leading, spacing: AP.Space.m) {
                Text("Prices are not available")
                    .font(AP.Font.headline)
                    .foregroundStyle(AP.Palette.paper)
                    .accessibilityAddTraits(.isHeader)
                Text("The App Store could not be reached. Check your connection and try again. Nothing was charged.")
                    .font(AP.Font.callout)
                    .foregroundStyle(AP.Palette.mist)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task { await store.loadProducts() }
                } label: {
                    Text("Try again")
                }
                .buttonStyle(.apSecondaryWide)
                .accessibilityIdentifier("export.paywall.retry")
            }

        case .ready:
            VStack(spacing: 0) {
                APHairline()
                if let pack = store.pack {
                    optionRow(
                        product: pack,
                        title: String(localized: "3 exports"),
                        detail: String(localized: "A one-time purchase. Each save or share uses one."),
                        symbol: "photo.on.rectangle",
                        emphasised: true,
                        accessibilityLabel: String(localized: "3 exports, \(pack.displayPrice)")
                    )
                    APHairline()
                }
                if let premium = store.premium {
                    optionRow(
                        product: premium,
                        title: String(localized: "Premium"),
                        detail: String(localized: "Unlimited exports for every tool. One purchase, no subscription."),
                        symbol: "infinity",
                        emphasised: false,
                        accessibilityLabel: String(localized: "Premium, unlimited exports, \(premium.displayPrice)")
                    )
                    APHairline()
                }
            }
        }
    }

    private func optionRow(product: StoreProduct, title: String, detail: String, symbol: String, emphasised: Bool, accessibilityLabel: String) -> some View {
        let busyHere = store.busyProductID == product.id
        return Button {
            buy(product.id)
        } label: {
            HStack(alignment: .center, spacing: AP.Space.m) {
                Image(systemName: symbol)
                    .font(.system(size: 19))
                    .foregroundStyle(AP.Palette.brass)
                    .frame(width: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(AP.Font.headline).foregroundStyle(AP.Palette.paper)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(AP.Font.callout).foregroundStyle(AP.Palette.mist)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: AP.Space.s)
                if busyHere {
                    ProgressView().tint(AP.Palette.brass)
                } else {
                    Text(verbatim: product.displayPrice)
                        .font(AP.Font.label)
                        .foregroundStyle(emphasised ? AP.Palette.onBrass : AP.Palette.paper)
                        .padding(.horizontal, AP.Space.m)
                        .frame(minHeight: 36)
                        .background(
                            Capsule().fill(emphasised ? AP.Palette.brass : Color.clear)
                        )
                        .overlay(
                            Capsule().strokeBorder(emphasised ? Color.clear : AP.Palette.paper.opacity(0.28), lineWidth: 1)
                        )
                }
            }
            .padding(.vertical, AP.Space.m)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.isBusy)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityHint(Text("Opens the App Store purchase sheet"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("export.paywall.buy.\(product.id)")
    }

    // MARK: Actions

    private func buy(_ productID: String) {
        guard !store.isBusy else { return }
        status = nil
        Task {
            switch await store.purchase(productID) {
            case .purchased:
                if store.access.isOpen {
                    onUnlocked()
                } else {
                    setStatus(String(localized: "The purchase went through, but it could not be added yet. Tap Restore purchases in a moment."))
                }
            case .pending:
                setStatus(String(localized: "Your purchase is waiting for approval. The export will be available once it is approved."))
            case .cancelled:
                break
            case .unverified:
                setStatus(String(localized: "The App Store could not confirm this purchase, so nothing was added. Nothing was charged."))
            case .failed:
                setStatus(String(localized: "The purchase did not go through. Check your connection and try again."))
            }
        }
    }

    private func restore() {
        guard !store.isBusy else { return }
        status = nil
        Task {
            switch await store.restore() {
            case .premiumActive:
                if store.access.isOpen { onUnlocked() }
            case .nothingFound:
                setStatus(String(localized: "No Premium purchase was found for this Apple Account. Export packs are used up and cannot be restored."))
            case .failed:
                setStatus(String(localized: "Purchases could not be restored right now. Check your connection and try again."))
            }
        }
    }

    private func setStatus(_ message: String) {
        status = message
        AccessibilityNotification.Announcement(message).post()
    }
}
