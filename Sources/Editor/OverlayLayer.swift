import SwiftUI
import UIKit

/// Everything drawn on top of the processed picture: pen strokes, text, stickers.
/// Used on screen (interactive) and for export (via ImageRenderer), so what you see is what you save.
/// All positions are unit coordinates of the canvas and all sizes are fractions of the canvas width.
struct OverlayLayer: View {
    let state: EditState
    let canvasSize: CGSize
    let selection: UUID?
    let interactive: Bool
    let model: EditorModel?

    var body: some View {
        ZStack {
            StrokeCanvas(strokes: state.strokes, size: canvasSize)
                .allowsHitTesting(false)
            ForEach(state.overlays) { overlay in
                OverlayItemView(
                    overlay: overlay,
                    canvasSize: canvasSize,
                    selected: interactive && selection == overlay.id,
                    interactive: interactive,
                    model: model
                )
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
    }
}

// MARK: - Pen strokes

struct StrokeCanvas: View {
    let strokes: [DrawStroke]
    let size: CGSize

    var body: some View {
        Canvas { context, canvasSize in
            for stroke in strokes {
                let points = stroke.points.map { CGPoint(x: $0.x * canvasSize.width, y: $0.y * canvasSize.height) }
                guard let first = points.first else { continue }
                let width = max(1, CGFloat(stroke.width) * canvasSize.width)
                let colour = Color(hex: stroke.colorHex)
                var path = Path()
                path.move(to: first)
                if points.count == 1 {
                    path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y))
                } else {
                    for p in points.dropFirst() { path.addLine(to: p) }
                }
                switch stroke.kind {
                case .pen:
                    context.stroke(path, with: .color(colour), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
                case .marker:
                    context.stroke(path, with: .color(colour.opacity(0.45)), style: StrokeStyle(lineWidth: width * 2.4, lineCap: .square, lineJoin: .round))
                case .neon:
                    context.drawLayer { layer in
                        layer.addFilter(.shadow(color: colour.opacity(0.9), radius: width * 1.6, x: 0, y: 0, blendMode: .normal, options: []))
                        layer.stroke(path, with: .color(colour), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
                    }
                    context.stroke(path, with: .color(Color.white.opacity(0.85)), style: StrokeStyle(lineWidth: max(1, width * 0.35), lineCap: .round, lineJoin: .round))
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - One text or sticker

struct OverlayItemView: View {
    let overlay: Overlay
    let canvasSize: CGSize
    let selected: Bool
    let interactive: Bool
    let model: EditorModel?

    @State private var dragOrigin: CGPoint?
    @State private var scaleOrigin: CGFloat?
    @State private var rotationOrigin: Double?

    var body: some View {
        let item = content
            .padding(4)
            .overlay(selectionOutline)
            .scaleEffect(overlay.scale)
            .rotationEffect(.radians(overlay.rotation))
        interactiveItem(item)
            .position(x: overlay.center.x * canvasSize.width, y: overlay.center.y * canvasSize.height)
    }

    /// Gestures go on the item itself, before it is positioned, so only the item (not the whole canvas) reacts.
    @ViewBuilder
    private func interactiveItem<V: View>(_ item: V) -> some View {
        if interactive, let model {
            item
                .contentShape(Rectangle())
                .gesture(dragGesture(model))
                .simultaneousGesture(magnifyGesture(model))
                .simultaneousGesture(rotateGesture(model))
        } else {
            item.allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var selectionOutline: some View {
        if selected {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(AP.Palette.brass, style: StrokeStyle(lineWidth: 1.5 / max(overlay.scale, 0.3), dash: [6, 4]))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch overlay.content {
        case .text(let style):
            OverlayTextView(style: style, canvasWidth: canvasSize.width)
        case .emoji(let emoji):
            Text(emoji)
                .font(.system(size: canvasSize.width * 0.16))
                .fixedSize()
        case .symbol(let symbol):
            Image(systemName: symbol.name)
                .font(.system(size: canvasSize.width * 0.14, weight: .semibold))
                .foregroundStyle(Color(hex: symbol.colorHex))
                .shadow(color: .black.opacity(0.35), radius: canvasSize.width * 0.004, x: 0, y: canvasSize.width * 0.002)
        }
    }

    // MARK: Gestures

    private func dragGesture(_ model: EditorModel) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("apCanvas"))
            .onChanged { value in
                if dragOrigin == nil {
                    model.checkpoint()
                    model.selectedOverlay = overlay.id
                    dragOrigin = overlay.center
                }
                guard let origin = dragOrigin, canvasSize.width > 0, canvasSize.height > 0 else { return }
                let x = min(1, max(0, origin.x + value.translation.width / canvasSize.width))
                let y = min(1, max(0, origin.y + value.translation.height / canvasSize.height))
                model.updateOverlay(overlay.id) { $0.center = CGPoint(x: x, y: y) }
            }
            .onEnded { value in
                if dragOrigin == nil { model.selectedOverlay = overlay.id }
                dragOrigin = nil
            }
    }

    private func magnifyGesture(_ model: EditorModel) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if scaleOrigin == nil {
                    model.checkpoint()
                    model.selectedOverlay = overlay.id
                    scaleOrigin = overlay.scale
                }
                guard let origin = scaleOrigin else { return }
                let next = min(8, max(0.15, origin * value.magnification))
                model.updateOverlay(overlay.id) { $0.scale = next }
            }
            .onEnded { _ in scaleOrigin = nil }
    }

    private func rotateGesture(_ model: EditorModel) -> some Gesture {
        RotateGesture()
            .onChanged { value in
                if rotationOrigin == nil {
                    model.checkpoint()
                    model.selectedOverlay = overlay.id
                    rotationOrigin = overlay.rotation
                }
                guard let origin = rotationOrigin else { return }
                model.updateOverlay(overlay.id) { $0.rotation = origin + value.rotation.radians }
            }
            .onEnded { _ in rotationOrigin = nil }
    }
}

struct OverlayTextView: View {
    let style: TextStyle
    let canvasWidth: CGFloat

    var body: some View {
        let size = max(8, CGFloat(style.size) * canvasWidth)
        let font = Font(style.font.uiFont(size: size) as CTFont)
        let colour = Color(hex: style.colorHex)
        let plate: Color = style.colorHex.luminance > 0.55 ? Color.black.opacity(0.55) : Color.white.opacity(0.78)
        Text(style.text.isEmpty ? " " : style.text)
            .font(font)
            .tracking(CGFloat(style.tracking) * size * 0.01)
            .multilineTextAlignment(.center)
            .foregroundStyle(colour)
            .shadow(color: style.shadow ? Color.black.opacity(0.45) : .clear, radius: size * 0.08, x: 0, y: size * 0.03)
            .padding(.horizontal, style.background == .none ? 0 : size * 0.45)
            .padding(.vertical, style.background == .none ? 0 : size * 0.22)
            .background(backgroundShape(plate))
            .fixedSize()
    }

    @ViewBuilder
    private func backgroundShape(_ colour: Color) -> some View {
        switch style.background {
        case .none: Color.clear
        case .box: RoundedRectangle(cornerRadius: 4, style: .continuous).fill(colour)
        case .pill: Capsule().fill(colour)
        }
    }
}
