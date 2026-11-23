import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct MediaItem: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    let source: MediaSource
    var metadata: MovieMetadata?
    var favorite = false
    var position = 0.0
    var duration = 0.0
    var lastPlayed: Date?

    init(id: UUID = UUID(), title: String, source: MediaSource) {
        self.id = id
        self.title = title
        self.source = source
    }

    var displayTitle: String { metadata?.title ?? title }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }
}

enum MediaSource: Codable, Equatable, Sendable {
    case remote(URL)
    case file(String)

    var label: String {
        switch self {
        case .remote(let url): return url.host ?? "Liên kết"
        case .file: return "Tệp trên iPhone"
        }
    }

    var format: String? {
        let suffix: String
        switch self {
        case .remote(let url): suffix = url.pathExtension
        case .file(let filename): suffix = URL(fileURLWithPath: filename).pathExtension
        }
        return MediaLibrary.fileExtensions.contains(suffix.lowercased()) ? suffix.uppercased() : nil
    }
}

@MainActor
final class MediaLibrary: ObservableObject {
    nonisolated static let fileExtensions = ["mkv", "mp4", "mov", "avi", "webm", "m4v", "ts", "m2ts", "mpg", "mpeg", "wmv", "flv", "ogv"]
    static let fileTypes = [.audiovisualContent, .data] as [UTType]

    @Published private(set) var items: [MediaItem] = []
    @Published var storageError: String?

    private let folder: URL
    private var indexURL: URL { folder.appendingPathComponent("library.json") }

    init() {
        folder = URL.applicationSupportDirectory.appendingPathComponent("LocalCinema", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                items = try JSONDecoder().decode([MediaItem].self, from: Data(contentsOf: indexURL))
            }
        } catch {
            storageError = error.localizedDescription
        }
    }

    var recent: [MediaItem] {
        items.filter { $0.position > 0 && $0.progress < 0.98 }
            .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
    }

    func item(_ id: UUID) -> MediaItem? { items.first { $0.id == id } }

    func url(for item: MediaItem) -> URL {
        switch item.source {
        case .remote(let url): return url
        case .file(let filename): return folder.appendingPathComponent(filename)
        }
    }

    func addLink(_ url: URL, title: String) -> MediaItem? {
        if let existing = items.first(where: { $0.source == .remote(url) }) { return existing }
        let entry = MediaItem(title: title.isEmpty ? Self.guessTitle(url) : title, source: .remote(url))
        return write([entry] + items) ? entry : nil
    }

    func importFile(_ source: URL) async throws {
        let suffix = source.pathExtension.lowercased()
        guard Self.fileExtensions.contains(suffix) else { throw ImportError.unsupported }

        let id = UUID()
        let filename = "\(id.uuidString).\(suffix)"
        let destination = folder.appendingPathComponent(filename)
        do {
            try await Task.detached(priority: .userInitiated) {
                let scoped = source.startAccessingSecurityScopedResource()
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }

                var coordinationError: NSError?
                var copyError: Error?
                NSFileCoordinator().coordinate(readingItemAt: source, error: &coordinationError) { readable in
                    do {
                        try FileManager.default.copyItem(at: readable, to: destination)
                        var localFile = destination
                        var values = URLResourceValues()
                        values.isExcludedFromBackup = true
                        try? localFile.setResourceValues(values)
                    } catch {
                        copyError = error
                    }
                }
                if let error = coordinationError { throw error }
                if let error = copyError { throw error }
            }.value
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        let entry = MediaItem(id: id, title: Self.guessTitle(source), source: .file(filename))
        if !write([entry] + items) { try? FileManager.default.removeItem(at: destination) }
    }

    func toggleFavorite(_ id: UUID) { update(id) { $0.favorite.toggle() } }
    func setMetadata(_ id: UUID, value: MovieMetadata?) { update(id) { $0.metadata = value } }

    func markPlayed(_ id: UUID, position: Double, duration: Double) {
        guard position.isFinite, position >= 0, duration.isFinite, duration > 0 else { return }
        update(id) {
            $0.position = min(position, duration)
            $0.duration = duration
            $0.lastPlayed = .now
        }
    }

    func remove(_ item: MediaItem) {
        guard write(items.filter { $0.id != item.id }) else { return }
        if case .file = item.source {
            try? FileManager.default.removeItem(at: url(for: item))
        }
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
