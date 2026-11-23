import AMSMB2
import Foundation
import SwiftUI

struct SMBAddress {
    let server: URL
    let folders: [String]

    init?(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = text.contains("://") ? text : "smb://" + text
        guard var parts = URLComponents(string: address),
              parts.scheme?.lowercased() == "smb", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        let path = parts.percentEncodedPath
        let folders = path.split(separator: "/").compactMap { $0.removingPercentEncoding }
        guard folders.count == path.split(separator: "/").count,
              folders.allSatisfy(Self.validComponent) else { return nil }
        parts.scheme = "smb"
        parts.path = ""
        guard let url = parts.url else { return nil }
        self.server = url
        self.folders = folders
    }

    static func validComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
            && !name.contains("\0")
    }
}

struct SMBProfile: Codable, Sendable, Identifiable {
    var id = UUID()
    let address: String
    let user: String
    let domain: String

    func makeClient(password: String) throws -> SMB2Manager {
        guard let address = SMBAddress(address) else { throw SMBFailure.address }
        let credential: URLCredential? = user.isEmpty ? nil :
            URLCredential(user: user, password: password, persistence: .none)
        guard let client = SMB2Manager(url: address.server, domain: domain, credential: credential) else {
            throw SMBFailure.address
        }
        client.timeout = 8
        return client
    }
}

struct SMBScannedFile: Sendable {
    let share: String
    let path: String
    let name: String
    let fileSize: Int64?
    let sidecarSubtitles: [String]
}

@MainActor
final class SMBProfiles: ObservableObject {
    @Published private(set) var saved: [SMBProfile]
    private let defaults = UserDefaults.standard
    private let storeKey = "smbProfiles"
    private let keychainService = "com.local.cinema.smb"

    init() {
        if let data = UserDefaults.standard.data(forKey: "smbProfiles"),
           let profiles = try? JSONDecoder().decode([SMBProfile].self, from: data) {
            saved = profiles
        } else {
            saved = []
        }
    }

    func save(_ profile: SMBProfile, password: String) throws {
        let next = [profile] + saved.filter { $0.id != profile.id }
        let data = try JSONEncoder().encode(next)
        guard KeychainStore.write(password, service: keychainService, account: profile.id.uuidString) else {
            throw SMBFailure.credentials
        }
        defaults.set(data, forKey: storeKey)
        saved = next
    }

    func remove(_ profile: SMBProfile) throws {
        let next = saved.filter { $0.id != profile.id }
        let data = try JSONEncoder().encode(next)
        guard KeychainStore.delete(service: keychainService, account: profile.id.uuidString) else {
            throw SMBFailure.credentials
        }
        defaults.set(data, forKey: storeKey)
        saved = next
    }

    func password(for profile: SMBProfile) -> String {
        KeychainStore.read(service: keychainService, account: profile.id.uuidString) ?? ""
    }

    func prepare(_ location: SMBMediaLocation) async throws -> SMBReadSource {
        guard let profile = saved.first(where: { $0.id == location.connectionID }) else { throw SMBFailure.missing }
        let client = try profile.makeClient(password: password(for: profile))
        try await client.connectShare(name: location.share)
        let values = try await client.attributesOfItem(atPath: location.path)
        guard let size = (values[.fileSizeKey] as? NSNumber)?.int64Value, size > 0 else { throw SMBFailure.file }
        return SMBReadSource(client: client, path: location.path, length: size)
    }

    func scanFolder(profile: SMBProfile, share: String, folderPath: String) async throws -> [SMBScannedFile] {
        let client = try profile.makeClient(password: password(for: profile))
        try await client.connectShare(name: share)
        let rows = try await client.contentsOfDirectory(atPath: folderPath, recursive: true)

        var subtitleByStem: [String: [String]] = [:]
        var videoRows: [(name: String, path: String, size: Int64?)] = []

        for row in rows {
            let isDir = (row[.isDirectoryKey] as? NSNumber)?.boolValue == true
            guard !isDir, let relPath = (row[.pathKey] as? String) ?? (row[.nameKey] as? String) else { continue }
            let normalized = relPath.hasPrefix("/") ? relPath : (folderPath == "/" ? "/\(relPath)" : "\(folderPath)/\(relPath)")
            let url = URL(fileURLWithPath: normalized)
            let ext = url.pathExtension.lowercased()
            let stem = url.deletingPathExtension().path.lowercased()
            if MediaLibrary.subtitleExtensions.contains(ext) {
                subtitleByStem[stem, default: []].append(normalized)
            } else if MediaLibrary.fileExtensions.contains(ext) {
                let size = (row[.fileSizeKey] as? NSNumber)?.int64Value
                videoRows.append((url.lastPathComponent, normalized, size))
            }
        }

        return videoRows.map { row in
            let stem = URL(fileURLWithPath: row.path).deletingPathExtension().path.lowercased()
            let exactMatches = subtitleByStem[stem] ?? []
            let prefixMatches = subtitleByStem.filter { $0.key.hasPrefix(stem + ".") }.flatMap(\.value)
            let sidecars = Array(Set(exactMatches + prefixMatches)).sorted()
            return SMBScannedFile(share: share, path: row.path, name: row.name, fileSize: row.size, sidecarSubtitles: sidecars)
        }
    }

    func downloadSidecarSubtitles(for location: SMBMediaLocation, sidecars: [String]) async -> [URL] {
        guard !sidecars.isEmpty,
              let profile = saved.first(where: { $0.id == location.connectionID }),
              let client = try? profile.makeClient(password: password(for: profile)) else {
            return []
        }
        do {
            try await client.connectShare(name: location.share)
        } catch {
            return []
        }

        var localURLs: [URL] = []
        let subDir = FileManager.default.temporaryDirectory.appendingPathComponent("LocalCinemaSubs", isDirectory: true)
        try? FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        for remotePath in sidecars.prefix(4) {
            do {
                var data = Data()
                for try await chunk in client.contents(atPath: remotePath, range: 0..<Int64(8 * 1024 * 1024)) {
                    data.append(chunk)
                }
                guard !data.isEmpty else { continue }
                let filename = URL(fileURLWithPath: remotePath).lastPathComponent
                let dest = subDir.appendingPathComponent("\(UUID().uuidString)_\(filename)")
                try data.write(to: dest, options: .atomic)
                localURLs.append(dest)
            } catch {
                continue
            }
        }
        return localURLs
    }
}

enum SMBFailure: LocalizedError {
    case address, credentials, missing, file

    var errorDescription: String? {
        switch self {
        case .address: return "Nhập địa chỉ như smb://192.168.1.20/Phim."
        case .credentials: return "Không thể lưu thông tin đăng nhập SMB vào Keychain."
        case .missing: return "Kết nối SMB đã bị gỡ. Hãy mở lại video từ Nguồn SMB."
        case .file: return "Không thể đọc tệp video trên máy chủ SMB."
        }
    }
}
