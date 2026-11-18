import SwiftUI

/// The standard way every tool finishes: save to the photo library or share.
/// Each export is paid for by one rewarded ad the person chooses to watch (see `RewardedGate`). With no ad ready,
/// saving and sharing are simply free. Shows a short status line.
struct ExportBar: View {
    let items: [ExportItem]
    /// Text for the status line after saving, for example "Saved 3 photos".
    var savedMessage: String? = nil

    @State private var status: Status = .idle
    @State private var shareURLs: [URL] = []
    @State private var showShare = false
    @State private var showSettingsButton = false

    private enum Status: Equatable {
        case idle, saving
        case saved(String)
        case failed(String)
    }

    var body: some View {
        VStack(spacing: AP.Space.s) {
            HStack(spacing: AP.Space.s) {
                Button {
                    RewardedGate.shared.requestExport { Task { await save() } }
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
                    RewardedGate.shared.requestExport { share() }
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
        // A new result replaces the old one, so an earlier "Saved" line must not stay on screen.
        .onChange(of: items.map { $0.id }) { _, _ in
            if status != .saving { status = .idle }
            showSettingsButton = false
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
            if showSettingsButton {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.apSecondary)
                .accessibilityHint(Text("Opens the Aperta page in the Settings app to allow adding photos"))
            }
        default:
            EmptyView()
        }
    }

    private func save() async {
        status = .saving
        showSettingsButton = false
        do {
            try await LibrarySaver.save(items)
            APHaptics.success()
            let text = savedMessage ?? (items.count == 1 ? "Saved to your library" : "Saved \(items.count) photos to your library")
            status = .saved(text)
        } catch LibrarySaver.SaveError.denied {
            status = .failed("Allow Photos access in Settings to save. You can still share.")
            showSettingsButton = true
        } catch {
            status = .failed("Could not save. Try again, or share the file instead.")
        }
    }

    private func share() {
        let files = items
        Task {
            // Writing the files can take a moment for large photos, so it happens off the main thread.
            let urls: [URL] = await Task.detached(priority: .userInitiated) { () -> [URL] in
                ExportItem.clearShareFolder()
                return files.compactMap { $0.temporaryURL() }
            }.value
            guard !urls.isEmpty else {
                status = .failed("Could not prepare the file to share.")
                showSettingsButton = false
                return
            }
            shareURLs = urls
            showShare = true
        }
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
