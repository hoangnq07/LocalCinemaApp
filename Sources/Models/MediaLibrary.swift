import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class MediaLibrary: ObservableObject {
    nonisolated static let fileExtensions = [
        "mkv", "mp4", "mov", "avi", "webm", "m4v", "ts", "m2ts",
        "mpg", "mpeg", "wmv", "flv", "ogv", "rmvb", "iso"
    ]
    nonisolated static let subtitleExtensions = ["srt", "ass", "ssa", "vtt", "sub"]
    static let fileTypes: [UTType] = [.audiovisualContent, .data]

    @Published private(set) var items: [MediaItem] = []
    @Published var storageError: String?
    @Published private(set) var scrapingProgress: String?

    private let folder: URL
    private let documentsFolder: URL?
    private var indexURL: URL { folder.appendingPathComponent("library.json") }

    init(customFolder: URL? = nil, documentsFolder: URL? = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first) {
        if let customFolder {
            folder = customFolder
        } else {
            folder = URL.applicationSupportDirectory.appendingPathComponent("LocalCinema", isDirectory: true)
        }
        self.documentsFolder = documentsFolder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                let data = try Data(contentsOf: indexURL)
                items = try JSONDecoder().decode([MediaItem].self, from: data)
            }
        } catch {
            storageError = error.localizedDescription
        }
        scanDocumentsFolder()
    }

    // MARK: - Grouped Views

    var recent: [MediaItem] { continueWatching }

    var continueWatching: [MediaItem] {
        items.filter { $0.position > 0 && !$0.isCompleted }
            .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
    }

    var recentlyAdded: [MediaItem] {
        items.sorted { $0.dateAdded > $1.dateAdded }
    }

    var favorites: [MediaItem] {
        items.filter(\.favorite)
    }

    var movies: [MediaItem] {
        items.filter { $0.episodeInfo == nil && $0.metadata?.kind != "tv" }
    }

    var seriesGroups: [SeriesGroup] {
        let episodic = items.filter { $0.episodeInfo != nil || $0.metadata?.kind == "tv" }
        var buckets: [String: [MediaItem]] = [:]
        for item in episodic {
            let key = (item.metadata?.title ?? item.episodeInfo?.seriesTitle ?? item.title)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            buckets[key, default: []].append(item)
        }

        return buckets.map { key, groupItems in
            let sortedEpisodes = groupItems.sorted { lhs, rhs in
                let ls = lhs.episodeInfo?.season ?? 1
                let rs = rhs.episodeInfo?.season ?? 1
                if ls != rs { return ls < rs }
                let le = lhs.episodeInfo?.episode ?? 0
                let re = rhs.episodeInfo?.episode ?? 0
                if le != re { return le < re }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            var seasonMap: [Int: [MediaItem]] = [:]
            for ep in sortedEpisodes {
                seasonMap[ep.episodeInfo?.season ?? 1, default: []].append(ep)
            }
            let orderedSeasons = seasonMap.keys.sorted()
            let rep = sortedEpisodes.first { $0.metadata != nil } ?? sortedEpisodes[0]
            let title = rep.metadata?.title ?? rep.episodeInfo?.seriesTitle ?? rep.title
            let latest = sortedEpisodes.sorted { ($0.lastPlayed ?? $0.dateAdded) > ($1.lastPlayed ?? $1.dateAdded) }.first ?? rep
            let unwatched = sortedEpisodes.filter { !$0.isCompleted }.count
            return SeriesGroup(
                id: key,
                title: title,
                seasons: seasonMap,
                orderedSeasons: orderedSeasons,
                episodes: sortedEpisodes,
                metadata: rep.metadata,
                latestItem: latest,
                unwatchedCount: unwatched,
                isFavorite: sortedEpisodes.contains(where: \.favorite)
            )
        }
        .sorted { $0.latestItem.dateAdded > $1.latestItem.dateAdded }
    }

    var allGenres: [String] {
        let genres = items.flatMap { $0.metadata?.genres ?? [] }
        return Array(Set(genres)).sorted()
    }

    func item(_ id: UUID) -> MediaItem? {
        items.first { $0.id == id }
    }

    func url(for item: MediaItem) -> URL? {
        switch item.source {
        case .remote(let url), .remoteAuth(let url, _):
            return url
        case .file(let filename):
            if filename.hasPrefix("Documents/"), let docs = documentsFolder {
                let relative = String(filename.dropFirst("Documents/".count))
                return docs.appendingPathComponent(relative)
            }
            return folder.appendingPathComponent(filename)
        case .smb, .webdav, .mediaServer, .plex:
            return nil
        }
    }

    func nextEpisode(after item: MediaItem) -> MediaItem? {
        guard let info = item.episodeInfo else { return nil }
        let key = (item.metadata?.title ?? info.seriesTitle).lowercased()
        guard let group = seriesGroups.first(where: { $0.id == key }) else { return nil }
        guard let idx = group.episodes.firstIndex(where: { $0.id == item.id }),
              idx + 1 < group.episodes.count else { return nil }
        return group.episodes[idx + 1]
    }

    // MARK: - Adding & Scanning Items

    @discardableResult
    func addLink(_ url: URL, title: String, headers: [String: String] = [:]) -> MediaItem? {
        let source: MediaSource = headers.isEmpty ? .remote(url) : .remoteAuth(url, headers: headers)
        if let existing = items.first(where: { $0.source == source }) { return existing }
        let parsed = FilenameParser.parse(title.isEmpty ? Self.guessTitle(url) : title)
        let entry = MediaItem(
            title: title.isEmpty ? parsed.cleanTitle : title,
            source: source,
            mediaInfo: parsed.technicalInfo,
            episodeInfo: parsed.episodeInfo
        )
        return write([entry] + items) ? entry : nil
    }

    @discardableResult
    func addSMB(_ location: SMBMediaLocation, fileSize: Int64? = nil, sidecars: [String] = []) -> MediaItem? {
        let source = MediaSource.smb(location)
        if let existing = items.first(where: { $0.source == source }) { return existing }
        let parsed = FilenameParser.parse(location.path, fileSize: fileSize, sidecars: sidecars)
        let entry = MediaItem(
            title: parsed.cleanTitle,
            source: source,
            mediaInfo: parsed.technicalInfo,
            episodeInfo: parsed.episodeInfo
        )
        return write([entry] + items) ? entry : nil
    }

    @discardableResult
    func addWebDAV(_ location: WebDAVMediaLocation, fileSize: Int64? = nil, sidecars: [String] = []) -> MediaItem? {
        let source = MediaSource.webdav(location)
        if let existing = items.first(where: { $0.source == source }) { return existing }
        let parsed = FilenameParser.parse(location.path, fileSize: fileSize, sidecars: sidecars)
        let entry = MediaItem(
            title: parsed.cleanTitle,
            source: source,
            mediaInfo: parsed.technicalInfo,
            episodeInfo: parsed.episodeInfo
        )
        return write([entry] + items) ? entry : nil
    }

    @discardableResult
    func addMediaServerItem(
        _ location: MediaServerMediaLocation,
        title: String,
        metadata: MovieMetadata?,
        episodeInfo: EpisodeInfo?,
        mediaInfo: MediaTechnicalInfo?,
        position: Double = 0,
        duration: Double = 0,
        watched: Bool = false
    ) -> MediaItem? {
        let source = MediaSource.mediaServer(location)
        if let existing = items.first(where: { $0.source == source }) { return existing }
        let entry = MediaItem(
            title: title,
            source: source,
            metadata: metadata,
            watched: watched,
            position: position,
            duration: duration,
            mediaInfo: mediaInfo,
            episodeInfo: episodeInfo
        )
        return write([entry] + items) ? entry : nil
    }

    @discardableResult
    func addPlexItem(
        _ location: PlexMediaLocation,
        title: String,
        metadata: MovieMetadata?,
        episodeInfo: EpisodeInfo?,
        mediaInfo: MediaTechnicalInfo?,
        position: Double = 0,
        duration: Double = 0,
        watched: Bool = false
    ) -> MediaItem? {
        let source = MediaSource.plex(location)
        if let existing = items.first(where: { $0.source == source }) { return existing }
        let entry = MediaItem(
            title: title,
            source: source,
            metadata: metadata,
            watched: watched,
            position: position,
            duration: duration,
            mediaInfo: mediaInfo,
            episodeInfo: episodeInfo
        )
        return write([entry] + items) ? entry : nil
    }

    @discardableResult
    func batchAdd(_ newEntries: [MediaItem]) -> Int {
        var added = 0
        var updated = items
        for entry in newEntries {
            if !updated.contains(where: { $0.source == entry.source }) {
                updated.insert(entry, at: 0)
                added += 1
            }
        }
        if added > 0 {
            _ = write(updated)
        }
        return added
    }

    func importFile(_ source: URL) async throws {
        let suffix = source.pathExtension.lowercased()
        guard Self.fileExtensions.contains(suffix) else { throw ImportError.unsupported }

        let id = UUID()
        let filename = "\(id.uuidString).\(suffix)"
        let destination = folder.appendingPathComponent(filename)
        let attrs = try await Task.detached(priority: .userInitiated) { () -> Int64? in
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }

            var coordinationError: NSError?
            var copyError: Error?
            var sizeValue: Int64?
            NSFileCoordinator().coordinate(readingItemAt: source, error: &coordinationError) { readable in
                do {
                    try FileManager.default.copyItem(at: readable, to: destination)
                    var localFile = destination
                    var values = URLResourceValues()
                    values.isExcludedFromBackup = true
                    try? localFile.setResourceValues(values)
                    let attr = try? FileManager.default.attributesOfItem(atPath: destination.path)
                    sizeValue = (attr?[.size] as? NSNumber)?.int64Value
                } catch {
                    copyError = error
                }
            }
            if let error = coordinationError { throw error }
            if let error = copyError { throw error }
            return sizeValue
        }.value

        let parsed = FilenameParser.parse(source.lastPathComponent, fileSize: attrs)
        let entry = MediaItem(
            id: id,
            title: parsed.cleanTitle,
            source: .file(filename),
            mediaInfo: parsed.technicalInfo,
            episodeInfo: parsed.episodeInfo
        )
        if !write([entry] + items) {
            try? FileManager.default.removeItem(at: destination)
        }
    }

    func scanDocumentsFolder() {
        guard let docs = documentsFolder,
              let enumerator = FileManager.default.enumerator(
                at: docs,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
              ) else { return }

        var discovered: [MediaItem] = []
        while let fileURL = enumerator.nextObject() as? URL {
            let ext = fileURL.pathExtension.lowercased()
            guard Self.fileExtensions.contains(ext) else { continue }
            let relative = fileURL.path.replacingOccurrences(of: docs.path + "/", with: "")
            let source = MediaSource.file("Documents/" + relative)
            guard !items.contains(where: { $0.source == source }) else { continue }
            let vals = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
            let size = vals?.fileSize.map(Int64.init)
            let parsed = FilenameParser.parse(fileURL.lastPathComponent, fileSize: size)
            discovered.append(MediaItem(
                title: parsed.cleanTitle,
                source: source,
                mediaInfo: parsed.technicalInfo,
                episodeInfo: parsed.episodeInfo
            ))
        }
        if !discovered.isEmpty {
            _ = write(discovered + items)
        }
    }

    // MARK: - Mutations & Persistence

    func toggleFavorite(_ id: UUID) {
        update(id) { $0.favorite.toggle() }
    }

    func toggleWatched(_ id: UUID) {
        update(id) { item in
            item.watched.toggle()
            if !item.watched && item.progress >= 0.95 {
                item.position = 0
            }
        }
    }

    func resetProgress(_ id: UUID) {
        update(id) {
            $0.position = 0
            $0.watched = false
        }
    }

    func setMetadata(_ id: UUID, value: MovieMetadata?) {
        update(id) { $0.metadata = value }
    }

    func updateTechnicalInfo(_ id: UUID, width: Int?, height: Int?, audio: String?) {
        update(id) { item in
            var info = item.mediaInfo ?? MediaTechnicalInfo()
            if let width, width > 0 { info.width = width }
            if let height, height > 0 { info.height = height }
            if let width, let height, width > 0 {
                if width >= 3800 || height >= 2100 { info.resolutionLabel = "4K" }
                else if width >= 1900 || height >= 1000 { info.resolutionLabel = "1080p" }
                else if width >= 1200 || height >= 700 { info.resolutionLabel = "720p" }
            }
            if let audio, !audio.isEmpty { info.audioLabel = audio }
            item.mediaInfo = info
        }
    }

    func markPlayed(_ id: UUID, position: Double, duration: Double) {
        guard position.isFinite, position >= 0, duration.isFinite, duration > 0 else { return }
        update(id) {
            $0.position = min(position, duration)
            $0.duration = duration
            $0.lastPlayed = .now
            if $0.position / duration >= 0.95 {
                $0.watched = true
            }
        }
    }

    func remove(_ item: MediaItem) {
        guard write(items.filter { $0.id != item.id }) else { return }
        if case .file(let filename) = item.source, !filename.hasPrefix("Documents/"), let url = url(for: item) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Auto TMDB Scraping

    func autoScrapeUnmatched(token: String) async -> Int {
        let unmatched = items.filter { $0.metadata == nil }
        guard !unmatched.isEmpty else { return 0 }
        var updatedCount = 0
        for (index, item) in unmatched.enumerated() {
            scrapingProgress = "Đang khớp \(index + 1)/\(unmatched.count)…"
            do {
                let candidates = try await TMDB.search(item.metadataQuery, token: token)
                if let first = candidates.first {
                    let detailed = (try? await TMDB.fetchDetails(id: first.id, kind: first.kind, token: token)) ?? first
                    setMetadata(item.id, value: detailed)
                    updatedCount += 1
                }
            } catch {
                continue
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        scrapingProgress = nil
        return updatedCount
    }

    // MARK: - Sideload-Safe JSON Backup & Restore

    struct LibraryBackupPayload: Codable {
        let version: Int
        let exportedAt: Date
        let items: [MediaItem]
    }

    func exportBackupJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(LibraryBackupPayload(version: 2, exportedAt: Date(), items: items))
    }

    @discardableResult
    func importBackupJSON(_ data: Data) throws -> Int {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let incoming: [MediaItem]
        if let payload = try? decoder.decode(LibraryBackupPayload.self, from: data) {
            incoming = payload.items
        } else {
            incoming = try decoder.decode([MediaItem].self, from: data)
        }

        var merged = items
        var importedCount = 0
        for entry in incoming {
            if let existingIdx = merged.firstIndex(where: { $0.source == entry.source || $0.id == entry.id }) {
                var current = merged[existingIdx]
                if entry.position > current.position {
                    current.position = entry.position
                    current.duration = max(current.duration, entry.duration)
                    current.lastPlayed = entry.lastPlayed ?? current.lastPlayed
                }
                current.favorite = current.favorite || entry.favorite
                current.watched = current.watched || entry.watched
                if current.metadata == nil { current.metadata = entry.metadata }
                merged[existingIdx] = current
                importedCount += 1
            } else {
                merged.append(entry)
                importedCount += 1
            }
        }
        if write(merged) {
            return importedCount
        }
        return 0
    }

    // MARK: - URL Helpers

    static func resolveLink(_ raw: String, server: String) -> URL? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.hasPrefix("/"), !input.hasPrefix("//"), let base = httpURL(server) {
            return URL(string: input, relativeTo: base)?.absoluteURL
        }
        return httpURL(input)
    }

    static func httpURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    private func update(_ id: UUID, change: (inout MediaItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var replacement = items
        change(&replacement[index])
        _ = write(replacement)
    }

    @discardableResult
    private func write(_ updated: [MediaItem]) -> Bool {
        do {
            try JSONEncoder().encode(updated).write(to: indexURL, options: .atomic)
            items = updated
            return true
        } catch {
            storageError = error.localizedDescription
            return false
        }
    }

    private static func guessTitle(_ url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        let readable = name.replacingOccurrences(of: "[._]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return readable.isEmpty ? (url.host ?? "Video") : readable
    }

    private enum ImportError: LocalizedError {
        case unsupported
        var errorDescription: String? { "Định dạng tệp này chưa được hỗ trợ." }
    }
}
