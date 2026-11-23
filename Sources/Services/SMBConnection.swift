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
        let normKey = Self.dedupeKey(for: profile)
        let duplicates = saved.filter { $0.id != profile.id && Self.dedupeKey(for: $0) == normKey }
        for dup in duplicates {
            _ = KeychainStore.delete(service: keychainService, account: dup.id.uuidString)
        }
        let next = [profile] + saved.filter { $0.id != profile.id && Self.dedupeKey(for: $0) != normKey }
        let data = try JSONEncoder().encode(next)
        guard KeychainStore.write(password, service: keychainService, account: profile.id.uuidString) else {
            throw SMBFailure.credentials
        }
        defaults.set(data, forKey: storeKey)
        saved = next
    }

    func existingProfileID(matchingAddress address: String, user: String) -> UUID? {
        let probe = SMBProfile(address: address, user: user, domain: "")
        let key = Self.dedupeKey(for: probe)
        return saved.first { Self.dedupeKey(for: $0) == key }?.id
    }

    private static func dedupeKey(for profile: SMBProfile) -> String {
        let hostPart = SMBAddress(profile.address)?.server.absoluteString.lowercased()
            ?? profile.address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pathPart = SMBAddress(profile.address)?.folders.joined(separator: "/").lowercased() ?? ""
        return "\(hostPart)|\(pathPart)|\(profile.user.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
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

        var subtitlePaths: [String] = []
        var videoRows: [(name: String, path: String, size: Int64?)] = []

        for row in rows {
            let isDir = (row[.isDirectoryKey] as? NSNumber)?.boolValue == true
            guard !isDir, let relPath = (row[.pathKey] as? String) ?? (row[.nameKey] as? String) else { continue }
            let normalized = relPath.hasPrefix("/") ? relPath : (folderPath == "/" ? "/\(relPath)" : "\(folderPath)/\(relPath)")
            let url = URL(fileURLWithPath: normalized)
            let ext = url.pathExtension.lowercased()
            if MediaLibrary.subtitleExtensions.contains(ext) {
                subtitlePaths.append(normalized)
            } else if MediaLibrary.fileExtensions.contains(ext) {
                let size = (row[.fileSizeKey] as? NSNumber)?.int64Value
                videoRows.append((url.lastPathComponent, normalized, size))
            }
        }

        return videoRows.map { row in
            let sidecars = FolderSubtitleMatcher.match(videoPath: row.path, candidateSubtitlePaths: subtitlePaths)
            return SMBScannedFile(share: share, path: row.path, name: row.name, fileSize: row.size, sidecarSubtitles: sidecars)
        }
    }

    func findFolderSubtitles(for location: SMBMediaLocation) async -> [String] {
        guard let profile = saved.first(where: { $0.id == location.connectionID }),
              let client = try? profile.makeClient(password: password(for: profile)) else {
            return []
        }
        do {
            try await client.connectShare(name: location.share)
            let normalizedVideo = location.path.hasPrefix("/") ? location.path : "/\(location.path)"
            let parentURL = URL(fileURLWithPath: normalizedVideo).deletingLastPathComponent()
            let parentPath = parentURL.path.isEmpty ? "/" : parentURL.path

            let rows = try await client.contentsOfDirectory(atPath: parentPath)
            var candidates: [String] = []
            var subFolderPaths: [String] = []

            for row in rows {
                guard let name = row[.nameKey] as? String, SMBAddress.validComponent(name) else { continue }
                let isDir = (row[.isDirectoryKey] as? NSNumber)?.boolValue == true
                let fullPath = parentPath == "/" ? "/\(name)" : "\(parentPath)/\(name)"
                if isDir {
                    if FolderSubtitleMatcher.isSubtitleFolderName(name) {
                        subFolderPaths.append(fullPath)
                    }
                } else if MediaLibrary.subtitleExtensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased()) {
                    candidates.append(fullPath)
                }
            }

            for subDirPath in subFolderPaths.prefix(2) {
                if let subRows = try? await client.contentsOfDirectory(atPath: subDirPath) {
                    for sRow in subRows {
                        guard let sName = sRow[.nameKey] as? String,
                              SMBAddress.validComponent(sName),
                              (sRow[.isDirectoryKey] as? NSNumber)?.boolValue != true else { continue }
                        if MediaLibrary.subtitleExtensions.contains(URL(fileURLWithPath: sName).pathExtension.lowercased()) {
                            candidates.append("\(subDirPath)/\(sName)")
                        }
                    }
                }
            }

            return FolderSubtitleMatcher.match(videoPath: normalizedVideo, candidateSubtitlePaths: candidates)
        } catch {
            return []
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

        for remotePath in sidecars.prefix(8) {
            do {
                let data = try await client.contents(
                    atPath: remotePath,
                    range: 0..<Int64(8 * 1024 * 1024),
                    progress: nil
                )
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
