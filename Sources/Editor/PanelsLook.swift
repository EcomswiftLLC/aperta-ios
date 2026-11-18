import SwiftUI
import UIKit
import CoreImage

// MARK: - Shared pieces for tool panels

/// Colours offered by text, stickers, drawing and frames.
enum APSwatches {
    static let colors: [UInt32] = [
        0xFFFFFF, 0x0C0D0F, 0xD2AE6E, 0xE5534B, 0xF2A33A, 0xF6D860, 0x5CB85C, 0x3FA7D6, 0x7A5CFA, 0xF08FC0,
    ]

    /// Spoken name of a swatch, so VoiceOver says "Gold" and not a hex code.
    static func name(for hex: UInt32) -> String {
        switch hex {
        case 0xFFFFFF: return "White"
        case 0x0C0D0F: return "Black"
        case 0xD2AE6E: return "Gold"
        case 0xE5534B: return "Red"
        case 0xF2A33A: return "Orange"
        case 0xF6D860: return "Yellow"
        case 0x5CB85C: return "Green"
        case 0x3FA7D6: return "Blue"
        case 0x7A5CFA: return "Purple"
        case 0xF08FC0: return "Pink"
        default: return "Custom colour"
        }
    }
}

struct SwatchRow: View {
    let selected: UInt32
    var allowsCustom: Bool = true
    let onPick: (UInt32) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AP.Space.s) {
                ForEach(APSwatches.colors, id: \.self) { hex in
                    Button {
                        onPick(hex)
                    } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 30, height: 30)
                            .overlay(Circle().strokeBorder(AP.Palette.paper.opacity(0.25), lineWidth: 1))
                            .overlay(
                                Circle()
                                    .strokeBorder(AP.Palette.brass, lineWidth: selected == hex ? 2.5 : 0)
                                    .padding(-4)
                            )
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(APSwatches.name(for: hex)))
                    .accessibilityAddTraits(selected == hex ? .isSelected : [])
                }
                if allowsCustom {
                    ColorPicker("Custom colour", selection: Binding(
                        get: { Color(hex: selected) },
                        set: { onPick($0.hexValue) }
                    ), supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 44, height: 44)
                }
            }
            .padding(.horizontal, AP.Space.m)
        }
    }
}

/// Header row of a panel: title, optional reset, and a done button that closes the tool.
struct PanelHeader: View {
    let title: String
    var onReset: (() -> Void)? = nil
    let onDone: () -> Void

    var body: some View {
        HStack {
            Text(title).font(AP.Font.title(20)).foregroundStyle(AP.Palette.paper)
            Spacer()
            if let onReset {
                Button("Reset", action: onReset)
                    .font(AP.Font.label)
                    .foregroundStyle(AP.Palette.mist)
                    .frame(minWidth: 44, minHeight: 44)
            }
            Button(action: onDone) {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(AP.Palette.onBrass)
                    .frame(width: 44, height: 44)
                    .background(AP.Palette.brass, in: Capsule())
            }
            .accessibilityLabel(Text("Done"))
        }
        .padding(.horizontal, AP.Space.m)
    }
}

/// Small square icon button used in panels.
struct PanelIconButton: View {
    let systemImage: String
    let label: String
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(AP.Palette.paper)
                .frame(width: 44, height: 44)
                .background(AP.Palette.graphite, in: RoundedRectangle(cornerRadius: AP.Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .accessibilityLabel(Text(label))
    }
}

// MARK: - Adjust

struct AdjustPanel: View {
    @ObservedObject var model: EditorModel
    @State private var kind: AdjustKind = .exposure

    var body: some View {
        VStack(spacing: AP.Space.s) {
            PanelHeader(title: "Adjust", onReset: reset, onDone: { model.tool = nil })
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AP.Space.s) {
                    autoChip
                    ForEach(AdjustKind.allCases) { item in
                        adjustChip(item)
                    }
                }
                .padding(.horizontal, AP.Space.m)
            }
            DialSlider(
                title: kind.title,
                value: binding(kind),
                range: kind.range,
                defaultValue: 0,
                onEditingChanged: { editing in if editing { model.checkpoint() } }
            )
            .padding(.horizontal, AP.Space.m)
        }
    }

    private var autoChip: some View {
        APChip(title: "Auto", systemImage: "wand.and.stars", selected: model.state.autoEnhance) {
            model.commit { $0.autoEnhance.toggle() }
        }
    }

    private func adjustChip(_ item: AdjustKind) -> some View {
        let changed = abs(model.state.adjust[keyPath: item.keyPath]) > 0.5
        return Button {
            kind = item
            APHaptics.tap()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: item.symbol).font(.system(size: 13, weight: .semibold))
                Text(item.title).font(AP.Font.label)
                if changed {
                    Circle().fill(kind == item ? AP.Palette.onBrass : AP.Palette.brass).frame(width: 5, height: 5)
                }
            }
            .foregroundStyle(kind == item ? AP.Palette.onBrass : AP.Palette.paper)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(kind == item ? AP.Palette.brass : AP.Palette.graphite, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(kind == item ? .isSelected : [])
    }

    private func binding(_ item: AdjustKind) -> Binding<Double> {
        Binding(
            get: { model.state.adjust[keyPath: item.keyPath] },
            set: { newValue in
                var next = model.state
                next.adjust[keyPath: item.keyPath] = newValue
                model.state = next
            }
        )
    }

    private func reset() {
        model.commit { state in
            state.adjust = Adjustments()
            state.autoEnhance = false
        }
    }
}

// MARK: - Filters

@MainActor
final class FilterThumbnails: ObservableObject {
    @Published private(set) var images: [FilterID: UIImage] = [:]
    private var started = false

    func load(from source: CGImage?) {
        guard !started, let source else { return }
        started = true
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let small = ImageCodec.scaled(source, maxPixel: 200) else { return }
            let base = CIImage(cgImage: small)
            for id in FilterID.allCases {
                let styled = FilterLibrary.apply(id, to: base)
                if let cg = EditPipeline.shared.cgImage(styled) {
                    let image = UIImage(cgImage: cg)
                    await MainActor.run { self?.images[id] = image }
                }
            }
        }
    }
}

struct FilterPanel: View {
    @ObservedObject var model: EditorModel
    @StateObject private var thumbs = FilterThumbnails()

    var body: some View {
        VStack(spacing: AP.Space.s) {
            PanelHeader(title: "Filters", onReset: {
                model.commit { state in
                    state.filter = .original
                    state.filterIntensity = 100
                }
            }, onDone: { model.tool = nil })
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: AP.Space.s) {
                    ForEach(FilterID.allCases) { id in
                        thumbnail(id)
                    }
                }
                .padding(.horizontal, AP.Space.m)
            }
            .frame(height: 104)
            if model.state.filter != .original {
                DialSlider(
                    title: "Intensity",
                    value: Binding(
                        get: { model.state.filterIntensity },
                        set: { value in
                            var next = model.state
                            next.filterIntensity = value
                            model.state = next
                        }
                    ),
                    range: 0...100,
                    defaultValue: 100,
                    unit: "%",
                    onEditingChanged: { editing in if editing { model.checkpoint() } }
                )
                .padding(.horizontal, AP.Space.m)
            }
        }
        .onAppear { thumbs.load(from: model.originalPreview?.cgImage) }
    }

    private func thumbnail(_ id: FilterID) -> some View {
        let selected = model.state.filter == id
        return Button {
            APHaptics.tap()
            model.commit { state in
                state.filter = id
                state.filterIntensity = 100
            }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    if let image = thumbs.images[id] {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        AP.Palette.graphite
                    }
                }
                .frame(width: 68, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: AP.Radius.chip, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AP.Radius.chip, style: .continuous)
                        .strokeBorder(selected ? AP.Palette.brass : AP.Palette.line, lineWidth: selected ? 2 : 1)
                )
                Text(id.title)
                    .font(AP.Font.caption)
                    .foregroundStyle(selected ? AP.Palette.brass : AP.Palette.mist)
                    .lineLimit(1)
            }
            .frame(width: 72)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(id.title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Crop

struct CropPanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: AP.Space.s) {
            PanelHeader(title: "Crop", onReset: reset, onDone: { model.tool = nil })
            APChipRow {
                ForEach(CropRatio.allCases) { ratio in
                    APChip(title: ratio.title, selected: model.state.crop.ratio == ratio) {
                        setRatio(ratio)
                    }
                }
            }
            HStack(spacing: AP.Space.s) {
                PanelIconButton(systemImage: "rotate.left", label: "Rotate left") { rotate(-1) }
                PanelIconButton(systemImage: "rotate.right", label: "Rotate right") { rotate(1) }
                PanelIconButton(systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right", label: "Flip horizontally") {
                    flip(horizontal: true)
                }
                PanelIconButton(systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down", label: "Flip vertically") {
                    flip(horizontal: false)
                }
                Spacer()
            }
            .padding(.horizontal, AP.Space.m)
            DialSlider(
                title: "Straighten",
                value: Binding(
                    get: { model.state.crop.straighten },
                    set: { value in
                        var next = model.state
                        next.crop.straighten = value
                        next.crop.rect = model.fittedCropRect(ratio: next.crop.ratio, crop: next.crop)
                        model.state = next
                    }
                ),
                range: -45...45,
                defaultValue: 0,
                unit: "°",
                onEditingChanged: { editing in if editing { model.checkpoint() } }
            )
            .padding(.horizontal, AP.Space.m)
        }
    }

    private func setRatio(_ ratio: CropRatio) {
        model.commit { state in
            state.crop.ratio = ratio
            state.crop.rect = ratio == .free
                ? CGRect(x: 0, y: 0, width: 1, height: 1)
                : model.fittedCropRect(ratio: ratio, crop: state.crop)
        }
    }

    private func rotate(_ turns: Int) {
        model.commit { state in
            state.crop.quarterTurns += turns
            var ratio = state.crop.ratio
            if ratio == .original { ratio = .free }
            state.crop.ratio = ratio
            state.crop.rect = model.fittedCropRect(ratio: ratio, crop: state.crop)
        }
    }

    private func flip(horizontal: Bool) {
        model.commit { state in
            // Flips are applied before the rotation, so after a quarter turn the buttons swap axes.
            let swapped = abs(state.crop.quarterTurns) % 2 == 1
            if horizontal != swapped { state.crop.flipH.toggle() } else { state.crop.flipV.toggle() }
        }
    }

    private func reset() {
        model.commit { $0.crop = CropState() }
    }
}
