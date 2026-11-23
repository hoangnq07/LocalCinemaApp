import Foundation

struct MediaServerProfile: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var kind: MediaServerKind
    var name: String
    var serverURL: String
    var username: String
    var userID: String

    var normalizedURL: URL? {
        var raw = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") { raw = "http://" + raw }
        while raw.hasSuffix("/") { raw.removeLast() }
        return URL(string: raw)
    }
}

struct ServerCollection: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let collectionType: String
}

struct ServerMediaEntry: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let originalTitle: String?
    let kind: String // "movie" | "series" | "season" | "episode"
    let year: String?
    let overview: String
    let rating: Double?
    let posterURL: URL?
    let backdropURL: URL?
    let genres: [String]
    let runtimeMinutes: Int?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let seriesTitle: String?
    let partKey: String?
    let positionSeconds: Double
    let durationSeconds: Double
    let watched: Bool
    let technicalInfo: MediaTechnicalInfo?
}

@MainActor
final class MediaServerStore: ObservableObject {
    @Published private(set) var servers: [MediaServerProfile] = []
    private let storeKey = "mediaServerProfiles"
    private let keychainService = "com.local.cinema.mediaserver"

    init() {
        if let data = UserDefaults.standard.data(forKey: storeKey),
           let list = try? JSONDecoder().decode([MediaServerProfile].self, from: data) {
            servers = list
        }
    }

    func save(_ profile: MediaServerProfile, token: String) {
        let next = [profile] + servers.filter { $0.id != profile.id }
        if let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: storeKey)
            servers = next
        }
        _ = KeychainStore.write(token, service: keychainService, account: profile.id.uuidString)
    }

    func remove(_ profile: MediaServerProfile) {
        let next = servers.filter { $0.id != profile.id }
        if let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: storeKey)
            servers = next
        }
        _ = KeychainStore.delete(service: keychainService, account: profile.id.uuidString)
    }

    func token(for profile: MediaServerProfile) -> String {
        KeychainStore.read(service: keychainService, account: profile.id.uuidString) ?? ""
    }

    func server(for id: UUID) -> MediaServerProfile? {
        servers.first { $0.id == id }
    }

    func streamConfig(for location: MediaServerMediaLocation) -> (url: URL, headers: [String: String])? {
        guard let profile = server(for: location.serverID),
              let base = profile.normalizedURL else { return nil }
        let token = token(for: profile)
        let url = base.appendingPathComponent("Videos/\(location.itemID)/stream")
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "MediaSourceId", value: location.itemID),
            URLQueryItem(name: "api_key", value: token)
        ]
        guard let finalURL = comps?.url else { return nil }
        return (finalURL, ["X-Emby-Token": token])
    }

    func plexStreamURL(for location: PlexMediaLocation) -> URL? {
        guard let profile = server(for: location.serverID),
              let base = profile.normalizedURL else { return nil }
        let token = token(for: profile)
        var comps = URLComponents(url: base.appendingPathComponent(location.partKey.trimmingCharacters(in: CharacterSet(charactersIn: "/"))), resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "X-Plex-Token", value: token)]
        return comps?.url
    }

    func syncProgress(for item: MediaItem, position: Double, duration: Double, stopped: Bool) async {
        switch item.source {
        case .mediaServer(let loc):
            guard let profile = server(for: loc.serverID) else { return }
            let token = token(for: profile)
            await EmbyJellyfinClient.reportPlayback(
                profile: profile,
                token: token,
                itemID: loc.itemID,
                positionSeconds: position,
                stopped: stopped
            )
        case .plex(let loc):
            guard let profile = server(for: loc.serverID) else { return }
            let token = token(for: profile)
            await PlexClient.reportProgress(
                profile: profile,
                token: token,
                ratingKey: loc.ratingKey,
                positionSeconds: position,
                durationSeconds: duration,
                stopped: stopped
            )
        default:
            break
        }
    }
}

// MARK: - Jellyfin & Emby Client

enum EmbyJellyfinClient {
    static func authenticate(
        kind: MediaServerKind,
        serverURL: String,
        username: String,
        password: String,
        session: URLSession = .shared
    ) async throws -> (profile: MediaServerProfile, token: String) {
        let draft = MediaServerProfile(kind: kind, name: kind.label, serverURL: serverURL, username: username, userID: "")
        guard let base = draft.normalizedURL else { throw MediaServerError.invalidURL }

        let endpoint = base.appendingPathComponent("Users/AuthenticateByName")
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader(token: nil), forHTTPHeaderField: "X-Emby-Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["Username": username, "Pw": password])

        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw MediaServerError.network }
        if status == 401 || status == 403 { throw MediaServerError.unauthorized }
        guard (200...299).contains(status) else { throw MediaServerError.serverStatus(status) }

        let decoded = try JSONDecoder().decode(AuthResponse.self, from: data)
        let hostName = base.host ?? kind.label
        let profile = MediaServerProfile(
            kind: kind,
            name: "\(kind.label) · \(hostName)",
            serverURL: base.absoluteString,
            username: username,
            userID: decoded.User.Id
        )
        return (profile, decoded.AccessToken)
    }

    static func fetchViews(profile: MediaServerProfile, token: String, session: URLSession = .shared) async throws -> [ServerCollection] {
        guard let base = profile.normalizedURL else { throw MediaServerError.invalidURL }
        let url = base.appendingPathComponent("Users/\(profile.userID)/Views")
        let data = try await get(url, token: token, session: session)
        let decoded = try JSONDecoder().decode(ViewsResponse.self, from: data)
        return decoded.Items.map {
            ServerCollection(id: $0.Id, title: $0.Name, collectionType: $0.CollectionType ?? "mixed")
        }
    }

    static func fetchItems(
        profile: MediaServerProfile,
        token: String,
        parentID: String? = nil,
        includeTypes: String = "Movie,Series",
        session: URLSession = .shared
    ) async throws -> [ServerMediaEntry] {
        guard let base = profile.normalizedURL else { throw MediaServerError.invalidURL }
        var comps = URLComponents(url: base.appendingPathComponent("Users/\(profile.userID)/Items"), resolvingAgainstBaseURL: false)!
        var query = [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: includeTypes),
            URLQueryItem(name: "Fields", value: "Overview,Genres,RunTimeTicks,MediaSources,OriginalTitle"),
            URLQueryItem(name: "SortBy", value: "DateCreated,SortName"),
            URLQueryItem(name: "SortOrder", value: "Descending"),
            URLQueryItem(name: "Limit", value: "100")
        ]
        if let parentID { query.append(URLQueryItem(name: "ParentId", value: parentID)) }
        comps.queryItems = query
        guard let url = comps.url else { throw MediaServerError.invalidURL }
        let data = try await get(url, token: token, session: session)
        let decoded = try JSONDecoder().decode(ItemsResponse.self, from: data)
        return decoded.Items.map { mapItem($0, base: base, token: token) }
    }

    static func fetchEpisodes(
        profile: MediaServerProfile,
        token: String,
        seriesID: String,
        session: URLSession = .shared
    ) async throws -> [ServerMediaEntry] {
        guard let base = profile.normalizedURL else { throw MediaServerError.invalidURL }
        var comps = URLComponents(url: base.appendingPathComponent("Shows/\(seriesID)/Episodes"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "UserId", value: profile.userID),
            URLQueryItem(name: "Fields", value: "Overview,RunTimeTicks,MediaSources")
        ]
        guard let url = comps.url else { throw MediaServerError.invalidURL }
        let data = try await get(url, token: token, session: session)
        let decoded = try JSONDecoder().decode(ItemsResponse.self, from: data)
        return decoded.Items.map { mapItem($0, base: base, token: token) }
    }

    static func reportPlayback(
        profile: MediaServerProfile,
        token: String,
        itemID: String,
        positionSeconds: Double,
        stopped: Bool,
        session: URLSession = .shared
    ) async {
        guard let base = profile.normalizedURL else { return }
        let endpoint = stopped ? "Sessions/Playing/Stopped" : "Sessions/Playing/Progress"
        let url = base.appendingPathComponent(endpoint)
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader(token: token), forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        let ticks = Int64(max(0, positionSeconds) * 10_000_000)
        let payload: [String: Any] = ["ItemId": itemID, "PositionTicks": ticks]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        _ = try? await session.data(for: request)
    }

    private static func get(_ url: URL, token: String, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(authHeader(token: token), forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw MediaServerError.network }
        if status == 401 || status == 403 { throw MediaServerError.unauthorized }
        guard (200...299).contains(status) else { throw MediaServerError.serverStatus(status) }
        return data
    }

    private static func authHeader(token: String?) -> String {
        var base = #"MediaBrowser Client="LocalCinema", Device="iPhone", DeviceId="localcinema-ios", Version="2.0.0""#
        if let token, !token.isEmpty {
            base += #", Token="\#(token)""#
        }
        return base
    }

    private static func mapItem(_ item: EmbyItem, base: URL, token: String) -> ServerMediaEntry {
        let primaryTag = item.ImageTags?["Primary"]
        let backdropTag = item.BackdropImageTags?.first
        let posterURL = buildImageURL(
            base: base,
            path: "Items/\(item.Id)/Images/Primary",
            query: ["fillWidth": "360", "tag": primaryTag, "api_key": token]
        )
        let backdropURL = backdropTag.flatMap { tag in
            buildImageURL(
                base: base,
                path: "Items/\(item.Id)/Images/Backdrop/0",
                query: ["maxWidth": "960", "tag": tag, "api_key": token]
            )
        }

        let kindStr = (item.Type ?? "Movie").lowercased()
        let posSec = Double(item.UserData?.PlaybackPositionTicks ?? 0) / 10_000_000.0
        let durSec = Double(item.RunTimeTicks ?? 0) / 10_000_000.0
        let runtimeMin = durSec > 0 ? Int(durSec / 60) : nil
        let tech = FilenameParser.parse(item.Name).technicalInfo

        return ServerMediaEntry(
            id: item.Id,
            title: item.Name,
            originalTitle: item.OriginalTitle,
            kind: kindStr,
            year: item.ProductionYear.map(String.init),
            overview: item.Overview ?? "",
            rating: item.CommunityRating,
            posterURL: posterURL,
            backdropURL: backdropURL,
            genres: item.Genres ?? [],
            runtimeMinutes: runtimeMin,
            seasonNumber: item.ParentIndexNumber,
            episodeNumber: item.IndexNumber,
            seriesTitle: item.SeriesName,
            partKey: nil,
            positionSeconds: posSec,
            durationSeconds: durSec,
            watched: item.UserData?.Played ?? false,
            technicalInfo: tech
        )
    }

    private static func buildImageURL(base: URL, path: String, query: [String: String?]) -> URL? {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        comps?.queryItems = query.compactMap { key, value in
            guard let value, !value.isEmpty else { return nil }
            return URLQueryItem(name: key, value: value)
        }
        return comps?.url
    }

    private struct AuthResponse: Decodable {
        let AccessToken: String
        let User: UserObj
        struct UserObj: Decodable { let Id: String }
    }

    private struct ViewsResponse: Decodable {
        let Items: [ViewObj]
        struct ViewObj: Decodable {
            let Id: String
            let Name: String
            let CollectionType: String?
        }
    }

    private struct ItemsResponse: Decodable { let Items: [EmbyItem] }

    private struct EmbyItem: Decodable {
        let Id: String
        let Name: String
        let OriginalTitle: String?
        let `Type`: String?
        let ProductionYear: Int?
        let Overview: String?
        let CommunityRating: Double?
        let Genres: [String]?
        let RunTimeTicks: Int64?
        let ParentIndexNumber: Int?
        let IndexNumber: Int?
        let SeriesName: String?
        let ImageTags: [String: String]?
        let BackdropImageTags: [String]?
        let UserData: UserDataObj?

        struct UserDataObj: Decodable {
            let PlaybackPositionTicks: Int64?
            let Played: Bool?
        }
    }
}

// MARK: - Plex Client

enum PlexClient {
    static func connect(serverURL: String, token: String, session: URLSession = .shared) async throws -> MediaServerProfile {
        let draft = MediaServerProfile(kind: .plex, name: "Plex", serverURL: serverURL, username: "", userID: "")
        guard let base = draft.normalizedURL else { throw MediaServerError.invalidURL }
        _ = try await fetchSections(profile: draft, token: token, session: session)
        let hostName = base.host ?? "Plex"
        return MediaServerProfile(
            kind: .plex,
            name: "Plex · \(hostName)",
            serverURL: base.absoluteString,
            username: "Plex",
            userID: "plex"
        )
    }

    static func fetchSections(profile: MediaServerProfile, token: String, session: URLSession = .shared) async throws -> [ServerCollection] {
        guard let base = profile.normalizedURL else { throw MediaServerError.invalidURL }
        let url = base.appendingPathComponent("library/sections")
        let data = try await getJSON(url, token: token, session: session)
        let decoded = try JSONDecoder().decode(PlexSectionContainer.self, from: data)
        return (decoded.MediaContainer.Directory ?? []).map {
            ServerCollection(id: $0.key, title: $0.title, collectionType: $0.type)
        }
    }

    static func fetchItems(
        profile: MediaServerProfile,
        token: String,
        sectionKey: String,
        session: URLSession = .shared
    ) async throws -> [ServerMediaEntry] {
        guard let base = profile.normalizedURL else { throw MediaServerError.invalidURL }
        let url = base.appendingPathComponent("library/sections/\(sectionKey)/all")
        let data = try await getJSON(url, token: token, session: session)
        let decoded = try JSONDecoder().decode(PlexMetadataContainer.self, from: data)
        return (decoded.MediaContainer.Metadata ?? []).map { mapMetadata($0, base: base, token: token) }
    }

    static func fetchChildren(
        profile: MediaServerProfile,
        token: String,
        ratingKey: String,
        session: URLSession = .shared
    ) async throws -> [ServerMediaEntry] {
        guard let base = profile.normalizedURL else { throw MediaServerError.invalidURL }
        let url = base.appendingPathComponent("library/metadata/\(ratingKey)/allLeaves")
        let data = try await getJSON(url, token: token, session: session)
        let decoded = try JSONDecoder().decode(PlexMetadataContainer.self, from: data)
        return (decoded.MediaContainer.Metadata ?? []).map { mapMetadata($0, base: base, token: token) }
    }

    static func reportProgress(
        profile: MediaServerProfile,
        token: String,
        ratingKey: String,
        positionSeconds: Double,
        durationSeconds: Double,
        stopped: Bool,
        session: URLSession = .shared
    ) async {
        guard let base = profile.normalizedURL,
              var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return }
        comps.path = base.path + "/:/timeline"
        comps.queryItems = [
            URLQueryItem(name: "ratingKey", value: ratingKey),
            URLQueryItem(name: "key", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "state", value: stopped ? "stopped" : "playing"),
            URLQueryItem(name: "time", value: String(Int(max(0, positionSeconds) * 1000))),
            URLQueryItem(name: "duration", value: String(Int(max(0, durationSeconds) * 1000))),
            URLQueryItem(name: "X-Plex-Token", value: token)
        ]
        if let url = comps.url {
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            _ = try? await session.data(for: request)
        }
    }

    private static func getJSON(_ url: URL, token: String, session: URLSession) async throws -> Data {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: "X-Plex-Token", value: token))
        comps.queryItems = items
        guard let finalURL = comps.url else { throw MediaServerError.invalidURL }
        var request = URLRequest(url: finalURL, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw MediaServerError.network }
        if status == 401 || status == 403 { throw MediaServerError.unauthorized }
        guard (200...299).contains(status) else { throw MediaServerError.serverStatus(status) }
        return data
    }

    private static func mapMetadata(_ item: PlexMetadata, base: URL, token: String) -> ServerMediaEntry {
        let thumbURL = item.thumb.flatMap { path -> URL? in
            var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
            comps?.path = base.path + (path.hasPrefix("/") ? path : "/\(path)")
            comps?.queryItems = [URLQueryItem(name: "X-Plex-Token", value: token)]
            return comps?.url
        }
        let artURL = item.art.flatMap { path -> URL? in
            var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
            comps?.path = base.path + (path.hasPrefix("/") ? path : "/\(path)")
            comps?.queryItems = [URLQueryItem(name: "X-Plex-Token", value: token)]
            return comps?.url
        }
        let partKey = item.Media?.first?.Part?.first?.key
        let durSec = Double(item.duration ?? 0) / 1000.0
        let posSec = Double(item.viewOffset ?? 0) / 1000.0
        return ServerMediaEntry(
            id: item.ratingKey,
            title: item.title,
            originalTitle: item.originalTitle,
            kind: item.type ?? "movie",
            year: item.year.map(String.init),
            overview: item.summary ?? "",
            rating: item.rating,
            posterURL: thumbURL,
            backdropURL: artURL,
            genres: (item.Genre ?? []).map(\.tag),
            runtimeMinutes: durSec > 0 ? Int(durSec / 60) : nil,
            seasonNumber: item.parentIndex,
            episodeNumber: item.index,
            seriesTitle: item.grandparentTitle,
            partKey: partKey,
            positionSeconds: posSec,
            durationSeconds: durSec,
            watched: (item.viewCount ?? 0) > 0,
            technicalInfo: FilenameParser.parse(item.title).technicalInfo
        )
    }

    private struct PlexSectionContainer: Decodable {
        let MediaContainer: Container
        struct Container: Decodable { let Directory: [Dir]? }
        struct Dir: Decodable {
            let key: String
            let title: String
            let type: String
        }
    }

    private struct PlexMetadataContainer: Decodable {
        let MediaContainer: Container
        struct Container: Decodable { let Metadata: [PlexMetadata]? }
    }

    private struct PlexMetadata: Decodable {
        let ratingKey: String
        let title: String
        let originalTitle: String?
        let type: String?
        let year: Int?
        let summary: String?
        let rating: Double?
        let thumb: String?
        let art: String?
        let duration: Int64?
        let viewOffset: Int64?
        let viewCount: Int?
        let parentIndex: Int?
        let index: Int?
        let grandparentTitle: String?
        let Genre: [TagItem]?
        let Media: [MediaEntry]?

        struct TagItem: Decodable { let tag: String }
        struct MediaEntry: Decodable { let Part: [PartEntry]? }
        struct PartEntry: Decodable { let key: String? }
    }
}

enum MediaServerError: LocalizedError {
    case invalidURL, network, unauthorized, serverStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Địa chỉ máy chủ không hợp lệ."
        case .network: return "Không thể kết nối tới máy chủ media."
        case .unauthorized: return "Sai tên đăng nhập, mật khẩu hoặc token."
        case .serverStatus(let code): return "Máy chủ phản hồi lỗi HTTP \(code)."
        }
    }
}
