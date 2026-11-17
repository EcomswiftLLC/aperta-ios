import SwiftUI
import PhotosUI
import UIKit

/// Collage tool: pick 2 to 9 photos, choose a layout and shape, frame each photo, then save a 2160 px JPG.
@MainActor
struct CollageView: View {
    @StateObject private var model = ClgModel()
    @StateObject private var selection = PhotoSelection()
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var replaceItem: PhotosPickerItem? = nil
    @State private var notice: String? = nil
    @State private var isPreparing: Bool = false

    init() {}

    var body: some View {
        ToolScreen(title: "Collage", subtitle: "Arrange two to nine photos in one frame.") {
            if model.photos.count >= 2 {
                editor
            } else {
                pickStep
            }
        }
        .onChange(of: pickerItems) { _, items in
            Task { await loadPicked(items) }
        }
        .onChange(of: replaceItem) { _, item in
            guard let item, let index = model.selectedCell else { return }
            Task { await replace(index: index, with: item) }
        }
        .onChange(of: model.customColor) { _, _ in
            model.backdrop = .custom
        }
    }

    // MARK: - Pick step

    private var pickStep: some View {
        VStack(alignment: .leading, spacing: AP.Space.m) {
            PhotosPicker(selection: $pickerItems, maxSelectionCount: 9, selectionBehavior: .ordered, matching: .images) {
                PickPhotosPrompt(
                    title: "Choose photos",
                    detail: "Pick two to nine, in the order you want them placed. You can swap them later.",
                    systemImage: "square.grid.2x2"
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Choose two to nine photos"))
            .disabled(isBusy)

            if isBusy {
                loadingRow
            }
            if let notice {
                Text(notice)
                    .font(AP.Font.callout)
                    .foregroundStyle(AP.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var isBusy: Bool { selection.isLoading || isPreparing }

    private var loadingRow: some View {
        HStack(spacing: AP.Space.s) {
            ProgressView().tint(AP.Palette.brass)
            Text("Opening photos").font(AP.Font.callout).foregroundStyle(AP.Palette.mist)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: AP.Space.m) {
            Group {
                photosRow
                canvasSection
                selectionBar
                APHairline()
                layoutSection
                APHairline()
            }
            Group {
                shapeSection
                APHairline()
                styleSection
                APHairline()
                backgroundSection
                APHairline()
                exportSection
            }
        }
    }

    private var photosRow: some View {
        HStack(spacing: AP.Space.s) {
            Text("\(model.photos.count) photos")
                .font(AP.Font.callout)
                .foregroundStyle(AP.Palette.mist)
            if isBusy {
                ProgressView().tint(AP.Palette.brass)
            }
            Spacer(minLength: AP.Space.s)
            PhotosPicker(selection: $pickerItems, maxSelectionCount: 9, selectionBehavior: .ordered, matching: .images) {
                Text("Change photos")
            }
            .buttonStyle(.apQuiet)
            .accessibilityLabel(Text("Change photos"))
            .disabled(isBusy)
        }
    }

    private var canvasSection: some View {
        let ratio: CGFloat = model.aspect.ratio
        let containerRatio: CGFloat = max(ratio, 0.8)
        return Color.clear
            .aspectRatio(containerRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay(
                GeometryReader { geo in
                    ClgCanvasView(
                        model: model,
                        size: CollageView.fitted(ratio: ratio, in: geo.size),
                        onTap: { index in tapCell(index) }
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            )
    }

    @ViewBuilder
    private var selectionBar: some View {
        if model.isSwapping {
            HStack(spacing: AP.Space.s) {
                Text("Tap another photo to swap places.")
                    .font(AP.Font.callout)
                    .foregroundStyle(AP.Palette.paper)
                Spacer(minLength: AP.Space.s)
                Button("Cancel") {
                    model.isSwapping = false
                }
                .buttonStyle(.apQuiet)
                .accessibilityLabel(Text("Cancel swap"))
            }
        } else if let index = model.selectedCell, index < model.photos.count {
            selectedActions(index: index)
        } else {
            Text("Tap a photo to move, zoom, swap or replace it.")
                .font(AP.Font.callout)
                .foregroundStyle(AP.Palette.mist)
                .frame(minHeight: 44, alignment: .leading)
        }
    }

    private func selectedActions(index: Int) -> some View {
        HStack(spacing: 0) {
            Button {
                APHaptics.tap()
                model.isSwapping = true
            } label: {
                ClgActionLabel(title: "Swap", systemImage: "arrow.left.arrow.right")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Swap with another photo"))

            PhotosPicker(selection: $replaceItem, matching: .images) {
                ClgActionLabel(title: "Replace", systemImage: "photo.badge.plus")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Replace this photo"))

            Button {
                APHaptics.tap()
                model.resetFraming(at: index)
            } label: {
                ClgActionLabel(title: "Reset", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Reset framing"))

            Button {
                model.selectedCell = nil
            } label: {
                ClgActionLabel(title: "Done", systemImage: "checkmark", active: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Done editing this photo"))
        }
        .background(AP.Palette.carbon, in: RoundedRectangle(cornerRadius: AP.Radius.control, style: .continuous))
    }

    private var layoutSection: some View {
        VStack(alignment: .leading, spacing: AP.Space.s) {
            HStack {
                Text("Layout").font(AP.Font.label).foregroundStyle(AP.Palette.mist)
                Spacer()
                Text(model.layout?.name ?? "")
                    .font(AP.Font.label)
                    .foregroundStyle(AP.Palette.paper)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AP.Space.s) {
                    ForEach(model.layouts) { layout in
                        ClgLayoutThumb(layout: layout, selected: layout.id == model.layout?.id) {
                            APHaptics.tap()
                            model.layoutID = layout.id
                        }
                    }
                }
                .padding(.horizontal, AP.Space.m)
            }
            .padding(.horizontal, -AP.Space.m)
        }
    }

    private var shapeSection: some View {
        VStack(alignment: .leading, spacing: AP.Space.s) {
            Text("Shape").font(AP.Font.label).foregroundStyle(AP.Palette.mist)
            APChipRow {
                ForEach(ClgAspect.allCases) { aspect in
                    APChip(title: aspect.title, selected: model.aspect == aspect) {
                        model.aspect = aspect
                    }
                    .accessibilityLabel(Text(aspect.spokenName))
                }
            }
            .padding(.horizontal, -AP.Space.m)
        }
    }

    private var styleSection: some View {
        VStack(alignment: .leading, spacing: AP.Space.m) {
            DialSlider(title: "Spacing", value: $model.spacing, range: 0...40, defaultValue: 8)
            DialSlider(title: "Corner radius", value: $model.cornerRadius, range: 0...60, defaultValue: 0)
            DialSlider(title: "Outer margin", value: $model.margin, range: 0...40, defaultValue: 0)
        }
    }

    private var backgroundSection: some View {
        VStack(alignment: .leading, spacing: AP.Space.s) {
            Text("Background").font(AP.Font.label).foregroundStyle(AP.Palette.mist)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AP.Space.s) {
                    ForEach(presetBackdrops) { backdrop in
                        ClgSwatchChip(
                            title: backdrop.title,
                            color: swatchColor(backdrop),
                            selected: model.backdrop == backdrop
                        ) {
                            model.backdrop = backdrop
                        }
                    }
                    customColorControl
                }
                .padding(.horizontal, AP.Space.m)
            }
            .padding(.horizontal, -AP.Space.m)
        }
    }

    private var presetBackdrops: [ClgBackdrop] {
        ClgBackdrop.allCases.filter { $0 != .custom }
    }

    private var customColorControl: some View {
        HStack(spacing: 6) {
            ColorPicker("Custom background colour", selection: $model.customColor, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 44, height: 44)
            Text("Custom")
                .font(AP.Font.label)
                .foregroundStyle(model.backdrop == .custom ? AP.Palette.brass : AP.Palette.mist)
                .accessibilityHidden(true)
        }
        .padding(.trailing, AP.Space.s)
        .accessibilityElement(children: .contain)
    }

    private func swatchColor(_ backdrop: ClgBackdrop) -> Color {
        switch backdrop {
        case .black: return Color.black
        case .white: return Color.white
        case .brass: return AP.Palette.brass
        case .graphite: return AP.Palette.graphite
        case .custom: return model.customColor
        }
    }

    @ViewBuilder
    private var exportSection: some View {
        VStack(alignment: .leading, spacing: AP.Space.m) {
            if model.exportItems.isEmpty {
                createButton
                Text("Saved as a JPG, \(exportSizeText) pixels.")
                    .font(AP.Font.caption)
                    .foregroundStyle(AP.Palette.mist)
            } else {
                readyRow
                ExportBar(items: model.exportItems, savedMessage: "Collage saved to your library")
            }
            if let error = model.errorMessage {
                Text(error)
                    .font(AP.Font.callout)
                    .foregroundStyle(AP.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var createButton: some View {
        Button {
            model.selectedCell = nil
            model.isSwapping = false
            Task { await model.export() }
        } label: {
            HStack(spacing: 8) {
                if model.isRendering {
                    ProgressView().tint(AP.Palette.onBrass)
                }
                Text(model.isRendering ? "Creating collage" : "Create collage")
            }
        }
        .buttonStyle(.apPrimaryWide)
        .disabled(model.isRendering || model.layout == nil)
    }

    private var readyRow: some View {
        HStack(spacing: AP.Space.m) {
            if let preview = model.exportPreview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Collage ready").font(AP.Font.headline).foregroundStyle(AP.Palette.paper)
                Text(readyDetail).font(AP.Font.caption).foregroundStyle(AP.Palette.mist)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var exportSizeText: String {
        let size = ClgRenderer.canvasSize(aspect: model.aspect.ratio, longSide: ClgModel.exportLongSide)
        return "\(Int(size.width)) × \(Int(size.height))"
    }

    private var readyDetail: String {
        let bytes = model.exportItems.first?.data.count ?? 0
        return "JPG, \(exportSizeText) px, \(ByteText.string(bytes))"
    }

    // MARK: - Actions

    private func tapCell(_ index: Int) {
        APHaptics.tap()
        if model.isSwapping {
            if let source = model.selectedCell, source != index {
                model.swapCells(source, index)
                model.selectedCell = index
            }
            model.isSwapping = false
        } else {
            model.selectedCell = model.selectedCell == index ? nil : index
        }
    }

    private func loadPicked(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        notice = nil
        await selection.load(items, maxPixel: 3072)
        let fulls: [CGImage] = selection.photos.map { $0.image }
        guard fulls.count >= 2 else {
            notice = fulls.isEmpty
                ? "These photos could not be opened. Choose others."
                : "Choose at least two photos to make a collage."
            if !model.photos.isEmpty { model.errorMessage = notice }
            return
        }
        isPreparing = true
        let prepared: [ClgPhoto] = await Task.detached(priority: .userInitiated) { () -> [ClgPhoto] in
            fulls.prefix(9).map { ClgPhoto(full: $0) }
        }.value
        isPreparing = false
        model.setPhotos(prepared)
        if selection.failedCount > 0 {
            model.errorMessage = selection.failedCount == 1
                ? "One photo could not be opened and was left out."
                : "\(selection.failedCount) photos could not be opened and were left out."
        }
    }

    private func replace(index: Int, with item: PhotosPickerItem) async {
        defer { replaceItem = nil }
        guard let loaded = await PhotoLoader.load(item, maxPixel: 3072) else {
            model.errorMessage = "That photo could not be opened. Choose another."
            return
        }
        let full: CGImage = loaded.image
        let photo: ClgPhoto = await Task.detached(priority: .userInitiated) { () -> ClgPhoto in
            ClgPhoto(full: full)
        }.value
        model.replacePhoto(at: index, with: photo)
        model.errorMessage = nil
    }

    // MARK: - Geometry

    static func fitted(ratio: CGFloat, in box: CGSize) -> CGSize {
        guard box.width > 0, box.height > 0, ratio > 0 else { return .zero }
        if box.width / box.height > ratio {
            return CGSize(width: (box.height * ratio).rounded(.down), height: box.height.rounded(.down))
        }
        return CGSize(width: box.width.rounded(.down), height: (box.width / ratio).rounded(.down))
    }
}
