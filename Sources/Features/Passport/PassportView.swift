import SwiftUI
import UIKit
import PhotosUI
import ImageIO

// MARK: - Model

enum PssBackground: String, CaseIterable, Identifiable {
    case white, lightGrey, lightBlue, red, custom

    var id: String { rawValue }

    static let presets: [PssBackground] = [.white, .lightGrey, .lightBlue, .red]

    var title: String {
        switch self {
        case .white: return "White"
        case .lightGrey: return "Light grey"
        case .lightBlue: return "Light blue"
        case .red: return "Red"
        case .custom: return "Custom"
        }
    }

    var uiColor: UIColor {
        switch self {
        case .white: return UIColor.white
        case .lightGrey: return UIColor(hex: 0xE4E5E7)
        case .lightBlue: return UIColor(hex: 0xD6E6F5)
        case .red: return UIColor(hex: 0xC8102E)
        case .custom: return UIColor.white
        }
    }
}

enum PssSize: String, CaseIterable, Identifiable {
    case us, euUK, india, china, canada, schengen, japan, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .us: return "US 2 \u{00D7} 2 in"
        case .euUK: return "EU and UK 35 \u{00D7} 45 mm"
        case .india: return "India 51 \u{00D7} 51 mm"
        case .china: return "China 33 \u{00D7} 48 mm"
        case .canada: return "Canada 50 \u{00D7} 70 mm"
        case .schengen: return "Schengen visa 35 \u{00D7} 45 mm"
        case .japan: return "Japan 35 \u{00D7} 45 mm"
        case .custom: return "Custom"
        }
    }

    /// Width and height in millimetres. Nil for custom.
    var millimetres: CGSize? {
        switch self {
        case .us: return CGSize(width: 50.8, height: 50.8)
        case .euUK, .schengen, .japan: return CGSize(width: 35, height: 45)
        case .india: return CGSize(width: 51, height: 51)
        case .china: return CGSize(width: 33, height: 48)
        case .canada: return CGSize(width: 50, height: 70)
        case .custom: return nil
        }
    }
}

enum PssOutput: String, CaseIterable, Identifiable {
    case single, sheet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .single: return "Single photo"
        case .sheet: return "Print sheet"
        }
    }
}

enum PssSheet: String, CaseIterable, Identifiable {
    case fourBySix, a4, letter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fourBySix: return "4 \u{00D7} 6 in"
        case .a4: return "A4"
        case .letter: return "Letter"
        }
    }

    /// Portrait size in pixels at 300 dpi.
    var pixelSize: CGSize {
        switch self {
        case .fourBySix: return CGSize(width: 1200, height: 1800)
        case .a4: return CGSize(width: 2480, height: 3508)
        case .letter: return CGSize(width: 2550, height: 3300)
        }
    }
}

/// How the cut-out person sits in the frame. Offsets are fractions of the frame size, so the same framing gives
/// the same picture on screen and in the 300 dpi file.
struct PssFraming: Equatable {
    var scale: CGFloat = 1
    var offset: CGSize = .zero

    static let scaleRange: ClosedRange<CGFloat> = 0.3...4

    static func clamp(_ value: CGFloat) -> CGFloat {
        min(scaleRange.upperBound, max(scaleRange.lowerBound, value))
    }
}

private enum PssPhase: Equatable {
    case idle, loading, working, unreadable, noPerson, ready
}

private struct PssExportKey: Equatable {
    let framing: PssFraming
    let background: PssBackground
    let customColor: Color
    let pixelSize: CGSize
    let output: PssOutput
    let sheet: PssSheet
}

private struct PssResult {
    let item: ExportItem
    let preview: CGImage
}

// MARK: - Compositing (shared by preview and export)

private enum PssCompositor {
    static let dpi: CGFloat = 300
    static let sheetGap: CGFloat = 24
    static let sheetMargin: CGFloat = 48

    static func pixels(fromMillimetres size: CGSize) -> CGSize {
        CGSize(
            width: max(1, (size.width / 25.4 * dpi).rounded()),
            height: max(1, (size.height / 25.4 * dpi).rounded())
        )
    }

    /// Where the cut-out is drawn inside a frame of `canvas` size: aspect fit, then the person's zoom and offset.
    static func layoutRect(imageSize: CGSize, canvas: CGSize, framing: PssFraming) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, canvas.width > 0, canvas.height > 0 else { return .zero }
        let fit = min(canvas.width / imageSize.width, canvas.height / imageSize.height)
        let scale = fit * framing.scale
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        let centreX = canvas.width / 2 + framing.offset.width * canvas.width
        let centreY = canvas.height / 2 + framing.offset.height * canvas.height
        return CGRect(x: centreX - width / 2, y: centreY - height / 2, width: width, height: height)
    }

    /// A starting framing: the person fills most of the width with the top of the head just under the top edge.
    static func autoFraming(bounds: CGRect?, imageSize: CGSize, canvas: CGSize) -> PssFraming {
        guard let bounds, bounds.width > 0, bounds.height > 0,
              imageSize.width > 0, imageSize.height > 0, canvas.width > 0, canvas.height > 0 else {
            return PssFraming()
        }
        let fit = min(canvas.width / imageSize.width, canvas.height / imageSize.height)
        let scale = PssFraming.clamp((canvas.width * 0.9) / (imageSize.width * fit * bounds.width))
        let drawnWidth = imageSize.width * fit * scale
        let drawnHeight = imageSize.height * fit * scale
        let centreX = canvas.width / 2 + drawnWidth / 2 - bounds.midX * drawnWidth
        let centreY = canvas.height * 0.08 + drawnHeight / 2 - bounds.minY * drawnHeight
        let offset = CGSize(
            width: (centreX - canvas.width / 2) / canvas.width,
            height: (centreY - canvas.height / 2) / canvas.height
        )
        return PssFraming(scale: scale, offset: offset)
    }

    /// Background fill plus the cut-out, cropped to the frame. `canvas` is in pixels.
    static func compose(cutout: CGImage, background: UIColor, canvas: CGSize, framing: PssFraming) -> CGImage? {
        guard canvas.width >= 1, canvas.height >= 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let imageSize = CGSize(width: cutout.width, height: cutout.height)
        let rect = layoutRect(imageSize: imageSize, canvas: canvas, framing: framing)
        let image = UIGraphicsImageRenderer(size: canvas, format: format).image { context in
            background.setFill()
            context.fill(CGRect(origin: .zero, size: canvas))
            context.cgContext.interpolationQuality = .high
            UIImage(cgImage: cutout).draw(in: rect)
        }
        return image.cgImage
    }

    /// Positions of each copy on a print sheet, centred, with gaps for cutting.
    static func sheetRects(photo: CGSize, sheet: CGSize) -> [CGRect] {
        guard photo.width > 0, photo.height > 0 else { return [] }
        let usableWidth = sheet.width - 2 * sheetMargin + sheetGap
        let usableHeight = sheet.height - 2 * sheetMargin + sheetGap
        let columns = max(0, Int(usableWidth / (photo.width + sheetGap)))
        let rows = max(0, Int(usableHeight / (photo.height + sheetGap)))
        guard columns > 0, rows > 0 else { return [] }
        let gridWidth = CGFloat(columns) * photo.width + CGFloat(columns - 1) * sheetGap
        let gridHeight = CGFloat(rows) * photo.height + CGFloat(rows - 1) * sheetGap
        let originX = ((sheet.width - gridWidth) / 2).rounded()
        let originY = ((sheet.height - gridHeight) / 2).rounded()
        var rects: [CGRect] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let x = originX + CGFloat(column) * (photo.width + sheetGap)
                let y = originY + CGFloat(row) * (photo.height + sheetGap)
                rects.append(CGRect(x: x, y: y, width: photo.width, height: photo.height))
            }
        }
        return rects
    }

    static func composeSheet(photo: CGImage, sheet: CGSize) -> CGImage? {
        let photoSize = CGSize(width: photo.width, height: photo.height)
        let rects = sheetRects(photo: photoSize, sheet: sheet)
        guard !rects.isEmpty else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let single = UIImage(cgImage: photo)
        let image = UIGraphicsImageRenderer(size: sheet, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: sheet))
            UIColor(white: 0.78, alpha: 1).setStroke()
            for rect in rects {
                single.draw(in: rect)
                // A thin line just outside each photo shows where to cut.
                let line = UIBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
                line.lineWidth = 2
                line.stroke()
            }
        }
        return image.cgImage
    }

    /// The box around the visible (non-transparent) pixels, as fractions of the image, measured from the top left.
    static func subjectBounds(_ image: CGImage) -> CGRect? {
        let longest = max(image.width, image.height)
        guard longest > 0 else { return nil }
        let ratio = min(1, CGFloat(256) / CGFloat(longest))
        let width = max(1, Int(CGFloat(image.width) * ratio))
        let height = max(1, Int(CGFloat(image.height) * ratio))
        let bytesPerRow = width * 4
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        return pixels.withUnsafeMutableBytes { buffer -> CGRect? in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            var minX = width
            var minY = height
            var maxX = -1
            var maxY = -1
            for y in 0..<height {
                let rowStart = y * bytesPerRow
                for x in 0..<width where buffer[rowStart + x * 4 + 3] > 24 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
            guard maxX >= minX, maxY >= minY else { return nil }
            return CGRect(
                x: CGFloat(minX) / CGFloat(width),
                y: CGFloat(minY) / CGFloat(height),
                width: CGFloat(maxX - minX + 1) / CGFloat(width),
                height: CGFloat(maxY - minY + 1) / CGFloat(height)
            )
        }
    }
}

/// On-screen guide only: an oval for the face and a line for the eyes. Never drawn into the file.
private struct PssGuide: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let ovalWidth = rect.width * 0.52
        let ovalTop = rect.minY + rect.height * 0.10
        let ovalHeight = rect.height * 0.66
        path.addEllipse(in: CGRect(x: rect.midX - ovalWidth / 2, y: ovalTop, width: ovalWidth, height: ovalHeight))
        let eyeY = rect.minY + rect.height * 0.40
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.18, y: eyeY))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.18, y: eyeY))
        return path
    }
}

// MARK: - Screen

@MainActor
struct PassportView: View {
    @StateObject private var selection = PhotoSelection()
    @State private var pickerItem: PhotosPickerItem?
    @State private var phase: PssPhase = .idle
    @State private var cutout: CGImage?
    @State private var cutoutImage: UIImage?
    @State private var subjectBounds: CGRect?
    @State private var background: PssBackground = .white
    @State private var customColor: Color = Color(hex: 0xEAF2FA)
    @State private var size: PssSize = .us
    @State private var customWidth: Double = 35
    @State private var customHeight: Double = 45
    @State private var framing = PssFraming()
    @State private var dragStart: PssFraming?
    @State private var pinchStart: PssFraming?
    @State private var output: PssOutput = .single
    @State private var sheet: PssSheet = .fourBySix
    @State private var result: PssResult?
    @State private var isPreparing: Bool = false
    @State private var prepareFailed: Bool = false

    nonisolated init() {}

    var body: some View {
        ToolScreen(
            title: "ID and passport photos",
            subtitle: "Make a photo with a plain background at the right size, ready to print or upload."
        ) {
            content
        }
        #if DEBUG
        .task {
            if DebugSamples.enabled && selection.photos.isEmpty {
                selection.photos = DebugSamples.photos(1)
                await runCutout()
            }
        }
        #endif
        .onChange(of: pickerItem) {
            Task { await loadAndCut() }
        }
        .onChange(of: photoPixelSize) {
            framing = automaticFraming
        }
        .onChange(of: exportKey) {
            result = nil
            prepareFailed = false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle:
            pickPrompt
        case .loading:
            progressPanel("Opening your photo")
        case .working:
            progressPanel("Finding you in the photo")
        case .unreadable:
            problemPanel(
                message: "That photo could not be opened. Try another one.",
                showRetry: false
            )
        case .noPerson:
            problemPanel(
                message: "We could not find a person in this photo. Try a photo with your face and shoulders in view.",
                showRetry: true
            )
        case .ready:
            framingSection
            backgroundSection
            sizeSection
            outputSection
            rulesNote
        }
    }

    // MARK: Derived values

    private var millimetres: CGSize {
        size.millimetres ?? CGSize(width: customWidth, height: customHeight)
    }

    private var photoPixelSize: CGSize {
        PssCompositor.pixels(fromMillimetres: millimetres)
    }

    private var backgroundUIColor: UIColor {
        background == .custom ? UIColor(customColor) : background.uiColor
    }

    private var backgroundColor: Color {
        Color(uiColor: backgroundUIColor)
    }

    private var automaticFraming: PssFraming {
        guard let cutout else { return PssFraming() }
        return PssCompositor.autoFraming(
            bounds: subjectBounds,
            imageSize: CGSize(width: cutout.width, height: cutout.height),
            canvas: photoPixelSize
        )
    }

    private var exportKey: PssExportKey {
        PssExportKey(
            framing: framing,
            background: background,
            customColor: customColor,
            pixelSize: photoPixelSize,
            output: output,
            sheet: sheet
        )
    }

    private var copiesOnSheet: Int {
        PssCompositor.sheetRects(photo: photoPixelSize, sheet: sheet.pixelSize).count
    }

    private var sizeDetail: String {
        let mm = millimetres
        let px = photoPixelSize
        let widthText = formatted(mm.width)
        let heightText = formatted(mm.height)
        return "\(widthText) \u{00D7} \(heightText) mm, \(Int(px.width)) \u{00D7} \(Int(px.height)) pixels at 300 dpi"
    }

    private func formatted(_ value: CGFloat) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.1f", Double(rounded))
    }

    // MARK: Pick and progress

    private var pickPrompt: some View {
        PhotosPicker(selection: $pickerItem, matching: .images) {
            PickPhotosPrompt(
                title: "Choose a portrait",
                detail: "Use a well lit photo of your face and shoulders, looking straight at the camera.",
                systemImage: "person.crop.square"
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Choose a portrait photo"))
    }

    private func progressPanel(_ text: String) -> some View {
        VStack(spacing: AP.Space.m) {
            ProgressView().tint(AP.Palette.brass)
            Text(text)
                .font(AP.Font.callout)
                .foregroundStyle(AP.Palette.mist)
            Text("This happens on your device and takes a few seconds.")
                .font(AP.Font.caption)
                .foregroundStyle(AP.Palette.mist)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .padding(AP.Space.m)
        .background(AP.Palette.carbon, in: RoundedRectangle(cornerRadius: AP.Radius.panel, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func problemPanel(message: String, showRetry: Bool) -> some View {
        VStack(alignment: .leading, spacing: AP.Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: AP.Space.s) {
                Image(systemName: "person.crop.square.badge.exclamationmark")
                    .foregroundStyle(AP.Palette.brass)
                    .accessibilityHidden(true)
                Text(message)
                    .font(AP.Font.body)
                    .foregroundStyle(AP.Palette.paper)
                    .fixedSize(horizontal: false, vertical: true)
            }
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Text("Choose another photo")
            }
            .buttonStyle(.apPrimaryWide)
            .accessibilityLabel(Text("Choose another photo"))
            if showRetry {
                Button("Try again") {
                    Task { await runCutout() }
                }
                .buttonStyle(.apSecondaryWide)
            }
        }
        .padding(AP.Space.m)
        .background(AP.Palette.carbon, in: RoundedRectangle(cornerRadius: AP.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AP.Radius.panel, style: .continuous)
                .strokeBorder(AP.Palette.line, lineWidth: 1)
        )
    }

    // MARK: Framing

    private var zoomBinding: Binding<Double> {
        Binding(
            get: { Double(framing.scale * 100) },
            set: { framing.scale = PssFraming.clamp(CGFloat($0 / 100)) }
        )
    }

    private var framingSection: some View {
        VStack(alignment: .leading, spacing: AP.Space.m) {
            framingArea
            Text("Drag to move and pinch to zoom. Keep your face inside the oval with your eyes near the line. The guide is not saved.")
                .font(AP.Font.caption)
                .foregroundStyle(AP.Palette.mist)
                .fixedSize(horizontal: false, vertical: true)
            DialSlider(
                title: "Zoom",
                value: zoomBinding,
                range: 30...400,
                defaultValue: Double(automaticFraming.scale * 100),
                unit: "%"
            )
            HStack(spacing: AP.Space.s) {
                Button("Fit to guide") {
                    framing = automaticFraming
                    APHaptics.tap()
                }
                .buttonStyle(.apQuiet)
                Spacer(minLength: AP.Space.s)
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Text("Change photo")
                }
                .buttonStyle(.apQuiet)
                .accessibilityLabel(Text("Choose a different photo"))
            }
        }
        .padding(AP.Space.m)
        .background(AP.Palette.carbon, in: RoundedRectangle(cornerRadius: AP.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AP.Radius.panel, style: .continuous)
                .strokeBorder(AP.Palette.line, lineWidth: 1)
        )
    }

    private var framingArea: some View {
        let canvas = photoPixelSize
        let ratio = canvas.width / max(canvas.height, 1)
        return GeometryReader { geo in
            framingCanvas(viewSize: geo.size)
        }
        .aspectRatio(ratio, contentMode: .fit)
        .frame(maxWidth: 300, maxHeight: 400)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func framingCanvas(viewSize: CGSize) -> some View {
        if let cutout, let cutoutImage {
            let imageSize = CGSize(width: cutout.width, height: cutout.height)
            let rect = PssCompositor.layoutRect(imageSize: imageSize, canvas: viewSize, framing: framing)
            ZStack {
                Rectangle().fill(backgroundColor)
                Image(uiImage: cutoutImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: max(1, rect.width), height: max(1, rect.height))
                    .position(x: rect.midX, y: rect.midY)
                PssGuide()
                    .stroke(AP.Palette.brass.opacity(0.9), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                    .allowsHitTesting(false)
            }
            .frame(width: viewSize.width, height: viewSize.height)
            .clipped()
            .overlay(Rectangle().strokeBorder(AP.Palette.line, lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(dragGesture(viewSize: viewSize).simultaneously(with: pinchGesture))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Framing area"))
            .accessibilityValue(Text("Zoom \(Int((framing.scale * 100).rounded())) percent"))
            .accessibilityHint(Text("Drag to move the photo and pinch to zoom."))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: framing.scale = PssFraming.clamp(framing.scale * 1.1)
                case .decrement: framing.scale = PssFraming.clamp(framing.scale / 1.1)
                @unknown default: break
                }
            }
            .accessibilityAction(named: Text("Move up")) { nudge(dx: 0, dy: -0.03) }
            .accessibilityAction(named: Text("Move down")) { nudge(dx: 0, dy: 0.03) }
            .accessibilityAction(named: Text("Move left")) { nudge(dx: -0.03, dy: 0) }
            .accessibilityAction(named: Text("Move right")) { nudge(dx: 0.03, dy: 0) }
        }
    }

    private func nudge(dx: CGFloat, dy: CGFloat) {
        framing.offset = CGSize(width: framing.offset.width + dx, height: framing.offset.height + dy)
    }

    private func dragGesture(viewSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = dragStart ?? framing
                if dragStart == nil { dragStart = framing }
                let width = max(viewSize.width, 1)
                let height = max(viewSize.height, 1)
                framing.offset = CGSize(
                    width: start.offset.width + value.translation.width / width,
                    height: start.offset.height + value.translation.height / height
                )
            }
            .onEnded { _ in
                dragStart = nil
            }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? framing
                if pinchStart == nil { pinchStart = framing }
                framing.scale = PssFraming.clamp(start.scale * value.magnification)
            }
            .onEnded { _ in
                pinchStart = nil
            }
    }

    // MARK: Background

    private var backgroundSection: some View {
        VStack(alignment: .leading, spacing: AP.Space.m) {
            APSectionTitle(text: "Background")
            APChipRow {
                ForEach(PssBackground.presets) { option in
                    APChip(title: option.title, selected: background == option) {
                        background = option
                        APHaptics.tap()
                    }
                    .accessibilityLabel(Text("\(option.title) background"))
                }
                customColorChip
            }
            .padding(.horizontal, -AP.Space.m)
            .onChange(of: customColor) {
                background = .custom
            }
        }
    }

    private var customColorChip: some View {
        let selected = background == .custom
        return HStack(spacing: 8) {
            ColorPicker("Custom background color", selection: $customColor, supportsOpacity: false)
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
            background = .custom
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Size

    private var sizeSection: some View {
        VStack(alignment: .leading, spacing: AP.Space.m) {
            APSectionTitle(text: "Photo size")
            APChipRow {
                ForEach(PssSize.allCases) { option in
                    APChip(title: option.title, selected: size == option) {
                        size = option
                        APHaptics.tap()
                    }
                }
            }
            .padding(.horizontal, -AP.Space.m)
            Text(sizeDetail)
                .font(AP.Font.callout)
                .foregroundStyle(AP.Palette.mist)
            if size == .custom {
                VStack(spacing: AP.Space.m) {
                    DialSlider(title: "Width", value: $customWidth, range: 20...80, defaultValue: 35, unit: " mm")
                    APHairline()
                    DialSlider(title: "Height", value: $customHeight, range: 20...100, defaultValue: 45, unit: " mm")
                }
            }
        }
    }

    // MARK: Output

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: AP.Space.m) {
            APSectionTitle(text: "Save")
            APChipRow {
                ForEach(PssOutput.allCases) { option in
                    APChip(title: option.title, selected: output == option) {
                        output = option
                        APHaptics.tap()
                    }
                }
            }
            .padding(.horizontal, -AP.Space.m)
            if output == .sheet {
                sheetOptions
            } else {
                Text("One JPG at \(Int(photoPixelSize.width)) \u{00D7} \(Int(photoPixelSize.height)) pixels, set to print at 300 dpi.")
                    .font(AP.Font.callout)
                    .foregroundStyle(AP.Palette.mist)
                    .fixedSize(horizontal: false, vertical: true)
            }
            saveAction
        }
    }

    private var sheetOptions: some View {
        VStack(alignment: .leading, spacing: AP.Space.m) {
            APChipRow {
                ForEach(PssSheet.allCases) { option in
                    APChip(title: option.title, selected: sheet == option) {
                        sheet = option
                        APHaptics.tap()
                    }
                    .accessibilityLabel(Text("\(option.title) paper"))
                }
            }
            .padding(.horizontal, -AP.Space.m)
            Text(sheetDetail)
                .font(AP.Font.callout)
                .foregroundStyle(copiesOnSheet == 0 ? AP.Palette.danger : AP.Palette.mist)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sheetDetail: String {
        let count = copiesOnSheet
        if count == 0 { return "This photo size is too large for \(sheet.title) paper. Choose a larger sheet." }
        let copies = count == 1 ? "1 copy fits" : "\(count) copies fit"
        return "\(copies) on \(sheet.title) paper, with thin lines to cut along. Print at actual size."
    }

    @ViewBuilder
    private var saveAction: some View {
        if let result {
            if output == .sheet {
                Image(uiImage: UIImage(cgImage: result.preview))
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 280)
                    .accessibilityLabel(Text("Preview of the print sheet"))
            }
            ExportBar(items: [result.item], savedMessage: output == .sheet ? "Print sheet saved to your library" : "Photo saved to your library")
        } else {
            Button {
                Task { await prepare() }
            } label: {
                HStack(spacing: 8) {
                    if isPreparing { ProgressView().tint(AP.Palette.onBrass) }
                    Text(prepareTitle)
                }
            }
            .buttonStyle(.apPrimaryWide)
            .disabled(isPreparing || (output == .sheet && copiesOnSheet == 0))
            if prepareFailed {
                Label("The file could not be made. Try again.", systemImage: "exclamationmark.triangle")
                    .font(AP.Font.label)
                    .foregroundStyle(AP.Palette.danger)
            }
        }
    }

    private var prepareTitle: String {
        if isPreparing { return "Preparing" }
        return output == .sheet ? "Make print sheet" : "Make photo"
    }

    private var rulesNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: AP.Space.s) {
            Image(systemName: "info.circle")
                .foregroundStyle(AP.Palette.mist)
                .accessibilityHidden(true)
            Text("Always check your country's current photo rules before you print.")
                .font(AP.Font.caption)
                .foregroundStyle(AP.Palette.mist)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Work

    private func loadAndCut() async {
        guard let item = pickerItem else { return }
        result = nil
        cutout = nil
        cutoutImage = nil
        phase = .loading
        await selection.load([item], maxPixel: 3000)
        guard selection.photos.first != nil else {
            phase = .unreadable
            APHaptics.warning()
            return
        }
        await runCutout()
    }

    private func runCutout() async {
        guard let photo = selection.photos.first else {
            phase = .idle
            return
        }
        phase = .working
        result = nil
        let image = photo.image
        guard let lifted = await CutoutService.cutout(image) else {
            phase = .noPerson
            APHaptics.warning()
            return
        }
        let bounds: CGRect? = await Task.detached(priority: .userInitiated) { () -> CGRect? in
            PssCompositor.subjectBounds(lifted)
        }.value
        cutout = lifted
        cutoutImage = UIImage(cgImage: lifted)
        subjectBounds = bounds
        framing = automaticFraming
        phase = .ready
        APHaptics.success()
    }

    private func prepare() async {
        guard let cutout else { return }
        let canvas = photoPixelSize
        let fill = backgroundUIColor
        let currentFraming = framing
        let currentOutput = output
        let sheetSize = sheet.pixelSize
        isPreparing = true
        prepareFailed = false
        let made: PssResult? = await Task.detached(priority: .userInitiated) { () -> PssResult? in
            guard let single = PssCompositor.compose(cutout: cutout, background: fill, canvas: canvas, framing: currentFraming) else {
                return nil
            }
            let finalImage: CGImage
            let base: String
            if currentOutput == .sheet {
                guard let sheetImage = PssCompositor.composeSheet(photo: single, sheet: sheetSize) else { return nil }
                finalImage = sheetImage
                base = "Aperta-id-sheet"
            } else {
                finalImage = single
                base = "Aperta-id"
            }
            let properties: [String: Any] = [
                kCGImagePropertyDPIWidth as String: 300,
                kCGImagePropertyDPIHeight as String: 300,
            ]
            guard let data = ImageCodec.encode(finalImage, format: .jpeg, quality: 0.95, properties: properties) else {
                return nil
            }
            let item = ExportItem(data: data, filename: ExportItem.uniqueName(base, format: .jpeg), format: .jpeg)
            return PssResult(item: item, preview: finalImage)
        }.value
        isPreparing = false
        if let made {
            result = made
            APHaptics.success()
        } else {
            prepareFailed = true
            APHaptics.warning()
        }
    }
}
