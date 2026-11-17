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
}
