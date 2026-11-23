import Foundation

struct TraktDeviceCode: Equatable, Sendable {
    let deviceCode: String
    let userCode: String
    let verificationURL: String
    let expiresIn: Int
    let interval: Int
}

enum TraktCredential {
    private static let service = "com.local.cinema.trakt"

    static var clientID: String? { KeychainStore.read(service: service, account: "client-id") }
    static var clientSecret: String? { KeychainStore.read(service: service, account: "client-secret") }
    static var accessToken: String? { KeychainStore.read(service: service, account: "access-token") }

    @discardableResult
    static func saveClient(id: String, secret: String) -> Bool {
        let ok1 = KeychainStore.write(id, service: service, account: "client-id", deleteIfEmpty: true)
        let ok2 = KeychainStore.write(secret, service: service, account: "client-secret", deleteIfEmpty: true)
        return ok1 && ok2
    }

    @discardableResult
    static func saveAccessToken(_ token: String) -> Bool {
        KeychainStore.write(token, service: service, account: "access-token", deleteIfEmpty: true)
    }

    static func disconnect() {
        _ = KeychainStore.delete(service: service, account: "access-token")
    }
}

enum TraktService {
    static func requestDeviceCode(clientID: String, session: URLSession = .shared) async throws -> TraktDeviceCode {
        let url = URL(string: "https://api.trakt.tv/oauth/device/code")!
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["client_id": clientID])

        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
            throw TraktError.requestFailed
        }
        let decoded = try JSONDecoder().decode(CodePayload.self, from: data)
        return TraktDeviceCode(
            deviceCode: decoded.device_code,
            userCode: decoded.user_code,
            verificationURL: decoded.verification_url,
            expiresIn: decoded.expires_in,
            interval: decoded.interval
        )
    }

    static func pollDeviceToken(
        code: String,
        clientID: String,
        clientSecret: String,
        session: URLSession = .shared
    ) async throws -> String? {
        let url = URL(string: "https://api.trakt.tv/oauth/device/token")!
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": code,
            "client_id": clientID,
            "client_secret": clientSecret
        ])
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw TraktError.requestFailed }
        if status == 400 { return nil } // Authorization pending
        guard status == 200 else { throw TraktError.requestFailed }
        let tokenPayload = try JSONDecoder().decode(TokenPayload.self, from: data)
        TraktCredential.saveAccessToken(tokenPayload.access_token)
        return tokenPayload.access_token
    }

    static func scrobble(
        action: String, // "start" | "pause" | "stop"
        tmdbID: Int,
        kind: String,
        progressPercent: Double,
        season: Int? = nil,
        episode: Int? = nil,
        session: URLSession = .shared
    ) async {
        guard let clientID = TraktCredential.clientID, !clientID.isEmpty,
              let token = TraktCredential.accessToken, !token.isEmpty else { return }

        let url = URL(string: "https://api.trakt.tv/scrobble/\(action)")!
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(clientID, forHTTPHeaderField: "trakt-api-key")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = ["progress": min(max(progressPercent, 0), 100)]
        if kind == "tv", let season, let episode {
            body["show"] = ["ids": ["tmdb": tmdbID]]
            body["episode"] = ["season": season, "number": episode]
        } else {
            body["movie"] = ["ids": ["tmdb": tmdbID]]
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await session.data(for: request)
    }

    private struct CodePayload: Decodable {
        let device_code: String
        let user_code: String
        let verification_url: String
        let expires_in: Int
        let interval: Int
    }

    private struct TokenPayload: Decodable {
        let access_token: String
    }

    enum TraktError: LocalizedError {
        case requestFailed
        var errorDescription: String? { "Không thể xác thực với Trakt.tv. Kiểm tra Client ID và Secret." }
    }
}
