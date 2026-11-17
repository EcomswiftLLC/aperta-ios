#if DEBUG
import SwiftUI
import UIKit

/// Debug builds can open a given screen directly, with a generated sample photo, so CI can take screenshots
/// of every screen without tapping through the app: `xcrun simctl launch <device> com.ecomswift.aperta -apScreen home`.
enum DebugScreens {
    static var requested: String? {
        guard let value = UserDefaults.standard.string(forKey: "apScreen"), !value.isEmpty else { return nil }
        return value
    }

    @ViewBuilder
    static func view(for screen: String) -> some View {
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
    static func make() -> LoadedPhoto {
        let size = CGSize(width: 1600, height: 1200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let sky = CGGradient(colorsSpace: space, colors: [
                UIColor(hex: 0x1F2A44).cgColor, UIColor(hex: 0xC76B5A).cgColor, UIColor(hex: 0xF3C58A).cgColor,
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
        let data = image.pngData() ?? Data()
        return LoadedPhoto(image: cg, originalData: data, properties: [:], name: "Sample")
    }
}
#endif
