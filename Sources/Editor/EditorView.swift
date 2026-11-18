import SwiftUI
import UIKit

/// The full-screen photo editor.
struct EditorView: View {
    @StateObject private var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var showExport = false
    @State private var confirmClose = false

    #if DEBUG
    /// Debug builds only: lets CI put the editor into a finished-looking state for store screenshots.
    private var debugPreset: (@MainActor (EditorModel) async -> Void)?

    init(photo: LoadedPhoto, startTool: EditorTool? = nil, debugPreset: (@MainActor (EditorModel) async -> Void)? = nil) {
        let model = EditorModel(photo: photo)
        model.tool = startTool
        _model = StateObject(wrappedValue: model)
        self.debugPreset = debugPreset
    }
    #else
    init(photo: LoadedPhoto, startTool: EditorTool? = nil) {
        let model = EditorModel(photo: photo)
        model.tool = startTool
        _model = StateObject(wrappedValue: model)
    }
    #endif

    var body: some View {
        VStack(spacing: 0) {
            topBar
            CanvasView(model: model)
                .frame(maxHeight: .infinity)
            if let tool = model.tool {
                panel(for: tool)
                    .padding(.top, AP.Space.s)
                    .padding(.bottom, AP.Space.s)
                    .background(AP.Palette.carbon)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            toolTray
        }
        .apScreen()
        .preferredColorScheme(.dark)
        #if DEBUG
        .task { if let debugPreset { await debugPreset(model) } }
        #endif
        .animation(.easeOut(duration: 0.22), value: model.tool)
        .sheet(isPresented: $showExport) {
            ExportSheet(model: model)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog("Discard your edits?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Discard edits", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("Your changes have not been saved.")
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 4) {
            Button {
                if model.hasEdits { confirmClose = true } else { dismiss() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AP.Palette.paper)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(Text("Close editor"))

            Spacer()

            barButton("arrow.uturn.backward", label: "Undo", disabled: !model.canUndo) { model.undo() }
            barButton("arrow.uturn.forward", label: "Redo", disabled: !model.canRedo) { model.redo() }
            compareButton

            Spacer()

            Button {
                model.tool = nil
                showExport = true
            } label: {
                Text("Export")
                    .font(AP.Font.headline)
                    .foregroundStyle(AP.Palette.onBrass)
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .background(AP.Palette.brass, in: Capsule())
            }
            .accessibilityLabel(Text("Export"))
        }
        .padding(.horizontal, AP.Space.m)
        .frame(height: 52)
    }

    private func barButton(_ symbol: String, label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(AP.Palette.paper)
                .frame(width: 44, height: 44)
        }
        .disabled(disabled)
        .opacity(disabled ? 0.3 : 1)
        .accessibilityLabel(Text(label))
    }

    /// Press and hold to see the original.
    private var compareButton: some View {
        Image(systemName: "square.split.2x1")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(model.showingOriginal ? AP.Palette.brass : AP.Palette.paper)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !model.showingOriginal { model.showingOriginal = true } }
                    .onEnded { _ in model.showingOriginal = false }
            )
            .accessibilityLabel(Text("Hold to compare with the original"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: Text("Show original")) { model.showingOriginal = true }
            .accessibilityAction(named: Text("Show edited")) { model.showingOriginal = false }
    }

    // MARK: Panels and tray

    @ViewBuilder
    private func panel(for tool: EditorTool) -> some View {
        switch tool {
        case .crop: CropPanel(model: model)
        case .adjust: AdjustPanel(model: model)
        case .filters: FilterPanel(model: model)
        case .text: TextPanel(model: model)
        case .stickers: StickerPanel(model: model)
        case .draw: DrawPanel(model: model)
        case .blur: BlurPanel(model: model)
        case .cutout: CutoutPanel(model: model)
        case .frame: FramePanel(model: model)
        }
    }

    private var toolTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(EditorTool.allCases) { tool in
                    trayButton(tool)
                }
            }
            .padding(.horizontal, AP.Space.s)
        }
        .frame(height: 64)
        .background(AP.Palette.lens)
        .overlay(alignment: .top) { APHairline() }
    }

    private func trayButton(_ tool: EditorTool) -> some View {
        let selected = model.tool == tool
        return Button {
            APHaptics.tap()
            model.tool = selected ? nil : tool
        } label: {
            VStack(spacing: 4) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 19, weight: .regular))
                Text(tool.title)
                    .font(AP.Font.caption)
            }
            .foregroundStyle(selected ? AP.Palette.brass : AP.Palette.paper.opacity(0.85))
            .frame(width: 72, height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(tool.title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Export

struct ExportSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    @State private var options = ExportOptions()
    @State private var item: ExportItem?
    @State private var rendering = false
    @State private var failed = false

    private let sizes: [(title: String, value: Int?)] = [
        ("Original size", nil), ("2048 px", 2048), ("1080 px", 1080),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AP.Space.l) {
                    ToolHeader(title: "Export", subtitle: "Choose a format and size, then save or share.")
                    previewImage
                    optionsSection
                    summary
                    ExportBar(items: item.map { [$0] } ?? [])
                }
                .padding(.horizontal, AP.Space.m)
                .padding(.bottom, AP.Space.xl)
                .readableWidth()
            }
            .apScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(AP.Palette.brass)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task(id: options) { await render() }
    }

    private var previewImage: some View {
        Group {
            if let image = model.preview {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: AP.Radius.chip, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: AP.Radius.chip, style: .continuous).strokeBorder(AP.Palette.line))
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(Text("Preview of your edited photo"))
            }
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: AP.Space.m) {
            VStack(alignment: .leading, spacing: AP.Space.s) {
                Text("Format").font(AP.Font.label).foregroundStyle(AP.Palette.mist)
                HStack(spacing: AP.Space.s) {
                    ForEach(OutputFormat.available) { format in
                        APChip(title: format.title, selected: options.format == format) { options.format = format }
                    }
                }
            }
            VStack(alignment: .leading, spacing: AP.Space.s) {
                Text("Size").font(AP.Font.label).foregroundStyle(AP.Palette.mist)
                HStack(spacing: AP.Space.s) {
                    ForEach(sizes, id: \.title) { size in
                        APChip(title: size.title, selected: options.maxLongSide == size.value) { options.maxLongSide = size.value }
                    }
                }
            }
            if options.format.usesQuality {
                DialSlider(
                    title: "Quality",
                    value: Binding(get: { options.quality * 100 }, set: { options.quality = $0 / 100 }),
                    range: 40...100,
                    defaultValue: 92,
                    unit: "%"
                )
            }
        }
    }

    @ViewBuilder
    private var summary: some View {
        HStack(spacing: AP.Space.s) {
            if rendering {
                ProgressView().tint(AP.Palette.brass)
                Text("Preparing your photo").font(AP.Font.callout).foregroundStyle(AP.Palette.mist)
            } else if let item {
                Image(systemName: "checkmark.seal").foregroundStyle(AP.Palette.brass)
                Text("\(item.format.title), \(ByteText.string(item.data.count))")
                    .font(AP.Font.callout).foregroundStyle(AP.Palette.paper)
                if model.state.background.mode == .transparent && model.cutoutReady && options.format == .jpeg {
                    Text("Saved as PNG to keep transparency").font(AP.Font.caption).foregroundStyle(AP.Palette.mist)
                }
            } else if failed {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(AP.Palette.danger)
                Text("Could not prepare the photo. Try a smaller size.").font(AP.Font.callout).foregroundStyle(AP.Palette.danger)
            }
        }
        .frame(minHeight: 24)
    }

    private func render() async {
        rendering = true
        failed = false
        item = nil
        // Small delay so quick changes of the options do not start a render each time.
        try? await Task.sleep(nanoseconds: 250_000_000)
        if Task.isCancelled { return }
        let result = await model.renderExport(options: options)
        if Task.isCancelled { return }
        item = result
        failed = result == nil
        rendering = false
    }
}
