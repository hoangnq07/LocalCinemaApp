import CoreGraphics
import Foundation
import XCTest
@testable import LocalCinema

final class ServicesAndStorageTests: XCTestCase {
    func testParsesWebDAVPropfindXML() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/dav/Movies/</D:href>
            <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
          </D:response>
          <D:response>
            <D:href>/dav/Movies/4K%20HDR/</D:href>
            <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
          </D:response>
          <D:response>
            <D:href>/dav/Movies/Interstellar.2014.2160p.mkv</D:href>
            <D:propstat><D:prop><D:resourcetype/><D:getcontentlength>4294967296</D:getcontentlength></D:prop></D:propstat>
          </D:response>
          <D:response>
            <D:href>/dav/Movies/Interstellar.2014.2160p.vi.srt</D:href>
            <D:propstat><D:prop><D:resourcetype/><D:getcontentlength>98210</D:getcontentlength></D:prop></D:propstat>
          </D:response>
        </D:multistatus>
        """
        let baseURL = URL(string: "https://nas.local/dav")!
        let entries = WebDAVClient.parsePropfindResponse(Data(xml.utf8), baseURL: baseURL, requestedPath: "/dav/Movies")

        XCTAssertEqual(entries.count, 3)
        XCTAssertTrue(entries[0].isDirectory)
        XCTAssertEqual(entries[0].name, "4K HDR")
        XCTAssertTrue(entries[1].isVideo)
        XCTAssertEqual(entries[1].size, 4_294_967_296)
        XCTAssertTrue(entries[2].isSubtitle)
    }

    func testParsesM3UAndSTRMPlaylists() {
        let m3u = """
        #EXTM3U
        #EXTINF:-1,VTV1 HD
        #EXTVLCOPT:http-user-agent=LocalCinema/2.0
        http://192.168.1.50:8080/live/vtv1.m3u8
        #EXTINF:-1,Movie 4K
        https://cdn.local/film.mp4
        """
        let entries = PlaylistParser.parseM3U(m3u)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].title, "VTV1 HD")
        XCTAssertEqual(entries[0].headers["User-Agent"], "LocalCinema/2.0")
        XCTAssertEqual(entries[1].url.absoluteString, "https://cdn.local/film.mp4")

        let strm = PlaylistParser.parseSTRM("https://nas.local/stream/dune2.mkv\n", fallbackTitle: "Dune 2")
        XCTAssertEqual(strm?.title, "Dune 2")
        XCTAssertEqual(strm?.url.absoluteString, "https://nas.local/stream/dune2.mkv")
    }

    @MainActor
    func testDecodesV13LibraryJSONAndBackupRoundTrip() throws {
        let v13JSON = """
        [
          {
            "id": "11111111-1111-1111-1111-111111111111",
            "title": "Legacy Movie",
            "source": {"remote": {"_0": "http://127.0.0.1:8080/test.mkv"}},
            "favorite": true,
            "position": 120.5,
            "duration": 600.0
          }
        ]
        """
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("LocalCinemaLegacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let indexURL = tempDir.appendingPathComponent("library.json")
        try Data(v13JSON.utf8).write(to: indexURL)

        let library = MediaLibrary(customFolder: tempDir, documentsFolder: nil)
        XCTAssertEqual(library.items.count, 1)
        XCTAssertEqual(library.items.first?.title, "Legacy Movie")
        XCTAssertEqual(library.items.first?.favorite, true)
        XCTAssertEqual(library.items.first?.position, 120.5)

        let backupData = try library.exportBackupJSON()
        let secondDir = FileManager.default.temporaryDirectory.appendingPathComponent("LocalCinemaRestore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: secondDir) }
        let restored = MediaLibrary(customFolder: secondDir, documentsFolder: nil)
        let importedCount = try restored.importBackupJSON(backupData)

        XCTAssertEqual(importedCount, 1)
        XCTAssertEqual(restored.items.first?.title, "Legacy Movie")
        XCTAssertEqual(restored.items.first?.position, 120.5)
    }

    func testMPVDimensionsMatch() {
        XCTAssertTrue(MPVPlayback.dimensionsMatch(osdWidth: 1206, osdHeight: 2622, target: CGSize(width: 1206, height: 2622)))
        XCTAssertTrue(MPVPlayback.dimensionsMatch(osdWidth: 2622, osdHeight: 1206, target: CGSize(width: 2622, height: 1206)))
        XCTAssertFalse(MPVPlayback.dimensionsMatch(osdWidth: 1206, osdHeight: 2622, target: CGSize(width: 2622, height: 1206)))
        XCTAssertFalse(MPVPlayback.dimensionsMatch(osdWidth: 2622, osdHeight: 1206, target: CGSize(width: 1206, height: 2622)))
        XCTAssertFalse(MPVPlayback.dimensionsMatch(osdWidth: 0, osdHeight: 0, target: CGSize(width: 2622, height: 1206)))
        XCTAssertTrue(MPVPlayback.dimensionsMatch(osdWidth: 2616, osdHeight: 1200, target: CGSize(width: 2622, height: 1206)))
    }
}
