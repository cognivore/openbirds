// XCUITest — scroll to the bottom and tap CLOSE.
//
// The whole typography page scrolls (no sticky chrome). Both the
// [X] at the top of content and the CLOSE button at the bottom of
// content trigger close. This test verifies the bottom path:
// swipe up enough times to reach the bottom of content, then tap
// the CLOSE row, then check that the app terminates after the
// goodbye animation.
//
// Run via `just test-ui-scroll`.

import XCTest

final class ScrollAndCloseTest: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // Sanity check: at scroll-y = 0 (initial state), tapping the
    // [X] in the top-right corner of content should close the app.
    // If this fails, the tap-dispatch / hit-test path is broken
    // independent of the scroll math.
    //
    // Tap dy = 0.16 = ~140 logical px, which is BELOW the iOS
    // status-bar safe area (~50 px) and inside the [X] hit rect.
    // dy < ~0.06 gets intercepted by the system as a
    // UIStatusBarTapAction and never reaches the SwiftUI view.
    func testTopXTapClosesApp() throws {
        let app = XCUIApplication()
        app.launch()
        sleep(3)
        let topX = app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.16))
        topX.tap()
        let exited = waitForApp(app: app, state: .notRunning, timeout: 10)
        XCTAssertTrue(exited, "Expected app to terminate after [X] tap; state was \(app.state.rawValue)")
    }

    func testScrollToBottomThenTapCloseExitsApp() throws {
        let app = XCUIApplication()
        app.launch()

        // Wait for the asynchronously-loaded fonts to register and the
        // first paint to settle.
        sleep(3)

        // Capture the initial state for diagnostic attachment.
        attachScreenshot(app, name: "01-initial")

        // Scroll to the bottom: a series of fast swipe-ups. Each
        // swipeUp travels roughly 0.6 of the screen height, so 8
        // swipes should comfortably reach the bottom of the
        // ~2.5x-viewport-tall content.
        for i in 0..<10 {
            app.swipeUp(velocity: .fast)
            usleep(150_000) // let momentum land between swipes
            if i % 3 == 2 {
                attachScreenshot(app, name: String(format: "02-scroll-%02d", i))
            }
        }

        // Capture the post-scroll state. The CLOSE button should be
        // visible at the bottom of the viewport now.
        attachScreenshot(app, name: "03-bottom")

        // Tap on the CLOSE region (centred at ~85% down the viewport).
        let closeTarget = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        closeTarget.tap()

        // The app plays a Lucile goodbye animation for ~3-4 seconds
        // before exit(0). Wait for it. Note: we cannot screenshot
        // the app once it's dead, so the assertion comes first.
        let exited = waitForApp(app: app, state: .notRunning, timeout: 10)
        XCTAssertTrue(exited, "Expected app to terminate after CLOSE tap; state was \(app.state.rawValue)")
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let ss = app.screenshot()
        let attachment = XCTAttachment(screenshot: ss)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // XCUIApplication.state caches; the official wait API forces a
    // re-poll. Keep both available so we can fall back if the
    // wait API misbehaves on a future Xcode.
    private func waitForApp(app: XCUIApplication, state: XCUIApplication.State, timeout: TimeInterval) -> Bool {
        return app.wait(for: state, timeout: timeout)
    }
}
