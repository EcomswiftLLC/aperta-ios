import CoreImage
import UIKit

/// Turns the original picture plus an `EditState` into pixels, with Core Image.
/// The same code runs for the small on-screen preview and for the full-size export, so they always match.
/// Everything that is drawn on top (text, stickers, pen strokes) is handled by SwiftUI, see `OverlayLayer`.
final class EditPipeline {
    static let shared = EditPipeline()

    let context: CIContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// Result of geometry: the picture after turns, flips and straightening, before the crop rectangle.
    struct Geometry {
        let image: CIImage
        let size: CGSize
    }

    // MARK: Main entry

    /// - Parameters:
    ///   - source: the picture, extent origin (0,0).
    ///   - mask: subject mask (white = subject) of the same pixel size as `source`, if a cut-out was made.
    ///   - applyCrop: false while the crop tool is open, so the whole picture is visible.
    func render(source: CIImage, mask: CIImage?, state: EditState, applyCrop: Bool = true) -> CIImage {
        var image = composeBackground(source: source, mask: mask, background: state.background)
        image = geometry(image, crop: state.crop).image
        if applyCrop { image = cropped(image, rect: state.crop.rect) }
        image = adjust(image, state: state)
        image = FilterLibrary.apply(state.filter, to: image, intensity: state.filterIntensity)
        image = applyLocalEffects(image, state: state)
        if applyCrop { image = applyFrame(image, frame: state.frame) }
        return image
    }

    func cgImage(_ image: CIImage) -> CGImage? {
        let extent = image.extent.integral
        guard extent.width >= 1, extent.height >= 1 else { return nil }
        return context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: colorSpace)
    }

    // MARK: Cut-out background

    private func composeBackground(source: CIImage, mask: CIImage?, background: BackgroundState) -> CIImage {
        guard let mask, background.mode != .original else { return source }
        let extent = source.extent
        let backdrop: CIImage
        switch background.mode {
        case .original:
            return source
        case .transparent:
            backdrop = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
        case .color:
            backdrop = CIImage(color: CIColor(color: UIColor(hex: background.colorHex))).cropped(to: extent)
        case .blur:
            let sigma = max(extent.width, extent.height) * 0.02
            backdrop = source.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sigma])
                .cropped(to: extent)
        case .mono:
            backdrop = source.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.0, kCIInputBrightnessKey: -0.08, kCIInputContrastKey: 1.05,
            ])
        }
        var fitted = mask
        if abs(mask.extent.width - extent.width) > 0.5 || abs(mask.extent.height - extent.height) > 0.5 {
            let sx = extent.width / mask.extent.width
            let sy = extent.height / mask.extent.height
            fitted = mask.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        }
        return source.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: backdrop,
            kCIInputMaskImageKey: fitted,
        ]).cropped(to: extent)
    }

    // MARK: Geometry

    func geometry(_ input: CIImage, crop: CropState) -> Geometry {
        var image = input
        let w0 = input.extent.width
        let h0 = input.extent.height

        if crop.flipH {
            image = image.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w0, ty: 0))
        }
        if crop.flipV {
            image = image.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h0))
        }
        let turns = ((crop.quarterTurns % 4) + 4) % 4
        if turns != 0 {
            image = image.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(turns) * .pi / 2))
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        }
        if abs(crop.straighten) > 0.01 {
            let w = image.extent.width
            let h = image.extent.height
            let radians = CGFloat(crop.straighten) * .pi / 180
            let c = abs(cos(radians))
            let s = abs(sin(radians))
            let k = min(w / (w * c + h * s), h / (w * s + h * c))
            let centre = CGPoint(x: w / 2, y: h / 2)
            var transform = CGAffineTransform(translationX: -centre.x, y: -centre.y)
            transform = transform.concatenating(CGAffineTransform(rotationAngle: -radians))
            transform = transform.concatenating(CGAffineTransform(translationX: centre.x, y: centre.y))
            image = image.transformed(by: transform)
            let box = CGRect(x: centre.x - w * k / 2, y: centre.y - h * k / 2, width: w * k, height: h * k)
            image = image.cropped(to: box)
            image = image.transformed(by: CGAffineTransform(translationX: -box.minX, y: -box.minY))
        }
        return Geometry(image: image, size: image.extent.size)
    }

    private func cropped(_ image: CIImage, rect unit: CGRect) -> CIImage {
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        let r = unit.intersection(full)
        guard r.width > 0.001, r.height > 0.001, r != full else { return image }
        let size = image.extent.size
        let box = CGRect(
            x: r.minX * size.width,
            y: (1 - r.maxY) * size.height,
            width: r.width * size.width,
            height: r.height * size.height
        ).integral
        let out = image.cropped(to: box)
        return out.transformed(by: CGAffineTransform(translationX: -box.minX, y: -box.minY))
    }

    // MARK: Adjustments

    private func adjust(_ input: CIImage, state: EditState) -> CIImage {
        var image = input
        let extent = input.extent
        let minSide = min(extent.width, extent.height)

        if state.autoEnhance {
            for filter in input.autoAdjustmentFilters(options: [.redEye: false]) {
                filter.setValue(image, forKey: kCIInputImageKey)
                if let out = filter.outputImage { image = out }
            }
        }

        let a = state.adjust
        if a.isIdentity { return image.cropped(to: extent) }

        if a.exposure != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: a.exposure / 100 * 2.0])
        }
        if a.brightness != 0 || a.contrast != 0 || a.saturation != 0 {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: a.brightness / 100 * 0.25,
                kCIInputContrastKey: 1 + a.contrast / 100 * 0.45,
                kCIInputSaturationKey: 1 + a.saturation / 100,
            ])
        }
        if a.highlights != 0 || a.shadows != 0 {
            let highlightAmount = a.highlights < 0 ? 1 + a.highlights / 100 * 0.85 : 1
            image = image.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": highlightAmount,
                "inputShadowAmount": a.shadows / 100,
                kCIInputRadiusKey: 0.0,
            ])
            if a.highlights > 0 {
                let lift = a.highlights / 100 * 0.08
                image = image.applyingFilter("CIToneCurve", parameters: [
                    "inputPoint0": CIVector(x: 0, y: 0),
                    "inputPoint1": CIVector(x: 0.25, y: 0.25),
                    "inputPoint2": CIVector(x: 0.5, y: 0.5 + lift * 0.3),
                    "inputPoint3": CIVector(x: 0.75, y: 0.75 + lift),
                    "inputPoint4": CIVector(x: 1, y: 1),
                ])
            }
        }
        if a.warmth != 0 || a.tint != 0 {
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: CGFloat(6500 + a.warmth / 100 * 2600), y: CGFloat(a.tint / 100 * -70)),
                "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ])
        }
        if a.fade > 0 {
            let f = CGFloat(a.fade / 100)
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1 - 0.16 * f, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1 - 0.16 * f, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1 - 0.16 * f, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 0.13 * f, y: 0.13 * f, z: 0.13 * f, w: 0),
            ])
        }
        if a.clarity > 0 {
            image = image.applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: minSide * 0.012,
                kCIInputIntensityKey: a.clarity / 100 * 0.9,
            ])
        }
        if a.sharpness > 0 {
            image = image.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: a.sharpness / 100 * 1.6,
                kCIInputRadiusKey: max(1.2, minSide / 1400),
            ])
        }
        if a.grain > 0 {
            image = addGrain(image, amount: a.grain / 100, extent: extent)
        }
        if a.vignette > 0 {
            image = FilterLibrary.vignette(image, amount: a.vignette / 100)
        }
        return image.cropped(to: extent)
    }

    private func addGrain(_ image: CIImage, amount: Double, extent: CGRect) -> CIImage {
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }
        let scale = max(1, min(extent.width, extent.height) / 900)
        let grainy = noise
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
                "inputGVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
                "inputBVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(amount * 0.55)),
            ])
            .cropped(to: extent)
        return grainy.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: image])
            .cropped(to: extent)
    }

    // MARK: Local blur, pixelate and smooth

    private func applyLocalEffects(_ input: CIImage, state: EditState) -> CIImage {
        guard !state.blurs.isEmpty else { return input }
        var image = input
        let extent = input.extent
        let minSide = min(extent.width, extent.height)
        for mode in BlurMode.allCases {
            let strokes = state.blurs.filter { $0.mode == mode }
            guard !strokes.isEmpty, let mask = maskImage(strokes: strokes, size: extent.size) else { continue }
            let strength = state.blurStrength / 100
            let effect: CIImage
            switch mode {
            case .blur:
                effect = image.clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: minSide * (0.004 + 0.03 * strength)])
                    .cropped(to: extent)
            case .smooth:
                effect = image.clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: minSide * (0.002 + 0.008 * strength)])
                    .cropped(to: extent)
            case .pixelate:
                effect = image.applyingFilter("CIPixellate", parameters: [
                    kCIInputCenterKey: CIVector(x: 0, y: 0),
                    kCIInputScaleKey: max(4, minSide * (0.006 + 0.03 * strength)),
                ]).cropped(to: extent)
            }
            image = effect.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: image,
                kCIInputMaskImageKey: mask,
            ]).cropped(to: extent)
        }
        return image
    }

    private func maskImage(strokes: [BlurStroke], size: CGSize) -> CIImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let minSide = min(size.width, size.height)
        let image = renderer.image { rendererContext in
            let cg = rendererContext.cgContext
            cg.setFillColor(UIColor.black.cgColor)
            cg.fill(CGRect(origin: .zero, size: size))
            cg.setStrokeColor(UIColor.white.cgColor)
            cg.setFillColor(UIColor.white.cgColor)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            for stroke in strokes {
                let lineWidth = max(2, CGFloat(stroke.width) * minSide)
                cg.setLineWidth(lineWidth)
                let points = stroke.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
                guard let first = points.first else { continue }
                if points.count == 1 {
                    cg.fillEllipse(in: CGRect(x: first.x - lineWidth / 2, y: first.y - lineWidth / 2, width: lineWidth, height: lineWidth))
                } else {
                    cg.beginPath()
                    cg.move(to: first)
                    for p in points.dropFirst() { cg.addLine(to: p) }
                    cg.strokePath()
                }
            }
        }
        guard let cg = image.cgImage else { return nil }
        // The mask was drawn top-down in UIKit space; CIImage(cgImage:) keeps the same visual orientation.
        return CIImage(cgImage: cg)
    }

    // MARK: Frame (fit to a ratio, border)

    private func applyFrame(_ input: CIImage, frame: FrameState) -> CIImage {
        if frame.isIdentity { return input }
        var image = input
        let w = image.extent.width
        let h = image.extent.height

        if let aspect = frame.fit.aspect {
            let canvas: CGSize
            if w / h > aspect { canvas = CGSize(width: w, height: w / aspect) } else { canvas = CGSize(width: h * aspect, height: h) }
            let canvasRect = CGRect(origin: .zero, size: canvas)
            let backdrop: CIImage
            if frame.blurFill {
                let cover = max(canvas.width / w, canvas.height / h)
                let scaled = image.transformed(by: CGAffineTransform(scaleX: cover, y: cover))
                let dx = (canvas.width - scaled.extent.width) / 2 - scaled.extent.minX
                let dy = (canvas.height - scaled.extent.height) / 2 - scaled.extent.minY
                let moved = scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
                backdrop = moved.clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(canvas.width, canvas.height) * 0.025])
                    .cropped(to: canvasRect)
            } else {
                backdrop = CIImage(color: CIColor(color: UIColor(hex: frame.fillHex))).cropped(to: canvasRect)
            }
            let placed = image.transformed(by: CGAffineTransform(
                translationX: (canvas.width - w) / 2 - image.extent.minX,
                y: (canvas.height - h) / 2 - image.extent.minY
            ))
            image = placed.composited(over: backdrop).cropped(to: canvasRect)
        }

        if frame.border > 0 {
            let side = min(image.extent.width, image.extent.height)
            let b = (side * frame.border / 100).rounded()
            if b >= 1 {
                let outer = CGRect(x: 0, y: 0, width: image.extent.width + 2 * b, height: image.extent.height + 2 * b)
                let colour = CIImage(color: CIColor(color: UIColor(hex: frame.borderHex))).cropped(to: outer)
                let moved = image.transformed(by: CGAffineTransform(translationX: b - image.extent.minX, y: b - image.extent.minY))
                image = moved.composited(over: colour).cropped(to: outer)
            }
        }
        return image
    }
}
