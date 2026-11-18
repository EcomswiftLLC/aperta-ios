import SwiftUI

extension View {
    /// On iPad, keeps reading content a comfortable width and centred. On iPhone it changes nothing.
    func readableWidth(_ width: CGFloat = 680) -> some View {
        frame(maxWidth: width).frame(maxWidth: .infinity)
    }
}

/// Common frame for the tool screens (Compress, Resize, Convert, ...): scrolling content on the app background,
/// a headline, and an inline navigation title. Put the tool's own controls inside `content`.
struct ToolScreen<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AP.Space.l) {
                ToolHeader(title: title, subtitle: subtitle)
                content()
            }
            .padding(.horizontal, AP.Space.m)
            .padding(.top, AP.Space.s)
            .padding(.bottom, AP.Space.xxl)
            .readableWidth()
        }
        .scrollIndicators(.hidden)
        .apScreen()
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}

/// Dashed-outline area that invites the person to pick photos. Wrap it in a `PhotosPicker`.
struct PickPhotosPrompt: View {
    let title: String
    let detail: String
    var systemImage: String = "photo.on.rectangle.angled"

    var body: some View {
        VStack(spacing: AP.Space.s) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(AP.Palette.brass)
            Text(title).font(AP.Font.headline).foregroundStyle(AP.Palette.paper)
            Text(detail).font(AP.Font.callout).foregroundStyle(AP.Palette.mist).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AP.Space.xl)
        .padding(.horizontal, AP.Space.m)
        .overlay(
            RoundedRectangle(cornerRadius: AP.Radius.panel, style: .continuous)
                .strokeBorder(AP.Palette.paper.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
        )
        .contentShape(Rectangle())
    }
}
