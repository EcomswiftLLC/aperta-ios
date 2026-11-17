import SwiftUI
import PhotosUI
import UIKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Settings

private enum CnvTarget: Hashable, Identifiable {
    case image(OutputFormat)
    case pdf

    var id: String {
        switch self {
        case .image(let format): return format.rawValue
        case .pdf: return "pdf"
        }
    }

    var title: String {
        switch self {
        case .image(let format): return format.title
        case .pdf: return "PDF"
        }
    }

    var imageFormat: OutputFormat? {
        if case .image(let format) = self { return format }
        return nil
    }

    static var all: [CnvTarget] {
        OutputFormat.available.map { CnvTarget.image($0) } + [CnvTarget.pdf]
    }
}

private enum CnvPageSize: String, CaseIterable, Identifiable {
    case fit, a4, letter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fit: return "Fit to photo"
        case .a4: return "A4"
        case .letter: return "Letter"
        }
    }
}

private struct CnvSettings: Equatable {
    var target: CnvTarget
    var quality: Int
    var keepMetadata: Bool
    var pageSize: CnvPageSize
    var margin: Int
}

private struct CnvJobKey: Equatable {
    var photoIDs: [UUID]
    var settings: CnvSettings
}

private struct CnvResult {
    let data: Data
    let format: OutputFormat
}

/// Pure work, safe to call off the main thread.
private enum CnvEngine {
    /// Short name of the file type the person picked, for example "HEIC".
    static func sourceFormatName(_ data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) else { return "Photo" }
        let identifier = type as String
        switch identifier {
        case UTType.jpeg.identifier: return "JPG"
        case UTType.png.identifier: return "PNG"
        case UTType.heic.identifier: return "HEIC"
        case UTType.heif.identifier: return "HEIF"
        case UTType.gif.identifier: return "GIF"
        case UTType.tiff.identifier: return "TIFF"
        case UTType.webP.identifier: return "WebP"
        case UTType.bmp.identifier: return "BMP"
        default:
            if let ext = UTType(identifier)?.preferredFilenameExtension { return ext.uppercased() }
            return "Photo"
        }
    }

    static func convert(_ image: CGImage, format: OutputFormat, quality: Int, properties: [String: Any]?) -> CnvResult? {
        guard let data = ImageCodec.encode(image, format: format, quality: Double(quality) / 100, properties: properties) else {
            return nil
        }
        return CnvResult(data: data, format: format)
    }

    // PDF

    private static let a4 = CGSize(width: 595.28, height: 841.89)
    private static let letter = CGSize(width: 612, height: 792)
    /// Longest side of a "fit to photo" page, in points (the long side of A4).
    private static let fitLongSide: CGFloat = 842

    static func pageRect(for image: CGImage, pageSize: CnvPageSize, margin: CGFloat) -> CGRect {
        let imageW = CGFloat(max(1, image.width))
        let imageH = CGFloat(max(1, image.height))
        let landscape = imageW > imageH
        switch pageSize {
        case .fit:
            let scale = fitLongSide / max(imageW, imageH)
            return CGRect(x: 0, y: 0, width: imageW * scale + margin * 2, height: imageH * scale + margin * 2)
        case .a4:
            return CGRect(x: 0, y: 0, width: landscape ? a4.height : a4.width, height: landscape ? a4.width : a4.height)
        case .letter:
            return CGRect(x: 0, y: 0, width: landscape ? letter.height : letter.width, height: landscape ? letter.width : letter.height)
        }
    }

    static func aspectFit(_ size: CGSize, in box: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, box.width > 0, box.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        let w = size.width * scale
        let h = size.height * scale
        return CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }

    /// A JPEG-backed copy so the PDF stores compressed image data instead of raw pixels.
    static func jpegBacked(_ image: CGImage) -> CGImage? {
        guard let data = ImageCodec.encode(image, format: .jpeg, quality: 0.88),
              let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            jpegDataProviderSource: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    /// One photo per page.
    static func makePDF(_ images: [CGImage], pageSize: CnvPageSize, margin: CGFloat) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextCreator as String: "Aperta",
            kCGPDFContextTitle as String: "Photos",
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: a4), format: format)
        return renderer.pdfData { context in
            for image in images {
                autoreleasepool {
                    let page = pageRect(for: image, pageSize: pageSize, margin: margin)
                    context.beginPage(withBounds: page, pageInfo: [:])
                    let box = page.insetBy(dx: margin, dy: margin)
                    let drawRect = aspectFit(CGSize(width: image.width, height: image.height), in: box)
                    let embedded: CGImage = jpegBacked(image) ?? image
                    UIImage(cgImage: embedded).draw(in: drawRect)
                }
            }
        }
    }
}

@MainActor
private final class CnvModel: ObservableObject {
    @Published var results: [UUID: CnvResult] = [:]
    @Published var pdfData: Data?
    @Published var completed: Int = 0
    @Published var total: Int = 0
    @Published var isWorking: Bool = false
    @Published var failedCount: Int = 0
    @Published var exportItems: [ExportItem] = []
    /// True once a run has finished for the current photos.
    @Published var hasRun: Bool = false

    func run(photos: [LoadedPhoto], settings: CnvSettings) async {
        do {
            try await Task.sleep(nanoseconds: 400_000_000)
        } catch {
            return
        }
        guard !photos.isEmpty else {
            hasRun = false
            results = [:]
            pdfData = nil
            exportItems = []
            total = 0
            completed = 0
            failedCount = 0
            isWorking = false
            return
        }
        isWorking = true
        exportItems = []
        pdfData = nil
        total = photos.count
        completed = 0
        failedCount = 0

        switch settings.target {
        case .pdf:
            await buildPDF(photos: photos, settings: settings)
        case .image(let format):
            await convertImages(photos: photos, settings: settings, format: format)
        }
    }

    private func buildPDF(photos: [LoadedPhoto], settings: CnvSettings) async {
        let images: [CGImage] = photos.map { $0.image }
        let pageSize: CnvPageSize = settings.pageSize
        let margin = CGFloat(settings.margin)
        let data: Data = await Task.detached(priority: .userInitiated) { () -> Data in
            CnvEngine.makePDF(images, pageSize: pageSize, margin: margin)
        }.value
        if Task.isCancelled { return }
        completed = photos.count
        results = [:]
        pdfData = data.isEmpty ? nil : data
        if data.isEmpty { failedCount = photos.count }
        hasRun = true
        isWorking = false
    }

    private func convertImages(photos: [LoadedPhoto], settings: CnvSettings, format: OutputFormat) async {
        var fresh: [UUID: CnvResult] = [:]
        for photo in photos {
            let image: CGImage = photo.image
            let properties: [String: Any]? = settings.keepMetadata ? ImageCodec.privacySafe(photo.properties) : nil
            let quality: Int = settings.quality
            let result: CnvResult? = await Task.detached(priority: .userInitiated) { () -> CnvResult? in
                CnvEngine.convert(image, format: format, quality: quality, properties: properties)
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
            let base: String = photos.count > 1 ? "Aperta-converted-\(index + 1)" : "Aperta-converted"
            items.append(ExportItem(
                data: result.data,
                filename: ExportItem.uniqueName(base, format: format),
                format: format
            ))
        }
        exportItems = items
        hasRun = true
        isWorking = false
    }
}

// MARK: - PDF share button

/// PDF files cannot go to the photo library, so they are shared (Files, Mail, Messages, printers ...).
/// Sharing uses one export, like every other save or share (see `ExportBar`).
private struct CnvPDFShareButton: View {
    let data: Data?

    @EnvironmentObject private var exportStore: ExportStore
    @State private var sheet: ExportPresentation?
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AP.Space.s) {
            Button {
                request()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.up")
                    Text("Share PDF")
                }
            }
            .buttonStyle(.apPrimaryWide)
            .disabled(data == nil)
            .accessibilityLabel(Text("Share PDF"))
            .accessibilityHint(Text("Save to Files, send or print the PDF"))

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(AP.Font.label)
                    .foregroundStyle(AP.Palette.danger)
            } else {
                Text("Choose Save to Files to keep it, or send it straight to an app or printer.")
                    .font(AP.Font.caption)
                    .foregroundStyle(AP.Palette.mist)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .exportSheets($sheet, onUnlocked: share, onShareFinished: shareFinished)
    }

    @MainActor
    private func request() {
        guard exportStore.access.isOpen else {
            sheet = .paywall
            return
        }
        share()
    }

    @MainActor
    private func shareFinished(_ completed: Bool) {
        exportStore.settle(completed ? .completed : .cancelled)
        if completed { InterstitialController.shared.exportFinished() }
    }

    @MainActor
    private func share() {
        guard exportStore.access.isOpen else { return }
        guard let data else { return }
        let stamp = Int(Date().timeIntervalSince1970 * 1000) % 100_000_000
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Aperta-photos-\(stamp).pdf")
        do {
            try data.write(to: url, options: .atomic)
            errorText = nil
            sheet = .share([url])
        } catch {
            errorText = "Could not prepare the PDF. Try again."
        }
    }
}

// MARK: - Screen

struct ConvertView: View {
    @StateObject private var selection = PhotoSelection()
    @StateObject private var thumbnails = PhotoListThumbnails()
    @StateObject private var model = CnvModel()

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var target: CnvTarget = .image(.jpeg)
    @State private var quality: Double = 90
    @State private var keepMetadata: Bool = false
    @State private var pageSize: CnvPageSize = .a4
    @State private var margin: Double = 24

    init() {}

    private var photoIDs: [UUID] { selection.photos.map { $0.id } }

    private var settings: CnvSettings {
        CnvSettings(
            target: target,
            quality: Int(quality.rounded()),
            keepMetadata: keepMetadata,
            pageSize: pageSize,
            margin: Int(margin.rounded())
        )
    }

    private var subtitle: String {
        let names = CnvTarget.all.map { $0.title }
        guard names.count > 1 else { return "Change the file type of your photos." }
        let head = names.dropLast().joined(separator: ", ")
        return "Change photos to \(head) or \(names[names.count - 1]). PDF puts one photo on each page."
    }

    var body: some View {
        ToolScreen(title: "Convert", subtitle: subtitle) {
            content
        }
        #if DEBUG
        .task { if DebugSamples.enabled && selection.photos.isEmpty { selection.photos = DebugSamples.photos(3) } }
        #endif
        .onChange(of: pickerItems) { _, newItems in
            Task { await selection.load(newItems, maxPixel: 4096) }
        }
        .task(id: photoIDs) {
            await prepareThumbnails()
        }
        .task(id: CnvJobKey(photoIDs: photoIDs, settings: settings)) {
            await runConversion()
        }
    }

    private func prepareThumbnails() async {
        await thumbnails.prepare(selection.photos)
    }

    private func runConversion() async {
        await model.run(photos: selection.photos, settings: settings)
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
            settingsPanel
            resultSection
            photoList
        }
    }

    private var pickerPrompt: some View {
        VStack(alignment: .leading, spacing: AP.Space.s) {
            PhotosPicker(selection: $pickerItems, maxSelectionCount: 30, matching: .images) {
                PickPhotosPrompt(
                    title: "Choose photos",
                    detail: "Pick up to 30 photos to change their format, or to put them together in one PDF.",
                    systemImage: "arrow.triangle.2.circlepath"
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Choose up to 30 photos to convert"))
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
            targetRow
            APHairline()
            if target == .pdf {
                pdfControls
            } else {
                imageControls
            }
        }
        .padding(AP.Space.m)
        .background(AP.Palette.carbon, in: RoundedRectangle(cornerRadius: AP.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AP.Radius.panel, style: .continuous)
                .strokeBorder(AP.Palette.line, lineWidth: 1)
        )
    }

    private var targetRow: some View {
        VStack(alignment: .leading, spacing: AP.Space.s) {
            Text("Convert to").font(AP.Font.label).foregroundStyle(AP.Palette.mist)
            HStack(spacing: AP.Space.s) {
                ForEach(CnvTarget.all) { option in
                    APChip(title: option.title, selected: target == option) {
                        APHaptics.tap()
                        target = option
                    }
                    .accessibilityLabel(Text("Convert to \(option.title)"))
                }
            }
        }
    }

    private var imageControls: some View {
        VStack(alignment: .leading, spacing: AP.Space.m) {
            if let format = target.imageFormat, format.usesQuality {
                DialSlider(title: "Quality", value: $quality, range: 10...100, defaultValue: 90, unit: "%")
            } else {
                Text("PNG keeps every pixel exactly. Files are larger than JPG or HEIC.")
                    .font(AP.Font.caption)
                    .foregroundStyle(AP.Palette.mist)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle(isOn: $keepMetadata) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep camera details")
                        .font(AP.Font.body)
                        .foregroundStyle(AP.Palette.paper)
                    Text("Date, camera and lens settings. Location and personal data are always removed.")
                        .font(AP.Font.caption)
                        .foregroundStyle(AP.Palette.mist)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(AP.Palette.brass)
            .frame(minHeight: 44)
        }
    }

    private var pdfControls: some View {
        VStack(alignment: .leading, spacing: AP.Space.m) {
            VStack(alignment: .leading, spacing: AP.Space.s) {
                Text("Page size").font(AP.Font.label).foregroundStyle(AP.Palette.mist)
                HStack(spacing: AP.Space.s) {
                    ForEach(CnvPageSize.allCases) { option in
                        APChip(title: option.title, selected: pageSize == option) {
                            APHaptics.tap()
                            pageSize = option
                        }
                        .accessibilityLabel(Text("Page size \(option.title)"))
                    }
                }
            }
            DialSlider(title: "Margin", value: $margin, range: 0...40, defaultValue: 24, unit: " pt")
            Text("One photo per page. Pages turn sideways for landscape photos.")
                .font(AP.Font.caption)
                .foregroundStyle(AP.Palette.mist)
                .fixedSize(horizontal: false, vertical: true)
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
            if target == .pdf {
                CnvPDFShareButton(data: model.isWorking ? nil : model.pdfData)
            } else {
                ExportBar(
                    items: model.isWorking ? [] : model.exportItems,
                    savedMessage: model.exportItems.count == 1
                        ? "Saved the converted photo to your library"
                        : "Saved \(model.exportItems.count) converted photos to your library"
                )
            }
        }
    }

    private var progressRow: some View {
        HStack(spacing: AP.Space.s) {
            ProgressView().tint(AP.Palette.brass)
            Text(progressText)
                .font(AP.Font.callout)
                .foregroundStyle(AP.Palette.mist)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    private var progressText: String {
        if target == .pdf { return "Making the PDF" }
        guard model.total > 0 else { return "Preparing" }
        return "Converting \(min(model.completed + 1, model.total)) of \(model.total)"
    }

    private var summaryBlock: some View {
        let before: Int = selection.photos.reduce(0) { $0 + $1.originalBytes }
        let headline: String
        let detail: String
        if target == .pdf {
            if let data = model.pdfData {
                let pages = selection.photos.count
                headline = "PDF, \(pages == 1 ? "1 page" : "\(pages) pages"), \(ByteText.string(data.count))"
                detail = "Made from \(PhotoListText.photoCount(pages)), \(ByteText.string(before)) in total."
            } else {
                headline = "The PDF could not be made"
                detail = "Try fewer photos, or choose them again."
            }
        } else {
            let results: [CnvResult] = selection.photos.compactMap { model.results[$0.id] }
            let after: Int = results.reduce(0) { $0 + $1.data.count }
            headline = "\(PhotoListText.photoCount(results.count)) as \(target.title), \(ByteText.string(before)) to \(ByteText.string(after))"
            detail = model.failedCount > 0
                ? "\(model.failedCount) could not be converted and will be left out."
                : "Ready to save or share."
        }
        return VStack(alignment: .leading, spacing: AP.Space.xs) {
            Text(headline)
                .font(AP.Font.headline)
                .foregroundStyle(AP.Palette.paper)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(AP.Font.callout)
                .foregroundStyle(model.failedCount > 0 ? AP.Palette.danger : AP.Palette.mist)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: List

    private var photoList: some View {
        VStack(alignment: .leading, spacing: AP.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                APSectionTitle(text: "Photos")
                Spacer()
                PhotosPicker(selection: $pickerItems, maxSelectionCount: 30, matching: .images) {
                    Text("Choose other photos")
                        .font(AP.Font.label)
                        .foregroundStyle(AP.Palette.brass)
                        .frame(minHeight: 44)
                }
                .accessibilityLabel(Text("Choose other photos"))
            }
            failedNote
            VStack(spacing: 0) {
                ForEach(Array(selection.photos.enumerated()), id: \.element.id) { index, photo in
                    row(for: photo, index: index)
                    APHairline()
                }
            }
        }
    }

    private func row(for photo: LoadedPhoto, index: Int) -> some View {
        let sourceName: String = CnvEngine.sourceFormatName(photo.originalData)
        let before: String = "\(sourceName), \(ByteText.string(photo.originalBytes))"
        var resultText: String? = nil
        if target == .pdf {
            if model.pdfData != nil { resultText = "\(before) to page \(index + 1)" }
        } else if let result = model.results[photo.id] {
            resultText = "\(before) to \(result.format.title), \(ByteText.string(result.data.count))"
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
            detail: "\(before), \(PhotoListText.pixels(photo.pixelSize))",
            result: resultText,
            tone: model.isWorking ? .neutral : .good,
            onRemove: removeAction
        )
        .opacity(model.isWorking && resultText != nil ? 0.6 : 1)
    }
}
