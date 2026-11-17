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
            guard let result = request.results?.first, !result.allInstances.isEmpty else { return nil }
            let buffer = try result.generateMaskedImage(
                ofInstances: result.allInstances,
                from: handler,
                croppedToInstancesExtent: false
            )
            let ci = CIImage(cvPixelBuffer: buffer)
            return ciContext.createCGImage(ci, from: ci.extent)
        } catch {
            return nil
        }
    }

    private static func maskSync(for image: CGImage) -> CIImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
            guard let result = request.results?.first, !result.allInstances.isEmpty else { return nil }
            let buffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
            return CIImage(cvPixelBuffer: buffer)
        } catch {
            return nil
        }
    }
}
