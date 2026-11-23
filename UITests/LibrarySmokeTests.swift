import XCTest

final class LibrarySmokeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testObsidianLibraryAndAIVideoEnhancements() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Local Cinema"].waitForExistence(timeout: 15))
        attachScreenshot("Obsidian Home")

        app.buttons["Liên kết"].tap()
        let link = app.textFields["https://… hoặc /stream/…"]
        XCTAssertTrue(link.waitForExistence(timeout: 8))
        link.tap()
        link.typeText("http://127.0.0.1:8712/surround.mkv")
        let title = app.textFields["Tên hiển thị (tùy chọn)"]
        title.tap()
        title.typeText("MKV Smoke")
        app.buttons["Thêm"].tap()

        app.buttons["tab-library"].tap()
        let card = app.buttons["media-item-MKV Smoke"]
        XCTAssertTrue(card.waitForExistence(timeout: 12), app.debugDescription)
        attachScreenshot("Poster Wall Library")
        card.tap()

        let play = app.buttons["movie-details-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 12))
        attachScreenshot("Movie Detail")
        play.tap()

        let videoSize = app.staticTexts["320 × 180"]
        XCTAssertTrue(videoSize.waitForExistence(timeout: 30), app.debugDescription)

        // Open Hình ảnh & AI drawer and test AI FSRCNNX ×2 + SDR->HDR + Frame Interpolation
        let videoDrawer = app.buttons["player-drawer-video"]
        XCTAssertTrue(videoDrawer.waitForExistence(timeout: 8))
        videoDrawer.tap()

        let fsrcnnxBtn = app.buttons["upscaler-aiFSRCNNX"]
        XCTAssertTrue(fsrcnnxBtn.waitForExistence(timeout: 8), app.debugDescription)
        fsrcnnxBtn.tap()

        let resume = app.buttons["Phát"]
        if resume.exists { resume.tap() }

        let activeAI = app.staticTexts["FSRCNNX ×2 đang chạy"]
        XCTAssertTrue(activeAI.waitForExistence(timeout: 15), app.debugDescription)

        let sdrToHDRBtn = app.buttons["sdr-to-hdr-cinema"]
        XCTAssertTrue(sdrToHDRBtn.exists)
        sdrToHDRBtn.tap()
        XCTAssertTrue(app.staticTexts["SDR → HDR"].waitForExistence(timeout: 8), app.debugDescription)

        let interpBtn = app.buttons["interp-cinema"]
        XCTAssertTrue(interpBtn.exists)
        interpBtn.tap()
        XCTAssertTrue(app.staticTexts["Nội suy"].waitForExistence(timeout: 8), app.debugDescription)

        app.buttons["Đóng ngăn kéo"].tap()
        app.buttons["player-stats-toggle"].tap()
        let statsHeader = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Stats for Nerds")).firstMatch
        XCTAssertTrue(statsHeader.waitForExistence(timeout: 6), app.debugDescription)
        attachScreenshot("Pro Player AI HDR Interp")

        // Toggle AI / SDR->HDR / Interpolation back to defaults so subsequent tests start clean
        app.buttons["player-stats-toggle"].tap()
        videoDrawer.tap()
        app.buttons["upscaler-lanczos"].tap()
        app.buttons["sdr-to-hdr-off"].tap()
        app.buttons["interp-off"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: activeAI)
        waitForExpectations(timeout: 8)
        app.buttons["Đóng ngăn kéo"].tap()

        // Verify audio tracks drawer
        app.buttons["player-drawer-audio"].tap()
        let surround = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Surround 5.1")).firstMatch
        let stereo = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Stereo track")).firstMatch
        XCTAssertTrue(surround.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(stereo.exists)
        stereo.tap()
        app.buttons["Đóng ngăn kéo"].tap()

        app.buttons["Đóng trình phát"].tap()
        XCTAssertTrue(app.buttons["tab-sources"].waitForExistence(timeout: 8))
        app.buttons["tab-sources"].tap()
        XCTAssertTrue(app.staticTexts["Nguồn & Máy chủ"].waitForExistence(timeout: 8))
        attachScreenshot("Sources Hub")

        app.buttons["tab-settings"].tap()
        XCTAssertTrue(app.staticTexts["Cài đặt"].waitForExistence(timeout: 8))
        attachScreenshot("Settings")
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

        let passwordOffer = app.sheets["Save Password?"].buttons["Not Now"]
        if passwordOffer.waitForExistence(timeout: 5) { passwordOffer.tap() }

        let hittable = NSPredicate(format: "exists == true AND hittable == true")
        let folder = app.buttons["smb-entry-Danh mục"]
        expectation(for: hittable, evaluatedWith: folder)
        waitForExpectations(timeout: 20)
        folder.tap()
        if passwordOffer.exists { passwordOffer.tap() }
        let video = app.buttons["smb-entry-surround.mkv"]
        expectation(for: hittable, evaluatedWith: video)
        waitForExpectations(timeout: 15)
        attachScreenshot("SMB Folder")
        video.tap()

        let videoSize = app.staticTexts["320 × 180"]
        XCTAssertTrue(videoSize.waitForExistence(timeout: 25), app.debugDescription)
        attachScreenshot("SMB MKV Playback")

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

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
