import SwiftUI
import PhotosUI
import UIKit
import ImageIO

// MARK: - Settings and results

private enum CmpMode: String, CaseIterable, Identifiable {
    case quality, targetSize

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quality: return "Quality"
        case .targetSize: return "Target size"
        }
    }
}

private struct CmpSettings: Equatable {
    var format: OutputFormat
    var mode: CmpMode
    var quality: Int
    var targetKB: Int
    var removePrivate: Bool
}

private struct CmpJobKey: Equatable {
    var photoIDs: [UUID]
    var settings: CmpSettings
}

private struct CmpResult {
    let data: Data
    let pixelSize: CGSize
    let originalPixelSize: CGSize
    let originalBytes: Int

    var wasScaled: Bool {
        Int(pixelSize.width) != Int(originalPixelSize.width) || Int(pixelSize.height) != Int(originalPixelSize.height)
    }
}

/// Pure work, safe to call off the main thread.
private enum CmpEngine {
    static func compress(
        _ image: CGImage,
        properties: [String: Any],
        settings: CmpSettings,
        originalBytes: Int
    ) -> CmpResult? {
        let originalSize = CGSize(width: image.width, height: image.height)
        switch settings.mode {
        case .quality:
            guard let data = ImageCodec.encode(
                image,
                format: settings.format,
                quality: Double(settings.quality) / 100,
                properties: properties
            ) else { return nil }
            return CmpResult(data: data, pixelSize: originalSize, originalPixelSize: originalSize, originalBytes: originalBytes)
        case .targetSize:
            guard let output = ImageCodec.encode(
                image,
                format: settings.format,
                targetBytes: settings.targetKB * 1000,
                properties: properties
            ) else { return nil }
            return CmpResult(data: output.data, pixelSize: output.size, originalPixelSize: originalSize, originalBytes: originalBytes)
        }
    }
}

@MainActor
private final class CmpModel: ObservableObject {
    @Published var results: [UUID: CmpResult] = [:]
    @Published var completed: Int = 0
    @Published var total: Int = 0
    @Published var isWorking: Bool = false
    @Published var failedCount: Int = 0
    @Published var exportItems: [ExportItem] = []
    /// True once a run has finished for the current photos.
    @Published var hasRun: Bool = false

    /// Called from `.task(id:)`, so a settings change cancels the previous run. The short sleep is the debounce.
    func run(photos: [LoadedPhoto], settings: CmpSettings) async {
        do {
            try await Task.sleep(nanoseconds: 400_000_000)
        } catch {
            return
        }
        guard !photos.isEmpty else {
            hasRun = false
            results = [:]
            exportItems = []
            total = 0
            completed = 0
            failedCount = 0
            isWorking = false
            return
        }
        isWorking = true
        exportItems = []
        total = photos.count
        completed = 0
        failedCount = 0

        var fresh: [UUID: CmpResult] = [:]
        for photo in photos {
            let image: CGImage = photo.image
            let properties: [String: Any] = settings.removePrivate
                ? ImageCodec.privacySafe(photo.properties)
                : photo.properties
            let originalBytes: Int = photo.originalBytes
            let jobSettings: CmpSettings = settings
            let result: CmpResult? = await Task.detached(priority: .userInitiated) { () -> CmpResult? in
                CmpEngine.compress(image, properties: properties, settings: jobSettings, originalBytes: originalBytes)
            }.value
            if Task.isCancelled { return }
            if let result {
                fresh[photo.id] = result
                results[photo.id] = result
            } else {
                failedCount += 1
            }
            completed += 1
        }

        results = fresh
        var items: [ExportItem] = []
        for (index, photo) in photos.enumerated() {
            guard let result = fresh[photo.id] else { continue }
            let base: String = photos.count > 1 ? "Aperta-compressed-\(index + 1)" : "Aperta-compressed"
            let name: String = ExportItem.uniqueName(base, format: settings.format)
            items.append(ExportItem(data: result.data, filename: name, format: settings.format))
        }
        exportItems = items
        hasRun = true
        isWorking = false
    }
}

// MARK: - Screen

struct CompressView: View {
    @StateObject private var selection = PhotoSelection()
    @StateObject private var thumbnails = PhotoListThumbnails()
    @StateObject private var model = CmpModel()

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var format: OutputFormat = .jpeg
    @State private var mode: CmpMode = .quality
    @State private var quality: Double = 75
    @State private var targetKB: Double = 500
    @State private var removePrivate: Bool = true

    init() {}

    private var formats: [OutputFormat] {
        let lossy = OutputFormat.available.filter { $0.usesQuality }
        return lossy.isEmpty ? [.jpeg] : lossy
    }

    private var photoIDs: [UUID] { selection.photos.map { $0.id } }

    private var settings: CmpSettings {
        CmpSettings(
            format: format,
            mode: mode,
            quality: Int(quality.rounded()),
            targetKB: Int((targetKB / 10).rounded()) * 10,
            removePrivate: removePrivate
        )
    }

    var body: some View {
        ToolScreen(
            title: "Compress",
            subtitle: "Make photos lighter to send, upload or store. Everything happens on this phone."
        ) {
            content
        }
        #if DEBUG
        .task { if DebugSamples.enabled && selection.photos.isEmpty { selection.photos = DebugSamples.photos(3); quality = 45 } }
        #endif
        .onChange(of: pickerItems) { _, newItems in
            Task { await selection.load(newItems, maxPixel: 4096) }
        }
        .task(id: photoIDs) {
            await prepareThumbnails()
        }
        .task(id: CmpJobKey(photoIDs: photoIDs, settings: settings)) {
            await runCompression()
        }
    }

    private func prepareThumbnails() async {
        await thumbnails.prepare(selection.photos)
    }

    private func runCompression() async {
        await model.run(photos: selection.photos, settings: settings)
    }

    @ViewBuilder
    private var content: some View {
        if selection.photos.isEmpty {
            if selection.isLoading {
                loadingRow
            } else {
                pickerPrompt
            }
        } else {
            settingsPanel
            resultSection
            photoList
        }
    }

    // MARK: Picking

    private var pickerPrompt: some View {
        VStack(alignment: .leading, spacing: AP.Space.s) {
            PhotosPicker(selection: $pickerItems, maxSelectionCount: 20, matching: .images) {
                PickPhotosPrompt(
                    title: "Choose photos",
                    detail: "Pick up to 20 photos. You will see the new size of each one before you save."
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Choose up to 20 photos to compress"))
            failedNote
        }
    }

    private var loadingRow: some View {
        HStack(spacing: AP.Space.s) {
            ProgressView().tint(AP.Palette.brass)
            Text("Opening your photos")
                .font(AP.Font.callout)
                .foregroundStyle(AP.Palette.mist)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    @ViewBuilder
    private var failedNote: some View {
        if selection.failedCount > 0 {
            Text(selection.failedCount == 1
                 ? "1 photo could not be opened and was skipped."
                 : "\(selection.failedCount) photos could not be opened and were skipped.")
                .font(AP.Font.caption)
                .foregroundStyle(AP.Palette.danger)
        }
    }

    // MARK: Settings

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: AP.Space.m) {
            formatRow
            APHairline()
            modeRow
            modeControl
            APHairline()
            privacyToggle
        }
        .padding(AP.Space.m)
        .background(AP.Palette.carbon, in: RoundedRectangle(cornerRadius: AP.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AP.Radius.panel, style: .continuous)
                .strokeBorder(AP.Palette.line, lineWidth: 1)
        )
    }

    private var formatRow: some View {
        VStack(alignment: .leading, spacing: AP.Space.s) {
            Text("Format").font(AP.Font.label).foregroundStyle(AP.Palette.mist)
            HStack(spacing: AP.Space.s) {
                ForEach(formats) { option in
                    APChip(title: option.title, selected: format == option) {
                        APHaptics.tap()
                        format = option
                    }
                    .accessibilityLabel(Text("Save as \(option.title)"))
                }
            }
            if format == .heic {
                Text("HEIC files are about half the size of JPG at the same quality. Some older computers and websites cannot open them.")
                    .font(AP.Font.caption)
                    .foregroundStyle(AP.Palette.mist)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modeRow: some View {
        VStack(alignment: .leading, spacing: AP.Space.s) {
            Text("Compress by").font(AP.Font.label).foregroundStyle(AP.Palette.mist)
            HStack(spacing: AP.Space.s) {
                ForEach(CmpMode.allCases) { option in
                    APChip(title: option.title, selected: mode == option) {
                        APHaptics.tap()
                        mode = option
                    }
                    .accessibilityLabel(Text("Compress by \(option.title.lowercased())"))
                }
            }
        }
    }

    @ViewBuilder
    private var modeControl: some View {
        switch mode {
        case .quality:
            VStack(alignment: .leading, spacing: AP.Space.xs) {
                DialSlider(title: "Quality", value: $quality, range: 10...100, defaultValue: 75, unit: "%")
                Text("75% looks the same as the original for most photos.")
                    .font(AP.Font.caption)
                    .foregroundStyle(AP.Palette.mist)
            }
        case .targetSize:
            VStack(alignment: .leading, spacing: AP.Space.xs) {
                DialSlider(title: "Largest file size", value: $targetKB, range: 50...5000, defaultValue: 500, unit: " KB")
                Text("Each photo gets the best quality that fits. Very small targets also reduce the pixel size.")
                    .font(AP.Font.caption)
                    .foregroundStyle(AP.Palette.mist)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var privacyToggle: some View {
        Toggle(isOn: $removePrivate) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Remove location and personal data")
                    .font(AP.Font.body)
                    .foregroundStyle(AP.Palette.paper)
                Text("Removes where the photo was taken, camera serial numbers and owner names.")
                    .font(AP.Font.caption)
                    .foregroundStyle(AP.Palette.mist)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(AP.Palette.brass)
        .frame(minHeight: 44)
    }

    // MARK: Results

    private var currentResults: [CmpResult] {
        selection.photos.compactMap { model.results[$0.id] }
    }

    @ViewBuilder
    private var resultSection: some View {
        VStack(alignment: .leading, spacing: AP.Space.m) {
            if model.isWorking || !model.hasRun {
                progressRow
            } else {
                summaryBlock
            }
            ExportBar(
                items: model.isWorking ? [] : model.exportItems,
                savedMessage: model.exportItems.count == 1
                    ? "Saved the compressed photo to your library"
                    : "Saved \(model.exportItems.count) compressed photos to your library"
            )
        }
    }

    private var progressRow: some View {
        HStack(spacing: AP.Space.s) {
            ProgressView().tint(AP.Palette.brass)
            Text(model.total > 0
                 ? "Compressing \(min(model.completed + 1, model.total)) of \(model.total)"
                 : "Preparing")
                .font(AP.Font.callout)
                .foregroundStyle(AP.Palette.mist)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    private var summaryBlock: some View {
        let results: [CmpResult] = currentResults
        let before: Int = results.reduce(0) { $0 + $1.originalBytes }
        let after: Int = results.reduce(0) { $0 + $1.data.count }
        let saved: Int = before > 0 ? Int(((1 - Double(after) / Double(before)) * 100).rounded()) : 0
        return VStack(alignment: .leading, spacing: AP.Space.xs) {
            Text("\(PhotoListText.photoCount(results.count)), \(ByteText.string(before)) to \(ByteText.string(after))")
                .font(AP.Font.headline)
                .foregroundStyle(AP.Palette.paper)
            Text(saved > 0
                 ? "\(saved)% smaller overall"
                 : "These photos are already well compressed. Try a lower quality or a smaller target.")
                .font(AP.Font.callout)
                .foregroundStyle(saved > 0 ? AP.Palette.brass : AP.Palette.mist)
                .fixedSize(horizontal: false, vertical: true)
            if model.failedCount > 0 {
                Text(model.failedCount == 1
                     ? "1 photo could not be compressed in this format."
                     : "\(model.failedCount) photos could not be compressed in this format.")
                    .font(AP.Font.caption)
                    .foregroundStyle(AP.Palette.danger)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: List

    private var photoList: some View {
        VStack(alignment: .leading, spacing: AP.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                APSectionTitle(text: "Photos")
                Spacer()
                PhotosPicker(selection: $pickerItems, maxSelectionCount: 20, matching: .images) {
                    Text("Choose other photos")
                        .font(AP.Font.label)
                        .foregroundStyle(AP.Palette.brass)
                        .frame(minHeight: 44)
                }
                .accessibilityLabel(Text("Choose other photos"))
            }
            failedNote
            VStack(spacing: 0) {
                ForEach(selection.photos) { photo in
                    row(for: photo)
                    APHairline()
                }
            }
        }
    }

    private func row(for photo: LoadedPhoto) -> some View {
        let result: CmpResult? = model.results[photo.id]
        let isStale: Bool = model.isWorking
        var resultText: String? = nil
        var tone: PhotoListRow.Tone = .neutral
        if let result {
            var text = PhotoListText.sizeChange(from: result.originalBytes, to: result.data.count)
            if result.wasScaled {
                text += ". Scaled to \(PhotoListText.pixels(result.pixelSize)) to fit"
            }
            resultText = text
            tone = result.data.count < result.originalBytes ? .good : .warning
            if isStale { tone = .neutral }
        }
        let photoID: UUID = photo.id
        let currentSelection: PhotoSelection = selection
        var removeAction: (() -> Void)? = nil
        if selection.photos.count > 1 {
            removeAction = { currentSelection.remove(photoID) }
        }
        return PhotoListRow(
            thumbnail: thumbnails.images[photo.id],
            title: photo.name,
            detail: "\(ByteText.string(photo.originalBytes)), \(PhotoListText.pixels(photo.pixelSize))",
            result: resultText,
            tone: tone,
            onRemove: removeAction
        )
        .opacity(isStale && result != nil ? 0.6 : 1)
    }
}
