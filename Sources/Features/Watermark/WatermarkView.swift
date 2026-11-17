import SwiftUI
import UIKit
import PhotosUI
import ImageIO

// MARK: - Model

enum WmkSource: String, CaseIterable, Identifiable {
    case text, logo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: return "Text"
        case .logo: return "Logo"
        }
    }

    var systemImage: String {
        switch self {
        case .text: return "textformat"
        case .logo: return "seal"
        }
    }
}

enum WmkFont: String, CaseIterable, Identifiable {
    case serif, sans, rounded, mono

    var id: String { rawValue }

    var title: String {
        switch self {
        case .serif: return "Serif"
        case .sans: return "Sans"
        case .rounded: return "Rounded"
        case .mono: return "Mono"
        }
    }

    var design: UIFontDescriptor.SystemDesign {
        switch self {
        case .serif: return .serif
        case .sans: return .default
        case .rounded: return .rounded
        case .mono: return .monospaced
        }
    }

    func font(size: CGFloat) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: .semibold)
        if let descriptor = base.fontDescriptor.withDesign(design) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return base
    }
}

enum WmkInk: String, CaseIterable, Identifiable {
    case white, black, brass, custom

    var id: String { rawValue }

    static let presets: [WmkInk] = [.white, .black, .brass]

    var title: String {
        switch self {
        case .white: return "White"
        case .black: return "Black"
        case .brass: return "Brass"
        case .custom: return "Custom"
        }
    }

    var uiColor: UIColor {
        switch self {
        case .white: return UIColor.white
        case .black: return UIColor.black
        case .brass: return UIColor(hex: 0xD2AE6E)
        case .custom: return UIColor.white
        }
    }
}

/// Everything that decides how the watermark looks. Shared by the preview and the export so both match.
struct WmkConfig: Equatable {
    var source: WmkSource = .text
    var text: String = "\u{00A9} Your name"
    var font: WmkFont = .serif
    var color: UIColor = UIColor.white
    var logo: CGImage? = nil
    /// 0...8, read left to right, top to bottom.
    var cell: Int = 8
    var tiled: Bool = false
    /// Percent of the photo width.
    var size: Double = 12
    /// Percent.
    var opacity: Double = 70
    /// Degrees, positive turns counterclockwise.
    var rotation: Double = 0
    /// Percent of the photo width.
    var margin: Double = 3

    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var hasMark: Bool {
        switch source {
        case .text: return !trimmedText.isEmpty
        case .logo: return logo != nil
        }
    }

    static func == (lhs: WmkConfig, rhs: WmkConfig) -> Bool {
        let sameContent: Bool = lhs.source == rhs.source && lhs.text == rhs.text && lhs.font == rhs.font
        let sameInk: Bool = lhs.color.isEqual(rhs.color) && lhs.logo === rhs.logo
        let samePlace: Bool = lhs.cell == rhs.cell && lhs.tiled == rhs.tiled
        let sameDials: Bool = lhs.size == rhs.size && lhs.opacity == rhs.opacity
        let sameFrame: Bool = lhs.rotation == rhs.rotation && lhs.margin == rhs.margin
        return sameContent && sameInk && samePlace && sameDials && sameFrame
    }
}

// MARK: - Rendering (shared by preview and export)

struct WmkMark {
    let image: UIImage
    let size: CGSize
}

enum WmkRenderer {
    /// Draws the photo at its own pixel size with the watermark on top. Every length is relative to the photo width,
    /// so a small preview and the full size export look the same.
    static func render(photo: CGImage, config: WmkConfig) -> CGImage? {
        let width = CGFloat(photo.width)
        let height = CGFloat(photo.height)
        guard width > 0, height > 0 else { return nil }
        let canvas = CGSize(width: width, height: height)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: canvas, format: format)
        let mark = markImage(config: config, photoWidth: width)
        let alpha = CGFloat(min(100, max(0, config.opacity)) / 100)

        let output = renderer.image { context in
            UIImage(cgImage: photo).draw(in: CGRect(origin: .zero, size: canvas))
            guard let mark else { return }
            if config.tiled {
                drawTiled(mark, canvas: canvas, config: config, alpha: alpha, context: context.cgContext)
            } else {
                drawSingle(mark, canvas: canvas, config: config, alpha: alpha, context: context.cgContext)
            }
        }
        return output.cgImage
    }

    static func markImage(config: WmkConfig, photoWidth: CGFloat) -> WmkMark? {
        let targetWidth = max(1, photoWidth * CGFloat(config.size) / 100)
        switch config.source {
        case .logo:
            guard let logo = config.logo, logo.width > 0, logo.height > 0 else { return nil }
            let targetHeight = targetWidth * CGFloat(logo.height) / CGFloat(logo.width)
            return WmkMark(image: UIImage(cgImage: logo), size: CGSize(width: targetWidth, height: targetHeight))
        case .text:
            let text = config.trimmedText
            guard !text.isEmpty else { return nil }
            let string = text as NSString
            let probeFont = config.font.font(size: 100)
            let probeWidth = string.size(withAttributes: [.font: probeFont]).width
            guard probeWidth > 0 else { return nil }
            let pointSize = max(1, 100 * targetWidth / probeWidth)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: config.font.font(size: pointSize),
                .foregroundColor: config.color,
            ]
            let measured = string.size(withAttributes: attributes)
            let size = CGSize(width: max(1, ceil(measured.width)), height: max(1, ceil(measured.height)))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = false
            format.preferredRange = .standard
            let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                string.draw(at: .zero, withAttributes: attributes)
            }
            return WmkMark(image: image, size: size)
        }
    }

    private static func drawSingle(_ mark: WmkMark, canvas: CGSize, config: WmkConfig, alpha: CGFloat, context: CGContext) {
        let radians = CGFloat(-config.rotation * Double.pi / 180)
        let markWidth = mark.size.width
        let markHeight = mark.size.height
        let boxWidth = abs(markWidth * cos(radians)) + abs(markHeight * sin(radians))
        let boxHeight = abs(markWidth * sin(radians)) + abs(markHeight * cos(radians))
        let margin = canvas.width * CGFloat(config.margin) / 100
        let cell = min(8, max(0, config.cell))
        let column = cell % 3
        let row = cell / 3

        let x: CGFloat
        switch column {
        case 0: x = margin + boxWidth / 2
        case 1: x = canvas.width / 2
        default: x = canvas.width - margin - boxWidth / 2
        }
        let y: CGFloat
        switch row {
        case 0: y = margin + boxHeight / 2
        case 1: y = canvas.height / 2
        default: y = canvas.height - margin - boxHeight / 2
        }

        context.saveGState()
        context.translateBy(x: x, y: y)
        context.rotate(by: radians)
        mark.image.draw(
            in: CGRect(x: -markWidth / 2, y: -markHeight / 2, width: markWidth, height: markHeight),
            blendMode: .normal,
            alpha: alpha
        )
        context.restoreGState()
    }

    private static func drawTiled(_ mark: WmkMark, canvas: CGSize, config: WmkConfig, alpha: CGFloat, context: CGContext) {
        let radians = CGFloat(-config.rotation * Double.pi / 180)
        let markWidth = mark.size.width
        let markHeight = mark.size.height
        let spacing = canvas.width * 0.05
        let stepX = max(1, markWidth * 1.5 + spacing)
        let stepY = max(1, max(markHeight * 2.4, markHeight + spacing))
        let diagonal = (canvas.width * canvas.width + canvas.height * canvas.height).squareRoot()
        let halfColumns = min(200, Int(ceil(diagonal / 2 / stepX)) + 1)
        let halfRows = min(200, Int(ceil(diagonal / 2 / stepY)) + 1)

        context.saveGState()
        context.translateBy(x: canvas.width / 2, y: canvas.height / 2)
        context.rotate(by: radians)
        for row in -halfRows...halfRows {
            // Every other row is shifted by half a step, which gives the diagonal rhythm.
            let shift: CGFloat = abs(row) % 2 == 0 ? 0 : stepX / 2
            for column in -halfColumns...halfColumns {
                let centreX = CGFloat(column) * stepX + shift
                let centreY = CGFloat(row) * stepY
                mark.image.draw(
                    in: CGRect(x: centreX - markWidth / 2, y: centreY - markHeight / 2, width: markWidth, height: markHeight),
                    blendMode: .normal,
                    alpha: alpha
                )
            }
        }
        context.restoreGState()
    }
}

enum WmkExporter {
    static func build(photos: [LoadedPhoto], config: WmkConfig, format: OutputFormat, removePrivate: Bool) -> [ExportItem] {
        var items: [ExportItem] = []
        for (index, photo) in photos.enumerated() {
            let item: ExportItem? = autoreleasepool { () -> ExportItem? in
                guard let rendered = WmkRenderer.render(photo: photo.image, config: config) else { return nil }
                let properties: [String: Any] = removePrivate
                    ? ImageCodec.privacySafe(photo.properties)
                    : ImageCodec.sanitized(photo.properties)
                guard let data = ImageCodec.encode(rendered, format: format, quality: 0.92, properties: properties) else {
                    return nil
                }
                let base = photos.count == 1 ? "Aperta-watermark" : "Aperta-watermark-\(index + 1)"
                return ExportItem(data: data, filename: ExportItem.uniqueName(base, format: format), format: format)
            }
            if let item { items.append(item) }
        }
        return items
    }
}

private struct WmkPreviewBase {
    let id: UUID
    let image: CGImage
}

private struct WmkPreviewKey: Equatable {
    let config: WmkConfig
    let photoID: UUID?
}

private struct WmkExportKey: Equatable {
    let config: WmkConfig
    let format: OutputFormat
    let removePrivate: Bool
    let photoIDs: [UUID]
}

private enum WmkPlacementNames {
    static let all: [String] = [
        "Top left", "Top center", "Top right",
        "Middle left", "Center", "Middle right",
        "Bottom left", "Bottom center", "Bottom right",
    ]
}

// MARK: - Screen

@MainActor
struct WatermarkView: View {
    @StateObject private var selection = PhotoSelection()
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var logoItem: PhotosPickerItem?
    @State private var config = WmkConfig()
    @State private var ink: WmkInk = .white
    @State private var customColor: Color = Color(hex: 0x9FB7C9)
    @State private var outputFormat: OutputFormat = .jpeg
    @State private var removePrivate: Bool = true
    @State private var previewImage: CGImage?
    @State private var previewBase: WmkPreviewBase?
    @State private var exportItems: [ExportItem] = []
    @State private var isExporting: Bool = false
    @State private var exportFailed: Bool = false
    @State private var logoFailed: Bool = false
    @State private var isLoadingLogo: Bool = false

    nonisolated init() {}

    private let formats: [OutputFormat] = [.jpeg, .png]

    var body: some View {
        ToolScreen(
            title: "Watermark",
            subtitle: "Add your name or logo to up to 20 photos at once. Your photos never leave this phone."
        ) {
            if selection.photos.isEmpty {
                emptyState
            } else {
                previewPanel
                markSection
                placementSection
                adjustSection
                saveSection
            }
        }
        .onChange(of: pickerItems) {
            let items = pickerItems
            Task { await selection.load(items, maxPixel: 4096) }
        }
        .onChange(of: logoItem) {
            Task { await loadLogo() }
        }
        .onChange(of: exportKey) {
            exportItems = []
            exportFailed = false
        }
        .task(id: previewKey) {
            await refreshPreview(previewKey)
        }
    }

    // MARK: Derived values

    private var renderConfig: WmkConfig {
        var result = config
        result.color = ink == .custom ? UIColor(customColor) : ink.uiColor
        return result
    }

    private var previewKey: WmkPreviewKey {
        WmkPreviewKey(config: renderConfig, photoID: selection.photos.first?.id)
    }

    private var exportKey: WmkExportKey {
        WmkExportKey(
            config: renderConfig,
            format: outputFormat,
            removePrivate: removePrivate,
            photoIDs: selection.photos.map { $0.id }
        )
    }

    private var photoCountText: String {
        let count = selection.photos.count
        return count == 1 ? "1 photo" : "\(count) photos, preview shows the first"
    }

    private var prepareTitle: String {
        let count = selection.photos.count
        return count == 1 ? "Add watermark" : "Add watermark to \(count) photos"
    }

    // MARK: Empty state

    @ViewBuilder
    private var emptyState: some View {
        if selection.isLoading {
            loadingRow("Opening your photos")
        } else {
            PhotosPicker(selection: $pickerItems, maxSelectionCount: 20, matching: .images) {
                PickPhotosPrompt(
                    title: "Choose photos",
                    detail: "Pick up to 20 photos. You will see the first one with your watermark before you save."
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Choose up to 20 photos"))
            if selection.failedCount > 0 {
                failureText("Some photos could not be opened. Try picking them again.")
            }
        }
    }

    private func loadingRow(_ text: String) -> some View {
        HStack(spacing: AP.Space.s) {
            ProgressView().tint(AP.Palette.brass)
            Text(text).font(AP.Font.callout).foregroundStyle(AP.Palette.mist)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private func failureText(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(AP.Font.label)
            .foregroundStyle(AP.Palette.danger)
    }

    // MARK: Preview

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: AP.Space.m) {
            previewImageView
            HStack(alignment: .center, spacing: AP.Space.s) {
                Text(photoCountText)
                    .font(AP.Font.callout)
                    .foregroundStyle(AP.Palette.mist)
                Spacer(minLength: AP.Space.s)
                PhotosPicker(selection: $pickerItems, maxSelectionCount: 20, matching: .images) {
                    Text("Change photos")
                }
                .buttonStyle(.apQuiet)
                .accessibilityLabel(Text("Change photos"))
            }
            if selection.failedCount > 0 {
                failureText("Some photos could not be opened and were left out.")
            }
        }
        .padding(AP.Space.m)
        .background(AP.Palette.carbon, in: RoundedRectangle(cornerRadius: AP.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AP.Radius.panel, style: .continuous)
                .strokeBorder(AP.Palette.line, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var previewImageView: some View {
        if let previewImage {
            Image(uiImage: UIImage(cgImage: previewImage))
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 440)
                .clipShape(RoundedRectangle(cornerRadius: AP.Radius.control, style: .continuous))
                .accessibilityLabel(Text("Preview of the first photo with your watermark"))
        } else {
            ProgressView()
                .tint(AP.Palette.brass)
                .frame(maxWidth: .infinity, minHeight: 240)
                .accessibilityLabel(Text("Preparing preview"))
        }
    }

    // MARK: Watermark source

    private var markSection: some View {
        VStack(alignment: .leading, spacing: AP.Space.m) {
            APSectionTitle(text: "Watermark")
            APChipRow {
                ForEach(WmkSource.allCases) { source in
                    APChip(title: source.title, systemImage: source.systemImage, selected: config.source == source) {
                        config.source = source
                        APHaptics.tap()
                    }
                }
            }
            .padding(.horizontal, -AP.Space.m)
            if config.source == .text {
                textControls
            } else {
                logoControls
            }
        }
    }

    private var textControls: some View {
        VStack(alignment: .leading, spacing: AP.Space.m) {
            TextField("Watermark text", text: $config.text, prompt: Text("Your name or website"))
                .font(AP.Font.body)
                .foregroundStyle(AP.Palette.paper)
                .tint(AP.Palette.brass)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .padding(.horizontal, AP.Space.m)
                .frame(minHeight: 48)
                .background(AP.Palette.graphite, in: RoundedRectangle(cornerRadius: AP.Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AP.Radius.control, style: .continuous)
                        .strokeBorder(AP.Palette.line, lineWidth: 1)
                )
                .accessibilityLabel(Text("Watermark text"))

            fieldLabel("Typeface")
            APChipRow {
                ForEach(WmkFont.allCases) { font in
                    APChip(title: font.title, selected: config.font == font) {
                        config.font = font
                        APHaptics.tap()
                    }
                    .accessibilityLabel(Text("\(font.title) typeface"))
                }
            }
            .padding(.horizontal, -AP.Space.m)

            fieldLabel("Color")
            colorRow
        }
    }

    private var colorRow: some View {
        APChipRow {
            ForEach(WmkInk.presets) { option in
                APChip(title: option.title, selected: ink == option) {
                    ink = option
                    APHaptics.tap()
                }
                .accessibilityLabel(Text("\(option.title) text"))
            }
            customColorChip
        }
        .padding(.horizontal, -AP.Space.m)
        .onChange(of: customColor) {
            ink = .custom
        }
    }

    private var customColorChip: some View {
        let selected = ink == .custom
        return HStack(spacing: 8) {
            ColorPicker("Custom color", selection: $customColor, supportsOpacity: false)
                .labelsHidden()
            Text("Custom")
                .font(AP.Font.label)
                .foregroundStyle(AP.Palette.paper)
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .frame(minHeight: 44)
        .background(AP.Palette.graphite, in: Capsule())
        .overlay(Capsule().strokeBorder(selected ? AP.Palette.brass : AP.Palette.line, lineWidth: selected ? 1.5 : 1))
        .contentShape(Capsule())
        .onTapGesture {
            ink = .custom
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var logoControls: some View {
        VStack(alignment: .leading, spacing: AP.Space.s) {
            PhotosPicker(selection: $logoItem, matching: .images) {
                logoRow
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(config.logo == nil ? "Choose a logo" : "Change logo"))
            if logoFailed {
                failureText("That image could not be opened. Try another one.")
            }
        }
    }

    private var logoRow: some View {
        HStack(spacing: AP.Space.m) {
            ZStack {
                RoundedRectangle(cornerRadius: AP.Radius.chip, style: .continuous)
                    .fill(AP.Palette.lens)
                if isLoadingLogo {
                    ProgressView().tint(AP.Palette.brass)
                } else if let logo = config.logo {
                    Image(uiImage: UIImage(cgImage: logo))
                        .resizable()
                        .scaledToFit()
                        .padding(6)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(AP.Palette.brass)
                }
            }
            .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(config.logo == nil ? "Choose a logo" : "Change logo")
                    .font(AP.Font.headline)
                    .foregroundStyle(AP.Palette.paper)
                Text("A PNG with a transparent background looks cleanest.")
                    .font(AP.Font.caption)
                    .foregroundStyle(AP.Palette.mist)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AP.Palette.mist)
        }
        .padding(AP.Space.s)
        .padding(.trailing, AP.Space.s)
        .frame(minHeight: 64)
        .background(AP.Palette.graphite, in: RoundedRectangle(cornerRadius: AP.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AP.Radius.control, style: .continuous)
                .strokeBorder(AP.Palette.line, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(AP.Font.label)
            .foregroundStyle(AP.Palette.mist)
    }

    // MARK: Placement

    private var placementSection: some View {
        VStack(alignment: .leading, spacing: AP.Space.m) {
            APSectionTitle(text: "Placement")
            HStack(alignment: .top, spacing: AP.Space.l) {
                positionGrid
                VStack(alignment: .leading, spacing: AP.Space.s) {
                    Text(config.tiled ? "Repeated across the photo" : WmkPlacementNames.all[min(8, max(0, config.cell))])
                        .font(AP.Font.headline)
                        .foregroundStyle(AP.Palette.paper)
                    Text("Tap a spot on the grid, or repeat the mark over the whole photo so it is harder to crop out.")
                        .font(AP.Font.caption)
                        .foregroundStyle(AP.Palette.mist)
                        .fixedSize(horizontal: false, vertical: true)
                    APChip(title: "Tile", systemImage: "square.grid.3x3", selected: config.tiled) {
                        config.tiled.toggle()
                        APHaptics.tap()
                    }
                    .accessibilityLabel(Text("Tile the watermark across the photo"))
                }
            }
        }
    }

    private var positionGrid: some View {
        VStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { column in
                        gridCell(row * 3 + column)
                    }
                }
            }
        }
        .padding(6)
        .background(AP.Palette.carbon, in: RoundedRectangle(cornerRadius: AP.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AP.Radius.control, style: .continuous)
                .strokeBorder(AP.Palette.line, lineWidth: 1)
        )
        .opacity(config.tiled ? 0.55 : 1)
    }

    private func gridCell(_ index: Int) -> some View {
        let selected = !config.tiled && config.cell == index
        return Button {
            config.cell = index
            config.tiled = false
            APHaptics.tap()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? AP.Palette.brass.opacity(0.18) : AP.Palette.graphite)
                Circle()
                    .fill(selected ? AP.Palette.brass : AP.Palette.mist.opacity(0.55))
                    .frame(width: selected ? 10 : 5, height: selected ? 10 : 5)
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(WmkPlacementNames.all[index]))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Adjust

    private var adjustSection: some View {
        VStack(alignment: .leading, spacing: AP.Space.m) {
            APSectionTitle(text: "Adjust")
            VStack(spacing: AP.Space.m) {
                DialSlider(title: "Size, share of photo width", value: $config.size, range: 2...40, defaultValue: 12, unit: "%")
                APHairline()
                DialSlider(title: "Opacity", value: $config.opacity, range: 10...100, defaultValue: 70, unit: "%")
                APHairline()
                DialSlider(title: "Rotation", value: $config.rotation, range: -45...45, defaultValue: 0, unit: "\u{00B0}")
                APHairline()
                DialSlider(title: "Margin from the edge", value: $config.margin, range: 0...10, defaultValue: 3, unit: "%")
                    .disabled(config.tiled)
                    .opacity(config.tiled ? 0.4 : 1)
            }
            Text("Double tap a dial to reset it.")
                .font(AP.Font.caption)
                .foregroundStyle(AP.Palette.mist)
        }
    }

    // MARK: Save

    private var saveSection: some View {
        VStack(alignment: .leading, spacing: AP.Space.m) {
            APSectionTitle(text: "Save")
            APChipRow {
                ForEach(formats) { format in
                    APChip(title: format.title, selected: outputFormat == format) {
                        outputFormat = format
                        APHaptics.tap()
                    }
                    .accessibilityLabel(Text("Save as \(format.title)"))
                }
            }
            .padding(.horizontal, -AP.Space.m)
            Toggle(isOn: $removePrivate) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remove location and device details")
                        .font(AP.Font.body)
                        .foregroundStyle(AP.Palette.paper)
                    Text("Recommended for photos you post online.")
                        .font(AP.Font.caption)
                        .foregroundStyle(AP.Palette.mist)
                }
            }
            .tint(AP.Palette.brass)
            .frame(minHeight: 44)
            saveAction
        }
    }

    @ViewBuilder
    private var saveAction: some View {
        if exportItems.isEmpty {
            Button {
                Task { await prepareExport() }
            } label: {
                HStack(spacing: 8) {
                    if isExporting { ProgressView().tint(AP.Palette.onBrass) }
                    Text(isExporting ? "Adding watermark" : prepareTitle)
                }
            }
            .buttonStyle(.apPrimaryWide)
            .disabled(isExporting || !renderConfig.hasMark)
            if !renderConfig.hasMark {
                Text(config.source == .text ? "Type the text for your watermark first." : "Choose a logo first.")
                    .font(AP.Font.caption)
                    .foregroundStyle(AP.Palette.mist)
            }
            if exportFailed {
                failureText("Some photos could not be prepared. Try again with fewer photos.")
            }
        } else {
            ExportBar(
                items: exportItems,
                savedMessage: exportItems.count == 1 ? "Saved to your library" : "Saved \(exportItems.count) photos to your library"
            )
            if exportFailed {
                failureText("Some photos could not be prepared and were left out.")
            }
        }
    }

    // MARK: Work

    private func refreshPreview(_ key: WmkPreviewKey) async {
        guard let first = selection.photos.first else {
            previewImage = nil
            return
        }
        try? await Task.sleep(nanoseconds: 40_000_000)
        if Task.isCancelled { return }

        let base: CGImage
        if let cached = previewBase, cached.id == first.id {
            base = cached.image
        } else {
            let source = first.image
            let scaled: CGImage? = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                ImageCodec.scaled(source, maxPixel: 1600)
            }.value
            guard let scaled else { return }
            previewBase = WmkPreviewBase(id: first.id, image: scaled)
            base = scaled
        }
        if Task.isCancelled { return }

        let config = key.config
        let rendered: CGImage? = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            WmkRenderer.render(photo: base, config: config)
        }.value
        if Task.isCancelled { return }
        if let rendered { previewImage = rendered }
    }

    private func prepareExport() async {
        let photos = selection.photos
        guard !photos.isEmpty else { return }
        let config = renderConfig
        let format = outputFormat
        let strip = removePrivate
        isExporting = true
        exportFailed = false
        let items: [ExportItem] = await Task.detached(priority: .userInitiated) { () -> [ExportItem] in
            WmkExporter.build(photos: photos, config: config, format: format, removePrivate: strip)
        }.value
        isExporting = false
        exportFailed = items.count < photos.count
        exportItems = items
        if !items.isEmpty { APHaptics.success() }
    }

    private func loadLogo() async {
        guard let item = logoItem else { return }
        logoFailed = false
        isLoadingLogo = true
        let photo = await PhotoLoader.load(item, maxPixel: 2048, name: "Logo")
        isLoadingLogo = false
        guard let photo else {
            logoFailed = true
            return
        }
        config.logo = photo.image
        config.source = .logo
    }
}
