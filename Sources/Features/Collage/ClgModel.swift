import SwiftUI
import UIKit
import CoreGraphics

/// One photo in the collage: the full image for the file and a smaller copy for the screen.
struct ClgPhoto: Identifiable, @unchecked Sendable {
    let id = UUID()
    let full: CGImage
    let display: CGImage

    var size: CGSize { CGSize(width: full.width, height: full.height) }

    /// Makes the screen copy. Call off the main thread.
    init(full: CGImage, displayMaxPixel: Int = 1200) {
        self.full = full
        self.display = ImageCodec.scaled(full, maxPixel: displayMaxPixel) ?? full
    }
}

enum ClgAspect: String, CaseIterable, Identifiable {
    case square, portrait, story, wide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .square: return "1:1"
        case .portrait: return "4:5"
        case .story: return "9:16"
        case .wide: return "16:9"
        }
    }

    var spokenName: String {
        switch self {
        case .square: return "Square, 1 to 1"
        case .portrait: return "Portrait, 4 to 5"
        case .story: return "Story, 9 to 16"
        case .wide: return "Wide, 16 to 9"
        }
    }

    /// Width divided by height.
    var ratio: CGFloat {
        switch self {
        case .square: return 1
        case .portrait: return 4.0 / 5.0
        case .story: return 9.0 / 16.0
        case .wide: return 16.0 / 9.0
        }
    }
}

enum ClgBackdrop: String, CaseIterable, Identifiable {
    case black, white, brass, graphite, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .black: return "Black"
        case .white: return "White"
        case .brass: return "Brass"
        case .graphite: return "Graphite"
        case .custom: return "Custom"
        }
    }
}

@MainActor
final class ClgModel: ObservableObject {
    /// Photos in cell order: `photos[i]` fills cell `i` of the current layout.
    @Published var photos: [ClgPhoto] = [] { didSet { invalidate() } }
    @Published var transforms: [ClgCellTransform] = [] { didSet { invalidate() } }
    @Published var layoutID: String = "" { didSet { invalidate() } }
    @Published var aspect: ClgAspect = .square { didSet { invalidate() } }
    @Published var spacing: Double = 8 { didSet { invalidate() } }
    @Published var cornerRadius: Double = 0 { didSet { invalidate() } }
    @Published var margin: Double = 0 { didSet { invalidate() } }
    @Published var backdrop: ClgBackdrop = .black { didSet { invalidate() } }
    @Published var customColor: Color = Color(hex: 0x3A2F25) { didSet { invalidate() } }

    @Published var selectedCell: Int? = nil
    @Published var isSwapping: Bool = false

    @Published var exportItems: [ExportItem] = []
    @Published var exportPreview: CGImage? = nil
    @Published var isRendering: Bool = false
    @Published var errorMessage: String? = nil

    static let exportLongSide: CGFloat = 2160

    var layouts: [CollageLayout] { CollageLayouts.forCount(photos.count) }

    var layout: CollageLayout? {
        let options = layouts
        return options.first(where: { $0.id == layoutID }) ?? options.first
    }

    var style: ClgStyle {
        ClgStyle(spacing: spacing, cornerRadius: cornerRadius, margin: margin)
    }

    var backgroundColor: Color {
        switch backdrop {
        case .black: return Color.black
        case .white: return Color.white
        case .brass: return AP.Palette.brass
        case .graphite: return AP.Palette.graphite
        case .custom: return customColor
        }
    }

    // MARK: Editing

    func setPhotos(_ newPhotos: [ClgPhoto]) {
        photos = newPhotos
        transforms = newPhotos.map { _ in ClgCellTransform() }
        layoutID = CollageLayouts.forCount(newPhotos.count).first?.id ?? ""
        selectedCell = nil
        isSwapping = false
        errorMessage = nil
    }

    func reset() {
        photos = []
        transforms = []
        layoutID = ""
        selectedCell = nil
        isSwapping = false
    }

    func transform(at index: Int) -> ClgCellTransform {
        index >= 0 && index < transforms.count ? transforms[index] : ClgCellTransform()
    }

    func setTransform(_ value: ClgCellTransform, at index: Int) {
        guard index >= 0, index < transforms.count else { return }
        let next = value.clamped()
        if transforms[index] != next { transforms[index] = next }
    }

    func swapCells(_ a: Int, _ b: Int) {
        guard a != b, a >= 0, b >= 0, a < photos.count, b < photos.count, a < transforms.count, b < transforms.count else { return }
        photos.swapAt(a, b)
        transforms.swapAt(a, b)
    }

    func replacePhoto(at index: Int, with photo: ClgPhoto) {
        guard index >= 0, index < photos.count else { return }
        photos[index] = photo
        setTransform(ClgCellTransform(), at: index)
    }

    func resetFraming(at index: Int) {
        setTransform(ClgCellTransform(), at: index)
    }

    private func invalidate() {
        if !exportItems.isEmpty { exportItems = [] }
        if exportPreview != nil { exportPreview = nil }
    }

    // MARK: Export

    func makeJob(longSide: CGFloat, useDisplayImages: Bool) -> ClgRenderJob? {
        guard let layout, layout.count == photos.count else { return nil }
        let images: [CGImage?] = photos.map { useDisplayImages ? $0.display : $0.full }
        return ClgRenderJob(
            layout: layout,
            images: images,
            transforms: transforms,
            style: style,
            aspect: aspect.ratio,
            longSide: longSide,
            background: UIColor(backgroundColor)
        )
    }

    func export() async {
        guard !isRendering, let job = makeJob(longSide: ClgModel.exportLongSide, useDisplayImages: false) else { return }
        isRendering = true
        errorMessage = nil
        let result: ClgRenderOutput = await Task.detached(priority: .userInitiated) { () -> ClgRenderOutput in
            guard let image = ClgRenderer.render(job) else { return ClgRenderOutput(data: nil, preview: nil) }
            let data = ImageCodec.encode(image, format: .jpeg, quality: 0.92)
            let preview = ImageCodec.scaled(image, maxPixel: 400)
            return ClgRenderOutput(data: data, preview: preview)
        }.value
        isRendering = false
        if let data = result.data {
            let name = ExportItem.uniqueName("Aperta-collage", format: .jpeg)
            exportItems = [ExportItem(data: data, filename: name, format: .jpeg)]
            exportPreview = result.preview
            APHaptics.success()
        } else {
            errorMessage = "The collage could not be created. Try again, or use fewer large photos."
            APHaptics.warning()
        }
    }
}

struct ClgRenderOutput: @unchecked Sendable {
    let data: Data?
    let preview: CGImage?
}
