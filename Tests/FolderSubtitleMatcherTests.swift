import Foundation
import XCTest
@testable import LocalCinema

final class FolderSubtitleMatcherTests: XCTestCase {
    func testExactStemMatchesAndPrioritizesVietnamese() {
        let matched = FolderSubtitleMatcher.match(
            videoPath: "/MOVIES/Dune.Part.Two.2024.mkv",
            candidateSubtitlePaths: [
                "/MOVIES/Dune.Part.Two.2024.en.srt",
                "/MOVIES/Dune.Part.Two.2024.vi.srt",
                "/OTHER/Dune.Part.Two.2024.vi.srt"
            ]
        )

        XCTAssertEqual(matched, [
            "/MOVIES/Dune.Part.Two.2024.vi.srt",
            "/MOVIES/Dune.Part.Two.2024.en.srt"
        ])
    }

    func testLoadsDifferentlyNamedSubtitlesInSameFolderAndSubsSubfolder() {
        let matched = FolderSubtitleMatcher.match(
            videoPath: "/Danh mục/surround.mkv",
            candidateSubtitlePaths: [
                "/Danh mục/Subs/English.ass",
                "/Danh mục/VietSub.srt",
                "/Danh mục/Subtitles/Japanese.srt",
                "/OtherFolder/Random.srt"
            ]
        )

        XCTAssertEqual(matched, [
            "/Danh mục/VietSub.srt",
            "/Danh mục/Subs/English.ass",
            "/Danh mục/Subtitles/Japanese.srt"
        ])
    }

    func testIsolatesEpisodesBySeasonAndEpisodeCode() {
        let matched = FolderSubtitleMatcher.match(
            videoPath: "/Series/Severance.S02E02.1080p.mkv",
            candidateSubtitlePaths: [
                "/Series/Severance.S02E01.vi.srt",
                "/Series/Severance.S02E02.en.srt",
                "/Series/Subs/S02E02.VietSub.srt",
                "/Series/Severance.S02E03.vi.srt"
            ]
        )

        XCTAssertEqual(matched, [
            "/Series/Severance.S02E02.en.srt",
            "/Series/Subs/S02E02.VietSub.srt"
        ])
    }

    func testScansRealLocalDirectoryAndSubsFolder() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("LocalCinemaSubTest-\(UUID().uuidString)", isDirectory: true)
        let subsDir = root.appendingPathComponent("Subs", isDirectory: true)
        try fm.createDirectory(at: subsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let videoURL = root.appendingPathComponent("CinemaDemo.mkv")
        let viSubURL = root.appendingPathComponent("VietSub.srt")
        let enSubURL = subsDir.appendingPathComponent("English.ass")

        try Data("video".utf8).write(to: videoURL)
        try Data("1\n00:00:00,000 --> 00:00:02,000\nXin chào\n".utf8).write(to: viSubURL)
        try Data("[Script Info]\n".utf8).write(to: enSubURL)

        let scanned = FolderSubtitleMatcher.scanLocalDirectory(for: videoURL)
        XCTAssertEqual(scanned.map(\.lastPathComponent), ["VietSub.srt", "English.ass"])
    }
}
