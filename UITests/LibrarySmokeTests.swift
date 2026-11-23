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

        app.buttons["quick-link"].tap()
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

        let activeAI = app.staticTexts["FSRCNNX ×2 đang chạy"]
        XCTAssertTrue(activeAI.waitForExistence(timeout: 15), app.debugDescription)

        let sdrToHDRBtn = app.buttons["sdr-to-hdr-cinema"]
        XCTAssertTrue(sdrToHDRBtn.waitForExistence(timeout: 4), app.debugDescription)
        sdrToHDRBtn.tap()
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "SDR → HDR"))
                .firstMatch.waitForExistence(timeout: 8),
            app.debugDescription
        )

        let interpBtn = app.buttons["interp-cinema"]
        XCTAssertTrue(interpBtn.waitForExistence(timeout: 4), app.debugDescription)
        interpBtn.tap()
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Nội suy ·"))
                .firstMatch.waitForExistence(timeout: 8),
            app.debugDescription
        )

        app.buttons["Đóng ngăn kéo"].tap()
        app.buttons["player-stats-toggle"].tap()
        let statsHeader = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Stats for Nerds")).firstMatch
        XCTAssertTrue(statsHeader.waitForExistence(timeout: 6), app.debugDescription)
        let statsAI = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "FSRCNNX ×2")).firstMatch
        XCTAssertTrue(statsAI.waitForExistence(timeout: 6), app.debugDescription)
        attachScreenshot("Pro Player Icon HUD AI")

        // Verify Landscape rotation resizes live libmpv osd-dimensions cleanly and toggles back to Portrait
        app.buttons["player-stats-toggle"].tap()
        let rotateBtn = app.buttons["player-rotate-toggle"]
        XCTAssertTrue(rotateBtn.waitForExistence(timeout: 6), app.debugDescription)
        rotateBtn.tap()
        XCTAssertTrue(
            waitForDimensions(of: rotateBtn, in: app, timeout: 6.0) { w, h in w > h && w >= 1500 },
            "Expected Landscape osd-dimensions (w > h && w >= 1500), got '\(String(describing: rotateBtn.value))'"
        )
        XCTAssertTrue(videoSize.waitForExistence(timeout: 6), app.debugDescription)
        attachScreenshot("Landscape Player")
        if !rotateBtn.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(rotateBtn.waitForExistence(timeout: 6))
        rotateBtn.tap()
        XCTAssertTrue(
            waitForDimensions(of: rotateBtn, in: app, timeout: 6.0) { w, h in h > w && h >= 1500 },
            "Expected Portrait osd-dimensions (h > w && h >= 1500), got '\(String(describing: rotateBtn.value))'"
        )
        if !videoDrawer.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }

        // Toggle AI / SDR->HDR / Interpolation back to defaults so subsequent tests start clean
        XCTAssertTrue(videoDrawer.waitForExistence(timeout: 6))
        videoDrawer.tap()
        let lanczosBtn = app.buttons["upscaler-lanczos"]
        XCTAssertTrue(lanczosBtn.waitForExistence(timeout: 6), app.debugDescription)
        lanczosBtn.tap()
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
        XCTAssertTrue(app.staticTexts["Nguồn"].waitForExistence(timeout: 8))
        attachScreenshot("Sources Hub")

        app.buttons["tab-settings"].tap()
        XCTAssertTrue(app.staticTexts["Cài đặt"].waitForExistence(timeout: 8))
        attachScreenshot("Settings")
    }

    func testBrowseAndPlayAuthenticatedSMB() {
        let app = XCUIApplication()
        app.launch()
        let sources = app.buttons["quick-smb"]
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

        let folder = app.buttons["smb-entry-Danh mục"]
        XCTAssertTrue(
            waitUntilHittable(folder, dismissingPasswordPromptIn: app, timeout: 25),
            app.debugDescription
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        dismissPasswordPromptIfPresent(in: app)
        XCTAssertTrue(
            waitUntilHittable(folder, dismissingPasswordPromptIn: app, timeout: 8),
            app.debugDescription
        )
        folder.tap()

        let video = app.buttons["smb-entry-surround.mkv"]
        if !waitUntilHittable(video, dismissingPasswordPromptIn: app, timeout: 8),
           folder.exists && folder.isHittable {
            dismissPasswordPromptIfPresent(in: app)
            folder.tap()
        }
        XCTAssertTrue(
            waitUntilHittable(video, dismissingPasswordPromptIn: app, timeout: 18),
            app.debugDescription
        )
        // Guard against a late iOS Save Password AutoFill sheet appearing right after navigation
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        dismissPasswordPromptIfPresent(in: app)
        XCTAssertTrue(
            waitUntilHittable(video, dismissingPasswordPromptIn: app, timeout: 8),
            app.debugDescription
        )
        attachScreenshot("SMB Folder")
        video.tap()

        let videoSize = app.staticTexts["320 × 180"]
        XCTAssertTrue(videoSize.waitForExistence(timeout: 25), app.debugDescription)
        attachScreenshot("SMB MKV Playback")

        // Verify differently-named folder subtitle (VietSub.srt) was automatically loaded & selected
        let subBtn = app.buttons["player-drawer-sub"]
        XCTAssertTrue(subBtn.waitForExistence(timeout: 6), app.debugDescription)
        subBtn.tap()
        let autoVietSub = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "VietSub")).firstMatch
        XCTAssertTrue(autoVietSub.waitForExistence(timeout: 12), app.debugDescription)
        attachScreenshot("SMB Auto Subtitles")
        app.buttons["Đóng ngăn kéo"].tap()

        let timeReadout = app.buttons["player-time-readout"]
        XCTAssertTrue(timeReadout.waitForExistence(timeout: 8), app.debugDescription)
        expectation(
            for: NSPredicate(format: "label MATCHES %@", "0:(0[4-9]|1[0-9]|2[0-5]) / 0:25"),
            evaluatedWith: timeReadout
        )
        waitForExpectations(timeout: 15)

        let beforeSeconds = parsePlaybackSeconds(timeReadout.label) ?? -1
        XCTAssertGreaterThanOrEqual(beforeSeconds, 4, "Expected >= 4s elapsed, got '\(timeReadout.label)'")

        let pause = app.buttons["Tạm dừng"]
        if pause.exists && pause.isHittable { pause.tap() }
        let rewind = app.buttons["Lùi 10 giây"]
        XCTAssertTrue(rewind.waitForExistence(timeout: 4), app.debugDescription)
        rewind.tap()

        let expectedMax = max(0, beforeSeconds - 3)
        let rewound = NSPredicate { obj, _ in
            guard let el = obj as? XCUIElement,
                  let secs = self.parsePlaybackSeconds(el.label) else { return false }
            return secs <= expectedMax
        }
        expectation(for: rewound, evaluatedWith: timeReadout)
        waitForExpectations(timeout: 8)
    }

    private func dismissPasswordPromptIfPresent(in app: XCUIApplication) {
        let notNow = app.buttons["Not Now"]
        if notNow.exists && notNow.isHittable {
            notNow.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        }
    }

    private func waitUntilHittable(
        _ element: XCUIElement,
        dismissingPasswordPromptIn app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let notNow = app.buttons["Not Now"]
            if notNow.exists && notNow.isHittable {
                notNow.tap()
                RunLoop.current.run(until: Date().addingTimeInterval(0.35))
                continue
            }
            if element.exists && element.isHittable {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        }
        return element.exists && element.isHittable
    }

    private func parseDimensions(_ value: Any?) -> (Int, Int)? {
        guard let str = value as? String else { return nil }
        let parts = str.split(separator: "x").compactMap { part in
            Int(String(part.filter { $0 >= "0" && $0 <= "9" }))
        }
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    private func waitForDimensions(
        of element: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval,
        predicate: (Int, Int) -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            if element.exists, let (w, h) = parseDimensions(element.value), predicate(w, h) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return false
    }

    private func parsePlaybackSeconds(_ label: String) -> Int? {
        let current = label.split(separator: "/").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? label
        let parts = current.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return nil
        }
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
