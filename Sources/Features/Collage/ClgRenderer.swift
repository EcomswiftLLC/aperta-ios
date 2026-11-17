import SwiftUI
import UIKit
import CoreGraphics

/// Pan and zoom of one photo inside its cell, stored independent of resolution so the screen and the file match.
/// `scale` 1 means aspect fill; `offsetX`/`offsetY` run from -1 to 1 as a fraction of how far the photo can move.
struct ClgCellTransform: Equatable, Sendable {
    var scale: CGFloat = 1
    var offsetX: CGFloat = 0
    var offsetY: CGFloat = 0

    static let minScale: CGFloat = 1
    static let maxScale: CGFloat = 4

    func clamped() -> ClgCellTransform {
        var next = self
        next.scale = min(ClgCellTransform.maxScale, max(ClgCellTransform.minScale, scale))
        next.offsetX = min(1, max(-1, offsetX))
        next.offsetY = min(1, max(-1, offsetY))
        return next
    }
}

/// Style values as the sliders show them. Lengths are in units of 1/600 of the canvas short side,
/// so the same numbers look the same on screen and in the 2160 px file.
struct ClgStyle: Equatable, Sendable {
    var spacing: Double = 8
    var cornerRadius: Double = 0
    var margin: Double = 0

    static let referenceUnits: CGFloat = 600
}

/// Everything a render needs, copied off the main actor.
struct ClgRenderJob: @unchecked Sendable {
    let layout: CollageLayout
    /// One image per cell, in cell order.
    let images: [CGImage?]
    let transforms: [ClgCellTransform]
    let style: ClgStyle
    /// Width divided by height.
    let aspect: CGFloat
    let longSide: CGFloat
    let background: UIColor
}

enum ClgRenderer {
    // MARK: Geometry shared by the screen and the file

    static func canvasSize(aspect: CGFloat, longSide: CGFloat) -> CGSize {
        let ratio = max(0.1, aspect)
        if ratio >= 1 {
            return CGSize(width: longSide.rounded(), height: max(1, (longSide / ratio).rounded()))
        }
        return CGSize(width: max(1, (longSide * ratio).rounded()), height: longSide.rounded())
    }

    static func unit(for canvas: CGSize) -> CGFloat {
        min(canvas.width, canvas.height) / ClgStyle.referenceUnits
    }

    /// Cell frames on a canvas of `canvas` size: the margin is taken off the outside, then half the spacing
    /// is taken off every inner edge, so every gap between cells equals the spacing.
    static func cellFrames(layout: CollageLayout, canvas: CGSize, style: ClgStyle) -> [CGRect] {
        let u = unit(for: canvas)
        let margin = CGFloat(style.margin) * u
        let half = CGFloat(style.spacing) * u / 2
        let inner = CGRect(origin: .zero, size: canvas).insetBy(dx: margin, dy: margin)
        guard inner.width > 1, inner.height > 1 else {
            return layout.rects.map { _ in CGRect.zero }
        }
        let edge: CGFloat = 0.000_1
        return layout.rects.map { r -> CGRect in
            let left: CGFloat = r.minX <= edge ? 0 : half
            let right: CGFloat = r.maxX >= 1 - edge ? 0 : half
            let top: CGFloat = r.minY <= edge ? 0 : half
            let bottom: CGFloat = r.maxY >= 1 - edge ? 0 : half
            let x = inner.minX + r.minX * inner.width + left
            let y = inner.minY + r.minY * inner.height + top
            let w = r.width * inner.width - left - right
            let h = r.height * inner.height - top - bottom
            return CGRect(x: x, y: y, width: max(0, w), height: max(0, h))
        }
    }

    static func cornerRadius(style: ClgStyle, canvas: CGSize, cell: CGRect) -> CGFloat {
        let wanted = CGFloat(style.cornerRadius) * unit(for: canvas)
        return max(0, min(wanted, min(cell.width, cell.height) / 2))
    }

    /// The size of the photo when it fills `cell` at the transform's zoom.
    static func filledSize(imageSize: CGSize, cell: CGSize, scale: CGFloat) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return cell }
        let fill = max(cell.width / imageSize.width, cell.height / imageSize.height) * max(1, scale)
        return CGSize(width: imageSize.width * fill, height: imageSize.height * fill)
    }

    /// Where the photo is drawn so it fills `cell` with the cell's pan and zoom.
    static func imageRect(imageSize: CGSize, cell: CGRect, transform: ClgCellTransform) -> CGRect {
        let t = transform.clamped()
        let size = filledSize(imageSize: imageSize, cell: cell.size, scale: t.scale)
        let slackX = max(0, (size.width - cell.width) / 2)
        let slackY = max(0, (size.height - cell.height) / 2)
        let x = cell.midX - size.width / 2 + t.offsetX * slackX
        let y = cell.midY - size.height / 2 + t.offsetY * slackY
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Applies a drag (in the same units as `cell`) to a starting transform.
    static func panned(_ start: ClgCellTransform, by translation: CGSize, imageSize: CGSize, cell: CGSize) -> ClgCellTransform {
        let size = filledSize(imageSize: imageSize, cell: cell, scale: start.scale)
        let slackX = max(0, (size.width - cell.width) / 2)
        let slackY = max(0, (size.height - cell.height) / 2)
        var next = start
        next.offsetX = slackX > 0.5 ? start.offsetX + translation.width / slackX : 0
        next.offsetY = slackY > 0.5 ? start.offsetY + translation.height / slackY : 0
        return next.clamped()
    }

    // MARK: Rendering

    /// Draws the collage. Pure: same input, same pixels. Safe to call off the main thread.
    static func render(_ job: ClgRenderJob) -> CGImage? {
        let canvas = canvasSize(aspect: job.aspect, longSide: job.longSide)
        guard canvas.width >= 1, canvas.height >= 1 else { return nil }
        let frames = cellFrames(layout: job.layout, canvas: canvas, style: job.style)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: canvas, format: format)

        let image: UIImage = renderer.image { context in
            let cg = context.cgContext
            cg.interpolationQuality = .high
            job.background.setFill()
            context.fill(CGRect(origin: .zero, size: canvas))

            for (index, frame) in frames.enumerated() {
                guard frame.width >= 1, frame.height >= 1 else { continue }
                let radius = cornerRadius(style: job.style, canvas: canvas, cell: frame)
                let clip = UIBezierPath(roundedRect: frame, cornerRadius: radius)
                cg.saveGState()
                clip.addClip()
                let photo: CGImage? = index < job.images.count ? job.images[index] : nil
                if let photo {
                    let transform = index < job.transforms.count ? job.transforms[index] : ClgCellTransform()
                    let size = CGSize(width: photo.width, height: photo.height)
                    let rect = imageRect(imageSize: size, cell: frame, transform: transform)
                    UIImage(cgImage: photo).draw(in: rect)
                } else {
                    UIColor(white: 0.12, alpha: 1).setFill()
                    clip.fill()
                }
                cg.restoreGState()
            }
        }
        return image.cgImage
    }
}
