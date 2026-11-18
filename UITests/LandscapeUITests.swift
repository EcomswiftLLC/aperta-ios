import XCTest

/// Opens each screen on an iPad that has been rotated to landscape and saves a screenshot of it.
/// It fails when the app window does not end up wider than it is tall, so a rotation that silently
/// did not happen can never pass as a landscape check. Run by the `ipad-landscape` CI job.
final class LandscapeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    private func check(_ screen: String, settle: TimeInterval = 18, file: StaticString = #filePath, line: UInt = #line) {
        let app = XCUIApplication()
        app.launchArguments = ["-apScreen", screen]
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 30), "No app window for \(screen)", file: file, line: line)

        // Give the rotation a few seconds, then let the screen finish loading its sample documents.
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline, window.frame.width <= window.frame.height {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(settle))

        let frame = window.frame
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "landscape-\(screen)"
        shot.lifetime = .keepAlways
        add(shot)

        XCTAssertGreaterThan(frame.width, frame.height, "\(screen): window is \(Int(frame.width))x\(Int(frame.height)), not landscape", file: file, line: line)
        XCTAssertTrue(app.state == .runningForeground, "\(screen): app left the foreground", file: file, line: line)
        app.terminate()
    }

    func testHome() { check("home", settle: 10) }
    func testOnboarding() { check("onboarding", settle: 10) }
    func testSettings() { check("settings", settle: 10) }
    func testEditorAdjust() { check("editor-adjust", settle: 10) }
    func testEditorFilters() { check("editor-filters", settle: 10) }
    func testEditorCrop() { check("editor-crop", settle: 10) }
    func testEditorText() { check("editor-text", settle: 10) }
    func testEditorDraw() { check("editor-draw", settle: 10) }
    func testCollage() { check("collage", settle: 10) }
    func testCompress() { check("compress", settle: 10) }
    func testResize() { check("resize", settle: 10) }
    func testConvert() { check("convert", settle: 10) }
    func testWatermark() { check("watermark", settle: 10) }
    func testPassport() { check("passport", settle: 10) }
    func testMetadata() { check("metadata", settle: 10) }
}
