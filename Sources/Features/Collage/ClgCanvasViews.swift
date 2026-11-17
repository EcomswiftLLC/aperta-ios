import SwiftUI
import UIKit

/// The interactive collage on screen. Uses the same geometry as `ClgRenderer`, so what you see is what is saved.
struct ClgCanvasView: View {
    @ObservedObject var model: ClgModel
    let size: CGSize
    let onTap: (Int) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(model.backgroundColor)
            cells
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Collage"))
    }

    @ViewBuilder
    private var cells: some View {
        if let layout = model.layout, size.width > 2, size.height > 2 {
            let frames: [CGRect] = ClgRenderer.cellFrames(layout: layout, canvas: size, style: model.style)
            let count: Int = min(frames.count, model.photos.count)
            ForEach(0..<count, id: \.self) { index in
                cell(index: index, frame: frames[index])
            }
        }
    }

    private func cell(index: Int, frame: CGRect) -> some View {
        let photo = model.photos[index]
        let radius = ClgRenderer.cornerRadius(style: model.style, canvas: size, cell: frame)
        let selected = model.selectedCell == index
        let candidate = model.isSwapping && !selected
        return ClgCellView(
            image: photo.display,
            frame: frame,
            cornerRadius: radius,
            transform: transformBinding(index),
            isSelected: selected,
            isSwapCandidate: candidate,
            label: "Photo \(index + 1) of \(model.photos.count)",
            onTap: { onTap(index) }
        )
    }

    private func transformBinding(_ index: Int) -> Binding<ClgCellTransform> {
        let model = self.model
        return Binding<ClgCellTransform>(
            get: { model.transform(at: index) },
            set: { model.setTransform($0, at: index) }
        )
    }
}

/// One cell: the photo aspect-filled with its pan and zoom, clipped to the cell's rounded rectangle.
/// When selected, drag moves the photo and pinch zooms it (1x to 4x).
struct ClgCellView: View {
    let image: CGImage
    let frame: CGRect
    let cornerRadius: CGFloat
    @Binding var transform: ClgCellTransform
    let isSelected: Bool
    let isSwapCandidate: Bool
    let label: String
    let onTap: () -> Void

    @State private var dragStart: ClgCellTransform? = nil
    @State private var pinchStart: ClgCellTransform? = nil

    private var imageSize: CGSize { CGSize(width: image.width, height: image.height) }

    var body: some View {
        let local = CGRect(origin: .zero, size: frame.size)
        let drawRect = ClgRenderer.imageRect(imageSize: imageSize, cell: local, transform: transform)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
            .frame(width: drawRect.width, height: drawRect.height)
            .offset(x: drawRect.minX, y: drawRect.minY)
            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
            .clipShape(shape)
            .overlay(shape.strokeBorder(outlineColor, lineWidth: isSelected ? 2 : 1.5))
            .contentShape(shape)
            .onTapGesture(perform: onTap)
            .gesture(editGesture, including: isSelected ? .all : .subviews)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(label))
            .accessibilityValue(Text(isSelected ? "Selected, zoom \(zoomText)" : ""))
            .accessibilityHint(Text(isSelected ? "Drag to move the photo, pinch to zoom. Swipe up or down to change the zoom." : "Double tap to select."))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
            .accessibilityAction { onTap() }
            .accessibilityAdjustableAction { direction in
                var next = transform
                switch direction {
                case .increment: next.scale += 0.25
                case .decrement: next.scale -= 0.25
                @unknown default: break
                }
                transform = next.clamped()
            }
            .position(x: frame.midX, y: frame.midY)
    }

    private var zoomText: String {
        String(format: "%.1fx", Double(transform.scale))
    }

    private var outlineColor: Color {
        if isSelected { return AP.Palette.brass }
        if isSwapCandidate { return AP.Palette.brass.opacity(0.4) }
        return Color.clear
    }

    private var editGesture: some Gesture {
        let cellSize = frame.size
        let size = imageSize
        let drag = DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start: ClgCellTransform = dragStart ?? transform
                if dragStart == nil { dragStart = transform }
                transform = ClgRenderer.panned(start, by: value.translation, imageSize: size, cell: cellSize)
            }
            .onEnded { _ in
                dragStart = nil
            }
        let pinch = MagnifyGesture()
            .onChanged { value in
                let start: ClgCellTransform = pinchStart ?? transform
                if pinchStart == nil { pinchStart = transform }
                var next = start
                next.scale = start.scale * value.magnification
                transform = next.clamped()
            }
            .onEnded { _ in
                pinchStart = nil
            }
        return SimultaneousGesture(drag, pinch)
    }
}

/// A layout drawn as outlines, for the layout strip.
struct ClgLayoutThumb: View {
    let layout: CollageLayout
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ClgLayoutGlyph(rects: layout.rects, selected: selected)
                .frame(width: 40, height: 40)
                .padding(9)
                .background(
                    RoundedRectangle(cornerRadius: AP.Radius.chip, style: .continuous)
                        .fill(selected ? AP.Palette.graphite : AP.Palette.carbon)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AP.Radius.chip, style: .continuous)
                        .strokeBorder(selected ? AP.Palette.brass : AP.Palette.line, lineWidth: selected ? 1.5 : 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(layout.name) layout"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ClgLayoutGlyph: View {
    let rects: [CGRect]
    let selected: Bool

    var body: some View {
        GeometryReader { geo in
            let path = glyphPath(size: geo.size)
            ZStack {
                path.fill(selected ? AP.Palette.brass.opacity(0.18) : Color.clear)
                path.stroke(selected ? AP.Palette.brass : AP.Palette.mist, lineWidth: 1.2)
            }
        }
        .accessibilityHidden(true)
    }

    private func glyphPath(size: CGSize) -> Path {
        var path = Path()
        for r in rects {
            let cell = CGRect(
                x: r.minX * size.width,
                y: r.minY * size.height,
                width: r.width * size.width,
                height: r.height * size.height
            ).insetBy(dx: 1.5, dy: 1.5)
            if cell.width > 0, cell.height > 0 {
                path.addRoundedRect(in: cell, cornerSize: CGSize(width: 1.5, height: 1.5))
            }
        }
        return path
    }
}

/// A colour chip with a small swatch, sized like the app's chips but with a 44 pt tap target.
struct ClgSwatchChip: View {
    let title: String
    let color: Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(AP.Palette.paper.opacity(0.3), lineWidth: 1))
                Text(title).font(AP.Font.label).lineLimit(1)
            }
            .foregroundStyle(selected ? AP.Palette.onBrass : AP.Palette.paper)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(selected ? AP.Palette.brass : AP.Palette.graphite, in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Color.clear : AP.Palette.line, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(title) background"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Icon over a short word, used in the row of actions for the selected photo.
struct ClgActionLabel: View {
    let title: String
    let systemImage: String
    var active: Bool = false

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .regular))
            Text(title)
                .font(AP.Font.label)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(active ? AP.Palette.brass : AP.Palette.paper)
        .frame(maxWidth: .infinity, minHeight: 56)
        .contentShape(Rectangle())
    }
}
