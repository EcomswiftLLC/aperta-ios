import SwiftUI
import PhotosUI

enum ApertaTool: String, Hashable, CaseIterable, Identifiable {
    case collage, compress, resize, convert, watermark, passport, metadata

    var id: String { rawValue }

    var title: String {
        switch self {
        case .collage: return "Collage"
        case .compress: return "Compress"
        case .resize: return "Resize"
        case .convert: return "Convert"
        case .watermark: return "Watermark"
        case .passport: return "ID photo"
        case .metadata: return "Photo details"
        }
    }

    var subtitle: String {
        switch self {
        case .collage: return "Combine two to nine photos in a clean layout"
        case .compress: return "Make files smaller, with the quality you choose"
        case .resize: return "Exact sizes, and presets for popular social networks"
        case .convert: return "HEIC, JPG, PNG, or photos to one PDF"
        case .watermark: return "Add your name or logo to many photos at once"
        case .passport: return "Passport and visa photos with a print sheet"
        case .metadata: return "See and remove location and camera details"
        }
    }

    var symbol: String {
        switch self {
        case .collage: return "square.grid.2x2"
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .resize: return "aspectratio"
        case .convert: return "arrow.triangle.2.circlepath"
        case .watermark: return "drop.degreesign"
        case .passport: return "person.text.rectangle"
        case .metadata: return "location.slash"
        }
    }
}

struct EditingSession: Identifiable {
    let id = UUID()
    let photo: LoadedPhoto
    let startTool: EditorTool?
}

struct HomeView: View {
    @State private var path: [ApertaTool] = []
    @State private var pickerShown = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var pendingStartTool: EditorTool?
    @State private var session: EditingSession?
    @State private var loading = false
    @State private var loadFailed = false
    @State private var showSettings = false
    @State private var spun = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: AP.Space.xl) {
                    topBar
                    hero
                    actions
                    toolsList
                    CKInlineBanner()
                }
                .padding(.horizontal, AP.Space.m)
                .padding(.bottom, AP.Space.xl)
                .readableWidth(640)
            }
            .scrollIndicators(.hidden)
            .apScreen()
            .navigationDestination(for: ApertaTool.self) { tool in
                destination(for: tool)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .photosPicker(isPresented: $pickerShown, selection: $pickedItem, matching: .images)
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            Task { await open(item) }
        }
        .fullScreenCover(item: $session) { session in
            EditorView(photo: session.photo, startTool: session.startTool)
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .alert("This photo could not be opened", isPresented: $loadFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Try another photo. If it is stored in iCloud, wait for it to finish downloading.")
        }
        .onAppear {
            if !reduceMotion { withAnimation(.easeOut(duration: 1.6)) { spun = true } } else { spun = true }
        }
    }

    // MARK: Pieces

    private var topBar: some View {
        HStack(spacing: 10) {
            ApertureMark(lineWidth: 1.5)
                .frame(width: 26, height: 26)
            Text("Aperta")
                .font(AP.Font.title(21))
                .foregroundStyle(AP.Palette.paper)
            Spacer()
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(AP.Palette.paper)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(Text("Settings"))
        }
        .padding(.top, AP.Space.s)
    }

    private var hero: some View {
        ZStack(alignment: .topTrailing) {
            ApertureMark(lineWidth: 1, color: AP.Palette.brass.opacity(0.22), openness: 0.22)
                .frame(width: 230, height: 230)
                .rotationEffect(.degrees(spun ? 0 : -70))
                .offset(x: 80, y: -60)
                .clipped()
            VStack(alignment: .leading, spacing: AP.Space.m) {
                Text("Your photos,\nfinished.")
                    .apDisplay(46)
                    .lineSpacing(-2)
                Text("Edit, combine and resize right on your device. Nothing is uploaded.")
                    .font(AP.Font.body)
                    .foregroundStyle(AP.Palette.mist)
                    .frame(maxWidth: 320, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, AP.Space.l)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    private var actions: some View {
        VStack(spacing: AP.Space.s) {
            Button {
                pendingStartTool = nil
                pickerShown = true
            } label: {
                HStack(spacing: 10) {
                    if loading { ProgressView().tint(AP.Palette.onBrass) }
                    Image(systemName: "photo.badge.plus")
                    Text(loading ? "Opening photo" : "Choose a photo")
                }
            }
            .buttonStyle(.apPrimaryWide)
            .disabled(loading)

            Button {
                pendingStartTool = .cutout
                pickerShown = true
            } label: {
                Label("Remove a background", systemImage: "person.crop.circle.dashed")
            }
            .buttonStyle(.apSecondaryWide)
            .disabled(loading)
        }
    }

    private var toolsList: some View {
        VStack(alignment: .leading, spacing: AP.Space.s) {
            APSectionTitle(text: "More tools")
            VStack(spacing: 0) {
                APHairline()
                ForEach(ApertaTool.allCases) { tool in
                    NavigationLink(value: tool) {
                        toolRow(tool)
                    }
                    .buttonStyle(.plain)
                    APHairline()
                }
            }
        }
    }

    private func toolRow(_ tool: ApertaTool) -> some View {
        HStack(spacing: AP.Space.m) {
            Image(systemName: tool.symbol)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(AP.Palette.brass)
                .frame(width: 40, height: 40)
                .overlay(Circle().strokeBorder(AP.Palette.line, lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.title).font(AP.Font.headline).foregroundStyle(AP.Palette.paper)
                Text(tool.subtitle).font(AP.Font.caption).foregroundStyle(AP.Palette.mist).multilineTextAlignment(.leading)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AP.Palette.mist)
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func destination(for tool: ApertaTool) -> some View {
        switch tool {
        case .collage: CollageView()
        case .compress: CompressView()
        case .resize: ResizeView()
        case .convert: ConvertView()
        case .watermark: WatermarkView()
        case .passport: PassportView()
        case .metadata: MetadataView()
        }
    }

    // MARK: Opening a photo

    private func open(_ item: PhotosPickerItem) async {
        loading = true
        defer {
            loading = false
            pickedItem = nil
        }
        guard let photo = await PhotoLoader.load(item, maxPixel: PhotoLoader.editorMaxPixel) else {
            loadFailed = true
            return
        }
        session = EditingSession(photo: photo, startTool: pendingStartTool)
    }
}
