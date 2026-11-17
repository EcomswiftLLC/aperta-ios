import SwiftUI

/// The standard way every tool finishes: save to the photo library or share.
/// Saving or sharing uses one export (an export pack, or Premium). With none available the paywall opens, and after
/// a purchase the action the person asked for continues by itself. An export is used up only after the photos were
/// really saved, or the share sheet reported that the file was really shared. Cancelling or failing uses nothing.
/// Shows a short status line, and offers an interstitial after finished exports (see `InterstitialPolicy`).
struct ExportBar: View {
    let items: [ExportItem]
    /// Text for the status line after saving, for example "Saved 3 photos".
    var savedMessage: String? = nil

    @EnvironmentObject private var exportStore: ExportStore
    @State private var status: Status = .idle
    @State private var sheet: ExportSheet?
    /// What the person asked for while the paywall was open.
    @State private var pending: PendingAction?

    private enum PendingAction { case save, share }

    private enum Status: Equatable {
        case idle, saving
        case saved(String)
        case failed(String)
    }

    var body: some View {
        VStack(spacing: AP.Space.s) {
            HStack(spacing: AP.Space.s) {
                Button {
                    request(.save)
                } label: {
                    HStack(spacing: 8) {
                        if status == .saving { ProgressView().tint(AP.Palette.onBrass) }
                        Image(systemName: "square.and.arrow.down")
                        Text("Save to Photos")
                    }
                }
                .buttonStyle(.apPrimaryWide)
                .disabled(items.isEmpty || status == .saving)

                Button {
                    request(.share)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .frame(width: 20)
                }
                .buttonStyle(.apSecondary)
                .disabled(items.isEmpty)
                .accessibilityLabel(Text("Share"))
            }
            statusLine
        }
        .exportSheets($sheet, onUnlocked: continuePending, onShareFinished: shareFinished)
    }

    // MARK: Gate

    private func request(_ action: PendingAction) {
        guard exportStore.access.isOpen else {
            pending = action
            sheet = .paywall
            return
        }
        run(action)
    }

    private func run(_ action: PendingAction) {
        switch action {
        case .save: Task { await save() }
        case .share: share()
        }
    }

    private func continuePending() {
        guard let action = pending else { return }
        pending = nil
        guard exportStore.access.isOpen else { return }
        run(action)
    }

    private func shareFinished(_ completed: Bool) {
        exportStore.settle(completed ? .completed : .cancelled)
        if completed { InterstitialController.shared.exportFinished() }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .saved(let text):
            Label(text, systemImage: "checkmark.circle.fill")
                .font(AP.Font.label).foregroundStyle(AP.Palette.success)
        case .failed(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(AP.Font.label).foregroundStyle(AP.Palette.danger)
        default:
            EmptyView()
        }
    }

    private func save() async {
        status = .saving
        do {
            try await LibrarySaver.save(items)
            // The photos are in the library now, so this export is used up.
            exportStore.settle(.completed)
            APHaptics.success()
            let text = savedMessage ?? (items.count == 1 ? "Saved to your library" : "Saved \(items.count) photos to your library")
            status = .saved(text)
            InterstitialController.shared.exportFinished()
        } catch LibrarySaver.SaveError.denied {
            status = .failed("Allow Photos access in Settings to save. You can still share.")
        } catch {
            status = .failed("Could not save. Try again, or share the file instead.")
        }
    }

    private func share() {
        let urls = items.compactMap { $0.temporaryURL() }
        guard !urls.isEmpty else {
            status = .failed("Could not prepare the file to share.")
            return
        }
        sheet = .share(urls)
    }
}

/// Header used at the top of every tool screen.
struct ToolHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).apDisplay(34)
            Text(subtitle).font(AP.Font.callout).foregroundStyle(AP.Palette.mist)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
