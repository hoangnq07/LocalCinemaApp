import Foundation

struct WebDAVProfile: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var baseURL: String
    var username: String

    var normalizedBaseURL: URL? {
        var raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") { raw = "https://" + raw }
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }
}

struct WebDAVEntry: Identifiable, Equatable, Sendable {
    var id: String { path }
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64?

    var isVideo: Bool {
        !isDirectory && MediaLibrary.fileExtensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased())
    }

    var isSubtitle: Bool {
        !isDirectory && MediaLibrary.subtitleExtensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased())
    }
}

@MainActor
final class WebDAVProfiles: ObservableObject {
    @Published private(set) var saved: [WebDAVProfile] = []
    private let storeKey = "webdavProfiles"
    private let keychainService = "com.local.cinema.webdav"

    init() {
        if let data = UserDefaults.standard.data(forKey: storeKey),
           let list = try? JSONDecoder().decode([WebDAVProfile].self, from: data) {
            saved = list
        }
    }

    func save(_ profile: WebDAVProfile, password: String) throws {
        let next = [profile] + saved.filter { $0.id != profile.id }
        let data = try JSONEncoder().encode(next)
        guard KeychainStore.write(password, service: keychainService, account: profile.id.uuidString) else {
            throw WebDAVError.credentials
        }
        UserDefaults.standard.set(data, forKey: storeKey)
        saved = next
    }

    func remove(_ profile: WebDAVProfile) {
        let next = saved.filter { $0.id != profile.id }
        if let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: storeKey)
            saved = next
        }
        _ = KeychainStore.delete(service: keychainService, account: profile.id.uuidString)
    }

    func password(for profile: WebDAVProfile) -> String {
        KeychainStore.read(service: keychainService, account: profile.id.uuidString) ?? ""
    }

    func profile(for id: UUID) -> WebDAVProfile? {
        saved.first { $0.id == id }
    }

    func playbackConfig(for location: WebDAVMediaLocation) -> (url: URL, headers: [String: String])? {
        guard let profile = profile(for: location.profileID),
              let url = WebDAVClient.resolveFileURL(baseURL: profile.normalizedBaseURL, path: location.path) else {
            return nil
        }
        let pass = password(for: profile)
        let headers = WebDAVClient.authHeaders(username: profile.username, password: pass)
        return (url, headers)
    }
}

enum WebDAVClient {
    private static let propfindBody = """
    <?xml version="1.0" encoding="utf-8" ?>
    <D:propfind xmlns:D="DAV:">
      <D:prop>
        <D:displayname/>
        <D:resourcetype/>
        <D:getcontentlength/>
      </D:prop>
    </D:propfind>
    """

    static func authHeaders(username: String, password: String) -> [String: String] {
        guard !username.isEmpty || !password.isEmpty else { return [:] }
        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        return ["Authorization": "Basic \(token)"]
    }

    static func resolveFileURL(baseURL: URL?, path: String) -> URL? {
        guard let baseURL else { return nil }
        if path.isEmpty || path == "/" { return baseURL }
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let components = trimmed.split(separator: "/").map(String.init)
        var built = baseURL
        for segment in components {
            built.appendPathComponent(segment, isDirectory: false)
        }
        return built
    }

    static func listDirectory(
        profile: WebDAVProfile,
        password: String,
        folderPath: String = "/",
        session: URLSession = .shared
    ) async throws -> [WebDAVEntry] {
        guard let targetURL = resolveFileURL(baseURL: profile.normalizedBaseURL, path: folderPath) else {
            throw WebDAVError.invalidURL
        }
        var request = URLRequest(url: targetURL, timeoutInterval: 15)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        for (k, v) in authHeaders(username: profile.username, password: password) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.httpBody = Data(propfindBody.utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.network }
        if http.statusCode == 401 || http.statusCode == 403 { throw WebDAVError.unauthorized }
        guard (200...299).contains(http.statusCode) || http.statusCode == 207 else {
            throw WebDAVError.serverStatus(http.statusCode)
        }
        let allEntries = parsePropfindResponse(data, baseURL: profile.normalizedBaseURL, requestedPath: targetURL.path)
        return allEntries.filter { $0.isDirectory || $0.isVideo }
    }

    static func scanFolder(
        profile: WebDAVProfile,
        password: String,
        folderPath: String = "/",
        session: URLSession = .shared
    ) async throws -> [(entry: WebDAVEntry, sidecars: [String])] {
        guard let targetURL = resolveFileURL(baseURL: profile.normalizedBaseURL, path: folderPath) else {
            throw WebDAVError.invalidURL
        }
        var request = URLRequest(url: targetURL, timeoutInterval: 15)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        for (k, v) in authHeaders(username: profile.username, password: password) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.httpBody = Data(propfindBody.utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) || http.statusCode == 207 else {
            throw WebDAVError.network
        }
        let all = parsePropfindResponse(data, baseURL: profile.normalizedBaseURL, requestedPath: targetURL.path)
        let subs = all.filter(\.isSubtitle)
        return all.filter(\.isVideo).map { video in
            let stem = URL(fileURLWithPath: video.path).deletingPathExtension().path.lowercased()
            let matched = subs.filter {
                let s = URL(fileURLWithPath: $0.path).deletingPathExtension().path.lowercased()
                return s == stem || s.hasPrefix(stem + ".")
            }.map(\.path)
            return (video, matched)
        }
    }

    static func downloadSubtitles(
        profile: WebDAVProfile,
        password: String,
        paths: [String],
        session: URLSession = .shared
    ) async -> [URL] {
        guard !paths.isEmpty else { return [] }
        let subDir = FileManager.default.temporaryDirectory.appendingPathComponent("LocalCinemaSubs", isDirectory: true)
        try? FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let headers = authHeaders(username: profile.username, password: password)
        var result: [URL] = []

        for path in paths.prefix(4) {
            guard let url = resolveFileURL(baseURL: profile.normalizedBaseURL, path: path) else { continue }
            var request = URLRequest(url: url, timeoutInterval: 15)
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
            if let (data, response) = try? await session.data(for: request),
               let code = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(code),
               !data.isEmpty {
                let name = URL(fileURLWithPath: path).lastPathComponent
                let dest = subDir.appendingPathComponent("\(UUID().uuidString)_\(name)")
                if (try? data.write(to: dest, options: .atomic)) != nil {
                    result.append(dest)
                }
            }
        }
        return result
    }

    static func parsePropfindResponse(_ data: Data, baseURL: URL?, requestedPath: String) -> [WebDAVEntry] {
        let delegate = PropfindParserDelegate(basePath: baseURL?.path ?? "/", requestedPath: requestedPath)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private final class PropfindParserDelegate: NSObject, XMLParserDelegate {
        private let basePath: String
        private let normalizedRequestPath: String

        var entries: [WebDAVEntry] = []

        private var inResponse = false
        private var currentElement = ""
        private var textBuffer = ""
        private var href = ""
        private var displayName = ""
        private var isCollection = false
        private var contentLength: Int64?

        init(basePath: String, requestedPath: String) {
            self.basePath = Self.normalizePath(basePath)
            self.normalizedRequestPath = Self.normalizePath(requestedPath)
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let local = elementName.components(separatedBy: ":").last?.lowercased() ?? elementName.lowercased()
            currentElement = local
            textBuffer = ""
            if local == "response" {
                inResponse = true
                href = ""
                displayName = ""
                isCollection = false
                contentLength = nil
            } else if inResponse && local == "collection" {
                isCollection = true
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            textBuffer += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let local = elementName.components(separatedBy: ":").last?.lowercased() ?? elementName.lowercased()
            let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if inResponse {
                switch local {
                case "href": href = value
                case "displayname": displayName = value
                case "getcontentlength": contentLength = Int64(value)
                case "response":
                    commitCurrentResponse()
                    inResponse = false
                default: break
                }
            }
            textBuffer = ""
            currentElement = ""
        }

        private func commitCurrentResponse() {
            let rawPath: String
            if let url = URL(string: href), url.scheme != nil {
                rawPath = url.path
            } else {
                rawPath = href.removingPercentEncoding ?? href
            }
            let normalizedHref = Self.normalizePath(rawPath)
            if normalizedHref == normalizedRequestPath { return }

            var relative = normalizedHref
            if basePath != "/" && relative.hasPrefix(basePath) {
                relative = String(relative.dropFirst(basePath.count))
                if !relative.hasPrefix("/") { relative = "/" + relative }
            }
            let name = !displayName.isEmpty
                ? displayName
                : URL(fileURLWithPath: normalizedHref).lastPathComponent
            guard !name.isEmpty, name != "/" else { return }

            let entry = WebDAVEntry(name: name, path: relative, isDirectory: isCollection, size: contentLength)
            if entry.isDirectory || entry.isVideo || entry.isSubtitle {
                entries.append(entry)
            }
        }

        private static func normalizePath(_ path: String) -> String {
            var decoded = path.removingPercentEncoding ?? path
            if decoded.isEmpty { decoded = "/" }
            if decoded.count > 1 && decoded.hasSuffix("/") { decoded.removeLast() }
            return decoded
        }
    }

    enum WebDAVError: LocalizedError {
        case invalidURL, credentials, unauthorized, network, serverStatus(Int)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Địa chỉ WebDAV không hợp lệ."
            case .credentials: return "Không thể lưu mật khẩu WebDAV vào Keychain."
            case .unauthorized: return "Sai tên đăng nhập hoặc mật khẩu WebDAV."
            case .network: return "Không thể kết nối tới máy chủ WebDAV."
            case .serverStatus(let code): return "Máy chủ WebDAV phản hồi mã lỗi \(code)."
            }
        }
    }
}
