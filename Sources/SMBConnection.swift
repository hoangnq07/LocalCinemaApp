import AMSMB2
import Foundation
import Security
import SwiftUI

struct SMBMediaLocation: Codable, Equatable, Sendable {
    let connectionID: UUID
    let share: String
    let path: String
}

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

@MainActor
final class SMBProfiles: ObservableObject {
    @Published private(set) var saved: [SMBProfile]
    private let defaults = UserDefaults.standard
    private let storeKey = "smbProfiles"

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
        try Self.writePassword(password, for: profile.id)
        defaults.set(data, forKey: storeKey)
        saved = next
    }

    func remove(_ profile: SMBProfile) throws {
        let next = saved.filter { $0.id != profile.id }
        let data = try JSONEncoder().encode(next)
        let result = SecItemDelete(Self.key(profile.id) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw SMBFailure.credentials }
        defaults.set(data, forKey: storeKey)
        saved = next
    }

    func password(for profile: SMBProfile) -> String {
        var query = Self.key(profile.id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess,
              let data = found as? Data, let password = String(data: data, encoding: .utf8) else { return "" }
        return password
    }

    func prepare(_ location: SMBMediaLocation) async throws -> SMBReadSource {
        guard let profile = saved.first(where: { $0.id == location.connectionID }) else { throw SMBFailure.missing }
        let client = try profile.makeClient(password: password(for: profile))
        try await client.connectShare(name: location.share)
        let values = try await client.attributesOfItem(atPath: location.path)
        guard let size = (values[.fileSizeKey] as? NSNumber)?.int64Value, size > 0 else { throw SMBFailure.file }
        return SMBReadSource(client: client, path: location.path, length: size)
    }

    private static func key(_ id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.local.cinema.smb",
            kSecAttrAccount as String: id.uuidString
        ]
    }

    private static func writePassword(_ password: String, for id: UUID) throws {
        let query = key(id)
        let attributes = [kSecValueData as String: Data(password.utf8)]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw SMBFailure.credentials }
        var entry = query
        entry[kSecValueData as String] = attributes[kSecValueData as String]
        entry[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(entry as CFDictionary, nil) == errSecSuccess else { throw SMBFailure.credentials }
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
