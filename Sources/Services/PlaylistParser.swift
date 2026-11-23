import Foundation

struct PlaylistEntry: Identifiable, Equatable, Sendable {
    let id = UUID()
    let title: String
    let url: URL
    let headers: [String: String]
}

enum PlaylistParser {
    static func parseM3U(_ content: String) -> [PlaylistEntry] {
        var entries: [PlaylistEntry] = []
        var pendingTitle: String?
        var pendingHeaders: [String: String] = [:]

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if line.hasPrefix("#EXTINF:") {
                if let commaIndex = line.firstIndex(of: ",") {
                    let name = String(line[line.index(after: commaIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { pendingTitle = name }
                }
                continue
            }

            if line.hasPrefix("#EXTVLCOPT:") {
                let opt = String(line.dropFirst("#EXTVLCOPT:".count))
                if opt.lowercased().hasPrefix("http-user-agent=") {
                    pendingHeaders["User-Agent"] = String(opt.dropFirst("http-user-agent=".count))
                } else if opt.lowercased().hasPrefix("http-referrer=") {
                    pendingHeaders["Referer"] = String(opt.dropFirst("http-referrer=".count))
                }
                continue
            }

            if line.hasPrefix("#") { continue }

            if let url = URL(string: line),
               let scheme = url.scheme?.lowercased(),
               ["http", "https", "rtsp", "rtmp"].contains(scheme) {
                let title = pendingTitle ?? url.deletingPathExtension().lastPathComponent
                entries.append(PlaylistEntry(
                    title: title.isEmpty ? (url.host ?? "Luồng phát") : title,
                    url: url,
                    headers: pendingHeaders
                ))
            }
            pendingTitle = nil
            pendingHeaders = [:]
        }
        return entries
    }

    static func parseSTRM(_ content: String, fallbackTitle: String) -> PlaylistEntry? {
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let url = URL(string: line),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https", "smb"].contains(scheme) else { continue }
            return PlaylistEntry(title: fallbackTitle, url: url, headers: [:])
        }
        return nil
    }
}
