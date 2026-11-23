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

        app.buttons["Liên kết"].tap()
        let link = app.textFields["https://… hoặc /stream/…"]
        XCTAssertTrue(link.waitForExistence(timeout: 8))
        link.tap()
        link.typeText("http://127.0.0.1:8712/surround.mkv")
        let title = app.textFields["Tên hiển thị (tùy chọn)"]
        title.tap()
        title.typeText("MKV Smoke")
        app.buttons["Thêm"].tap()
        let card = app.buttons["media-item-MKV Smoke"]
        XCTAssertTrue(card.waitForExistence(timeout: 12))
        card.tap()
        let play = app.buttons["movie-details-play"]
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
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testBrowseAndPlayAuthenticatedSMB() {
        let app = XCUIApplication()
        app.launch()
        let sources = app.buttons["Nguồn SMB"]
        XCTAssertTrue(sources.waitForExistence(timeout: 15))
        sources.tap()

        let address = app.textFields["smb-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 8))
        address.tap()
        address.typeText("smb://127.0.0.1:1445/MOVIES")
        let user = app.textFields["smb-user"]
        user.tap()
        user.typeText("cinema")
        let password = app.secureTextFields["smb-password"]
        password.tap()
        password.typeText("cinema-test")
        app.buttons["Kết nối"].tap()

        let folder = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Danh mục")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 20), app.debugDescription)
        folder.tap()
        let video = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "surround.mkv")).firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 10), app.debugDescription)
        attachScreenshot("SMB folder")
        video.tap()

        let videoSize = app.staticTexts["320 × 180"]
        XCTAssertTrue(videoSize.waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertTrue(app.buttons["Âm thanh"].exists)
        attachScreenshot("SMB MKV playback")
        let advanced = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "0:(0[4-9]|1[0-2]) / 0:12"))
            .firstMatch
        XCTAssertTrue(advanced.waitForExistence(timeout: 12), app.debugDescription)
        let pause = app.buttons["Tạm dừng"]
        if pause.exists { pause.tap() }
        app.buttons["Lùi 10 giây"].tap()
        let rewound = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "0:0[0-3] / 0:12"))
            .firstMatch
        XCTAssertTrue(rewound.waitForExistence(timeout: 8), app.debugDescription)
    }
}
