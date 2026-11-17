import SwiftUI
import PhotosUI
import UIKit
import ImageIO

// MARK: - Settings

private enum RszMode: String, CaseIterable, Identifiable {
    case pixels, percent, social

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pixels: return "Pixels"
        case .percent: return "Percent"
        case .social: return "Social sizes"
        }
    }
}

private struct RszPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let width: Int
    let height: Int

    static let all: [RszPreset] = [
        RszPreset(id: "ig-post", name: "Instagram post", width: 1080, height: 1350),
        RszPreset(id: "ig-square", name: "Instagram square", width: 1080, height: 1080),
        RszPreset(id: "ig-story", name: "Instagram story and Reels", width: 1080, height: 1920),
        RszPreset(id: "tiktok", name: "TikTok", width: 1080, height: 1920),
        RszPreset(id: "yt-thumb", name: "YouTube thumbnail", width: 1280, height: 720),
        RszPreset(id: "yt-banner", name: "YouTube channel banner", width: 2560, height: 1440),
        RszPreset(id: "fb-post", name: "Facebook post", width: 1200, height: 630),
        RszPreset(id: "fb-cover", name: "Facebook cover", width: 1640, height: 624),
        RszPreset(id: "x-post", name: "X post", width: 1600, height: 900),
        RszPreset(id: "x-header", name: "X header", width: 1500, height: 500),
        RszPreset(id: "li-banner", name: "LinkedIn banner", width: 1584, height: 396),
        RszPreset(id: "li-post", name: "LinkedIn post", width: 1200, height: 627),
        RszPreset(id: "pin", name: "Pinterest pin", width: 1000, height: 1500),
        RszPreset(id: "wa-status", name: "WhatsApp status", width: 1080, height: 1920),
        RszPreset(id: "passport", name: "Passport photo", width: 600, height: 600),
    ]
}

/// What to do to every photo.
private enum RszPlan: Equatable {
    /// Exact width and height (proportions may change).
    case exact(width: Int, height: Int)
    /// Set the width, the height follows each photo's own proportions.
    case fitWidth(Int)
    case percent(Int)
    /// Fill the size and crop the overflow from the centre.
    case fill(width: Int, height: Int)
}

private struct RszSettings: Equatable {
    var plan: RszPlan
    var format: OutputFormat
    var quality: Int
}

private struct RszJobKey: Equatable {
    var photoIDs: [UUID]
    var settings: RszSettings?
}

private struct RszOutput {
    let data: Data
    let pixelSize: CGSize
    let preview: UIImage?
}

private enum RszField: Hashable { case width, height }

/// Pure work, safe to call off the main thread.
private enum RszEngine {
    static let maxSide: Int = 10_000

    static func targetSize(for image: CGImage, plan: RszPlan) -> CGSize {
        let w = Double(image.width)
        let h = Double(image.height)
        var outW: Double
        var outH: Double
        switch plan {
        case let .exact(width, height):
            outW = Double(width); outH = Double(height)
        case let .fitWidth(width):
            outW = Double(width)
            outH = w > 0 ? (Double(width) * h / w).rounded() : Double(width)
        case let .percent(value):
            outW = (w * Double(value) / 100).rounded()
            outH = (h * Double(value) / 100).rounded()
        case let .fill(width, height):
            outW = Double(width); outH = Double(height)
        }
        outW = min(Double(maxSide), max(1, outW))
        outH = min(Double(maxSide), max(1, outH))
        return CGSize(width: outW, height: outH)
    }

    static func render(_ image: CGImage, plan: RszPlan) -> CGImage? {
        let size = targetSize(for: image, plan: plan)
        switch plan {
        case .fill:
            return aspectFill(image, width: Int(size.width), height: Int(size.height))
        default:
            return ImageCodec.scaled(image, to: size)
        }
    }

    /// Scales the image to cover the whole canvas and crops what overflows, keeping the centre.
    static func aspectFill(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, image.width > 0, image.height > 0 else { return nil }
        var space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        if let own = image.colorSpace, own.model == .rgb, own.supportsOutput { space = own }
        let info: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: info
        ) else { return nil }
        context.interpolationQuality = .high
        let sourceW = CGFloat(image.width)
        let sourceH = CGFloat(image.height)
        let scale: CGFloat = max(CGFloat(width) / sourceW, CGFloat(height) / sourceH)
        let drawW = sourceW * scale
        let drawH = sourceH * scale
        let rect = CGRect(
            x: (CGFloat(width) - drawW) / 2,
            y: (CGFloat(height) - drawH) / 2,
            width: drawW,
            height: drawH
        )
        context.draw(image, in: rect)
        return context.makeImage()
    }

    static func process(
        _ image: CGImage,
        properties: [String: Any],
        settings: RszSettings,
        makePreview: Bool
    ) -> RszOutput? {
        guard let resized = render(image, plan: settings.plan) else { return nil }
        guard let data = ImageCodec.encode(
            resized,
            format: settings.format,
            quality: Double(settings.quality) / 100,
            properties: properties
        ) else { return nil }
        var preview: UIImage? = nil
        if makePreview, let small = ImageCodec.scaled(resized, maxPixel: 1200) {
            preview = UIImage(cgImage: small)
        }
        return RszOutput(data: data, pixelSize: CGSize(width: resized.width, height: resized.height), preview: preview)
    }
}

@MainActor
private final class RszModel: ObservableObject {
    @Published var outputs: [UUID: RszOutput] = [:]
    @Published var preview: UIImage?
    @Published var completed: Int = 0
    @Published var total: Int = 0
    @Published var isWorking: Bool = false
    @Published var failedCount: Int = 0
    @Published var exportItems: [ExportItem] = []
    /// True once a run has finished for the current photos and settings.
    @Published var hasRun: Bool = false

    func run(photos: [LoadedPhoto], settings: RszSettings?) async {
        do {
            try await Task.sleep(nanoseconds: 400_000_000)
        } catch {
            return
        }
        guard let settings, !photos.isEmpty else {
            hasRun = false
            outputs = [:]
            preview = nil
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

        var fresh: [UUID: RszOutput] = [:]
        for (index, photo) in photos.enumerated() {
            let image: CGImage = photo.image
            let properties: [String: Any] = ImageCodec.privacySafe(photo.properties)
            let jobSettings: RszSettings = settings
            let wantsPreview: Bool = index == 0
            let output: RszOutput? = await Task.detached(priority: .userInitiated) { () -> RszOutput? in
                RszEngine.process(image, properties: properties, settings: jobSettings, makePreview: wantsPreview)
            }.value
            if Task.isCancelled { return }
            if let output {
                fresh[photo.id] = output
                outputs[photo.id] = output
                if let previewImage = output.preview { preview = previewImage }
            } else {
                failedCount += 1
            }
            completed += 1
        }

        outputs = fresh
        var items: [ExportItem] = []
        for (index, photo) in photos.enumerated() {
            guard let output = fresh[photo.id] else { continue }
            let base: String = photos.count > 1 ? "Aperta-resized-\(index + 1)" : "Aperta-resized"
            items.append(ExportItem(
                data: output.data,
                filename: ExportItem.uniqueName(base, format: settings.format),
                format: settings.format
            ))
        }
        exportItems = items
        hasRun = true
        isWorking = false
    }
}

// MARK: - Screen

struct ResizeView: View {
    @StateObject private var selection = PhotoSelection()
    @StateObject private var thumbnails = PhotoListThumbnails()
    @StateObject private var model = RszModel()

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var mode: RszMode = .pixels
    @State private var widthText: String = ""
    @State private var heightText: String = ""
    @State private var keepProportions: Bool = true
    @State private var percent: Double = 50
    @State private var presetID: String = RszPreset.all[0].id
    @State private var format: OutputFormat = .jpeg
    @State private var quality: Double = 90
    @FocusState private var focusedField: RszField?

    init() {}

    private var photoIDs: [UUID] { selection.photos.map { $0.id } }
    private var firstPhoto: LoadedPhoto? { selection.photos.first }

    private var enteredWidth: Int? { Self.parse(widthText) }
    private var enteredHeight: Int? { Self.parse(heightText) }

    private static func parse(_ text: String) -> Int? {
        guard let value = Int(text), value >= 1, value <= RszEngine.maxSide else { return nil }
        return value
    }

    private var selectedPreset: RszPreset {
        RszPreset.all.first { $0.id == presetID } ?? RszPreset.all[0]
    }

    private var plan: RszPlan? {
        switch mode {
        case .pixels:
            guard let width = enteredWidth else { return nil }
            if keepProportions { return .fitWidth(width) }
            guard let height = enteredHeight else { return nil }
            return .exact(width: width, height: height)
        case .percent:
            return .percent(Int(percent.rounded()))
        case .social:
            return .fill(width: selectedPreset.width, height: selectedPreset.height)
        }
    }

    private var settings: RszSettings? {
        guard let plan else { return nil }
        return RszSettings(plan: plan, format: format, quality: Int(quality.rounded()))
    }

    var body: some View {
        ToolScreen(
            title: "Resize",
            subtitle: "Set an exact size, scale by percent, or fit a social post. Photos are cropped from the centre only for social sizes."
        ) {
            content
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
                    .foregroundStyle(AP.Palette.brass)
            }
        }
        #if DEBUG
        .task { if DebugSamples.enabled && selection.photos.isEmpty { selection.photos = DebugSamples.photos(3) } }
        #endif
        .onChange(of: pickerItems) { _, newItems in
            Task { await selection.load(newItems, maxPixel: 4096) }
        }
        .onChange(of: firstPhoto?.id) { _, _ in
            fillFieldsFromFirstPhoto()
        }
        .onChange(of: widthText) { _, newValue in
            widthChanged(newValue)
        }
        .onChange(of: heightText) { _, newValue in
            heightChanged(newValue)
        }
        .onChange(of: keepProportions) { _, isOn in
            if isOn { syncHeightToWidth() }
        }
        .task(id: photoIDs) {
            await prepareThumbnails()
        }
        .task(id: RszJobKey(photoIDs: photoIDs, settings: settings)) {
            await runResize()
        }
    }

    private func prepareThumbnails() async {
        await thumbnails.prepare(selection.photos)
    }

    private func runResize() async {
        await model.run(photos: selection.photos, settings: settings)
    }

    // MARK: Field logic

    private func fillFieldsFromFirstPhoto() {
        guard let first = firstPhoto else { return }
        widthText = String(first.image.width)
        heightText = String(first.image.height)
    }

    private static func digitsOnly(_ text: String) -> String {
        String(text.filter { $0.isASCII && $0.isNumber }.prefix(5))
    }

    private func widthChanged(_ newValue: String) {
        let clean = Self.digitsOnly(newValue)
        if clean != newValue { widthText = clean; return }
        if keepProportions && focusedField == .width { syncHeightToWidth() }
    }

    private func heightChanged(_ newValue: String) {
        let clean = Self.digitsOnly(newValue)
        if clean != newValue { heightText = clean; return }
        guard keepProportions, focusedField == .height,
              let first = firstPhoto, let height = Int(clean), height > 0, first.image.height > 0 else { return }
        let width = Int((Double(height) * Double(first.image.width) / Double(first.image.height)).rounded())
        widthText = String(max(1, width))
    }

    private func syncHeightToWidth() {
        guard let first = firstPhoto, let width = Int(widthText), width > 0, first.image.width > 0 else { return }
        let height = Int((Double(width) * Double(first.image.height) / Double(first.image.width)).rounded())
        heightText = String(max(1, height))
    }

    // MARK: Layout

    @ViewBuilder
    private var content: some View {
        if selection.photos.isEmpty {
            if selection.isLoading {
                loadingRow
            } else {
                pickerPrompt
            }
        } else {
            previewPanel
            settingsPanel
            resultSection
            photoList
        }
    }

    private var pickerPrompt: some View {
        VStack(alignment: .leading, spacing: AP.Space.s) {
            PhotosPicker(selection: $pickerItems, maxSelectionCount: 20, matching: .images) {
                PickPhotosPrompt(
                    title: "Choose photos",
                    detail: "Pick up to 20 photos. Every photo gets the same size settings.",
                    systemImage: "arrow.up.left.and.arrow.down.right"
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Choose up to 20 photos to resize"))
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

    // MARK: Preview

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: AP.Space.s) {
            ZStack {
                Rectangle().fill(AP.Palette.carbon)
                previewImage
            }
            .frame(maxWidth: .infinity)
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: AP.Radius.panel, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AP.Radius.panel, style: .continuous)
                    .strokeBorder(AP.Palette.line, lineWidth: 1)
            )
            previewCaption
        }
    }

    @ViewBuilder
    private var previewImage: some View {
        if let image = model.preview {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .padding(AP.Space.m)
                .opacity(model.isWorking ? 0.55 : 1)
                .accessibilityLabel(Text("Preview of the first photo at the new size"))
        } else {
            ProgressView().tint(AP.Palette.brass)
                .accessibilityLabel(Text("Preparing preview"))
        }
    }

    private var previewCaption: some View {
        let output: RszOutput? = firstPhoto.flatMap { model.outputs[$0.id] }
        let text: String
        if settings == nil {
            text = "Enter a width and height between 1 and \(RszEngine.maxSide) pixels."
        } else if let output {
            text = "First photo: \(PhotoListText.pixels(output.pixelSize)) pixels, about \(ByteText.string(output.data.count))"
        } else {
            text = "Working out the new size"
        }
        return Text(text)
            .font(AP.Font.callout)
            .foregroundStyle(settings == nil ? AP.Palette.danger : AP.Palette.mist)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Settings

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: AP.Space.m) {
            modeRow
            modeControls
            APHairline()
            formatRow
            if format.usesQuality {
                DialSlider(title: "Quality", value: $quality, range: 10...100, defaultValue: 90, unit: "%")
            }
        }
        .padding(AP.Space.m)
        .background(AP.Palette.carbon, in: RoundedRectangle(cornerRadius: AP.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AP.Radius.panel, style: .continuous)
                .strokeBorder(AP.Palette.line, lineWidth: 1)
        )
    }

    private var modeRow: some View {
        VStack(alignment: .leading, spacing: AP.Space.s) {
            Text("Resize by").font(AP.Font.label).foregroundStyle(AP.Palette.mist)
            HStack(spacing: AP.Space.s) {
                ForEach(RszMode.allCases) { option in
                    APChip(title: option.title, selected: mode == option) {
                        APHaptics.tap()
                        focusedField = nil
                        mode = option
                    }
                    .accessibilityLabel(Text("Resize by \(option.title.lowercased())"))
                }
            }
        }
    }

    @ViewBuilder
    private var modeControls: some View {
        switch mode {
        case .pixels:
            pixelControls
        case .percent:
            VStack(alignment: .leading, spacing: AP.Space.xs) {
                DialSlider(title: "Scale", value: $percent, range: 10...200, defaultValue: 100, unit: "%")
                Text("Above 100% makes photos larger but does not add detail.")
                    .font(AP.Font.caption)
                    .foregroundStyle(AP.Palette.mist)
            }
        case .social:
            presetList
        }
    }

    private var pixelControls: some View {
        VStack(alignment: .leading, spacing: AP.Space.s) {
            HStack(spacing: AP.Space.s) {
                numberField(title: "Width", text: $widthText, field: .width)
                Text("×")
                    .font(AP.Font.body)
                    .foregroundStyle(AP.Palette.mist)
                    .accessibilityHidden(true)
                numberField(title: "Height", text: $heightText, field: .height)
            }
            Toggle(isOn: $keepProportions) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep proportions")
                        .font(AP.Font.body)
                        .foregroundStyle(AP.Palette.paper)
                    Text(keepProportions
                         ? "Each photo keeps its shape. The height shown is for the first photo."
                         : "Photos are stretched to exactly this size.")
                        .font(AP.Font.caption)
                        .foregroundStyle(AP.Palette.mist)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(AP.Palette.brass)
            .frame(minHeight: 44)
        }
    }

    private func numberField(title: String, text: Binding<String>, field: RszField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(AP.Font.label).foregroundStyle(AP.Palette.mist)
            HStack(spacing: 4) {
                TextField(title, text: text)
                    .keyboardType(.numberPad)
                    .font(AP.Font.number)
                    .foregroundStyle(AP.Palette.paper)
                    .tint(AP.Palette.brass)
                    .focused($focusedField, equals: field)
                    .accessibilityLabel(Text("\(title) in pixels"))
                Text("px")
                    .font(AP.Font.caption)
                    .foregroundStyle(AP.Palette.mist)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, AP.Space.m)
            .frame(minHeight: 48)
            .background(AP.Palette.graphite, in: RoundedRectangle(cornerRadius: AP.Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AP.Radius.control, style: .continuous)
                    .strokeBorder(focusedField == field ? AP.Palette.brass : AP.Palette.line, lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity)
    }

    private var presetList: some View {
        VStack(spacing: 0) {
            ForEach(RszPreset.all) { preset in
                presetRow(preset)
                if preset.id != RszPreset.all.last?.id {
                    APHairline()
                }
            }
        }
    }

    private func presetRow(_ preset: RszPreset) -> some View {
        let isSelected: Bool = preset.id == presetID
        return Button {
            APHaptics.tap()
            presetID = preset.id
        } label: {
            HStack(spacing: AP.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                        .font(AP.Font.body)
                        .foregroundStyle(isSelected ? AP.Palette.brass : AP.Palette.paper)
                    Text("\(preset.width) × \(preset.height)")
                        .font(AP.Font.caption)
                        .foregroundStyle(AP.Palette.mist)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(AP.Font.label)
                        .foregroundStyle(AP.Palette.brass)
                }
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(preset.name), \(preset.width) by \(preset.height) pixels"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }

    private var formatRow: some View {
        VStack(alignment: .leading, spacing: AP.Space.s) {
            Text("Format").font(AP.Font.label).foregroundStyle(AP.Palette.mist)
            HStack(spacing: AP.Space.s) {
                ForEach(OutputFormat.available) { option in
                    APChip(title: option.title, selected: format == option) {
                        APHaptics.tap()
                        format = option
                    }
                    .accessibilityLabel(Text("Save as \(option.title)"))
                }
            }
        }
    }

    // MARK: Results

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
                    ? "Saved the resized photo to your library"
                    : "Saved \(model.exportItems.count) resized photos to your library"
            )
        }
    }

    @ViewBuilder
    private var progressRow: some View {
        if settings != nil {
            HStack(spacing: AP.Space.s) {
                ProgressView().tint(AP.Palette.brass)
                Text(model.total > 0
                     ? "Resizing \(min(model.completed + 1, model.total)) of \(model.total)"
                     : "Preparing")
                    .font(AP.Font.callout)
                    .foregroundStyle(AP.Palette.mist)
            }
            .frame(minHeight: 44)
            .accessibilityElement(children: .combine)
        }
    }

    private var summaryBlock: some View {
        let outputs: [RszOutput] = selection.photos.compactMap { model.outputs[$0.id] }
        let totalBytes: Int = outputs.reduce(0) { $0 + $1.data.count }
        let sizes: Set<String> = Set(outputs.map { PhotoListText.pixels($0.pixelSize) })
        let sizeText: String = sizes.count == 1 ? (sizes.first ?? "") : "sizes vary by photo"
        return VStack(alignment: .leading, spacing: AP.Space.xs) {
            Text("\(PhotoListText.photoCount(outputs.count)), \(sizeText)")
                .font(AP.Font.headline)
                .foregroundStyle(AP.Palette.paper)
            Text("About \(ByteText.string(totalBytes)) in total as \(format.title). Location and personal details are removed.")
                .font(AP.Font.callout)
                .foregroundStyle(AP.Palette.mist)
                .fixedSize(horizontal: false, vertical: true)
            if model.failedCount > 0 {
                Text(model.failedCount == 1
                     ? "1 photo could not be resized."
                     : "\(model.failedCount) photos could not be resized.")
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
        let output: RszOutput? = model.outputs[photo.id]
        var resultText: String? = nil
        if let output {
            resultText = "\(PhotoListText.pixels(output.pixelSize)), \(ByteText.string(output.data.count))"
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
            detail: "\(PhotoListText.pixels(photo.pixelSize)), \(ByteText.string(photo.originalBytes))",
            result: resultText,
            tone: model.isWorking ? .neutral : .good,
            onRemove: removeAction
        )
        .opacity(model.isWorking && output != nil ? 0.6 : 1)
    }
}
