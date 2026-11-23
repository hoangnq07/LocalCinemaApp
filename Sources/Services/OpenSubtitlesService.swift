import Foundation

struct OpenSubtitleItem: Identifiable, Equatable, Sendable {
    let id: String
    let fileID: Int
    let releaseName: String
    let language: String
    let downloadCount: Int
    let rating: Double
    let hearingImpaired: Bool
}

enum OpenSubtitlesCredential {
    private static let service = "com.local.cinema.opensubtitles"
    private static let account = "api-key"

    static func read() -> String? {
        KeychainStore.read(service: service, account: account)
    }

    @discardableResult
    static func save(_ value: String) -> Bool {
        KeychainStore.write(value, service: service, account: account, deleteIfEmpty: true)
    }
}

enum OpenSubtitlesService {
    static func search(
        query: String,
        tmdbID: Int? = nil,
        languages: String = "vi,en",
        apiKey: String,
        session: URLSession = .shared
    ) async throws -> [OpenSubtitleItem] {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "api.opensubtitles.com"
        comps.path = "/api/v1/subtitles"
        var items = [
            URLQueryItem(name: "languages", value: languages),
            URLQueryItem(name: "order_by", value: "download_count")
        ]
        if let tmdbID {
            items.append(URLQueryItem(name: "tmdb_id", value: String(tmdbID)))
        } else {
            items.append(URLQueryItem(name: "query", value: query))
        }
        comps.queryItems = items
        guard let url = comps.url else { throw OpenSubError.network }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue("LocalCinema v2.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw OpenSubError.network }
        if status == 401 || status == 403 { throw OpenSubError.unauthorized }
        guard status == 200 else { throw OpenSubError.server(status) }

        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        return decoded.data.compactMap { row in
            guard let file = row.attributes.files.first else { return nil }
            return OpenSubtitleItem(
                id: row.id,
                fileID: file.file_id,
                releaseName: row.attributes.release ?? file.file_name ?? query,
                language: row.attributes.language ?? "vi",
                downloadCount: row.attributes.download_count ?? 0,
                rating: row.attributes.ratings ?? 0,
                hearingImpaired: row.attributes.hearing_impaired ?? false
            )
        }
    }

    static func download(fileID: Int, apiKey: String, session: URLSession = .shared) async throws -> URL {
        let endpoint = URL(string: "https://api.opensubtitles.com/api/v1/download")!
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue("LocalCinema v2.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["file_id": fileID])

        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw OpenSubError.network }
        if status == 401 || status == 403 { throw OpenSubError.unauthorized }
        guard status == 200 else { throw OpenSubError.server(status) }

        let decoded = try JSONDecoder().decode(DownloadResponse.self, from: data)
        guard let link = URL(string: decoded.link) else { throw OpenSubError.network }
        let (subData, _) = try await session.data(from: link)
        let subDir = FileManager.default.temporaryDirectory.appendingPathComponent("LocalCinemaSubs", isDirectory: true)
        try? FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let dest = subDir.appendingPathComponent("\(UUID().uuidString).srt")
        try subData.write(to: dest, options: .atomic)
        return dest
    }

    private struct SearchResponse: Decodable {
        let data: [Row]
        struct Row: Decodable {
            let id: String
            let attributes: Attrs
        }
        struct Attrs: Decodable {
            let language: String?
            let release: String?
            let download_count: Int?
            let ratings: Double?
            let hearing_impaired: Bool?
            let files: [FileInfo]
        }
        struct FileInfo: Decodable {
            let file_id: Int
            let file_name: String?
        }
    }

    private struct DownloadResponse: Decodable {
        let link: String
    }

    enum OpenSubError: LocalizedError {
        case unauthorized, network, server(Int)

        var errorDescription: String? {
            switch self {
            case .unauthorized: return "API Key OpenSubtitles không hợp lệ hoặc đã hết hạn."
            case .network: return "Không thể kết nối OpenSubtitles."
            case .server(let code): return "OpenSubtitles trả về lỗi \(code)."
            }
        }
    }
}
