import SwiftUI
import UIKit
import CoreImage

struct ExportOptions: Equatable {
    var format: OutputFormat = .jpeg
    /// Longest side in pixels. Nil keeps the full size.
    var maxLongSide: Int? = nil
    var quality: Double = 0.92
}

/// State and behaviour of one editing session: the edit, undo and redo, the live preview, the cut-out and export.
@MainActor
final class EditorModel: ObservableObject {
    let photo: LoadedPhoto

    @Published var state = EditState() {
        didSet { if state != oldValue { requestRender() } }
    }
    @Published var tool: EditorTool? = nil {
        didSet { if oldValue != tool { toolChanged(from: oldValue) } }
    }
    @Published private(set) var preview: UIImage?
    @Published private(set) var originalPreview: UIImage?
    @Published private(set) var previewAspect: CGFloat = 1
    @Published var selectedOverlay: UUID?
    @Published var showingOriginal = false
    @Published private(set) var isCutting = false
    @Published private(set) var cutoutReady = false
    @Published var notice: String?

    // Brush settings for the Draw and Blur tools.
    @Published var penKind: PenKind = .pen
    @Published var penColorHex: UInt32 = 0xFFFFFF
    @Published var penWidth: Double = 0.012
    @Published var blurMode: BlurMode = .blur
    @Published var blurWidth: Double = 0.08

    private let source: CIImage
    private var proxy: CIImage
    private var maskProxy: CIImage?
    private var maskFull: CIImage?

    private var undoStack: [EditState] = []
    private var redoStack: [EditState] = []
    private var lastKey: EditState?
    private var pending: (state: EditState, applyCrop: Bool)?
    private var rendering = false

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var hasEdits: Bool { state != EditState() }

    /// Size of the picture before the crop rectangle, used by the crop tool for ratios.
    var geometrySize: CGSize {
        let g = EditPipeline.shared.geometry(proxy, crop: state.crop)
        return g.size
    }

    /// Picture size for a given crop state (after turns and straightening), used to place crop rectangles.
    func geometrySize(for crop: CropState) -> CGSize {
        EditPipeline.shared.geometry(proxy, crop: crop).size
    }

    /// Largest centred crop rectangle (unit coordinates) with the given ratio for the current geometry.
    func fittedCropRect(ratio: CropRatio, crop: CropState) -> CGRect {
        let size = geometrySize(for: crop)
        guard size.width > 0, size.height > 0,
              let target = ratio.value(original: size.width / size.height) else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let current = size.width / size.height
        if current > target {
            let w = target / current
            return CGRect(x: (1 - w) / 2, y: 0, width: w, height: 1)
        }
        let h = current / target
        return CGRect(x: 0, y: (1 - h) / 2, width: 1, height: h)
    }

    init(photo: LoadedPhoto, previewLongSide: Int = 2048) {
        self.photo = photo
        let full = CIImage(cgImage: photo.image)
        self.source = full
        if let small = ImageCodec.scaled(photo.image, maxPixel: previewLongSide) {
            self.proxy = CIImage(cgImage: small)
            self.originalPreview = UIImage(cgImage: small)
        } else {
            self.proxy = full
            self.originalPreview = UIImage(cgImage: photo.image)
        }
        requestRender()
    }

    // MARK: Undo and redo

    /// Remembers the current edit so the next change can be undone. Call before a change starts (once per gesture).
    func checkpoint() {
        undoStack.append(state)
        if undoStack.count > 80 { undoStack.removeFirst() }
        redoStack.removeAll()
        objectWillChange.send()
    }

    /// Runs one discrete change as a single undo step.
    func commit(_ change: (inout EditState) -> Void) {
        checkpoint()
        var next = state
        change(&next)
        state = next
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(state)
        state = previous
        objectWillChange.send()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        state = next
        objectWillChange.send()
    }

    func resetAll() {
        guard hasEdits else { return }
        checkpoint()
        state = EditState()
        selectedOverlay = nil
    }

    // MARK: Preview rendering (latest request wins)

    private func toolChanged(from old: EditorTool?) {
        if (old == .crop) != (tool == .crop) {
            if tool != .crop { normaliseCropRect() }
            lastKey = nil
            requestRender()
        }
        if tool != .text && tool != .stickers { selectedOverlay = nil }
    }

    private func normaliseCropRect() {
        let r = state.crop.rect
        if r.width < 0.02 || r.height < 0.02 { state.crop.rect = CGRect(x: 0, y: 0, width: 1, height: 1) }
    }

    private static func key(_ state: EditState, applyCrop: Bool) -> EditState {
        var key = state
        key.overlays = []
        key.strokes = []
        if !applyCrop {
            key.crop.rect = CGRect(x: 0, y: 0, width: 1, height: 1)
            key.crop.ratio = .free
            key.frame = FrameState()
        }
        return key
    }

    func requestRender() {
        let applyCrop = tool != .crop
        let key = Self.key(state, applyCrop: applyCrop)
        if key == lastKey { return }
        lastKey = key
        pending = (state, applyCrop)
        if !rendering { startRender() }
    }

    private func startRender() {
        guard let job = pending else { return }
        pending = nil
        rendering = true
        let proxy = self.proxy
        let mask = self.maskProxy
        Task.detached(priority: .userInitiated) { [weak self] in
            let image = EditPipeline.shared.render(source: proxy, mask: mask, state: job.state, applyCrop: job.applyCrop)
            let cg = EditPipeline.shared.cgImage(image)
            await MainActor.run { self?.finishRender(cg) }
        }
    }

    private func finishRender(_ cg: CGImage?) {
        rendering = false
        if let cg {
            preview = UIImage(cgImage: cg)
            previewAspect = CGFloat(cg.width) / max(1, CGFloat(cg.height))
        }
        if pending != nil { startRender() }
    }

    // MARK: Cut-out

    func makeCutout() async {
        guard !isCutting else { return }
        isCutting = true
        defer { isCutting = false }
        guard let small = ImageCodec.scaled(photo.image, maxPixel: 1600) else { return }
        if let mask = await CutoutService.subjectMask(for: small) {
            maskProxy = mask
            // The preview proxy can be larger than the mask source; the pipeline rescales the mask to fit.
            cutoutReady = true
            checkpoint()
            var next = state
            next.background.mode = .transparent
            state = next
            lastKey = nil
            requestRender()
            APHaptics.success()
        } else {
            notice = "We could not find a clear subject in this photo. Try a photo with a person or object in front."
            APHaptics.warning()
        }
    }

    private func fullMask() async -> CIImage? {
        if let maskFull { return maskFull }
        guard let mask = await CutoutService.subjectMask(for: photo.image) else { return nil }
        maskFull = mask
        return mask
    }

    // MARK: Overlays

    func addText() {
        commit { state in
            let overlay = Overlay(content: .text(TextStyle()))
            state.overlays.append(overlay)
            selectedOverlay = overlay.id
        }
    }

    func addEmoji(_ emoji: String) {
        commit { state in
            let jitter = CGFloat.random(in: -0.05...0.05)
            let overlay = Overlay(content: .emoji(emoji), center: CGPoint(x: 0.5 + jitter, y: 0.5 + jitter))
            state.overlays.append(overlay)
            selectedOverlay = overlay.id
        }
    }

    func addSymbol(_ name: String, colorHex: UInt32) {
        commit { state in
            let overlay = Overlay(content: .symbol(SymbolStyle(name: name, colorHex: colorHex)))
            state.overlays.append(overlay)
            selectedOverlay = overlay.id
        }
    }

    func updateOverlay(_ id: UUID, _ change: (inout Overlay) -> Void) {
        guard let index = state.overlays.firstIndex(where: { $0.id == id }) else { return }
        var next = state
        change(&next.overlays[index])
        state = next
    }

    func deleteSelected() {
        guard let id = selectedOverlay else { return }
        commit { $0.overlays.removeAll { $0.id == id } }
        selectedOverlay = nil
    }

    func duplicateSelected() {
        guard let id = selectedOverlay, let original = state.overlays.first(where: { $0.id == id }) else { return }
        var copy = original
        copy.id = UUID()
        copy.center = CGPoint(x: min(0.95, original.center.x + 0.05), y: min(0.95, original.center.y + 0.05))
        commit { $0.overlays.append(copy) }
        selectedOverlay = copy.id
    }

    func bringSelectedToFront() {
        guard let id = selectedOverlay, let index = state.overlays.firstIndex(where: { $0.id == id }) else { return }
        guard index != state.overlays.count - 1 else { return }
        commit { state in
            let item = state.overlays.remove(at: index)
            state.overlays.append(item)
        }
    }

    var selectedTextStyle: TextStyle? {
        guard let id = selectedOverlay, let overlay = state.overlays.first(where: { $0.id == id }) else { return nil }
        if case .text(let style) = overlay.content { return style }
        return nil
    }

    // MARK: Export

    /// Renders the finished picture at full size (or the chosen size) and encodes it.
    func renderExport(options: ExportOptions) async -> ExportItem? {
        let snapshot = state
        var format = options.format
        let needsAlpha = snapshot.background.mode == .transparent && cutoutReady
        if needsAlpha && format == .jpeg { format = .png }

        var mask: CIImage?
        if cutoutReady && snapshot.background.mode != .original { mask = await fullMask() }

        let sourceImage = source
        let cgOptional: CGImage? = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            let ci = EditPipeline.shared.render(source: sourceImage, mask: mask, state: snapshot, applyCrop: true)
            return EditPipeline.shared.cgImage(ci)
        }.value
        guard var cg = cgOptional else { return nil }

        if let limit = options.maxLongSide, let smaller = ImageCodec.scaled(cg, maxPixel: limit) { cg = smaller }

        if snapshot.hasOverlays {
            let size = CGSize(width: cg.width, height: cg.height)
            let content = ZStack {
                Image(decorative: cg, scale: 1).resizable().frame(width: size.width, height: size.height)
                OverlayLayer(state: snapshot, canvasSize: size, selection: nil, interactive: false, model: nil)
            }
            .frame(width: size.width, height: size.height)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 1
            renderer.isOpaque = !needsAlpha
            if let composed = renderer.uiImage?.cgImage { cg = composed }
        }

        let properties = ImageCodec.privacySafe(photo.properties)
        guard let data = ImageCodec.encode(cg, format: format, quality: options.quality, properties: properties) else { return nil }
        return ExportItem(data: data, filename: ExportItem.uniqueName("Aperta", format: format), format: format)
    }
}
