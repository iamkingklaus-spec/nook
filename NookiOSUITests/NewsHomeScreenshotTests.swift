import XCTest

/// Uses the production app and a disposable RSS library seeded by the CI script.
/// No screenshot launch mode or alternate layout is compiled into NookiOS.
@MainActor
final class NewsHomeScreenshotTests: XCTestCase {
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-hasCompletedWelcome", "YES", "-seenReaderGestureHint", "YES",
            "-seenListTapHint", "YES", "-seenFeedsAddHint", "YES",
            "-seenSyncFolderHint", "YES", "-translateTitlesPromoSeen", "YES",
            "-usesLocalLibrary", "YES", "-autoRefreshEnabled", "NO"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["news.hero"].waitForExistence(timeout: 40))
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        // Images load asynchronously; capture the real app after its layout settles.
        Thread.sleep(forTimeInterval: 5)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }

    func testEditorialSectionsAndScroll() {
        let app = launch()
        capture(app, "01-for-you-top")
        let scroll = app.scrollViews["news.home.scroll"]
        scroll.swipeUp()
        scroll.swipeUp()
        capture(app, "02-horizontal-compact")

        let bar = app.otherElements["news.tabBar"]
        let last = app.buttons["news.lastStory"]
        for _ in 0..<45 {
            if last.exists, last.isHittable, last.frame.maxY <= bar.frame.minY { break }
            scroll.swipeUp()
        }
        XCTAssertTrue(last.isHittable, "The last story must remain reachable")
        XCTAssertLessThanOrEqual(last.frame.maxY, bar.frame.minY, "Tab bar must not cover the last story")
        capture(app, "07-bottom-safe-area")
        app.buttons["news.tab.home"].tap()
        XCTAssertTrue(app.buttons["news.section.world"].waitForExistence(timeout: 10))
        app.buttons["news.section.world"].tap()
        capture(app, "03-world")
        let categories = app.scrollViews["news.categories"]
        let technology = app.buttons["news.section.technology"]
        if !technology.isHittable { categories.swipeLeft() }
        technology.tap()
        capture(app, "04-technology")

        // The four destinations keep their original data/navigation behavior.
        for tab in ["feeds", "starred", "settings", "home"] {
            let button = app.buttons["news.tab." + tab]
            XCTAssertTrue(button.isHittable)
            button.tap()
        }
        XCTAssertTrue(app.buttons["news.hero"].waitForExistence(timeout: 10))
    }

    func testTypographyHero() { capture(launch(), "05-typography-hero") }
    func testDarkMode() { capture(launch(), "06-dark-mode") }
    func testIPad() { capture(launch(), "08-ipad") }
}
