import SwiftUI
import UIKit

// MARK: - Text

struct TextPanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: AP.Space.s) {
            PanelHeader(title: "Text", onDone: { model.tool = nil })
            if let style = model.selectedTextStyle, let id = model.selectedOverlay {
                editor(style: style, id: id)
            } else {
                VStack(spacing: AP.Space.s) {
                    Text("Add a title, caption or quote, then drag, pinch and rotate it on the photo.")
                        .font(AP.Font.callout)
                        .foregroundStyle(AP.Palette.mist)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, AP.Space.l)
                    Button {
                        model.addText()
                    } label: {
                        Label("Add text", systemImage: "plus")
                    }
                    .buttonStyle(.apPrimary)
                }
                .padding(.vertical, AP.Space.s)
            }
        }
    }

    private func editor(style: TextStyle, id: UUID) -> some View {
        VStack(spacing: AP.Space.s) {
            HStack(spacing: AP.Space.s) {
                TextField("Your text", text: textBinding(id), axis: .vertical)
                    .lineLimit(1...3)
                    .font(AP.Font.body)
                    .foregroundStyle(AP.Palette.paper)
                    .tint(AP.Palette.brass)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(AP.Palette.graphite, in: RoundedRectangle(cornerRadius: AP.Radius.chip, style: .continuous))
                PanelIconButton(systemImage: "plus", label: "Add another text") { model.addText() }
                PanelIconButton(systemImage: "plus.square.on.square", label: "Duplicate") { model.duplicateSelected() }
                PanelIconButton(systemImage: "trash", label: "Delete") { model.deleteSelected() }
            }
            .padding(.horizontal, AP.Space.m)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AP.Space.s) {
                    ForEach(FontChoice.allCases) { choice in
                        let selected = style.font == choice
                        Button {
                            change(id) { $0.font = choice }
                        } label: {
                            Text(choice.title)
                                .font(Font(choice.uiFont(size: 15) as CTFont))
                                .foregroundStyle(selected ? AP.Palette.onBrass : AP.Palette.paper)
                                .padding(.horizontal, 14)
                                .frame(minHeight: 44)
                                .background(selected ? AP.Palette.brass : AP.Palette.graphite, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(choice.title))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.horizontal, AP.Space.m)
            }
            SwatchRow(selected: style.colorHex) { hex in change(id) { $0.colorHex = hex } }
            HStack(spacing: AP.Space.s) {
                ForEach(TextBackground.allCases) { bg in
                    APChip(title: bg.title, selected: style.background == bg) { change(id) { $0.background = bg } }
                }
                APChip(title: "Shadow", selected: style.shadow) { change(id) { $0.shadow.toggle() } }
                Spacer()
            }
            .padding(.horizontal, AP.Space.m)
            DialSlider(
                title: "Size",
                value: Binding(
                    get: { style.size * 100 },
                    set: { value in updateStyle(id) { $0.size = value / 100 } }
                ),
                range: 3...30,
                defaultValue: 9,
                onEditingChanged: { editing in if editing { model.checkpoint() } }
            )
            .padding(.horizontal, AP.Space.m)
        }
    }

    private func textBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { model.selectedTextStyle?.text ?? "" },
            set: { value in updateStyle(id) { $0.text = value } }
        )
    }

    private func change(_ id: UUID, _ edit: (inout TextStyle) -> Void) {
        model.checkpoint()
        updateStyle(id, edit)
    }

    private func updateStyle(_ id: UUID, _ edit: (inout TextStyle) -> Void) {
        model.updateOverlay(id) { overlay in
            if case .text(var style) = overlay.content {
                edit(&style)
                overlay.content = .text(style)
            }
        }
    }
}

// MARK: - Stickers

struct StickerPanel: View {
    @ObservedObject var model: EditorModel
    @State private var category: String = "Smiles"
    @State private var symbolColor: UInt32 = 0xFFFFFF

    private let emoji: [(name: String, items: [String])] = [
        ("Smiles", ["😀", "😂", "😍", "🥰", "😎", "🤩", "😘", "😜", "🤔", "😴", "🥳", "😇", "🤗", "😭", "😡", "🙌"]),
        ("Love", ["❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "💖", "💕", "💞", "😻", "💋", "🌹", "💍", "🎁"]),
        ("Sparkle", ["✨", "💫", "🌟", "⭐️", "🔥", "💥", "💯", "🎉", "🎊", "🏆", "👑", "💎", "🌈", "☀️", "🌙", "⚡️"]),
        ("Nature", ["🌸", "🌺", "🌻", "🌿", "🍀", "🌴", "🌊", "🏔️", "🌅", "🦋", "🐶", "🐱", "🦁", "🐼", "🦄", "🌍"]),
        ("Food", ["🍕", "🍔", "🍟", "🍣", "🍩", "🍰", "🍓", "🍉", "🥑", "☕️", "🍷", "🍹", "🥂", "🍿", "🌮", "🍦"]),
        ("Travel", ["✈️", "🚗", "🏝️", "🗼", "🗽", "🏖️", "⛺️", "🎡", "📸", "🧳", "🗺️", "🚲", "⛵️", "🚀", "🏙️", "🎭"]),
        ("Hands", ["👍", "👏", "🙏", "💪", "✌️", "🤞", "👌", "🤙", "👋", "🫶", "👀", "🧿", "💬", "💭", "✅", "❌"]),
    ]

    private let symbols: [String] = [
        "arrow.up.right", "arrow.right", "heart.fill", "star.fill", "sparkle", "bolt.fill", "flame.fill", "crown.fill",
        "sun.max.fill", "moon.fill", "leaf.fill", "camera.fill", "music.note", "location.fill",
        "checkmark.circle.fill", "xmark.circle.fill", "exclamationmark.circle.fill", "questionmark.circle.fill",
        "circle", "square", "triangle", "hexagon", "diamond.fill", "seal.fill",
    ]

    var body: some View {
        VStack(spacing: AP.Space.s) {
            PanelHeader(title: "Stickers", onDone: { model.tool = nil })
            APChipRow {
                ForEach(emoji, id: \.name) { group in
                    APChip(title: group.name, selected: category == group.name) { category = group.name }
                }
                APChip(title: "Shapes", selected: category == "Shapes") { category = "Shapes" }
            }
            if category == "Shapes" {
                SwatchRow(selected: symbolColor, allowsCustom: false) { hex in
                    symbolColor = hex
                    recolourSelected(hex)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AP.Space.s) {
                        ForEach(symbols, id: \.self) { name in
                            Button {
                                model.addSymbol(name, colorHex: symbolColor)
                                APHaptics.tap()
                            } label: {
                                Image(systemName: name)
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(Color(hex: symbolColor))
                                    .frame(width: 52, height: 52)
                                    .background(AP.Palette.graphite, in: RoundedRectangle(cornerRadius: AP.Radius.chip, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(name.replacingOccurrences(of: ".", with: " ")))
                        }
                    }
                    .padding(.horizontal, AP.Space.m)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AP.Space.s) {
                        ForEach(emoji.first(where: { $0.name == category })?.items ?? [], id: \.self) { item in
                            Button {
                                model.addEmoji(item)
                                APHaptics.tap()
                            } label: {
                                Text(item)
                                    .font(.system(size: 30))
                                    .frame(width: 52, height: 52)
                                    .background(AP.Palette.graphite, in: RoundedRectangle(cornerRadius: AP.Radius.chip, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Sticker \(item)"))
                        }
                    }
                    .padding(.horizontal, AP.Space.m)
                }
            }
            if model.selectedOverlay != nil, model.selectedTextStyle == nil {
                HStack(spacing: AP.Space.s) {
                    PanelIconButton(systemImage: "plus.square.on.square", label: "Duplicate") { model.duplicateSelected() }
                    PanelIconButton(systemImage: "square.3.layers.3d.top.filled", label: "Bring to front") { model.bringSelectedToFront() }
                    PanelIconButton(systemImage: "trash", label: "Delete") { model.deleteSelected() }
                    Spacer()
                    Text("Drag, pinch and rotate on the photo")
                        .font(AP.Font.caption)
                        .foregroundStyle(AP.Palette.mist)
                }
                .padding(.horizontal, AP.Space.m)
            }
        }
    }

    private func recolourSelected(_ hex: UInt32) {
        guard let id = model.selectedOverlay else { return }
        model.checkpoint()
        model.updateOverlay(id) { overlay in
            if case .symbol(var style) = overlay.content {
                style.colorHex = hex
                overlay.content = .symbol(style)
            }
        }
    }
}

// MARK: - Draw

struct DrawPanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: AP.Space.s) {
            PanelHeader(title: "Draw", onDone: { model.tool = nil })
            HStack(spacing: AP.Space.s) {
                ForEach(PenKind.allCases) { kind in
                    APChip(title: kind.title, selected: model.penKind == kind) { model.penKind = kind }
                }
                Spacer()
                PanelIconButton(systemImage: "arrow.uturn.backward", label: "Remove last stroke", disabled: model.state.strokes.isEmpty) {
                    model.commit { $0.strokes.removeLast() }
                }
                PanelIconButton(systemImage: "trash", label: "Clear drawing", disabled: model.state.strokes.isEmpty) {
                    model.commit { $0.strokes.removeAll() }
                }
            }
            .padding(.horizontal, AP.Space.m)
            SwatchRow(selected: model.penColorHex) { model.penColorHex = $0 }
            DialSlider(
                title: "Brush size",
                value: Binding(get: { model.penWidth * 1000 }, set: { model.penWidth = $0 / 1000 }),
                range: 2...40,
                defaultValue: 12
            )
            .padding(.horizontal, AP.Space.m)
        }
    }
}

// MARK: - Blur

struct BlurPanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: AP.Space.s) {
            PanelHeader(title: "Blur", onDone: { model.tool = nil })
            HStack(spacing: AP.Space.s) {
                ForEach(BlurMode.allCases) { mode in
                    APChip(title: mode.title, selected: model.blurMode == mode) { model.blurMode = mode }
                }
                Spacer()
                PanelIconButton(systemImage: "arrow.uturn.backward", label: "Remove last stroke", disabled: model.state.blurs.isEmpty) {
                    model.commit { $0.blurs.removeLast() }
                }
                PanelIconButton(systemImage: "trash", label: "Clear effect", disabled: model.state.blurs.isEmpty) {
                    model.commit { $0.blurs.removeAll() }
                }
            }
            .padding(.horizontal, AP.Space.m)
            Text("Paint over a face, a plate or any detail you want to soften. Blur and pixelate reduce detail but cannot promise to hide something, so cover anything sensitive with a Draw stroke.")
                .font(AP.Font.caption)
                .foregroundStyle(AP.Palette.mist)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AP.Space.m)
            DialSlider(
                title: "Brush size",
                value: Binding(get: { model.blurWidth * 100 }, set: { model.blurWidth = $0 / 100 }),
                range: 2...25,
                defaultValue: 8
            )
            .padding(.horizontal, AP.Space.m)
            DialSlider(
                title: "Strength",
                value: Binding(
                    get: { model.state.blurStrength },
                    set: { value in
                        var next = model.state
                        next.blurStrength = value
                        model.state = next
                    }
                ),
                range: EditPipeline.minBlurStrength...100,
                defaultValue: 60,
                onEditingChanged: { editing in if editing { model.checkpoint() } }
            )
            .padding(.horizontal, AP.Space.m)
        }
    }
}

// MARK: - Cut-out

struct CutoutPanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: AP.Space.s) {
            PanelHeader(title: "Cutout", onReset: model.cutoutReady ? restore : nil, onDone: { model.tool = nil })
            if !model.cutoutReady {
                Text("Lift the main subject off its background. This runs on your device, so your photo is never uploaded.")
                    .font(AP.Font.callout)
                    .foregroundStyle(AP.Palette.mist)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AP.Space.l)
                Button {
                    Task { await model.makeCutout() }
                } label: {
                    HStack(spacing: 8) {
                        if model.isCutting { ProgressView().tint(AP.Palette.onBrass) }
                        Text(model.isCutting ? "Finding the subject" : "Remove background")
                    }
                }
                .buttonStyle(.apPrimary)
                .disabled(model.isCutting)
                if let notice = model.notice {
                    Text(notice)
                        .font(AP.Font.caption)
                        .foregroundStyle(AP.Palette.danger)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, AP.Space.l)
                }
            } else {
                APChipRow {
                    ForEach(BackgroundMode.allCases) { mode in
                        APChip(title: mode.title, selected: model.state.background.mode == mode) {
                            model.commit { $0.background.mode = mode }
                        }
                    }
                }
                if model.state.background.mode == .color {
                    SwatchRow(selected: model.state.background.colorHex) { hex in
                        model.commit { $0.background.colorHex = hex }
                    }
                }
                if model.state.background.mode == .transparent {
                    Text("Export as PNG keeps the transparent background.")
                        .font(AP.Font.caption)
                        .foregroundStyle(AP.Palette.mist)
                }
            }
        }
        .onAppear { model.notice = nil }
    }

    private func restore() {
        model.commit { $0.background = BackgroundState() }
    }
}

// MARK: - Frame

struct FramePanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: AP.Space.s) {
            PanelHeader(title: "Frame", onReset: { model.commit { $0.frame = FrameState() } }, onDone: { model.tool = nil })
            APChipRow {
                ForEach(FrameFit.allCases) { fit in
                    APChip(title: fit == .off ? "No canvas" : fit.title, selected: model.state.frame.fit == fit) {
                        model.commit { $0.frame.fit = fit }
                    }
                }
            }
            if model.state.frame.fit != .off {
                HStack(spacing: AP.Space.s) {
                    APChip(title: "Blurred photo", selected: model.state.frame.blurFill) {
                        model.commit { $0.frame.blurFill = true }
                    }
                    APChip(title: "Solid colour", selected: !model.state.frame.blurFill) {
                        model.commit { $0.frame.blurFill = false }
                    }
                    Spacer()
                }
                .padding(.horizontal, AP.Space.m)
                if !model.state.frame.blurFill {
                    SwatchRow(selected: model.state.frame.fillHex) { hex in
                        model.commit { $0.frame.fillHex = hex }
                    }
                }
            }
            DialSlider(
                title: "Border",
                value: Binding(
                    get: { model.state.frame.border },
                    set: { value in
                        var next = model.state
                        next.frame.border = value
                        model.state = next
                    }
                ),
                range: 0...20,
                defaultValue: 0,
                unit: "%",
                onEditingChanged: { editing in if editing { model.checkpoint() } }
            )
            .padding(.horizontal, AP.Space.m)
            if model.state.frame.border > 0 {
                SwatchRow(selected: model.state.frame.borderHex) { hex in
                    model.commit { $0.frame.borderHex = hex }
                }
            }
        }
    }
}
