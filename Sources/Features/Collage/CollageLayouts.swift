import CoreGraphics

/// A collage layout: cells as normalized rectangles inside the unit square (0...1 on both axes).
/// Cells tile the square exactly, without overlap. Spacing, margin and corner radius are applied later,
/// when the rectangles are stretched to a real canvas (see `ClgRenderer.cellFrames`).
struct CollageLayout: Identifiable, Equatable {
    let id: String
    let name: String
    let rects: [CGRect]

    var count: Int { rects.count }
}

enum CollageLayouts {
    /// Every layout, grouped by the number of photos it holds (2 to 9, at least three each).
    static let all: [CollageLayout] = [
        // Two photos
        rows("2-side", "Side by side", [2]),
        rows("2-stack", "Stacked", [1, 1]),
        columns("2-wide", "Wide and narrow", [1, 1], widths: [2, 1]),
        rows("2-tall", "Large over small", [1, 1], heights: [2, 1]),

        // Three photos
        columns("3-feature", "One large, two small", [1, 2], widths: [2, 1]),
        rows("3-columns", "Three columns", [3]),
        rows("3-rows", "Three rows", [1, 1, 1]),
        rows("3-banner", "Banner over two", [1, 2]),

        // Four photos
        rows("4-grid", "Grid", [2, 2]),
        columns("4-tall", "One tall, three small", [1, 3], widths: [2, 1]),
        rows("4-banner", "Large over three", [1, 3], heights: [2, 1]),
        rows("4-columns", "Four columns", [4]),

        // Five photos
        rows("5-two-three", "Two over three", [2, 3]),
        rows("5-three-two", "Three over two", [3, 2]),
        columns("5-feature", "Feature and four", [1, 2, 2], widths: [2, 1, 1]),
        rows("5-banner", "Large over four", [1, 4], heights: [2, 1]),

        // Six photos
        rows("6-three-two", "Three by two", [3, 3]),
        rows("6-two-three", "Two by three", [2, 2, 2]),
        featureSix(),
        rows("6-cascade", "Cascade", [1, 2, 3]),

        // Seven photos
        rows("7-three-four", "Three over four", [3, 4]),
        rows("7-two-three-two", "Centre row of three", [2, 3, 2]),
        rows("7-feature", "Feature centre", [3, 1, 3], heights: [1, 1.4, 1]),
        columns("7-columns", "Three and four columns", [3, 4]),

        // Eight photos
        rows("8-four-four", "Four by two", [4, 4]),
        rows("8-three-two-three", "Centre row of two", [3, 2, 3]),
        rows("8-two-by-four", "Two by four", [2, 2, 2, 2]),
        rows("8-three-three-two", "Three, three, two", [3, 3, 2]),

        // Nine photos
        rows("9-grid", "Grid", [3, 3, 3]),
        rows("9-feature", "Feature centre", [4, 1, 4], heights: [1, 1.6, 1]),
        rows("9-cascade", "Cascade", [2, 3, 4]),
        rows("9-four-five", "Four over five", [4, 5]),
    ]

    static func forCount(_ count: Int) -> [CollageLayout] {
        all.filter { $0.count == count }
    }

    // MARK: - Builders

    /// Horizontal bands from top to bottom; `counts[i]` equal cells side by side in band `i`.
    static func rows(_ id: String, _ name: String, _ counts: [Int], heights: [CGFloat]? = nil) -> CollageLayout {
        let bands = spans(heights ?? counts.map { _ in CGFloat(1) })
        var rects: [CGRect] = []
        for (band, count) in counts.enumerated() where band < bands.count && count > 0 {
            let y0 = bands[band].start
            let y1 = bands[band].end
            let cells = spans(Array(repeating: CGFloat(1), count: count))
            for cell in cells {
                rects.append(CGRect(x: cell.start, y: y0, width: cell.end - cell.start, height: y1 - y0))
            }
        }
        return CollageLayout(id: id, name: name, rects: rects)
    }

    /// Vertical bands from left to right; `counts[i]` equal cells stacked in band `i`.
    static func columns(_ id: String, _ name: String, _ counts: [Int], widths: [CGFloat]? = nil) -> CollageLayout {
        let bands = spans(widths ?? counts.map { _ in CGFloat(1) })
        var rects: [CGRect] = []
        for (band, count) in counts.enumerated() where band < bands.count && count > 0 {
            let x0 = bands[band].start
            let x1 = bands[band].end
            let cells = spans(Array(repeating: CGFloat(1), count: count))
            for cell in cells {
                rects.append(CGRect(x: x0, y: cell.start, width: x1 - x0, height: cell.end - cell.start))
            }
        }
        return CollageLayout(id: id, name: name, rects: rects)
    }

    /// One large photo top left (two thirds), two on the right, three along the bottom.
    private static func featureSix() -> CollageLayout {
        let a: CGFloat = 1.0 / 3.0
        let b: CGFloat = 2.0 / 3.0
        let rects: [CGRect] = [
            CGRect(x: 0, y: 0, width: b, height: b),
            CGRect(x: b, y: 0, width: 1 - b, height: a),
            CGRect(x: b, y: a, width: 1 - b, height: b - a),
            CGRect(x: 0, y: b, width: a, height: 1 - b),
            CGRect(x: a, y: b, width: b - a, height: 1 - b),
            CGRect(x: b, y: b, width: 1 - b, height: 1 - b),
        ]
        return CollageLayout(id: "6-feature", name: "Large with five", rects: rects)
    }

    /// Splits 0...1 into consecutive spans proportional to `weights`. The last span always ends exactly at 1.
    private static func spans(_ weights: [CGFloat]) -> [(start: CGFloat, end: CGFloat)] {
        let total = weights.reduce(CGFloat(0)) { $0 + max(0, $1) }
        guard total > 0 else { return [] }
        var result: [(start: CGFloat, end: CGFloat)] = []
        var cursor: CGFloat = 0
        for (index, weight) in weights.enumerated() {
            let end: CGFloat = index == weights.count - 1 ? 1 : cursor + max(0, weight) / total
            result.append((start: cursor, end: end))
            cursor = end
        }
        return result
    }

    // MARK: - Verification

    /// True when the cells stay inside the unit square, do not overlap and cover it completely.
    static func isTiling(_ layout: CollageLayout) -> Bool {
        let tolerance: CGFloat = 0.000_01
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1).insetBy(dx: -tolerance, dy: -tolerance)
        var area: CGFloat = 0
        for (i, rect) in layout.rects.enumerated() {
            guard rect.width > 0, rect.height > 0, unit.contains(rect) else { return false }
            area += rect.width * rect.height
            for other in layout.rects[(i + 1)...] {
                let overlap = rect.intersection(other)
                if !overlap.isNull && overlap.width > tolerance && overlap.height > tolerance { return false }
            }
        }
        return abs(area - 1) < 0.0001
    }

    /// Every layout tiles, and every count from 2 to 9 has at least three layouts.
    static var allValid: Bool {
        all.allSatisfy(isTiling) && (2...9).allSatisfy { forCount($0).count >= 3 }
    }
}
