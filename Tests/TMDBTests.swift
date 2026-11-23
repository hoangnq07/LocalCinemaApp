import Foundation
import XCTest
@testable import LocalCinema

final class TMDBTests: XCTestCase {
    func testLookupSendsLocalizedQueryAndParsesMovieAndTVResults() async throws {
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        let results = try await TMDB.search("Bản thử & phim", token: "test-token", session: session)

        XCTAssertEqual(results.map(\.kind), ["movie", "tv"])
        XCTAssertEqual(results.map(\.title), ["Phim thử", "Loạt phim thử"])
        XCTAssertEqual(results.map(\.year), ["2025", "2024"])
        XCTAssertEqual(results.first?.overview, "Tóm tắt mẫu.")
        XCTAssertEqual(results.first?.rating, 7.8)
        XCTAssertEqual(results.first?.posterURL?.absoluteString, "https://image.tmdb.org/t/p/w342/poster.png")
        XCTAssertEqual(results.first?.backdropURL?.absoluteString, "https://image.tmdb.org/t/p/w780/backdrop.png")
        XCTAssertNil(results.last?.rating)
    }

    func testUnauthorizedHasActionableError() async {
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await TMDB.search("Bản thử & phim", token: "expired-token", session: session)
            XCTFail("Expected unauthorized request to fail.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("API Read Access Token"))
        }
    }

    private func fixtureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TMDBFixture.self]
        return URLSession(configuration: configuration)
    }
}

private final class TMDBFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https",
              components.host == "api.themoviedb.org",
              components.path == "/3/search/multi",
              components.queryItems?.contains(URLQueryItem(name: "query", value: "Bản thử & phim")) == true,
              components.queryItems?.contains(URLQueryItem(name: "language", value: "vi-VN")) == true,
              components.queryItems?.contains(URLQueryItem(name: "include_adult", value: "false")) == true,
              request.value(forHTTPHeaderField: "Accept") == "application/json" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let valid = request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token"
        let response = HTTPURLResponse(url: url, statusCode: valid ? 200 : 401,
                                       httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static let body = """
    {
      "results": [
        {"id": 21, "media_type": "movie", "title": "Phim thử", "overview": "Tóm tắt mẫu.",
         "release_date": "2025-01-04", "vote_average": 7.8,
         "poster_path": "/poster.png", "backdrop_path": "/backdrop.png"},
        {"id": 22, "media_type": "person", "name": "Diễn viên thử"},
        {"id": 23, "media_type": "tv", "name": "Loạt phim thử",
         "first_air_date": "2024-01-04", "vote_average": 0}
      ]
    }
    """
}
