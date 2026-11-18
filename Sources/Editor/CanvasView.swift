import SwiftUI
import UIKit

/// The picture, its overlays and whichever tool layer is active (draw, blur, crop).
struct CanvasView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        GeometryReader { geo in
            let available = CGSize(width: max(1, geo.size.width - 24), height: max(1, geo.size.height - 24))
            let aspect = model.showingOriginal ? originalAspect : model.previewAspect
            let fitted = Self.fit(aspect: aspect, in: available)
            ZStack {
                if showsChecker { CheckerBoard() }
                picture
                    .frame(width: fitted.width, height: fitted.height)
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectedOverlay = nil }
                if !model.showingOriginal {
                    OverlayLayer(
                        state: model.state,
                        canvasSize: fitted,
                        selection: model.selectedOverlay,
                        interactive: overlaysInteractive,
                        model: model
                    )
                    toolLayer(size: fitted)
                }
            }
            .frame(width: fitted.width, height: fitted.height)
            .clipped()
            .coordinateSpace(name: "apCanvas")
            .shadow(color: .black.opacity(0.5), radius: 18, x: 0, y: 8)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .animation(.easeOut(duration: 0.18), value: model.previewAspect)
        }
    }

    private var originalAspect: CGFloat {
        CGFloat(model.photo.image.width) / max(1, CGFloat(model.photo.image.height))
    }

    private var showsChecker: Bool {
        model.cutoutReady && model.state.background.mode == .transparent && !model.showingOriginal
    }

    private var overlaysInteractive: Bool {
        guard let tool = model.tool else { return true }
        return tool == .text || tool == .stickers
    }

    @ViewBuilder
    private var picture: some View {
        let image = model.showingOriginal ? model.originalPreview : model.preview
        if let image {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            ProgressView().tint(AP.Palette.brass)
        }
    }

    @ViewBuilder
    private func toolLayer(size: CGSize) -> some View {
        switch model.tool {
        case .draw:
            BrushCapture(model: model, size: size, target: .pen)
        case .blur:
            BrushCapture(model: model, size: size, target: .blur)
        case .crop:
            CropOverlay(model: model, size: size)
        default:
            EmptyView()
        }
    }

    static func fit(aspect: CGFloat, in box: CGSize) -> CGSize {
        let a = max(0.05, aspect)
        if box.width / box.height > a {
            return CGSize(width: box.height * a, height: box.height)
        }
        return CGSize(width: box.width, height: box.width / a)
    }
}

/// Grey and white squares behind a transparent cut-out.
struct CheckerBoard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 12
            let columns = Int(size.width / cell) + 1
            let rows = Int(size.height / cell) + 1
            for row in 0..<rows {
                for column in 0..<columns where (row + column) % 2 == 0 {
                    let rect = CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
                    context.fill(Path(rect), with: .color(Color.white.opacity(0.10)))
                }
            }
        }
        .background(Color(hex: 0x2A2C30))
        .allowsHitTesting(false)
    }
}

// MARK: - Drawing and blur brushes

struct BrushCapture: View {
    enum Target { case pen, blur }

    @ObservedObject var model: EditorModel
    let size: CGSize
    let target: Target

    @State private var activeID: UUID?

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in handle(value.location) }
                    .onEnded { _ in activeID = nil }
            )
    }

    private func handle(_ location: CGPoint) {
        guard size.width > 0, size.height > 0 else { return }
        let point = CGPoint(x: min(1, max(0, location.x / size.width)), y: min(1, max(0, location.y / size.height)))
        if let id = activeID {
            appendPoint(point, to: id)
        } else {
            begin(at: point)
        }
    }

    private func begin(at point: CGPoint) {
        model.checkpoint()
        switch target {
        case .pen:
            let stroke = DrawStroke(points: [point], colorHex: model.penColorHex, width: model.penWidth, kind: model.penKind)
            activeID = stroke.id
            var next = model.state
            next.strokes.append(stroke)
            model.state = next
        case .blur:
            // Blur strokes are stored on the source picture, so they stay put when the crop, turn or frame changes.
            let stroke = BlurStroke(
                points: [model.sourcePoint(forCanvasPoint: point)],
                width: model.sourceBrushWidth(model.blurWidth),
                mode: model.blurMode
            )
            activeID = stroke.id
            var next = model.state
            next.blurs.append(stroke)
            model.state = next
        }
    }

    private func appendPoint(_ point: CGPoint, to id: UUID) {
        var next = model.state
        switch target {
        case .pen:
            guard let index = next.strokes.firstIndex(where: { $0.id == id }) else { return }
            if let last = next.strokes[index].points.last, hypot(last.x - point.x, last.y - point.y) < 0.002 { return }
            next.strokes[index].points.append(point)
        case .blur:
            guard let index = next.blurs.firstIndex(where: { $0.id == id }) else { return }
            let sourcePoint = model.sourcePoint(forCanvasPoint: point)
            if let last = next.blurs[index].points.last, hypot(last.x - sourcePoint.x, last.y - sourcePoint.y) < 0.0015 { return }
            next.blurs[index].points.append(sourcePoint)
        }
        model.state = next
    }
}

// MARK: - Crop

struct CropOverlay: View {
    @ObservedObject var model: EditorModel
    let size: CGSize

    private enum Handle { case topLeft, topRight, bottomLeft, bottomRight, top, bottom, left, right, move }

    @State private var startRect: CGRect?
    @State private var activeHandle: Handle?

    private let minSide: CGFloat = 0.08
    private let hit: CGFloat = 44

    private var rect: CGRect { model.state.crop.rect }

    var body: some View {
        let frame = CGRect(
            x: rect.minX * size.width, y: rect.minY * size.height,
            width: rect.width * size.width, height: rect.height * size.height
        )
        ZStack {
            DimmedOutside(hole: frame)
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
            Thirds(frame: frame)
                .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                .allowsHitTesting(false)
            Rectangle()
                .strokeBorder(AP.Palette.brass, lineWidth: 1.5)
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .allowsHitTesting(false)
            cornerMarks(frame)
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in dragChanged(value, frame: frame) }
                        .onEnded { _ in startRect = nil; activeHandle = nil }
                )
        }
    }

    private func cornerMarks(_ f: CGRect) -> some View {
        ZStack {
            ForEach(0..<4, id: \.self) { index in
                let x = (index % 2 == 0) ? f.minX + 8 : f.maxX - 8
                let y = index < 2 ? f.minY + 8 : f.maxY - 8
                Circle()
                    .fill(AP.Palette.brass)
                    .frame(width: 14, height: 14)
                    .position(x: x, y: y)
            }
        }
        .allowsHitTesting(false)
    }

    private func handleAt(_ point: CGPoint, frame f: CGRect) -> Handle {
        let nearLeft = abs(point.x - f.minX) < hit / 2 + 6
        let nearRight = abs(point.x - f.maxX) < hit / 2 + 6
        let nearTop = abs(point.y - f.minY) < hit / 2 + 6
        let nearBottom = abs(point.y - f.maxY) < hit / 2 + 6
        if nearLeft && nearTop { return .topLeft }
        if nearRight && nearTop { return .topRight }
        if nearLeft && nearBottom { return .bottomLeft }
        if nearRight && nearBottom { return .bottomRight }
        if model.state.crop.ratio == .free {
            let insideX = point.x > f.minX && point.x < f.maxX
            let insideY = point.y > f.minY && point.y < f.maxY
            if nearTop && insideX { return .top }
            if nearBottom && insideX { return .bottom }
            if nearLeft && insideY { return .left }
            if nearRight && insideY { return .right }
        }
        return .move
    }

    private func dragChanged(_ value: DragGesture.Value, frame: CGRect) {
        if startRect == nil {
            model.checkpoint()
            startRect = rect
            activeHandle = handleAt(value.startLocation, frame: frame)
        }
        guard let start = startRect, let handle = activeHandle, size.width > 0, size.height > 0 else { return }
        let dx = value.translation.width / size.width
        let dy = value.translation.height / size.height
        var next = start

        switch handle {
        case .move:
            next.origin.x = min(1 - start.width, max(0, start.minX + dx))
            next.origin.y = min(1 - start.height, max(0, start.minY + dy))
        case .top:
            let top = min(start.maxY - minSide, max(0, start.minY + dy))
            next = CGRect(x: start.minX, y: top, width: start.width, height: start.maxY - top)
        case .bottom:
            let bottom = max(start.minY + minSide, min(1, start.maxY + dy))
            next = CGRect(x: start.minX, y: start.minY, width: start.width, height: bottom - start.minY)
        case .left:
            let left = min(start.maxX - minSide, max(0, start.minX + dx))
            next = CGRect(x: left, y: start.minY, width: start.maxX - left, height: start.height)
        case .right:
            let right = max(start.minX + minSide, min(1, start.maxX + dx))
            next = CGRect(x: start.minX, y: start.minY, width: right - start.minX, height: start.height)
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            next = resizeCorner(handle, start: start, dx: dx, dy: dy)
        }
        var state = model.state
        state.crop.rect = next
        model.state = state
    }

    private func resizeCorner(_ handle: Handle, start: CGRect, dx: CGFloat, dy: CGFloat) -> CGRect {
        let fixed: CGPoint
        var moving: CGPoint
        switch handle {
        case .topLeft:
            fixed = CGPoint(x: start.maxX, y: start.maxY)
            moving = CGPoint(x: start.minX + dx, y: start.minY + dy)
        case .topRight:
            fixed = CGPoint(x: start.minX, y: start.maxY)
            moving = CGPoint(x: start.maxX + dx, y: start.minY + dy)
        case .bottomLeft:
            fixed = CGPoint(x: start.maxX, y: start.minY)
            moving = CGPoint(x: start.minX + dx, y: start.maxY + dy)
        default:
            fixed = CGPoint(x: start.minX, y: start.minY)
            moving = CGPoint(x: start.maxX + dx, y: start.maxY + dy)
        }
        moving.x = min(1, max(0, moving.x))
        moving.y = min(1, max(0, moving.y))
        var width = max(minSide, abs(moving.x - fixed.x))
        var height = max(minSide, abs(moving.y - fixed.y))

        let geometry = model.geometrySize
        if let ratio = model.state.crop.ratio.value(original: geometry.width / max(1, geometry.height)) {
            // Keep the pixel ratio: height in unit space = width * (Gw / Gh) / ratio.
            let factor = geometry.width / max(1, geometry.height) / ratio
            height = width * factor
            let directionX: CGFloat = moving.x >= fixed.x ? 1 : -1
            let directionY: CGFloat = moving.y >= fixed.y ? 1 : -1
            let maxWidth = directionX > 0 ? 1 - fixed.x : fixed.x
            let maxHeight = directionY > 0 ? 1 - fixed.y : fixed.y
            if height > maxHeight { height = maxHeight; width = height / factor }
            if width > maxWidth { width = maxWidth; height = width * factor }
            moving = CGPoint(x: fixed.x + directionX * width, y: fixed.y + directionY * height)
        } else {
            moving = CGPoint(x: moving.x >= fixed.x ? fixed.x + width : fixed.x - width, y: moving.y >= fixed.y ? fixed.y + height : fixed.y - height)
        }
        let minX = min(fixed.x, moving.x), maxX = max(fixed.x, moving.x)
        let minY = min(fixed.y, moving.y), maxY = max(fixed.y, moving.y)
        return CGRect(x: max(0, minX), y: max(0, minY), width: min(1, maxX) - max(0, minX), height: min(1, maxY) - max(0, minY))
    }
}

private struct DimmedOutside: Shape {
    let hole: CGRect
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addRect(hole)
        return path
    }
}

private struct Thirds: Shape {
    let frame: CGRect
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for i in 1...2 {
            let x = frame.minX + frame.width * CGFloat(i) / 3
            path.move(to: CGPoint(x: x, y: frame.minY))
            path.addLine(to: CGPoint(x: x, y: frame.maxY))
            let y = frame.minY + frame.height * CGFloat(i) / 3
            path.move(to: CGPoint(x: frame.minX, y: y))
            path.addLine(to: CGPoint(x: frame.maxX, y: y))
        }
        return path
    }
}
