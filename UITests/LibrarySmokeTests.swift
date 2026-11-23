import XCTest

final class LibrarySmokeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testLinkLibraryAndMKVTracks() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Local Cinema"].waitForExistence(timeout: 15))
        attachScreenshot("Library")

        app.buttons["Mở liên kết"].tap()
        let link = app.textFields["https://… hoặc /stream/…"]
        XCTAssertTrue(link.waitForExistence(timeout: 8))
        link.tap()
        link.typeText("http://127.0.0.1:8712/surround.mkv")
        let title = app.textFields["Tên hiển thị (tùy chọn)"]
        title.tap()
        title.typeText("MKV Smoke")
        app.buttons["Thêm"].tap()
        let play = app.buttons["Phát phim"]
        XCTAssertTrue(play.waitForExistence(timeout: 12))
        play.tap()

        let videoSize = app.staticTexts["320 × 180"]
        XCTAssertTrue(videoSize.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.buttons["Âm thanh"].exists)
        attachScreenshot("MKV playback")

        app.buttons["Âm thanh"].tap()
        let surround = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Surround 5.1")).firstMatch
        let stereo = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Stereo track")).firstMatch
        XCTAssertTrue(surround.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(stereo.exists)
        stereo.tap()

        let audioMenu = app.buttons["Âm thanh"]
        expectation(for: NSPredicate(format: "value CONTAINS %@", "Stereo track"), evaluatedWith: audioMenu)
        waitForExpectations(timeout: 8)

        let settings = app.buttons["Tùy chọn phát"]
        settings.tap()
        app.buttons["Siêu phân giải FSRCNNX ×2"].tap()
        let active = app.staticTexts["FSRCNNX ×2 đang chạy"]
        XCTAssertTrue(active.waitForExistence(timeout: 15), app.debugDescription)
        attachScreenshot("FSRCNNX active")

        settings.tap()
        app.buttons["Lanczos sắc nét"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: active)
        waitForExpectations(timeout: 8)

        app.buttons["Đóng trình phát"].tap()
        XCTAssertTrue(app.staticTexts["Đang xem"].waitForExistence(timeout: 8))
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
