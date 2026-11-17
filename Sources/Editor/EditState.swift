import SwiftUI
import UIKit

// MARK: - Colour helpers (colours are stored as plain 0xRRGGBB values so states stay Equatable and cheap)

extension Color {
    /// 0xRRGGBB of a SwiftUI colour (alpha ignored).
    var hexValue: UInt32 {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        let ri = UInt32(max(0, min(255, (r * 255).rounded())))
        let gi = UInt32(max(0, min(255, (g * 255).rounded())))
        let bi = UInt32(max(0, min(255, (b * 255).rounded())))
        return (ri << 16) | (gi << 8) | bi
    }
}

extension UInt32 {
    /// Perceived brightness 0...1 of a 0xRRGGBB colour.
    var luminance: Double {
        let r = Double((self >> 16) & 0xFF) / 255
        let g = Double((self >> 8) & 0xFF) / 255
        let b = Double(self & 0xFF) / 255
        return 0.299 * r + 0.587 * g + 0.114 * b
    }
}

// MARK: - Adjustments

struct Adjustments: Equatable {
    var exposure: Double = 0
    var brightness: Double = 0
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var saturation: Double = 0
    var warmth: Double = 0
    var tint: Double = 0
    var fade: Double = 0
    var sharpness: Double = 0
    var clarity: Double = 0
    var grain: Double = 0
    var vignette: Double = 0

    var isIdentity: Bool { self == Adjustments() }
}

enum AdjustKind: String, CaseIterable, Identifiable {
    case exposure, brightness, contrast, highlights, shadows, saturation, warmth, tint, fade, sharpness, clarity, grain, vignette

    var id: String { rawValue }

    var title: String {
        switch self {
        case .exposure: return "Exposure"
        case .brightness: return "Brightness"
        case .contrast: return "Contrast"
        case .highlights: return "Highlights"
        case .shadows: return "Shadows"
        case .saturation: return "Saturation"
        case .warmth: return "Warmth"
        case .tint: return "Tint"
        case .fade: return "Fade"
        case .sharpness: return "Sharpness"
        case .clarity: return "Clarity"
        case .grain: return "Grain"
        case .vignette: return "Vignette"
        }
    }

    /// Effects that only add something start at 0 and go up to 100; the others are centred on 0.
    var range: ClosedRange<Double> {
        switch self {
        case .fade, .sharpness, .clarity, .grain, .vignette: return 0...100
        default: return -100...100
        }
    }

    var keyPath: WritableKeyPath<Adjustments, Double> {
        switch self {
        case .exposure: return \.exposure
        case .brightness: return \.brightness
        case .contrast: return \.contrast
        case .highlights: return \.highlights
        case .shadows: return \.shadows
        case .saturation: return \.saturation
        case .warmth: return \.warmth
        case .tint: return \.tint
        case .fade: return \.fade
        case .sharpness: return \.sharpness
        case .clarity: return \.clarity
        case .grain: return \.grain
        case .vignette: return \.vignette
        }
    }

    var symbol: String {
        switch self {
        case .exposure: return "sun.max"
        case .brightness: return "circle.lefthalf.filled"
        case .contrast: return "circle.righthalf.filled"
        case .highlights: return "sun.haze"
        case .shadows: return "moon"
        case .saturation: return "drop"
        case .warmth: return "thermometer.medium"
        case .tint: return "eyedropper"
        case .fade: return "cloud.fog"
        case .sharpness: return "triangle"
        case .clarity: return "diamond"
        case .grain: return "circle.dotted"
        case .vignette: return "circle.circle"
        }
    }
}

// MARK: - Crop

enum CropRatio: String, CaseIterable, Identifiable {
    case free, original, square, portrait45, landscape54, portrait34, landscape43, story, wide, landscape32, portrait23

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: return "Free"
        case .original: return "Original"
        case .square: return "1:1"
        case .portrait45: return "4:5"
        case .landscape54: return "5:4"
        case .portrait34: return "3:4"
        case .landscape43: return "4:3"
        case .story: return "9:16"
        case .wide: return "16:9"
        case .landscape32: return "3:2"
        case .portrait23: return "2:3"
        }
    }

    /// Width divided by height. Nil means unconstrained.
    func value(original: CGFloat) -> CGFloat? {
        switch self {
        case .free: return nil
        case .original: return original
        case .square: return 1
        case .portrait45: return 4.0 / 5.0
        case .landscape54: return 5.0 / 4.0
        case .portrait34: return 3.0 / 4.0
        case .landscape43: return 4.0 / 3.0
        case .story: return 9.0 / 16.0
        case .wide: return 16.0 / 9.0
        case .landscape32: return 3.0 / 2.0
        case .portrait23: return 2.0 / 3.0
        }
    }
}

struct CropState: Equatable {
    var ratio: CropRatio = .free
    /// Crop rectangle in unit coordinates (origin top left) of the rotated, straightened picture.
    var rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    var quarterTurns: Int = 0
    /// Degrees, positive turns the picture clockwise. -45...45.
    var straighten: Double = 0
    var flipH: Bool = false
    var flipV: Bool = false

    var isIdentity: Bool { self == CropState() }
}

// MARK: - Background (cut-out) and frame

enum BackgroundMode: String, CaseIterable, Identifiable {
    case original, transparent, color, blur, mono
    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "Original"
        case .transparent: return "Transparent"
        case .color: return "Colour"
        case .blur: return "Blur"
        case .mono: return "Black and white"
        }
    }
}

struct BackgroundState: Equatable {
    var mode: BackgroundMode = .original
    var colorHex: UInt32 = 0xFFFFFF
}

enum FrameFit: String, CaseIterable, Identifiable {
    case off, square, portrait45, story, landscape

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .square: return "1:1"
        case .portrait45: return "4:5"
        case .story: return "9:16"
        case .landscape: return "16:9"
        }
    }

    var aspect: CGFloat? {
        switch self {
        case .off: return nil
        case .square: return 1
        case .portrait45: return 4.0 / 5.0
        case .story: return 9.0 / 16.0
        case .landscape: return 16.0 / 9.0
        }
    }
}

struct FrameState: Equatable {
    var fit: FrameFit = .off
    var blurFill: Bool = true
    var fillHex: UInt32 = 0x000000
    /// Border thickness, percent of the shorter side.
    var border: Double = 0
    var borderHex: UInt32 = 0xFFFFFF

    var isIdentity: Bool { self == FrameState() }
}

// MARK: - Overlays

enum FontChoice: String, CaseIterable, Identifiable {
    case serif, sans, rounded, mono, didot, futura, copperplate, script, georgia, marker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .serif: return "Serif"
        case .sans: return "Sans"
        case .rounded: return "Rounded"
        case .mono: return "Mono"
        case .didot: return "Didot"
        case .futura: return "Futura"
        case .copperplate: return "Copperplate"
        case .script: return "Script"
        case .georgia: return "Georgia"
        case .marker: return "Marker"
        }
    }

    func uiFont(size: CGFloat) -> UIFont {
        func system(_ design: UIFontDescriptor.SystemDesign, _ weight: UIFont.Weight) -> UIFont {
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            if let descriptor = base.fontDescriptor.withDesign(design) { return UIFont(descriptor: descriptor, size: size) }
            return base
        }
        switch self {
        case .serif: return system(.serif, .semibold)
        case .sans: return UIFont.systemFont(ofSize: size, weight: .bold)
        case .rounded: return system(.rounded, .bold)
        case .mono: return system(.monospaced, .semibold)
        case .didot: return UIFont(name: "Didot-Bold", size: size) ?? system(.serif, .bold)
        case .futura: return UIFont(name: "Futura-Medium", size: size) ?? UIFont.systemFont(ofSize: size, weight: .medium)
        case .copperplate: return UIFont(name: "Copperplate-Bold", size: size) ?? system(.serif, .bold)
        case .script: return UIFont(name: "SnellRoundhand-Bold", size: size) ?? system(.serif, .semibold)
        case .georgia: return UIFont(name: "Georgia-Bold", size: size) ?? system(.serif, .bold)
        case .marker: return UIFont(name: "MarkerFelt-Wide", size: size) ?? system(.rounded, .heavy)
        }
    }
}

enum TextBackground: String, CaseIterable, Identifiable {
    case none, box, pill
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "None"
        case .box: return "Box"
        case .pill: return "Pill"
        }
    }
}

struct TextStyle: Equatable {
    var text: String = "Your text"
    var font: FontChoice = .serif
    var colorHex: UInt32 = 0xFFFFFF
    /// Fraction of the canvas width.
    var size: Double = 0.09
    var background: TextBackground = .none
    var shadow: Bool = true
    var tracking: Double = 0
}

struct SymbolStyle: Equatable {
    var name: String
    var colorHex: UInt32 = 0xFFFFFF
}

enum OverlayContent: Equatable {
    case text(TextStyle)
    case emoji(String)
    case symbol(SymbolStyle)
}

struct Overlay: Identifiable, Equatable {
    var id = UUID()
    var content: OverlayContent
    /// Centre in unit coordinates of the canvas (origin top left).
    var center: CGPoint = CGPoint(x: 0.5, y: 0.5)
    var scale: CGFloat = 1
    /// Radians, clockwise.
    var rotation: Double = 0
}

// MARK: - Strokes

enum PenKind: String, CaseIterable, Identifiable {
    case pen, marker, neon
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pen: return "Pen"
        case .marker: return "Marker"
        case .neon: return "Neon"
        }
    }
}

struct DrawStroke: Identifiable, Equatable {
    var id = UUID()
    var points: [CGPoint]
    var colorHex: UInt32
    /// Fraction of the canvas width.
    var width: Double
    var kind: PenKind
}

enum BlurMode: String, CaseIterable, Identifiable {
    case blur, pixelate, smooth
    var id: String { rawValue }
    var title: String {
        switch self {
        case .blur: return "Blur"
        case .pixelate: return "Pixelate"
        case .smooth: return "Smooth"
        }
    }
}

struct BlurStroke: Identifiable, Equatable {
    var id = UUID()
    var points: [CGPoint]
    /// Fraction of the shorter side of the picture.
    var width: Double
    var mode: BlurMode
}

// MARK: - The whole edit

struct EditState: Equatable {
    var autoEnhance: Bool = false
    var adjust = Adjustments()
    var filter: FilterID = .original
    var filterIntensity: Double = 100
    var crop = CropState()
    var background = BackgroundState()
    var frame = FrameState()
    var blurStrength: Double = 60
    var blurs: [BlurStroke] = []
    var overlays: [Overlay] = []
    var strokes: [DrawStroke] = []

    var hasOverlays: Bool { !overlays.isEmpty || !strokes.isEmpty }
}

enum EditorTool: String, CaseIterable, Identifiable {
    case crop, adjust, filters, text, stickers, draw, blur, cutout, frame

    var id: String { rawValue }

    var title: String {
        switch self {
        case .crop: return "Crop"
        case .adjust: return "Adjust"
        case .filters: return "Filters"
        case .text: return "Text"
        case .stickers: return "Stickers"
        case .draw: return "Draw"
        case .blur: return "Blur"
        case .cutout: return "Cutout"
        case .frame: return "Frame"
        }
    }

    var symbol: String {
        switch self {
        case .crop: return "crop.rotate"
        case .adjust: return "slider.horizontal.3"
        case .filters: return "camera.filters"
        case .text: return "textformat"
        case .stickers: return "face.smiling"
        case .draw: return "pencil.tip"
        case .blur: return "circle.dotted.and.circle"
        case .cutout: return "person.crop.circle.dashed"
        case .frame: return "square.dashed"
        }
    }
}
