import Foundation
import XCTest
@testable import LocalCinema

final class FilenameParserTests: XCTestCase {
    func testParses4KDolbyVisionMovieTags() {
        let parsed = FilenameParser.parse("Dune.Part.Two.2024.2160p.BluRay.DV.HEVC.TrueHD.Atmos.7.1.mkv")
        XCTAssertEqual(parsed.cleanTitle, "Dune Part Two")
        XCTAssertEqual(parsed.year, "2024")
        XCTAssertNil(parsed.episodeInfo)
        XCTAssertEqual(parsed.technicalInfo.resolutionLabel, "4K")
        XCTAssertEqual(parsed.technicalInfo.hdrLabel, "Dolby Vision")
        XCTAssertEqual(parsed.technicalInfo.videoCodec, "HEVC")
        XCTAssertEqual(parsed.technicalInfo.audioLabel, "TrueHD Atmos")
    }

    func testParsesStandardSeasonEpisodeNotation() {
        let parsed = FilenameParser.parse("Shogun.2024.S01E04.2160p.HDR10+.EAC3.5.1.mkv")
        XCTAssertEqual(parsed.cleanTitle, "Shogun")
        XCTAssertEqual(parsed.year, "2024")
        XCTAssertEqual(parsed.episodeInfo?.season, 1)
        XCTAssertEqual(parsed.episodeInfo?.episode, 4)
        XCTAssertEqual(parsed.technicalInfo.hdrLabel, "HDR10+")
        XCTAssertEqual(parsed.technicalInfo.audioLabel, "EAC3 5.1")
    }

    func testParsesAlternativeEpisodeFormats() {
        let xNotation = FilenameParser.parse("Severance.2x06.1080p.x264.mkv")
        XCTAssertEqual(xNotation.episodeInfo?.season, 2)
        XCTAssertEqual(xNotation.episodeInfo?.episode, 6)
        XCTAssertEqual(xNotation.technicalInfo.resolutionLabel, "1080p")
        XCTAssertEqual(xNotation.technicalInfo.videoCodec, "H.264")

        let vnNotation = FilenameParser.parse("Phim.Bo.Tap.05.720p.mp4")
        XCTAssertEqual(vnNotation.episodeInfo?.season, 1)
        XCTAssertEqual(vnNotation.episodeInfo?.episode, 5)
        XCTAssertEqual(vnNotation.technicalInfo.resolutionLabel, "720p")
    }

    @MainActor
    func testLibraryGroupsTVEpisodesIntoSeriesGroup() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("LocalCinemaTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let library = MediaLibrary(customFolder: tempDir, documentsFolder: nil)
        library.addLink(URL(string: "http://127.0.0.1/Shogun.S01E01.mkv")!, title: "")
        library.addLink(URL(string: "http://127.0.0.1/Shogun.S01E02.mkv")!, title: "")
        library.addLink(URL(string: "http://127.0.0.1/Shogun.S02E01.mkv")!, title: "")

        XCTAssertEqual(library.seriesGroups.count, 1)
        let group = try XCTUnwrap(library.seriesGroups.first)
        XCTAssertEqual(group.orderedSeasons, [1, 2])
        XCTAssertEqual(group.episodeCount, 3)

        let first = group.episodes[0]
        let next = library.nextEpisode(after: first)
        XCTAssertEqual(next?.episodeInfo?.episode, 2)
    }
}
