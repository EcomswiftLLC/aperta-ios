import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers
import Photos
import PhotosUI

// MARK: - Formats

enum OutputFormat: String, CaseIterable, Identifiable {
    case jpeg, png, heic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jpeg: return "JPG"
        case .png: return "PNG"
        case .heic: return "HEIC"
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .heic: return "heic"
        }
    }

    var utType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        case .heic: return .heic
        }
    }

    /// PNG is lossless, so a quality value does nothing for it.
    var usesQuality: Bool { self != .png }

    /// HEIC encoding is available on every supported device, but the check keeps the picker honest.
    static var available: [OutputFormat] {
        let supported = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return allCases.filter { supported.contains($0.utType.identifier) }
    }
}

// MARK: - A photo that has been read from the library

struct LoadedPhoto: Identifiable {
    let id = UUID()
    /// Upright pixels (EXIF orientation already applied), capped to the size the caller asked for.
    let image: CGImage
    /// The bytes the person picked, untouched.
    let originalData: Data
    /// Metadata dictionary of the original file (EXIF, GPS, TIFF ...).
    let properties: [String: Any]
    let name: String

    var originalBytes: Int { originalData.count }
    var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }
    var uiImage: UIImage { UIImage(cgImage: image) }
}

enum PhotoLoader {
    /// Reads a picked item. Returns nil if the data cannot be decoded as an image.
    static func load(_ item: PhotosPickerItem, maxPixel: Int = 4096, name: String? = nil) async -> LoadedPhoto? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        return load(data: data, maxPixel: maxPixel, name: name ?? "Photo")
    }

    static func load(data: Data, maxPixel: Int = 4096, name: String = "Photo") -> LoadedPhoto? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
        return LoadedPhoto(image: image, originalData: data, properties: props, name: name)
    }
}

/// Holds the photos a tool is working on and loads picker items in the background.
@MainActor
final class PhotoSelection: ObservableObject {
    @Published var photos: [LoadedPhoto] = []
    @Published var isLoading = false
    @Published var failedCount = 0

    func load(_ items: [PhotosPickerItem], maxPixel: Int = 4096, append: Bool = false) async {
        guard !items.isEmpty else { return }
        isLoading = true
        failedCount = 0
        var result: [LoadedPhoto] = append ? photos : []
        for (index, item) in items.enumerated() {
            if let photo = await PhotoLoader.load(item, maxPixel: maxPixel, name: "Photo \(result.count + 1)") {
                result.append(photo)
            } else {
                failedCount += 1
            }
            _ = index
        }
        photos = result
        isLoading = false
    }

    func remove(_ id: UUID) { photos.removeAll { $0.id == id } }
    func clear() { photos = []; failedCount = 0 }
}

// MARK: - Encoding and resizing

enum ImageCodec {
    /// Encodes pixels as a file. `properties` are copied into the file (without orientation, because pixels are already upright).
    static func encode(
        _ image: CGImage,
        format: OutputFormat,
        quality: Double = 0.9,
        properties: [String: Any]? = nil
    ) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.utType.identifier as CFString, 1, nil) else {
            return nil
        }
        var options: [CFString: Any] = [:]
        if let properties {
            for (key, value) in sanitized(properties) { options[key as CFString] = value }
        }
        if format.usesQuality {
            options[kCGImageDestinationLossyCompressionQuality] = min(1, max(0.01, quality))
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Removes keys that no longer describe the exported pixels.
    static func sanitized(_ properties: [String: Any]) -> [String: Any] {
        var result = properties
        for key in [
            kCGImagePropertyOrientation as String,
            kCGImagePropertyPixelWidth as String,
            kCGImagePropertyPixelHeight as String,
            kCGImagePropertyDepth as String,
            kCGImagePropertyHasAlpha as String,
            kCGImagePropertyColorModel as String,
            kCGImagePropertyProfileName as String,
        ] {
            result.removeValue(forKey: key)
        }
        for dictionaryKey in [kCGImagePropertyTIFFDictionary as String, kCGImagePropertyExifDictionary as String] {
            if var inner = result[dictionaryKey] as? [String: Any] {
                inner.removeValue(forKey: kCGImagePropertyTIFFOrientation as String)
                inner.removeValue(forKey: kCGImagePropertyExifPixelXDimension as String)
                inner.removeValue(forKey: kCGImagePropertyExifPixelYDimension as String)
                result[dictionaryKey] = inner
            }
        }
        return result
    }

    /// Metadata with everything that identifies a person or place removed (GPS, device serial, owner names).
    static func privacySafe(_ properties: [String: Any]) -> [String: Any] {
        var result = sanitized(properties)
        result.removeValue(forKey: kCGImagePropertyGPSDictionary as String)
        result.removeValue(forKey: kCGImagePropertyMakerAppleDictionary as String)
        result.removeValue(forKey: kCGImagePropertyIPTCDictionary as String)
        if var exif = result[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            for key in [
                kCGImagePropertyExifBodySerialNumber, kCGImagePropertyExifLensSerialNumber,
                kCGImagePropertyExifCameraOwnerName, kCGImagePropertyExifUserComment,
            ] { exif.removeValue(forKey: key as String) }
            result[kCGImagePropertyExifDictionary as String] = exif
        }
        if var tiff = result[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff.removeValue(forKey: kCGImagePropertyTIFFArtist as String)
            tiff.removeValue(forKey: kCGImagePropertyTIFFHostComputer as String)
            result[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        return result
    }

    static func scaled(_ image: CGImage, to size: CGSize) -> CGImage? {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        if width == image.width && height == image.height { return image }
        var space = CGColorSpace(name: CGColorSpace.sRGB)!
        if let own = image.colorSpace, own.model == .rgb, own.supportsOutput { space = own }
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
            ?? CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info
            )
        guard let ctx = context else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// Scales so the longer side is at most `maxPixel`. Never enlarges.
    static func scaled(_ image: CGImage, maxPixel: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > maxPixel, maxPixel > 0 else { return image }
        let ratio = CGFloat(maxPixel) / CGFloat(longest)
        return scaled(image, to: CGSize(width: CGFloat(image.width) * ratio, height: CGFloat(image.height) * ratio))
    }

    /// Finds the best JPEG or HEIC quality whose file is at most `targetBytes`. If even the lowest quality is too large,
    /// the image is scaled down in steps until it fits. Returns the data and the pixel size that was used.
    static func encode(
        _ image: CGImage,
        format: OutputFormat,
        targetBytes: Int,
        properties: [String: Any]? = nil
    ) -> (data: Data, size: CGSize)? {
        guard format.usesQuality else {
            return encode(image, format: format, properties: properties).map { ($0, CGSize(width: image.width, height: image.height)) }
        }
        var current = image
        for _ in 0..<8 {
            var low = 0.05, high = 0.95
            var best: Data?
            for _ in 0..<7 {
                let mid = (low + high) / 2
                guard let data = encode(current, format: format, quality: mid, properties: properties) else { return nil }
                if data.count <= targetBytes { best = data; low = mid } else { high = mid }
            }
            if let best { return (best, CGSize(width: current.width, height: current.height)) }
            guard let smaller = scaled(
                current,
                to: CGSize(width: CGFloat(current.width) * 0.8, height: CGFloat(current.height) * 0.8)
            ), smaller.width > 64 else { break }
            current = smaller
        }
        guard let data = encode(current, format: format, quality: 0.05, properties: properties) else { return nil }
        return (data, CGSize(width: current.width, height: current.height))
    }
}

// MARK: - Sizes for display

enum ByteText {
    static func string(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - Output files

struct ExportItem: Identifiable {
    let id = UUID()
    let data: Data
    let filename: String
    let format: OutputFormat

    var contentType: UTType { format.utType }

    /// Writes the file to the temporary folder so it can be shared.
    func temporaryURL() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    static func uniqueName(_ base: String, format: OutputFormat) -> String {
        let stamp = Int(Date().timeIntervalSince1970 * 1000) % 100_000_000
        return "\(base)-\(stamp).\(format.fileExtension)"
    }
}

enum LibrarySaver {
    enum SaveError: Error { case denied, failed }

    /// Adds the files to the photo library. Needs the "add only" permission, which the system asks for once.
    static func save(_ items: [ExportItem]) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.denied }
        try await PHPhotoLibrary.shared().performChanges {
            for item in items {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = item.format.utType.identifier
                request.addResource(with: .photo, data: item.data, options: options)
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    /// Called when the share sheet ends. `true` only when a destination really finished (shared, saved, copied).
    var onFinish: ((Bool) -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        let finish = onFinish
        controller.completionWithItemsHandler = { _, completed, _, _ in
            finish?(completed)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
