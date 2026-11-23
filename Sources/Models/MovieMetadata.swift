import Foundation

struct CastMember: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: Int
    let name: String
    let character: String?
    let profilePath: String?

    var profileURL: URL? {
        guard let profilePath, profilePath.hasPrefix("/") else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w185\(profilePath)")
    }
}

struct MovieMetadata: Codable, Equatable, Sendable {
    let id: Int
    let kind: String
    let title: String
    let overview: String
    let year: String?
    let posterPath: String?
    let backdropPath: String?
    let rating: Double?
    var originalTitle: String? = nil
    var genres: [String]? = nil
    var runtimeMinutes: Int? = nil
    var tagline: String? = nil
    var cast: [CastMember]? = nil

    var posterURL: URL? { Self.image(posterPath, size: "w342") }
    var backdropURL: URL? { Self.image(backdropPath, size: "w780") }
    var kindLabel: String { kind == "tv" ? "Phim bộ" : "Phim lẻ" }

    var runtimeLabel: String? {
        guard let runtimeMinutes, runtimeMinutes > 0 else { return nil }
        let hours = runtimeMinutes / 60
        let mins = runtimeMinutes % 60
        return hours > 0 ? "\(hours)g \(mins)p" : "\(mins) phút"
    }

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

    static func fetchDetails(id: Int, kind: String, token: String, session: URLSession = .shared) async throws -> MovieMetadata {
        let cleanKind = kind == "tv" ? "tv" : "movie"
        var endpoint = URLComponents()
        endpoint.scheme = "https"
        endpoint.host = "api.themoviedb.org"
        endpoint.path = "/3/\(cleanKind)/\(id)"
        endpoint.queryItems = [
            URLQueryItem(name: "language", value: "vi-VN"),
            URLQueryItem(name: "append_to_response", value: "credits")
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
        let detail = try decoder.decode(DetailItem.self, from: data)
        return detail.toMetadata(kind: cleanKind)
    }

    private struct Results: Decodable { let results: [ResultItem] }

    private struct ResultItem: Decodable {
        let id: Int
        let mediaType: String
        let title: String?
        let name: String?
        let originalTitle: String?
        let originalName: String?
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
                id: id,
                kind: mediaType,
                title: title,
                overview: overview ?? "",
                year: date.count >= 4 ? String(date.prefix(4)) : nil,
                posterPath: posterPath,
                backdropPath: backdropPath,
                rating: voteAverage.flatMap { $0 > 0 ? $0 : nil },
                originalTitle: originalTitle ?? originalName
            )
        }
    }

    private struct DetailItem: Decodable {
        let id: Int
        let title: String?
        let name: String?
        let originalTitle: String?
        let originalName: String?
        let overview: String?
        let tagline: String?
        let posterPath: String?
        let backdropPath: String?
        let releaseDate: String?
        let firstAirDate: String?
        let voteAverage: Double?
        let runtime: Int?
        let episodeRunTime: [Int]?
        let genres: [GenreItem]?
        let credits: CreditsContainer?

        struct GenreItem: Decodable { let name: String }
        struct CreditsContainer: Decodable { let cast: [CastPayload]? }
        struct CastPayload: Decodable {
            let id: Int
            let name: String
            let character: String?
            let profilePath: String?
        }

        func toMetadata(kind: String) -> MovieMetadata {
            let date = releaseDate ?? firstAirDate ?? ""
            let castList = credits?.cast?.prefix(12).map {
                CastMember(id: $0.id, name: $0.name, character: $0.character, profilePath: $0.profilePath)
            }
            return MovieMetadata(
                id: id,
                kind: kind,
                title: title ?? name ?? "Không rõ tên",
                overview: overview ?? "",
                year: date.count >= 4 ? String(date.prefix(4)) : nil,
                posterPath: posterPath,
                backdropPath: backdropPath,
                rating: voteAverage.flatMap { $0 > 0 ? $0 : nil },
                originalTitle: originalTitle ?? originalName,
                genres: genres?.map(\.name),
                runtimeMinutes: runtime ?? episodeRunTime?.first,
                tagline: tagline?.isEmpty == false ? tagline : nil,
                cast: castList
            )
        }
    }

    enum TMDBError: LocalizedError {
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
    private static let service = "com.local.cinema.tmdb"
    private static let account = "read-access-token"

    static func read() -> String? {
        KeychainStore.read(service: service, account: account)
    }

    @discardableResult
    static func save(_ value: String) -> Bool {
        KeychainStore.write(value, service: service, account: account, deleteIfEmpty: true)
    }
}
