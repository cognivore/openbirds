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

        // Scroll to the bottom: a series of long, deterministic
        // coordinate drags. `swipeUp(velocity:.fast)` only varies
        // the *speed* of a fixed 0.2-of-viewport finger travel, so
        // its momentum kick is stochastic enough that "10 swipes
        // reach max-y" is true at @1x but borderline at @3x — the
        // taller @3x page has the same fractional reach, but the
        // run-to-run variance in release velocity (jittery sim
        // gesture timing → jittery velocity-window average) is
        // around 1000 fb-px, which becomes a meaningful fraction of
        // the remaining-to-scroll distance at @3x.
        //
        // A coordinate drag from y=0.85 to y=0.05 with a known
        // duration moves the finger a deterministic 0.8 of the
        // viewport in 0.20 s, producing a release velocity that
        // does not depend on the recogniser's internal heuristics.
        // 12 drags at @3x consistently overshoot max-y, then the
        // Holko rubber-band + critically-damped spring pins
        // scroll-y to max-y on release (the page can't scroll past
        // its bottom edge). This makes the resting position
        // deterministic regardless of per-drag momentum jitter:
        // "we definitely reached the end and bounced back" beats
        // "we hopefully scrolled enough" every time.
        for i in 0..<12 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            let end   = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast,
                        thenHoldForDuration: 0.0)
            usleep(350_000) // generous settle so spring-back lands before next drag
            if i % 4 == 3 {
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
