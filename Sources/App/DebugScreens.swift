#if DEBUG
import SwiftUI
import UIKit
import ImageIO

/// Debug builds can open a given screen directly, with a generated sample photo, so CI can take screenshots
/// of every screen without tapping through the app: `xcrun simctl launch <device> com.ecomswift.aperta -apScreen home`.
enum DebugScreens {
    static var requested: String? {
        guard let value = UserDefaults.standard.string(forKey: "apScreen"), !value.isEmpty else { return nil }
        return value
    }

    @ViewBuilder
    static func view(for requested: String) -> some View {
        let filled = requested.hasSuffix("-filled")
        let screen = filled ? String(requested.dropLast("-filled".count)) : requested
        let _ = { DebugSamples.enabled = filled }()
        switch screen {
        case "home": HomeView()
        case "onboarding": OnboardingView().environmentObject(AppState())
        case "settings": SettingsView()
        case "editor-adjust": EditorView(photo: SamplePhoto.make(), startTool: .adjust)
        case "editor-filters": EditorView(photo: SamplePhoto.make(), startTool: .filters)
        case "editor-crop": EditorView(photo: SamplePhoto.make(), startTool: .crop)
        case "editor-text": EditorView(photo: SamplePhoto.make(), startTool: .text)
        case "editor-draw": EditorView(photo: SamplePhoto.make(), startTool: .draw)
        case "editor-cutout": EditorView(photo: SamplePhoto.make(), startTool: .cutout)
        case "collage": NavigationStack { CollageView() }
        case "compress": NavigationStack { CompressView() }
        case "resize": NavigationStack { ResizeView() }
        case "convert": NavigationStack { ConvertView() }
        case "watermark": NavigationStack { WatermarkView() }
        case "passport": NavigationStack { PassportView() }
        case "metadata": NavigationStack { MetadataView() }
        default: HomeView()
        }
    }
}

/// A generated landscape used only for development screenshots.
enum SamplePhoto {
    static func make(variant: Int = 0) -> LoadedPhoto {
        let sizes: [CGSize] = [CGSize(width: 1600, height: 1200), CGSize(width: 1200, height: 1600), CGSize(width: 2400, height: 1600), CGSize(width: 1600, height: 1600)]
        let skies: [[UInt32]] = [[0x1F2A44, 0xC76B5A, 0xF3C58A], [0x0F2B3D, 0x2F8F9D, 0xBDE7D8], [0x2B1B3D, 0xD9567A, 0xFFC38B], [0x1E3A2B, 0x6FA66B, 0xF4E9A8]]
        let size = sizes[variant % sizes.count]
        let sky0 = skies[variant % skies.count]
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let sky = CGGradient(colorsSpace: space, colors: [
                UIColor(hex: sky0[0]).cgColor, UIColor(hex: sky0[1]).cgColor, UIColor(hex: sky0[2]).cgColor,
            ] as CFArray, locations: [0, 0.62, 1])!
            cg.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: size.height * 0.72), options: [])
            let sun = CGGradient(colorsSpace: space, colors: [
                UIColor(hex: 0xFFF1CF, alpha: 1).cgColor, UIColor(hex: 0xFFD18A, alpha: 0).cgColor,
            ] as CFArray, locations: [0, 1])!
            cg.drawRadialGradient(sun, startCenter: CGPoint(x: 1000, y: 760), startRadius: 0, endCenter: CGPoint(x: 1000, y: 760), endRadius: 460, options: [])
            let layers: [(UInt32, CGFloat, CGFloat)] = [(0x5B4A6B, 760, 90), (0x3A3552, 860, 120), (0x1D2233, 980, 160), (0x0F131C, 1090, 90)]
            for (hex, base, amp) in layers {
                cg.setFillColor(UIColor(hex: hex).cgColor)
                cg.beginPath()
                cg.move(to: CGPoint(x: 0, y: size.height))
                var x: CGFloat = 0
                while x <= size.width {
                    let y = base - amp * (0.5 + 0.5 * sin(x / 210 + base)) - amp * 0.3 * sin(x / 77)
                    cg.addLine(to: CGPoint(x: x, y: y))
                    x += 8
                }
                cg.addLine(to: CGPoint(x: size.width, y: size.height))
                cg.closePath()
                cg.fillPath()
            }
            cg.setFillColor(UIColor(hex: 0x0A0C12).cgColor)
            cg.fillEllipse(in: CGRect(x: 640, y: 700, width: 90, height: 90))
            cg.fill(CGRect(x: 612, y: 780, width: 146, height: 320))
        }
        let cg = image.cgImage!
        let data = image.jpegData(compressionQuality: 0.92) ?? Data()
        return LoadedPhoto(image: cg, originalData: data, properties: [:], name: "Sample \(variant + 1)")
    }
}

/// When a screen name ends in "-filled", tool screens start with generated sample photos so CI can check them with data.
enum DebugSamples {
    static var enabled = false

    static func photos(_ count: Int, withMetadata: Bool = false) -> [LoadedPhoto] {
        (0..<count).map { index in
            let base = SamplePhoto.make(variant: index)
            guard withMetadata else { return base }
            let properties: [String: Any] = [
                kCGImagePropertyTIFFDictionary as String: [
                    kCGImagePropertyTIFFMake as String: "Apple",
                    kCGImagePropertyTIFFModel as String: "iPhone 16 Pro",
                    kCGImagePropertyTIFFSoftware as String: "18.1",
                ],
                kCGImagePropertyExifDictionary as String: [
                    kCGImagePropertyExifDateTimeOriginal as String: "2026:11:02 18:41:07",
                    kCGImagePropertyExifFNumber as String: 1.8,
                    kCGImagePropertyExifISOSpeedRatings as String: [64],
                    kCGImagePropertyExifExposureTime as String: 0.008,
                    kCGImagePropertyExifFocalLength as String: 6.9,
                ],
                kCGImagePropertyGPSDictionary as String: [
                    kCGImagePropertyGPSLatitude as String: 51.5007,
                    kCGImagePropertyGPSLatitudeRef as String: "N",
                    kCGImagePropertyGPSLongitude as String: 0.1246,
                    kCGImagePropertyGPSLongitudeRef as String: "W",
                ],
            ]
            return LoadedPhoto(image: base.image, originalData: base.originalData, properties: properties, name: base.name)
        }
    }
}
#endif
