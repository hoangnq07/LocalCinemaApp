import Foundation
import Security

struct MovieMetadata: Codable, Equatable, Sendable {
    let id: Int
    let kind: String
    let title: String
    let overview: String
    let year: String?
    let posterPath: String?
    let backdropPath: String?
    let rating: Double?

    var posterURL: URL? { Self.image(posterPath, size: "w342") }
    var backdropURL: URL? { Self.image(backdropPath, size: "w780") }
    var kindLabel: String { kind == "tv" ? "Phim bộ" : "Phim lẻ" }

    private static func image(_ path: String?, size: String) -> URL? {
        guard let path, path.hasPrefix("/") else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size)\(path)")
    }
}

enum TMDB {
    static func search(_ query: String, token: String, session: URLSession = .shared) async throws -> [MovieMetadata] {
        var endpoint = URLComponents()
        endpoint.scheme = "https"
        endpoint.host = "api.themoviedb.org"
        endpoint.path = "/3/search/multi"
        endpoint.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "language", value: "vi-VN"),
            URLQueryItem(name: "include_adult", value: "false")
        ]
        guard let url = endpoint.url else { throw TMDBError.response }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw TMDBError.response }
        if status == 401 || status == 403 { throw TMDBError.token }
        guard status == 200 else { throw TMDBError.response }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Results.self, from: data).results.compactMap(\.metadata)
    }

    private struct Results: Decodable { let results: [ResultItem] }

    private struct ResultItem: Decodable {
        let id: Int
        let mediaType: String
        let title: String?
        let name: String?
        let overview: String?
        let posterPath: String?
        let backdropPath: String?
        let releaseDate: String?
        let firstAirDate: String?
        let voteAverage: Double?

        var metadata: MovieMetadata? {
            guard ["movie", "tv"].contains(mediaType), let title = title ?? name else { return nil }
            let date = releaseDate ?? firstAirDate ?? ""
            return MovieMetadata(
                id: id, kind: mediaType, title: title, overview: overview ?? "",
                year: date.count >= 4 ? String(date.prefix(4)) : nil,
                posterPath: posterPath, backdropPath: backdropPath,
                rating: voteAverage.flatMap { $0 > 0 ? $0 : nil }
            )
        }
    }

    private enum TMDBError: LocalizedError {
        case response, token

        var errorDescription: String? {
            switch self {
            case .response: return "TMDB chưa phản hồi. Hãy thử lại sau."
            case .token: return "TMDB từ chối mã truy cập. Hãy kiểm tra API Read Access Token trong Cài đặt."
            }
        }
    }
}

enum TMDBCredential {
    private static let key: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.local.cinema.tmdb",
        kSecAttrAccount as String: "read-access-token"
    ]

    static func read() -> String? {
        var query = key
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String) -> Bool {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            let status = SecItemDelete(key as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(cleaned.utf8)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var entry = key
        entry[kSecValueData as String] = data
        entry[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(entry as CFDictionary, nil) == errSecSuccess
    }
}
