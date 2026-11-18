import CoreGraphics

/// Blur, pixelate and smooth strokes are stored in the coordinates of the SOURCE picture (before turns, flips,
/// straightening, crop and frame), and the effect is applied to the source pixels first. That way a stroke always
/// lands on the same pixels, whatever crop, rotation or frame is chosen before or after it is painted.
///
/// The person paints on the finished picture (crop and frame applied), so this file turns a point on that picture
/// back into source coordinates. All values are fractions (0...1) measured from the top left. No Core Image here,
/// so it can be unit tested.
enum StrokeSpace {
    /// Where the cropped picture sits inside the framed canvas.
    struct FrameLayout: Equatable {
        /// Size of the finished picture, border included.
        let canvas: CGSize
        /// The cropped picture inside that canvas.
        let content: CGRect
    }

    /// The crop rectangle exactly as `EditPipeline` uses it: an empty or full rectangle means "no crop".
    static func effectiveCrop(_ rect: CGRect) -> CGRect {
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        let r = rect.intersection(full)
        guard !r.isNull, r.width > 0.001, r.height > 0.001 else { return full }
        return r
    }

    /// Size after quarter turns and straightening, before the crop rectangle (matches `EditPipeline.geometry`).
    static func geometrySize(source: CGSize, crop: CropState) -> CGSize {
        var w = source.width
        var h = source.height
        if (((crop.quarterTurns % 4) + 4) % 4) % 2 == 1 { swap(&w, &h) }
        if abs(crop.straighten) > 0.01 {
            let radians = CGFloat(crop.straighten) * .pi / 180
            let c = abs(cos(radians))
            let s = abs(sin(radians))
            let k = min(w / (w * c + h * s), h / (w * s + h * c))
            return CGSize(width: w * k, height: h * k)
        }
        return CGSize(width: w, height: h)
    }

    /// Canvas and picture position after the frame (fit to a ratio, border). Matches `EditPipeline.applyFrame`.
    static func frameLayout(content: CGSize, frame: FrameState) -> FrameLayout {
        var canvas = content
        if let aspect = frame.fit.aspect, content.width > 0, content.height > 0 {
            if content.width / content.height > aspect {
                canvas = CGSize(width: content.width, height: content.width / aspect)
            } else {
                canvas = CGSize(width: content.height * aspect, height: content.height)
            }
        }
        var inset: CGFloat = 0
        if frame.border > 0 {
            let side = min(canvas.width, canvas.height)
            let b = (side * CGFloat(frame.border) / 100).rounded()
            if b >= 1 { inset = b }
        }
        let outer = CGSize(width: canvas.width + 2 * inset, height: canvas.height + 2 * inset)
        let origin = CGPoint(x: inset + (canvas.width - content.width) / 2, y: inset + (canvas.height - content.height) / 2)
        return FrameLayout(canvas: outer, content: CGRect(origin: origin, size: content))
    }

    /// A point on the finished picture (fractions of crop + frame) as a point on the source picture (fractions).
    static func sourcePoint(_ point: CGPoint, source: CGSize, crop: CropState, frame: FrameState) -> CGPoint {
        let geometry = geometrySize(source: source, crop: crop)
        let rect = effectiveCrop(crop.rect)
        let content = CGSize(width: geometry.width * rect.width, height: geometry.height * rect.height)
        let layout = frameLayout(content: content, frame: frame)
        // Finished picture -> cropped picture.
        let cx = (point.x * layout.canvas.width - layout.content.minX) / max(1, layout.content.width)
        let cy = (point.y * layout.canvas.height - layout.content.minY) / max(1, layout.content.height)
        // Cropped picture -> picture after turns and straightening.
        let geometryPoint = CGPoint(x: rect.minX + cx * rect.width, y: rect.minY + cy * rect.height)
        return undoGeometry(geometryPoint, source: source, crop: crop)
    }

    /// A brush width given as a fraction of the shorter side of the finished picture, as a fraction of the shorter
    /// side of the source picture. Crop, turns and frame never rescale pixels, so only the two sides differ.
    static func sourceWidth(_ width: Double, source: CGSize, crop: CropState, frame: FrameState) -> Double {
        let geometry = geometrySize(source: source, crop: crop)
        let rect = effectiveCrop(crop.rect)
        let content = CGSize(width: geometry.width * rect.width, height: geometry.height * rect.height)
        let layout = frameLayout(content: content, frame: frame)
        let finishedSide = min(layout.canvas.width, layout.canvas.height)
        let sourceSide = max(1, min(source.width, source.height))
        return width * Double(finishedSide / sourceSide)
    }

    /// Inverse of flips, quarter turns and straightening, applied in the reverse order of `EditPipeline.geometry`.
    static func undoGeometry(_ geometryPoint: CGPoint, source: CGSize, crop: CropState) -> CGPoint {
        var point = geometryPoint
        let turns = ((crop.quarterTurns % 4) + 4) % 4
        var turnedW = source.width
        var turnedH = source.height
        if turns % 2 == 1 { swap(&turnedW, &turnedH) }

        if abs(crop.straighten) > 0.01 {
            let radians = CGFloat(crop.straighten) * .pi / 180
            let c = abs(cos(radians))
            let s = abs(sin(radians))
            let k = min(turnedW / (turnedW * c + turnedH * s), turnedH / (turnedW * s + turnedH * c))
            let dx = (point.x - 0.5) * turnedW * k
            let dy = (point.y - 0.5) * turnedH * k
            // The picture was turned clockwise by `radians`, so turn the point back the other way.
            let rx = dx * cos(radians) + dy * sin(radians)
            let ry = -dx * sin(radians) + dy * cos(radians)
            point = CGPoint(x: 0.5 + rx / turnedW, y: 0.5 + ry / turnedH)
        }

        // One quarter turn clockwise sends (u, v) to (1 - v, u), so undo it with (a, b) -> (b, 1 - a).
        for _ in 0..<turns {
            point = CGPoint(x: point.y, y: 1 - point.x)
        }
        if crop.flipV { point.y = 1 - point.y }
        if crop.flipH { point.x = 1 - point.x }
        return point
    }
}
