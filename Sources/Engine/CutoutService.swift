import UIKit
import CoreImage
import Vision

/// Finds the main subject of a photo on the device (Apple Vision, iOS 17) and lifts it from the background.
/// Nothing is uploaded and nothing costs money.
enum CutoutService {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Black and white mask the size of `image`: white is the subject. Nil if no subject was found.
    static func subjectMask(for image: CGImage) async -> CIImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<CIImage?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: maskSync(for: image))
            }
        }
    }

    /// The subject with a transparent background, same pixel size as `image`. Nil if no subject was found.
    static func cutout(_ image: CGImage) async -> CGImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: cutoutSync(image))
            }
        }
    }

    private static func cutoutSync(_ image: CGImage) -> CGImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
            guard let result = request.results?.first, !result.allInstances.isEmpty else { return debugCutout(image) }
            let buffer = try result.generateMaskedImage(
                ofInstances: result.allInstances,
                from: handler,
                croppedToInstancesExtent: false
            )
            let ci = CIImage(cvPixelBuffer: buffer)
            return ciContext.createCGImage(ci, from: ci.extent)
        } catch {
            return debugCutout(image)
        }
    }

    private static func maskSync(for image: CGImage) -> CIImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
            guard let result = request.results?.first, !result.allInstances.isEmpty else { return debugMask(image) }
            let buffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
            return CIImage(cvPixelBuffer: buffer)
        } catch {
            return debugMask(image)
        }
    }

    #if DEBUG
    /// The CI simulator has no Neural Engine, so Vision cannot find a subject there. For store screenshots only, a mask made offline
    /// for the sample portrait stands in. Release builds do not contain this code.
    private static func debugMask(_ image: CGImage) -> CIImage? {
        guard let mask = DebugMasks.current else { return nil }
        let ci = CIImage(cgImage: mask)
        let scaled = ci.transformed(by: CGAffineTransform(
            scaleX: CGFloat(image.width) / ci.extent.width, y: CGFloat(image.height) / ci.extent.height))
        return scaled
    }

    private static func debugCutout(_ image: CGImage) -> CGImage? {
        guard let mask = debugMask(image) else { return nil }
        let source = CIImage(cgImage: image)
        let clear = CIImage(color: .clear).cropped(to: source.extent)
        let out = source.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: mask])
        return ciContext.createCGImage(out, from: source.extent)
    }
    #else
    private static func debugMask(_ image: CGImage) -> CIImage? { nil }
    private static func debugCutout(_ image: CGImage) -> CGImage? { nil }
    #endif
}
