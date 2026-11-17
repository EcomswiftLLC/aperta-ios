import SwiftUI
import UIKit

// Shared pieces for the batch tools (Compress, Resize, Convert): small thumbnails, a list row and size wording.

/// Small thumbnails for photo lists, made once in the background so a list of large photos stays light in memory.
@MainActor
final class PhotoListThumbnails: ObservableObject {
    @Published private(set) var images: [UUID: UIImage] = [:]

    func prepare(_ photos: [LoadedPhoto], maxPixel: Int = 168) async {
        let keep: Set<UUID> = Set(photos.map { $0.id })
        images = images.filter { keep.contains($0.key) }
        let missing: [LoadedPhoto] = photos.filter { images[$0.id] == nil }
        for photo in missing {
            let source: CGImage = photo.image
            let limit: Int = maxPixel
            let small: CGImage? = await Task.detached(priority: .utility) { () -> CGImage? in
                ImageCodec.scaled(source, maxPixel: limit)
            }.value
            if Task.isCancelled { return }
            if let small {
                images[photo.id] = UIImage(cgImage: small)
            }
        }
    }
}

/// One photo in a tool's list: thumbnail, name, a detail line and an optional result line.
struct PhotoListRow: View {
    enum Tone { case neutral, good, warning }

    let thumbnail: UIImage?
    let title: String
    let detail: String
    var result: String? = nil
    var tone: Tone = .neutral
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: AP.Space.m) {
            thumbnailView
            textBlock
            Spacer(minLength: 0)
            removeButton
        }
        .padding(.vertical, AP.Space.s + 2)
    }

    private var thumbnailView: some View {
        ZStack {
            Rectangle().fill(AP.Palette.graphite)
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView().tint(AP.Palette.mist)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: AP.Radius.chip, style: .continuous))
        .accessibilityHidden(true)
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(AP.Font.body)
                .foregroundStyle(AP.Palette.paper)
                .lineLimit(1)
            Text(detail)
                .font(AP.Font.caption)
                .foregroundStyle(AP.Palette.mist)
                .fixedSize(horizontal: false, vertical: true)
            if let result {
                Text(result)
                    .font(AP.Font.label)
                    .foregroundStyle(resultColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var removeButton: some View {
        if let onRemove {
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(AP.Font.label)
                    .foregroundStyle(AP.Palette.mist)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Remove \(title)"))
        }
    }

    private var resultColor: Color {
        switch tone {
        case .neutral: return AP.Palette.paper
        case .good: return AP.Palette.brass
        case .warning: return AP.Palette.danger
        }
    }
}

/// Plain wording for file size changes, shared by the batch tools.
enum PhotoListText {
    /// "4.2 MB to 780 KB, 81% smaller"
    static func sizeChange(from before: Int, to after: Int) -> String {
        let base = "\(ByteText.string(before)) to \(ByteText.string(after))"
        guard before > 0 else { return base }
        let change: Int = Int(((1 - Double(after) / Double(before)) * 100).rounded())
        if change > 0 { return base + ", \(change)% smaller" }
        if change < 0 { return base + ", \(-change)% larger" }
        return base + ", about the same size"
    }

    /// "4032 × 3024"
    static func pixels(_ size: CGSize) -> String {
        "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
    }

    static func photoCount(_ count: Int) -> String {
        count == 1 ? "1 photo" : "\(count) photos"
    }
}
