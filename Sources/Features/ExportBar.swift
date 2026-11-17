import SwiftUI

/// The standard way every tool finishes: save to the photo library or share.
/// Shows a short status line, and offers an interstitial after finished exports (see `InterstitialPolicy`).
struct ExportBar: View {
    let items: [ExportItem]
    /// Text for the status line after saving, for example "Saved 3 photos".
    var savedMessage: String? = nil

    @State private var status: Status = .idle
    @State private var shareURLs: [URL] = []
    @State private var showShare = false

    private enum Status: Equatable {
        case idle, saving
        case saved(String)
        case failed(String)
    }

    var body: some View {
        VStack(spacing: AP.Space.s) {
            HStack(spacing: AP.Space.s) {
                Button {
                    Task { await save() }
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
                    share()
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
        .sheet(isPresented: $showShare) {
            ShareSheet(urls: shareURLs)
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
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
        shareURLs = urls
        showShare = true
        InterstitialController.shared.exportFinished()
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
