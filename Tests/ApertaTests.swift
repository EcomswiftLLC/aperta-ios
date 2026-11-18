import XCTest
import CoreImage
import UIKit
@testable import Aperta

final class ApertaTests: XCTestCase {
    private func makeImage(width: Int, height: Int) -> CGImage {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.orange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        }
        return image.cgImage!
    }

    func testRewardedPolicyOffersOnlyWithAdAndOutsideGrace() {
        var policy = RewardedPolicy()
        let now = Date()
        XCTAssertFalse(policy.shouldOffer(adReady: false, now: now))
        XCTAssertTrue(policy.shouldOffer(adReady: true, now: now))
        policy.didEarnReward(now: now)
        XCTAssertFalse(policy.shouldOffer(adReady: true, now: now.addingTimeInterval(60)))
        XCTAssertTrue(policy.shouldOffer(adReady: true, now: now.addingTimeInterval(300)))
    }

    func testDefaultEditKeepsSize() {
        let cg = makeImage(width: 200, height: 100)
        let out = EditPipeline.shared.render(source: CIImage(cgImage: cg), mask: nil, state: EditState())
        XCTAssertEqual(out.extent.width, 200, accuracy: 1)
        XCTAssertEqual(out.extent.height, 100, accuracy: 1)
    }

    func testQuarterTurnSwapsSides() {
        let cg = makeImage(width: 200, height: 100)
        var state = EditState()
        state.crop.quarterTurns = 1
        let out = EditPipeline.shared.render(source: CIImage(cgImage: cg), mask: nil, state: state)
        XCTAssertEqual(out.extent.width, 100, accuracy: 1)
        XCTAssertEqual(out.extent.height, 200, accuracy: 1)
    }

    func testStraightenKeepsAspectAndShrinks() {
        let cg = makeImage(width: 400, height: 200)
        var state = EditState()
        state.crop.straighten = 10
        let out = EditPipeline.shared.render(source: CIImage(cgImage: cg), mask: nil, state: state)
        XCTAssertLessThan(out.extent.width, 400)
        XCTAssertEqual(out.extent.width / out.extent.height, 2, accuracy: 0.05)
    }

    func testCropRectCropsPixels() {
        let cg = makeImage(width: 200, height: 100)
        var state = EditState()
        state.crop.rect = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        let out = EditPipeline.shared.render(source: CIImage(cgImage: cg), mask: nil, state: state)
        XCTAssertEqual(out.extent.width, 100, accuracy: 1.5)
    }

    func testEveryFilterRendersToSameSize() {
        let cg = makeImage(width: 120, height: 80)
        let base = CIImage(cgImage: cg)
        for id in FilterID.allCases {
            let out = FilterLibrary.apply(id, to: base, intensity: 80)
            XCTAssertEqual(out.extent.width, 120, accuracy: 1, "\(id.rawValue)")
            XCTAssertNotNil(EditPipeline.shared.cgImage(out), "\(id.rawValue)")
        }
    }

    func testFrameAddsCanvas() {
        let cg = makeImage(width: 200, height: 100)
        var state = EditState()
        state.frame.fit = .square
        let out = EditPipeline.shared.render(source: CIImage(cgImage: cg), mask: nil, state: state)
        XCTAssertEqual(out.extent.width, out.extent.height, accuracy: 1)
    }

    func testEncodeTargetBytes() {
        let cg = makeImage(width: 800, height: 600)
        let result = ImageCodec.encode(cg, format: .jpeg, targetBytes: 20_000)
        XCTAssertNotNil(result)
        XCTAssertLessThanOrEqual(result?.data.count ?? Int.max, 20_000)
    }

    func testCollageLayoutsTile() {
        XCTAssertTrue(CollageLayouts.allValid)
    }

    func testJPEGExportPutsTransparencyOnWhite() throws {
        let size = CGSize(width: 40, height: 40)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let clear = UIGraphicsImageRenderer(size: size, format: format).image { _ in }.cgImage!
        let data = try XCTUnwrap(ImageCodec.encode(clear, format: .jpeg, quality: 0.95))
        let decoded = try XCTUnwrap(PhotoLoader.decode(data, maxPixel: 100))
        let pixel = try XCTUnwrap(decoded.dataProvider?.data)
        let bytes = CFDataGetBytePtr(pixel)!
        XCTAssertGreaterThan(Int(bytes[0]) + Int(bytes[1]) + Int(bytes[2]), 700, "transparent areas must be white in a JPEG")
    }

    func testLazyPhotoKeepsSizeAndDecodesOnDemand() throws {
        let cg = makeImage(width: 900, height: 600)
        let data = try XCTUnwrap(ImageCodec.encode(cg, format: .jpeg, quality: 0.9))
        let lazy = try XCTUnwrap(PhotoLoader.loadLazy(data: data, maxPixel: 300, name: "T"))
        XCTAssertEqual(lazy.pixelSize.width, 300)
        XCTAssertEqual(lazy.pixelSize.height, 200)
        XCTAssertEqual(lazy.image.width, 300)
        XCTAssertEqual(lazy.image.height, 200)
    }

    // MARK: - Pixel helpers

    /// RGBA bytes of an image, row 0 = top row.
    private func rgba(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { buffer in
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return data
    }

    /// Difference between the brightest and darkest red value in a small window around a point.
    private func windowRange(_ image: CGImage, at point: CGPoint, half: Int = 3) -> Int {
        let w = image.width, h = image.height
        let px = rgba(image)
        var lo = 255, hi = 0
        let cx = Int(point.x.rounded()), cy = Int(point.y.rounded())
        for y in max(0, cy - half)...min(h - 1, cy + half) {
            for x in max(0, cx - half)...min(w - 1, cx + half) {
                let value = Int(px[(y * w + x) * 4])
                lo = min(lo, value)
                hi = max(hi, value)
            }
        }
        return hi - lo
    }

    /// Centre of everything in the picture that has fine detail (the checkerboard), or nil.
    private func detailCentre(_ image: CGImage) -> CGPoint? {
        let w = image.width, h = image.height
        let px = rgba(image)
        var sx = 0.0, sy = 0.0, n = 0.0
        for y in 2..<(h - 2) {
            for x in 2..<(w - 2) {
                var lo = 255, hi = 0
                for dy in -2...2 {
                    for dx in -2...2 {
                        let value = Int(px[((y + dy) * w + x + dx) * 4])
                        lo = min(lo, value)
                        hi = max(hi, value)
                    }
                }
                // Only the black and white checkerboard reaches this range; the grey picture, a black fill or a white border
                // next to grey stay at about 128.
                if hi - lo > 170 { sx += Double(x); sy += Double(y); n += 1 }
            }
        }
        return n > 20 ? CGPoint(x: sx / n, y: sy / n) : nil
    }

    /// 200 x 100 grey picture with a 40 x 40 checkerboard whose centre is at (60, 40) from the top left.
    private func makeCheckerSource() -> CGImage {
        let size = CGSize(width: 200, height: 100)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(white: 0.5, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            for row in 0..<10 {
                for col in 0..<10 {
                    ((row + col) % 2 == 0 ? UIColor.black : UIColor.white).setFill()
                    ctx.fill(CGRect(x: 40 + col * 4, y: 20 + row * 4, width: 4, height: 4))
                }
            }
        }
        return image.cgImage!
    }

    private func render(_ source: CGImage, _ state: EditState) throws -> CGImage {
        let ci = EditPipeline.shared.render(source: CIImage(cgImage: source), mask: nil, state: state)
        return try XCTUnwrap(EditPipeline.shared.cgImage(ci))
    }

    // MARK: - Finding 1: blur strokes land on the same pixels whatever crop, turn or frame

    /// Renders the picture without a stroke, finds where the checkerboard ended up, paints a stroke there the way the brush
    /// would (a point on the finished picture, converted to the source) and checks the checkerboard is now smoothed.
    private func assertBlurLandsOnDetail(_ base: EditState, file: StaticString = #filePath, line: UInt = #line) throws {
        let sourceSize = CGSize(width: 200, height: 100)
        let source = makeCheckerSource()
        let before = try render(source, base)
        let centre = try XCTUnwrap(detailCentre(before), "no detail found", file: file, line: line)

        let finished = CGPoint(x: centre.x / CGFloat(before.width), y: centre.y / CGFloat(before.height))
        let onSource = StrokeSpace.sourcePoint(finished, source: sourceSize, crop: base.crop, frame: base.frame)
        XCTAssertEqual(onSource.x, 0.30, accuracy: 0.04, "x on source", file: file, line: line)
        XCTAssertEqual(onSource.y, 0.40, accuracy: 0.04, "y on source", file: file, line: line)

        var blurred = base
        blurred.blurStrength = 100
        blurred.blurs = [BlurStroke(points: [onSource], width: 0.25, mode: .blur)]
        let after = try render(source, blurred)

        XCTAssertEqual(after.width, before.width, file: file, line: line)
        XCTAssertEqual(after.height, before.height, file: file, line: line)
        XCTAssertGreaterThan(windowRange(before, at: centre), 120, "checkerboard should be sharp before", file: file, line: line)
        XCTAssertLessThan(windowRange(after, at: centre), 60, "checkerboard should be blurred after", file: file, line: line)
        // Far from the stroke nothing changes.
        let corner = CGPoint(x: 6, y: 6)
        XCTAssertEqual(windowRange(before, at: corner), windowRange(after, at: corner), file: file, line: line)
    }

    func testBlurLandsOnSameSourcePixelsWithSquareFrame() throws {
        var state = EditState()
        state.frame.fit = .square
        state.frame.blurFill = false
        try assertBlurLandsOnDetail(state)
    }

    func testBlurLandsOnSameSourcePixelsWithCropFrameAndBorder() throws {
        var state = EditState()
        state.crop.rect = CGRect(x: 0.2, y: 0, width: 0.6, height: 1)
        state.frame.fit = .portrait45
        state.frame.blurFill = false
        state.frame.border = 5
        try assertBlurLandsOnDetail(state)
    }

    func testBlurLandsOnSameSourcePixelsWithFlipAndTurn() throws {
        var state = EditState()
        state.crop.flipH = true
        state.crop.quarterTurns = 1
        state.frame.fit = .square
        state.frame.blurFill = false
        try assertBlurLandsOnDetail(state)
    }

    func testBlurLandsOnSameSourcePixelsWithStraightenAndCrop() throws {
        var state = EditState()
        state.crop.straighten = 8
        state.crop.rect = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        try assertBlurLandsOnDetail(state)
    }

    func testStrokeKeepsItsPixelsWhenTheCropChangesAfterPainting() throws {
        let source = makeCheckerSource()
        var state = EditState()
        state.blurStrength = 100
        state.blurs = [BlurStroke(points: [CGPoint(x: 0.30, y: 0.40)], width: 0.25, mode: .blur)]
        // Same stroke, two different crops: the checkerboard is smoothed in both.
        for rect in [CGRect(x: 0, y: 0, width: 1, height: 1), CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.7)] {
            var cropped = state
            cropped.crop.rect = rect
            let out = try render(source, cropped)
            let expected = CGPoint(x: (0.30 - rect.minX) / rect.width * CGFloat(out.width),
                                   y: (0.40 - rect.minY) / rect.height * CGFloat(out.height))
            XCTAssertLessThan(windowRange(out, at: expected), 60)
        }
    }

    func testMaskCoversTheStrokePixels() throws {
        let stroke = BlurStroke(points: [CGPoint(x: 0.25, y: 0.30)], width: 0.2, mode: .blur)
        let mask = try XCTUnwrap(EditPipeline.shared.maskImage(strokes: [stroke], size: CGSize(width: 200, height: 100)))
        let cg = try XCTUnwrap(EditPipeline.shared.cgImage(mask))
        let px = rgba(cg)
        XCTAssertGreaterThan(Int(px[(30 * 200 + 50) * 4]), 200, "stroke centre must be white")
        XCTAssertLessThan(Int(px[(80 * 200 + 150) * 4]), 50, "far away must be black")
    }

    func testStrokeSpaceMapsFramedPointsBackToTheSource() {
        let source = CGSize(width: 200, height: 100)
        let identity = StrokeSpace.sourcePoint(CGPoint(x: 0.25, y: 0.75), source: source, crop: CropState(), frame: FrameState())
        XCTAssertEqual(identity.x, 0.25, accuracy: 0.001)
        XCTAssertEqual(identity.y, 0.75, accuracy: 0.001)

        // Square canvas on a 2:1 picture: the picture fills the middle half of the canvas height.
        var frame = FrameState()
        frame.fit = .square
        let top = StrokeSpace.sourcePoint(CGPoint(x: 0.5, y: 0.25), source: source, crop: CropState(), frame: frame)
        XCTAssertEqual(top.y, 0, accuracy: 0.001)
        let bottom = StrokeSpace.sourcePoint(CGPoint(x: 0.5, y: 0.75), source: source, crop: CropState(), frame: frame)
        XCTAssertEqual(bottom.y, 1, accuracy: 0.001)
        XCTAssertEqual(StrokeSpace.sourceWidth(0.1, source: source, crop: CropState(), frame: frame), 0.2, accuracy: 0.001)

        var crop = CropState()
        crop.rect = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let cropped = StrokeSpace.sourcePoint(CGPoint(x: 0, y: 0.5), source: source, crop: crop, frame: FrameState())
        XCTAssertEqual(cropped.x, 0.5, accuracy: 0.001)

        var flipped = CropState()
        flipped.flipH = true
        let mirrored = StrokeSpace.sourcePoint(CGPoint(x: 0.1, y: 0.2), source: source, crop: flipped, frame: FrameState())
        XCTAssertEqual(mirrored.x, 0.9, accuracy: 0.001)
        XCTAssertEqual(mirrored.y, 0.2, accuracy: 0.001)

        // One quarter turn clockwise sends source (u, v) to (1 - v, u).
        var turned = CropState()
        turned.quarterTurns = 1
        let back = StrokeSpace.sourcePoint(CGPoint(x: 0.9, y: 0.3), source: source, crop: turned, frame: FrameState())
        XCTAssertEqual(back.x, 0.3, accuracy: 0.001)
        XCTAssertEqual(back.y, 0.1, accuracy: 0.001)
    }

    func testBlurStrengthNeverFallsBelowTheFloor() throws {
        XCTAssertGreaterThanOrEqual(EditPipeline.minBlurStrength, 10)
        let source = makeCheckerSource()
        var zero = EditState()
        zero.blurStrength = 0
        zero.blurs = [BlurStroke(points: [CGPoint(x: 0.30, y: 0.40)], width: 0.25, mode: .blur)]
        var floor = zero
        floor.blurStrength = EditPipeline.minBlurStrength
        let atZero = try render(source, zero)
        let atFloor = try render(source, floor)
        let none = try render(source, EditState())
        let centre = CGPoint(x: 60, y: 40)
        XCTAssertEqual(windowRange(atZero, at: centre), windowRange(atFloor, at: centre))
        XCTAssertLessThan(windowRange(atZero, at: centre), windowRange(none, at: centre), "strength 0 must still change the pixels")
    }

    // MARK: - Finding 3: privacy metadata

    private func sampleMetadata() -> [String: Any] {
        [
            kCGImagePropertyGPSDictionary as String: [
                kCGImagePropertyGPSLatitude as String: 48.85, kCGImagePropertyGPSLatitudeRef as String: "N",
                kCGImagePropertyGPSLongitude as String: 2.35, kCGImagePropertyGPSLongitudeRef as String: "E",
            ] as [String: Any],
            kCGImagePropertyIPTCDictionary as String: [
                kCGImagePropertyIPTCCity as String: "Paris",
                kCGImagePropertyIPTCCountryPrimaryLocationName as String: "France",
                kCGImagePropertyIPTCCopyrightNotice as String: "Jane Doe",
            ],
            kCGImagePropertyMakerCanonDictionary as String: ["OwnerName": "Jane Doe"],
            kCGImagePropertyMakerNikonDictionary as String: ["SerialNumber": "123"],
            kCGImagePropertyMakerOlympusDictionary as String: ["SerialNumber": "456"],
            kCGImagePropertyExifAuxDictionary as String: ["SerialNumber": "789", "OwnerName": "Jane Doe"],
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifBodySerialNumber as String: "SN-1",
                kCGImagePropertyExifCameraOwnerName as String: "Jane Doe",
                kCGImagePropertyExifImageUniqueID as String: "unique-id",
                kCGImagePropertyExifUserComment as String: "private note",
                kCGImagePropertyExifDateTimeOriginal as String: "2026:01:02 10:20:30",
            ],
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFMake as String: "Canon",
                kCGImagePropertyTIFFModel as String: "EOS",
                kCGImagePropertyTIFFArtist as String: "Jane Doe",
                kCGImagePropertyTIFFCopyright as String: "(c) Jane",
                kCGImagePropertyTIFFImageDescription as String: "family trip",
            ],
        ]
    }

    func testPrivacySafeRemovesIdentifyingDictionariesAndKeys() throws {
        let safe = ImageCodec.privacySafe(sampleMetadata())
        for key in [
            kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyExifAuxDictionary,
            kCGImagePropertyMakerCanonDictionary, kCGImagePropertyMakerNikonDictionary, kCGImagePropertyMakerOlympusDictionary,
        ] {
            XCTAssertNil(safe[key as String], "\(key) must be removed")
        }
        let exif = try XCTUnwrap(safe[kCGImagePropertyExifDictionary as String] as? [String: Any])
        XCTAssertNil(exif[kCGImagePropertyExifBodySerialNumber as String])
        XCTAssertNil(exif[kCGImagePropertyExifCameraOwnerName as String])
        XCTAssertNil(exif[kCGImagePropertyExifImageUniqueID as String])
        XCTAssertNil(exif[kCGImagePropertyExifUserComment as String])
        XCTAssertNotNil(exif[kCGImagePropertyExifDateTimeOriginal as String], "the date stays")
        let tiff = try XCTUnwrap(safe[kCGImagePropertyTIFFDictionary as String] as? [String: Any])
        XCTAssertNil(tiff[kCGImagePropertyTIFFArtist as String])
        XCTAssertNil(tiff[kCGImagePropertyTIFFCopyright as String])
        XCTAssertNil(tiff[kCGImagePropertyTIFFImageDescription as String])
        XCTAssertNotNil(tiff[kCGImagePropertyTIFFMake as String], "the camera make stays")
        XCTAssertFalse(ImageCodec.containsLocation(safe))
    }

    func testPrivacySafeFileHasNoLocationOrIdentifiersWhenReadBack() throws {
        let image = makeImage(width: 64, height: 48)
        let raw = try XCTUnwrap(ImageCodec.encode(image, format: .jpeg, quality: 0.9, properties: sampleMetadata()))
        let rawProps = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(try XCTUnwrap(CGImageSourceCreateWithData(raw as CFData, nil)), 0, nil) as? [String: Any]
        )
        XCTAssertTrue(ImageCodec.containsLocation(rawProps), "the injected GPS position must be in the unsanitised file")
        XCTAssertTrue(MtdReader.hasLocation(raw))

        let safeData = try XCTUnwrap(ImageCodec.encode(image, format: .jpeg, quality: 0.9, properties: ImageCodec.privacySafe(sampleMetadata())))
        let safeProps = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(try XCTUnwrap(CGImageSourceCreateWithData(safeData as CFData, nil)), 0, nil) as? [String: Any]
        )
        XCTAssertFalse(ImageCodec.containsLocation(safeProps))
        XCTAssertFalse(MtdReader.hasLocation(safeData))
        let aux = safeProps[kCGImagePropertyExifAuxDictionary as String] as? [String: Any]
        XCTAssertNil(aux?["SerialNumber"])
        XCTAssertNil(safeProps[kCGImagePropertyMakerCanonDictionary as String])
        let safeExif = safeProps[kCGImagePropertyExifDictionary as String] as? [String: Any]
        XCTAssertNil(safeExif?[kCGImagePropertyExifBodySerialNumber as String])
        XCTAssertNil(safeExif?[kCGImagePropertyExifImageUniqueID as String])
    }

    func testRemovingLocationAlsoRemovesIPTCPlaceNames() throws {
        let cleaned = MtdCleaner.cleaned(sampleMetadata(), location: true, device: false, all: false)
        XCTAssertNil(cleaned[kCGImagePropertyGPSDictionary as String])
        let iptc = try XCTUnwrap(cleaned[kCGImagePropertyIPTCDictionary as String] as? [String: Any])
        XCTAssertNil(iptc[kCGImagePropertyIPTCCity as String])
        XCTAssertNil(iptc[kCGImagePropertyIPTCCountryPrimaryLocationName as String])
        XCTAssertNotNil(iptc[kCGImagePropertyIPTCCopyrightNotice as String], "only the place goes in a location-only copy")
        XCTAssertFalse(ImageCodec.containsLocation(cleaned))
        let tiff = try XCTUnwrap(cleaned[kCGImagePropertyTIFFDictionary as String] as? [String: Any])
        XCTAssertNotNil(tiff[kCGImagePropertyTIFFMake as String])

        let everything = MtdCleaner.cleaned(sampleMetadata(), location: true, device: true, all: true)
        XCTAssertTrue(everything.isEmpty)

        let deviceOnly = MtdCleaner.cleaned(sampleMetadata(), location: false, device: true, all: false)
        XCTAssertNotNil(deviceOnly[kCGImagePropertyGPSDictionary as String], "the person chose to keep the location")
        XCTAssertTrue(ImageCodec.containsLocation(deviceOnly))
        let exif = try XCTUnwrap(deviceOnly[kCGImagePropertyExifDictionary as String] as? [String: Any])
        XCTAssertNil(exif[kCGImagePropertyExifBodySerialNumber as String])
    }

    func testPlaceRowsListIPTCPlaceNames() {
        let rows = MtdReader.placeRows(sampleMetadata())
        XCTAssertEqual(rows.first { $0.label == "City" }?.value, "Paris")
        XCTAssertEqual(rows.first { $0.label == "Country" }?.value, "France")
        XCTAssertTrue(MtdReader.placeRows([:]).isEmpty)
    }

    // MARK: - Finding 4: a file that cannot be decoded is a failure, never an empty picture

    func testUndecodablePhotoHasNoImage() {
        let broken = LoadedPhoto(lazyData: Data([0, 1, 2, 3]), properties: [:], name: "Broken", pixelSize: CGSize(width: 10, height: 10), maxPixel: 100)
        XCTAssertNil(broken.decodedImage)
        XCTAssertNil(broken.thumbnail(maxPixel: 50))
    }

    // MARK: - Finding 6: sizes are described truthfully

    func testScaledPhotoSaysSoAndNeverCallsItOriginal() throws {
        let data = try XCTUnwrap(ImageCodec.encode(makeImage(width: 900, height: 600), format: .jpeg, quality: 0.9))
        let big = try XCTUnwrap(PhotoLoader.loadLazy(data: data, maxPixel: 300, name: "T"))
        XCTAssertTrue(big.isDownscaled)
        XCTAssertEqual(big.fullPixelSize.width, 900)
        XCTAssertTrue(big.sizeText.contains("scaled down from 900 \u{00D7} 600"), big.sizeText)
        XCTAssertEqual(big.fullSizeChipTitle, "Up to 300 px")

        let small = try XCTUnwrap(PhotoLoader.loadLazy(data: data, maxPixel: 4096, name: "T"))
        XCTAssertFalse(small.isDownscaled)
        XCTAssertEqual(small.sizeText, "900 \u{00D7} 600")
        XCTAssertEqual(small.fullSizeChipTitle, "Full size")
    }

    func testThumbnailIsDecodedSmall() throws {
        let data = try XCTUnwrap(ImageCodec.encode(makeImage(width: 900, height: 600), format: .jpeg, quality: 0.9))
        let photo = try XCTUnwrap(PhotoLoader.loadLazy(data: data, maxPixel: 4096, name: "T"))
        let thumb = try XCTUnwrap(photo.thumbnail(maxPixel: 168))
        XCTAssertLessThanOrEqual(max(thumb.width, thumb.height), 168)
        XCTAssertGreaterThan(max(thumb.width, thumb.height), 100)
    }

    func testFilterCountMatchesTheStoreWording() {
        // The listing says "24 filters": 17 made for Aperta and 7 Apple photo effects, plus the Original entry that is no filter.
        XCTAssertEqual(FilterID.allCases.count, 25)
        XCTAssertEqual(FilterID.allCases.filter { $0 != .original }.count, 24)
    }

    // MARK: - Finding 10 and 16: ad policy

    func testRewardedDecisionWaitsAfterAnEarlyCloseButNeverBlocksForever() {
        var policy = RewardedPolicy()
        let now = Date()
        XCTAssertEqual(policy.decision(adsReady: false, adReady: true, reloadInFlightAfterEarlyClose: true, now: now), .exportNow)
        XCTAssertEqual(policy.decision(adsReady: true, adReady: true, reloadInFlightAfterEarlyClose: false, now: now), .offerAd)
        XCTAssertEqual(policy.decision(adsReady: true, adReady: false, reloadInFlightAfterEarlyClose: false, now: now), .exportNow)
        XCTAssertEqual(policy.decision(adsReady: true, adReady: false, reloadInFlightAfterEarlyClose: true, now: now), .waitForAd)
        XCTAssertEqual(RewardedPolicy.maxWait, 6)
        policy.didEarnReward(now: now)
        XCTAssertEqual(policy.decision(adsReady: true, adReady: false, reloadInFlightAfterEarlyClose: true, now: now.addingTimeInterval(30)), .exportNow)
        XCTAssertEqual(policy.decision(adsReady: true, adReady: true, reloadInFlightAfterEarlyClose: false, now: now.addingTimeInterval(30)), .exportNow)
        XCTAssertEqual(policy.decision(adsReady: true, adReady: true, reloadInFlightAfterEarlyClose: false, now: now.addingTimeInterval(300)), .offerAd)
    }

    func testAdsRequestPolicy() {
        XCTAssertTrue(AdsRequestPolicy.adsReady(canRequestAds: true, sdkReady: true))
        XCTAssertFalse(AdsRequestPolicy.adsReady(canRequestAds: true, sdkReady: false))
        XCTAssertFalse(AdsRequestPolicy.adsReady(canRequestAds: false, sdkReady: true))
        XCTAssertFalse(AdsRequestPolicy.adsReady(canRequestAds: false, sdkReady: false))
        XCTAssertEqual(AdsRequestPolicy.maxContentRating.rawValue, "G")
        XCTAssertNil(AdsRequestPolicy.tagForChildDirectedTreatment)
        XCTAssertNil(AdsRequestPolicy.tagForUnderAgeOfConsent)

        func restart(_ attempted: Bool, _ canRequest: Bool, _ blocked: Bool, _ elapsed: TimeInterval?) -> Bool {
            AdsRequestPolicy.shouldRestartOnActive(
                startAttempted: attempted, canRequestAds: canRequest, blockedByEnvironment: blocked, secondsSinceLastStart: elapsed
            )
        }
        XCTAssertFalse(restart(false, false, true, nil), "never started: nothing to restart")
        XCTAssertFalse(restart(true, true, true, nil), "ads already allowed")
        XCTAssertFalse(restart(true, false, false, nil), "not blocked by the environment")
        XCTAssertTrue(restart(true, false, true, nil))
        XCTAssertFalse(restart(true, false, true, AdsRequestPolicy.restartThrottle - 1))
        XCTAssertTrue(restart(true, false, true, AdsRequestPolicy.restartThrottle))
    }

    func testAdUnitIDNormalisation() {
        XCTAssertNil(AdsConfiguration.normalizedUnitID(nil))
        XCTAssertNil(AdsConfiguration.normalizedUnitID(42))
        XCTAssertNil(AdsConfiguration.normalizedUnitID(""))
        XCTAssertNil(AdsConfiguration.normalizedUnitID("   \n"))
        XCTAssertNil(AdsConfiguration.normalizedUnitID("$(ADMOB_BANNER_UNIT_ID)"))
        XCTAssertNil(AdsConfiguration.normalizedUnitID("${ADMOB_BANNER_UNIT_ID}"))
        XCTAssertEqual(AdsConfiguration.normalizedUnitID("  ca-app-pub-1/2 "), "ca-app-pub-1/2")
        XCTAssertNil(AdsConfiguration.unitID(forKey: "APNoSuchKeyForTests"))
        XCTAssertTrue(AdsConfiguration.testDeviceIdentifiers.isEmpty, "no personal device id may be committed")
    }

    func testBannerSlotLogicRequestsOnlyForRealWidthChanges() {
        var slot = BannerSlotLogic()
        XCTAssertFalse(slot.widthChanged(to: 0))
        XCTAssertTrue(slot.widthChanged(to: 390))
        XCTAssertFalse(slot.widthChanged(to: 390.9), "a sub-point wobble is not a new request")
        XCTAssertFalse(slot.widthChanged(to: 392))
        XCTAssertFalse(slot.widthChanged(to: 390 + BannerSlotLogic.minWidthChange - 1))
        XCTAssertTrue(slot.widthChanged(to: 390 + BannerSlotLogic.minWidthChange), "a rotation or resize is")
        XCTAssertEqual(slot.status, .loading)
        XCTAssertTrue(slot.widthChanged(to: 844))
        XCTAssertEqual(slot.width, 844)
    }

    func testBannerSlotLogicRetriesThenGivesUpAndIgnoresRefreshFailures() {
        var slot = BannerSlotLogic()
        _ = slot.widthChanged(to: 390)
        for _ in 0..<BannerSlotLogic.maxRetries {
            XCTAssertEqual(slot.didFail(), .retry(after: BannerSlotLogic.retryDelay))
        }
        XCTAssertEqual(slot.didFail(), .giveUp)
        XCTAssertFalse(slot.isShowing)

        slot.didReceiveAd()
        XCTAssertTrue(slot.isShowing)
        XCTAssertEqual(slot.didFail(), .ignore, "a failed refresh keeps the ad that is on screen")
        slot.reset()
        XCTAssertEqual(slot.status, .idle)
        XCTAssertEqual(slot.width, 0)
    }

    // MARK: - Finding 12 and 16: print sheets

    func testSheetRectsForTwoByTwoInchOnFourBySix() {
        let photo = CGSize(width: 600, height: 600)
        let sheet = PssSheet.fourBySix.pixelSize
        let rects = PssCompositor.sheetRects(photo: photo, sheet: sheet)
        // 2 x 2 inch at 300 dpi cannot fit two across a 4 inch wide sheet once the margins and cutting gaps are kept.
        XCTAssertEqual(rects.count, 2)
        let bounds = CGRect(origin: .zero, size: sheet)
        for rect in rects {
            XCTAssertTrue(bounds.contains(rect), "\(rect) is outside the sheet")
            XCTAssertEqual(rect.size, photo)
        }
        XCTAssertFalse(rects[0].insetBy(dx: -PssCompositor.sheetGap + 1, dy: -PssCompositor.sheetGap + 1).intersects(rects[1]))
    }

    func testSheetRectsNeverOverlapOrLeaveTheSheet() {
        let cases: [(CGSize, CGSize)] = [
            (PssCompositor.pixels(fromMillimetres: CGSize(width: 35, height: 45)), PssSheet.a4.pixelSize),
            (PssCompositor.pixels(fromMillimetres: CGSize(width: 35, height: 45)), PssSheet.fourBySix.pixelSize),
            (PssCompositor.pixels(fromMillimetres: CGSize(width: 50.8, height: 50.8)), PssSheet.letter.pixelSize),
        ]
        for (photo, sheet) in cases {
            let rects = PssCompositor.sheetRects(photo: photo, sheet: sheet)
            XCTAssertFalse(rects.isEmpty)
            let bounds = CGRect(origin: .zero, size: sheet)
            for (i, a) in rects.enumerated() {
                XCTAssertTrue(bounds.contains(a))
                for b in rects[(i + 1)...] { XCTAssertFalse(a.intersects(b)) }
            }
        }
    }

    func testSheetRectsEmptyWhenPhotoDoesNotFit() {
        XCTAssertTrue(PssCompositor.sheetRects(photo: CGSize(width: 3000, height: 3000), sheet: PssSheet.fourBySix.pixelSize).isEmpty)
        XCTAssertTrue(PssCompositor.sheetRects(photo: .zero, sheet: PssSheet.a4.pixelSize).isEmpty)
    }

    // MARK: - Finding 16: encoding to a target size

    private func noiseImage(side: Int) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        var generator = SystemRandomNumberGenerator()
        for i in 0..<bytes.count { bytes[i] = i % 4 == 3 ? 255 : UInt8.random(in: 0...255, using: &generator) }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    func testEncodeTargetBytesScalesDownWhenQualityAloneIsNotEnough() throws {
        let image = noiseImage(side: 800)
        // 3 KB is far below what 800 x 800 pixels of noise need even at the lowest quality, so the pixels must shrink.
        let result = try XCTUnwrap(ImageCodec.encode(image, format: .jpeg, targetBytes: 3_000))
        XCTAssertLessThan(result.size.width, 800)
        XCTAssertFalse(result.data.isEmpty)
    }

    func testEncodeTargetBytesKeepsPixelsWhenTheTargetIsGenerous() throws {
        let image = makeImage(width: 400, height: 300)
        let result = try XCTUnwrap(ImageCodec.encode(image, format: .jpeg, targetBytes: 5_000_000))
        XCTAssertEqual(result.size.width, 400)
        XCTAssertEqual(result.size.height, 300)
    }

    func testEncodeTargetBytesForPNGIgnoresTheTarget() throws {
        let image = makeImage(width: 120, height: 80)
        let result = try XCTUnwrap(ImageCodec.encode(image, format: .png, targetBytes: 10))
        XCTAssertEqual(result.size.width, 120)
    }

    // MARK: - Finding 15: share files and swatches

    func testShareFilesLiveInOneFolderThatCanBeCleared() throws {
        let item = ExportItem(data: Data([1, 2, 3]), filename: "unit-test-share.jpg", format: .jpeg)
        let url = try XCTUnwrap(item.temporaryURL())
        XCTAssertTrue(url.path.contains("ApertaShare"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        ExportItem.clearShareFolder()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testEverySwatchHasASpokenName() {
        let names = APSwatches.colors.map { APSwatches.name(for: $0) }
        XCTAssertFalse(names.contains("Custom colour"))
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(APSwatches.name(for: 0x123456), "Custom colour")
    }

    func testExportErrorsHaveMessages() {
        for error in [ExportRenderError.cutoutFailed, .renderFailed, .overlaysFailed, .encodeFailed] {
            XCTAssertFalse(error.message.isEmpty)
        }
    }
}
