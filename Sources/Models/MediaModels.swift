import Foundation

// MARK: - Playback & Enhancement Enums

enum VideoUpscaler: String, CaseIterable, Identifiable, Codable, Sendable {
    case standard
    case lanczos
    case aiFSRCNNX
    case aiCinemaDetail

    var id: Self { self }

    var label: String {
        switch self {
        case .standard: return "Tiêu chuẩn"
        case .lanczos: return "Lanczos sắc nét"
        case .aiFSRCNNX: return "AI · FSRCNNX ×2"
        case .aiCinemaDetail: return "AI Siêu nét · FSRCNNX + CAS"
        }
    }

    var shortLabel: String {
        switch self {
        case .standard: return "Tiêu chuẩn"
        case .lanczos: return "Lanczos"
        case .aiFSRCNNX: return "FSRCNNX ×2"
        case .aiCinemaDetail: return "AI Siêu nét"
        }
    }

    var filter: String {
        self == .standard ? "bilinear" : "ewa_lanczossharp"
    }

    var usesNeuralShader: Bool {
        self == .aiFSRCNNX || self == .aiCinemaDetail
    }
}

enum HDRDisplayMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case autoEDR
    case toneMapSDR

    var id: Self { self }

    var label: String {
        switch self {
        case .autoEDR: return "Tự động HDR / Dolby Vision EDR"
        case .toneMapSDR: return "Tone-map về SDR"
        }
    }

    var shortLabel: String {
        switch self {
        case .autoEDR: return "Tự động EDR"
        case .toneMapSDR: return "SDR"
        }
    }
}

enum SDRtoHDRMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case off
    case natural
    case cinema
    case vivid

    var id: Self { self }

    var label: String {
        switch self {
        case .off: return "Tắt"
        case .natural: return "Tự nhiên · 400 nit"
        case .cinema: return "Rạp phim · 600 nit"
        case .vivid: return "Rực rỡ · 1000 nit"
        }
    }

    var shortLabel: String {
        switch self {
        case .off: return "Tắt"
        case .natural: return "Tự nhiên"
        case .cinema: return "Rạp phim"
        case .vivid: return "Rực rỡ"
        }
    }

    var targetPeakNits: Int {
        switch self {
        case .off: return 0
        case .natural: return 400
        case .cinema: return 600
        case .vivid: return 1000
        }
    }
}

enum MotionInterpolation: String, CaseIterable, Identifiable, Codable, Sendable {
    case off
    case cinema
    case smooth
    case sport

    var id: Self { self }

    var label: String {
        switch self {
        case .off: return "Tắt"
        case .cinema: return "Mượt điện ảnh · Oversample"
        case .smooth: return "Siêu mượt · Mitchell"
        case .sport: return "Thể thao · Catmull-Rom"
        }
    }

    var shortLabel: String {
        switch self {
        case .off: return "Tắt"
        case .cinema: return "Mượt điện ảnh"
        case .smooth: return "Siêu mượt"
        case .sport: return "Thể thao"
        }
    }

    var tscale: String {
        switch self {
        case .off, .cinema: return "oversample"
        case .smooth: return "mitchell"
        case .sport: return "catmull_rom"
        }
    }
}

enum InterpolationFPS: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto
    case fps60
    case fps120

    var id: Self { self }

    var label: String {
        switch self {
        case .auto: return "Theo màn hình"
        case .fps60: return "60 Hz"
        case .fps120: return "120 Hz"
        }
    }

    var overrideHz: Int {
        switch self {
        case .auto: return 0
        case .fps60: return 60
        case .fps120: return 120
        }
    }
}

struct EnhancementDecision: Equatable, Sendable {
    let effectiveUpscaler: VideoUpscaler
    let effectiveSDRToHDR: SDRtoHDRMode
    let effectiveInterpolation: MotionInterpolation
    let effectiveInterpolationFPS: InterpolationFPS
    let nativeHDRActive: Bool
    let sdrToHDRBypassedForNativeHDR: Bool
    let thermalThrottled: Bool
    let thermalNotice: String?
}

enum EnhancementPolicy {
    static func isHDRSource(sigPeak: Double, primaries: String?, gamma: String?) -> Bool {
        let p = primaries?.lowercased() ?? ""
        let g = gamma?.lowercased() ?? ""
        return sigPeak > 1.05 || p == "bt.2020" || g == "pq" || g == "hlg"
    }

    static func resolve(
        upscaler: VideoUpscaler,
        hdrMode: HDRDisplayMode,
        sdrToHDR: SDRtoHDRMode,
        interpolation: MotionInterpolation,
        interpolationFPS: InterpolationFPS,
        sourceIsHDR: Bool,
        edrAvailable: Bool,
        thermalState: ProcessInfo.ThermalState
    ) -> EnhancementDecision {
        var effUpscaler = upscaler
        var effSDRToHDR = sdrToHDR
        var effInterpolation = interpolation
        var throttled = false
        var notice: String?

        switch thermalState {
        case .serious:
            if effUpscaler.usesNeuralShader {
                effUpscaler = .lanczos
                throttled = true
            }
            if effInterpolation != .off {
                effInterpolation = .off
                throttled = true
            }
            if throttled {
                notice = "Máy đang nóng · tự hạ AI/Nội suy về Lanczos để giữ ổn định."
            }
        case .critical:
            if effUpscaler != .standard {
                effUpscaler = .standard
                throttled = true
            }
            if effInterpolation != .off {
                effInterpolation = .off
                throttled = true
            }
            if effSDRToHDR != .off {
                effSDRToHDR = .off
                throttled = true
            }
            if throttled {
                notice = "Nhiệt độ cao · tạm tắt xử lý GPU nặng để bảo vệ máy."
            }
        default:
            break
        }

        let bypassed = sourceIsHDR && effSDRToHDR != .off
        if sourceIsHDR {
            effSDRToHDR = .off
        }
        let nativeHDR = sourceIsHDR && hdrMode == .autoEDR && edrAvailable

        return EnhancementDecision(
            effectiveUpscaler: effUpscaler,
            effectiveSDRToHDR: effSDRToHDR,
            effectiveInterpolation: effInterpolation,
            effectiveInterpolationFPS: interpolationFPS,
            nativeHDRActive: nativeHDR,
            sdrToHDRBypassedForNativeHDR: bypassed,
            thermalThrottled: throttled,
            thermalNotice: notice
        )
    }
}

enum AspectMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case fit
    case fill
    case stretch
    case ratio16x9
    case ratio21x9
    case ratio4x3

    var id: Self { self }

    var label: String {
        switch self {
        case .fit: return "Vừa khung"
        case .fill: return "Lấp đầy"
        case .stretch: return "Kéo giãn"
        case .ratio16x9: return "16:9"
        case .ratio21x9: return "21:9"
        case .ratio4x3: return "4:3"
        }
    }
}

enum AudioOutput: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic
    case stereo
    case surround51
    case surround71

    var id: Self { self }

    var label: String {
        switch self {
        case .automatic: return "Tự động theo thiết bị"
        case .stereo: return "Stereo (2.0)"
        case .surround51: return "Âm thanh vòm 5.1"
        case .surround71: return "Âm thanh vòm 7.1"
        }
    }

    var shortLabel: String {
        switch self {
        case .automatic: return "Tự động"
        case .stereo: return "Stereo"
        case .surround51: return "5.1"
        case .surround71: return "7.1"
        }
    }

    var option: String {
        switch self {
        case .automatic: return "auto"
        case .stereo: return "stereo"
        case .surround51: return "5.1"
        case .surround71: return "7.1"
        }
    }
}

enum ColorPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case original
    case cinema
    case vivid
    case night
    case anime

    var id: Self { self }

    var label: String {
        switch self {
        case .original: return "Gốc"
        case .cinema: return "Rạp phim"
        case .vivid: return "Sống động"
        case .night: return "Phòng tối"
        case .anime: return "Anime"
        }
    }

    var brightness: Double {
        switch self {
        case .original: return 0
        case .cinema: return -2
        case .vivid: return 4
        case .night: return -10
        case .anime: return 2
        }
    }

    var contrast: Double {
        switch self {
        case .original: return 0
        case .cinema: return 6
        case .vivid: return 10
        case .night: return -4
        case .anime: return 6
        }
    }

    var saturation: Double {
        switch self {
        case .original: return 0
        case .cinema: return 4
        case .vivid: return 18
        case .night: return -6
        case .anime: return 14
        }
    }

    var gamma: Double {
        switch self {
        case .original: return 0
        case .cinema: return -3
        case .vivid: return 0
        case .night: return 4
        case .anime: return 0
        }
    }
}

enum SubtitleColorOption: String, CaseIterable, Identifiable, Codable, Sendable {
    case white
    case yellow
    case cyan
    case green

    var id: Self { self }

    var label: String {
        switch self {
        case .white: return "Trắng"
        case .yellow: return "Vàng"
        case .cyan: return "Xanh ngọc"
        case .green: return "Xanh lá"
        }
    }

    var mpvColor: String {
        switch self {
        case .white: return "#FFFFFFFF"
        case .yellow: return "#FFFDE047"
        case .cyan: return "#FF5EEAD4"
        case .green: return "#FF4ADE80"
        }
    }
}

enum SleepTimerOption: Int, CaseIterable, Identifiable, Codable, Sendable {
    case off = 0
    case min15 = 15
    case min30 = 30
    case min45 = 45
    case min60 = 60
    case endOfVideo = -1

    var id: Self { self }

    var label: String {
        switch self {
        case .off: return "Tắt"
        case .min15: return "15 phút"
        case .min30: return "30 phút"
        case .min45: return "45 phút"
        case .min60: return "60 phút"
        case .endOfVideo: return "Hết video"
        }
    }
}

// MARK: - Media Locations & Technical Metadata

struct SMBMediaLocation: Codable, Equatable, Hashable, Sendable {
    let connectionID: UUID
    let share: String
    let path: String
}

struct WebDAVMediaLocation: Codable, Equatable, Hashable, Sendable {
    let profileID: UUID
    let path: String
}

struct MediaServerMediaLocation: Codable, Equatable, Hashable, Sendable {
    let serverID: UUID
    let itemID: String
    let kind: MediaServerKind
}

struct PlexMediaLocation: Codable, Equatable, Hashable, Sendable {
    let serverID: UUID
    let ratingKey: String
    let partKey: String
}

enum MediaServerKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case jellyfin
    case emby
    case plex

    var id: Self { self }

    var label: String {
        switch self {
        case .jellyfin: return "Jellyfin"
        case .emby: return "Emby"
        case .plex: return "Plex"
        }
    }
}

struct MediaTechnicalInfo: Codable, Equatable, Sendable {
    var width: Int?
    var height: Int?
    var resolutionLabel: String?
    var videoCodec: String?
    var hdrLabel: String?
    var audioLabel: String?
    var fileSize: Int64?
    var sidecarSubtitles: [String] = []

    var formattedSize: String? {
        guard let fileSize, fileSize > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var badges: [String] {
        [resolutionLabel, hdrLabel, videoCodec, audioLabel, formattedSize].compactMap { $0 }
    }
}

struct EpisodeInfo: Codable, Equatable, Sendable {
    var seriesTitle: String
    var season: Int
    var episode: Int
    var episodeTitle: String?

    var shortCode: String {
        "M\(season) · T\(episode)"
    }

    var fullCode: String {
        String(format: "S%02dE%02d", season, episode)
    }
}

enum MediaSource: Codable, Equatable, Sendable {
    case remote(URL)
    case file(String)
    case smb(SMBMediaLocation)
    case remoteAuth(URL, headers: [String: String])
    case webdav(WebDAVMediaLocation)
    case mediaServer(MediaServerMediaLocation)
    case plex(PlexMediaLocation)

    var label: String {
        switch self {
        case .remote(let url), .remoteAuth(let url, _):
            return url.host ?? "Liên kết HTTP"
        case .file:
            return "Trên máy"
        case .smb(let location):
            return "SMB · \(location.share)"
        case .webdav:
            return "WebDAV"
        case .mediaServer(let loc):
            return loc.kind.label
        case .plex:
            return "Plex"
        }
    }

    var categoryTag: String {
        switch self {
        case .remote, .remoteAuth: return "Liên kết"
        case .file: return "Trên máy"
        case .smb: return "SMB"
        case .webdav: return "WebDAV"
        case .mediaServer(let loc): return loc.kind.label
        case .plex: return "Plex"
        }
    }

    var format: String? {
        let suffix: String
        switch self {
        case .remote(let url), .remoteAuth(let url, _):
            suffix = url.pathExtension
        case .file(let filename):
            suffix = URL(fileURLWithPath: filename).pathExtension
        case .smb(let location):
            suffix = URL(fileURLWithPath: location.path).pathExtension
        case .webdav(let location):
            suffix = URL(fileURLWithPath: location.path).pathExtension
        case .mediaServer:
            return "STREAM"
        case .plex(let loc):
            suffix = URL(fileURLWithPath: loc.partKey).pathExtension
        }
        return MediaLibrary.fileExtensions.contains(suffix.lowercased()) ? suffix.uppercased() : nil
    }

    var pathDescription: String {
        switch self {
        case .remote(let url), .remoteAuth(let url, _):
            return url.absoluteString
        case .file(let name):
            return name
        case .smb(let loc):
            return "smb://\(loc.share)\(loc.path)"
        case .webdav(let loc):
            return "webdav://\(loc.path)"
        case .mediaServer(let loc):
            return "\(loc.kind.label) · ID \(loc.itemID)"
        case .plex(let loc):
            return "Plex · \(loc.partKey)"
        }
    }
}

struct MediaItem: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    let source: MediaSource
    var metadata: MovieMetadata?
    var favorite = false
    var watched = false
    var position = 0.0
    var duration = 0.0
    var lastPlayed: Date?
    var dateAdded: Date
    var mediaInfo: MediaTechnicalInfo?
    var episodeInfo: EpisodeInfo?

    init(
        id: UUID = UUID(),
        title: String,
        source: MediaSource,
        metadata: MovieMetadata? = nil,
        favorite: Bool = false,
        watched: Bool = false,
        position: Double = 0,
        duration: Double = 0,
        lastPlayed: Date? = nil,
        dateAdded: Date = Date(),
        mediaInfo: MediaTechnicalInfo? = nil,
        episodeInfo: EpisodeInfo? = nil
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.metadata = metadata
        self.favorite = favorite
        self.watched = watched
        self.position = position
        self.duration = duration
        self.lastPlayed = lastPlayed
        self.dateAdded = dateAdded
        self.mediaInfo = mediaInfo
        self.episodeInfo = episodeInfo
    }

    enum CodingKeys: String, CodingKey {
        case id, title, source, metadata, favorite, watched, position, duration, lastPlayed, dateAdded, mediaInfo, episodeInfo
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        source = try container.decode(MediaSource.self, forKey: .source)
        metadata = try container.decodeIfPresent(MovieMetadata.self, forKey: .metadata)
        favorite = try container.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        watched = try container.decodeIfPresent(Bool.self, forKey: .watched) ?? false
        position = try container.decodeIfPresent(Double.self, forKey: .position) ?? 0
        duration = try container.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        lastPlayed = try container.decodeIfPresent(Date.self, forKey: .lastPlayed)
        dateAdded = try container.decodeIfPresent(Date.self, forKey: .dateAdded) ?? Date()
        mediaInfo = try container.decodeIfPresent(MediaTechnicalInfo.self, forKey: .mediaInfo)
        episodeInfo = try container.decodeIfPresent(EpisodeInfo.self, forKey: .episodeInfo)
    }

    var displayTitle: String {
        if let episodeInfo {
            let base = metadata?.title ?? episodeInfo.seriesTitle
            if let epTitle = episodeInfo.episodeTitle, !epTitle.isEmpty {
                return "\(base) · \(episodeInfo.shortCode): \(epTitle)"
            }
            return "\(base) · \(episodeInfo.shortCode)"
        }
        return metadata?.title ?? title
    }

    var cardTitle: String {
        metadata?.title ?? episodeInfo?.seriesTitle ?? title
    }

    var metadataQuery: String {
        if let metadata { return metadata.title }
        if let episodeInfo { return episodeInfo.seriesTitle }
        return FilenameParser.parse(title).searchQuery
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    var isCompleted: Bool {
        watched || progress >= 0.95
    }

    var is4KOrHDR: Bool {
        let res = mediaInfo?.resolutionLabel?.uppercased() ?? ""
        let hdr = mediaInfo?.hdrLabel?.uppercased() ?? ""
        return res.contains("4K") || res.contains("2160") || !hdr.isEmpty
    }

    var remainingText: String? {
        guard duration > 0, position > 0, !isCompleted else { return nil }
        let rem = max(0, Int(duration - position))
        let h = rem / 3600
        let m = (rem % 3600) / 60
        if h > 0 { return "Còn \(h)g \(m)p" }
        return "Còn \(max(1, m))p"
    }
}

struct SeriesGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let seasons: [Int: [MediaItem]]
    let orderedSeasons: [Int]
    let episodes: [MediaItem]
    let metadata: MovieMetadata?
    let latestItem: MediaItem
    let unwatchedCount: Int
    let isFavorite: Bool

    var seasonCount: Int { orderedSeasons.count }
    var episodeCount: Int { episodes.count }

    var summaryLabel: String {
        let seasonText = seasonCount > 1 ? "\(seasonCount) mùa" : "M\(orderedSeasons.first ?? 1)"
        return "\(seasonText) · \(episodeCount) tập"
    }
}

// MARK: - Deterministic Filename Parser

enum FilenameParser {
    struct ParsedResult: Equatable {
        let cleanTitle: String
        let searchQuery: String
        let year: String?
        let episodeInfo: EpisodeInfo?
        let technicalInfo: MediaTechnicalInfo
    }

    static func parse(_ rawName: String, fileSize: Int64? = nil, sidecars: [String] = []) -> ParsedResult {
        let stem = URL(fileURLWithPath: rawName).deletingPathExtension().lastPathComponent
        let spaced = stem
            .replacingOccurrences(of: "[._]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let working = spaced.isEmpty ? rawName : spaced
        let episodeInfo = extractEpisode(from: working)
        let tech = extractTechnicalInfo(from: working, fileSize: fileSize, sidecars: sidecars)
        let year = extractYear(from: working)

        var query = working
        query = query.replacingOccurrences(of: #"\[[^\]]+\]"#, with: " ", options: .regularExpression)
        if let epRange = firstMatchRange(#"(?i)\b(?:S\d{1,2}\s*[.\-_ ]?\s*E\d{1,3}|\d{1,2}x\d{1,3}|EP?\s?\d{1,3}|Tập\s*\d{1,3})\b"#, in: query) {
            query = String(query[..<epRange.lowerBound])
        }
        query = query.replacingOccurrences(
            of: #"(?i)\s+(?:\d{3,4}p|4k|8k|uhd|bluray|blu-ray|bdrip|remux|web[- ]?(?:dl|rip)|hdrip|hdtv|hevc|h\.?26[45]|x26[45]|av1|dv|dovi|dolby\.?vision|hdr10\+?|hdr|truehd|atmos|dts[- ]?hd|eac3|ac3|aac|flac)\b.*$"#,
            with: "",
            options: .regularExpression
        )
        query = query.replacingOccurrences(of: #"\s*\(?\b(19|20)\d{2}\b\)?.*$"#, with: "", options: .regularExpression)
        query = query.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "-–—:")))

        let clean = query.isEmpty ? working : query
        let normalizedEp = episodeInfo.map {
            EpisodeInfo(
                seriesTitle: clean,
                season: $0.season,
                episode: $0.episode,
                episodeTitle: $0.episodeTitle
            )
        }

        return ParsedResult(
            cleanTitle: clean,
            searchQuery: clean,
            year: year,
            episodeInfo: normalizedEp,
            technicalInfo: tech
        )
    }

    private static func extractEpisode(from text: String) -> EpisodeInfo? {
        if let match = firstMatchGroups(#"(?i)\bS(\d{1,2})\s*[.\-_ ]?\s*E(\d{1,3})\b"#, in: text),
           let s = Int(match[1]), let e = Int(match[2]) {
            return EpisodeInfo(seriesTitle: "", season: s, episode: e, episodeTitle: nil)
        }
        if let match = firstMatchGroups(#"(?i)\b(\d{1,2})x(\d{1,3})\b"#, in: text),
           let s = Int(match[1]), let e = Int(match[2]) {
            return EpisodeInfo(seriesTitle: "", season: s, episode: e, episodeTitle: nil)
        }
        if let match = firstMatchGroups(#"(?i)\b(?:EP|E|Tập|Tap)\s*0?(\d{1,3})\b"#, in: text),
           let e = Int(match[1]) {
            return EpisodeInfo(seriesTitle: "", season: 1, episode: e, episodeTitle: nil)
        }
        return nil
    }

    private static func extractYear(from text: String) -> String? {
        guard let groups = firstMatchGroups(#"\b((?:19|20)\d{2})\b"#, in: text) else { return nil }
        return groups[1]
    }

    private static func extractTechnicalInfo(from text: String, fileSize: Int64?, sidecars: [String]) -> MediaTechnicalInfo {
        let lower = text.lowercased()
        var info = MediaTechnicalInfo()
        info.fileSize = fileSize
        info.sidecarSubtitles = sidecars

        if lower.contains("2160p") || lower.contains(" 4k") || lower.hasPrefix("4k ") || lower.contains("uhd") {
            info.resolutionLabel = "4K"
        } else if lower.contains("1080p") {
            info.resolutionLabel = "1080p"
        } else if lower.contains("720p") {
            info.resolutionLabel = "720p"
        }

        if lower.contains("dolby vision") || lower.contains("dovi") || lower.range(of: #"\bdv\b"#, options: .regularExpression) != nil {
            info.hdrLabel = "Dolby Vision"
        } else if lower.contains("hdr10+") {
            info.hdrLabel = "HDR10+"
        } else if lower.contains("hdr10") || lower.range(of: #"\bhdr\b"#, options: .regularExpression) != nil {
            info.hdrLabel = "HDR10"
        }

        if lower.contains("hevc") || lower.contains("x265") || lower.contains("h265") {
            info.videoCodec = "HEVC"
        } else if lower.contains("av1") {
            info.videoCodec = "AV1"
        } else if lower.contains("x264") || lower.contains("h264") {
            info.videoCodec = "H.264"
        }

        if lower.contains("truehd") && lower.contains("atmos") {
            info.audioLabel = "TrueHD Atmos"
        } else if lower.contains("atmos") {
            info.audioLabel = "Dolby Atmos"
        } else if lower.contains("truehd") {
            info.audioLabel = "TrueHD 7.1"
        } else if lower.contains("dts-hd") || lower.contains("dtshd") {
            info.audioLabel = "DTS-HD MA"
        } else if lower.contains("eac3") || lower.contains("ddp") {
            info.audioLabel = "EAC3 5.1"
        } else if lower.contains("flac") {
            info.audioLabel = "FLAC"
        } else if lower.contains("7.1") {
            info.audioLabel = "7.1"
        } else if lower.contains("5.1") {
            info.audioLabel = "5.1"
        }

        return info
    }

    private static func firstMatchRange(_ pattern: String, in text: String) -> Range<String.Index>? {
        text.range(of: pattern, options: .regularExpression)
    }

    private static func firstMatchGroups(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange) else { return nil }
        return (0..<match.numberOfRanges).map { idx in
            let range = match.range(at: idx)
            guard let swiftRange = Range(range, in: text) else { return "" }
            return String(text[swiftRange])
        }
    }
}

// MARK: - Folder Subtitle Auto-Discovery & Matching

enum FolderSubtitleMatcher {
    static let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "sub"]
    static let subtitleFolderNames: Set<String> = ["subs", "subtitles", "sub", "phude", "phu de"]

    static func match(videoPath: String, candidateSubtitlePaths: [String]) -> [String] {
        let normVideo = normalizePath(videoPath)
        let videoURL = URL(fileURLWithPath: normVideo)
        let videoFilename = videoURL.lastPathComponent
        let videoStem = videoURL.deletingPathExtension().lastPathComponent.lowercased()
        let videoComps = directoryComponents(of: normVideo)
        let videoEp = FilenameParser.parse(videoFilename).episodeInfo

        struct Candidate {
            let originalPath: String
            let tier: Int
            let langRank: Int
            let sortKey: String
        }

        var hasSpecificSubs = false
        var prelim: [(Candidate, Bool)] = []

        for raw in candidateSubtitlePaths {
            let normSub = normalizePath(raw)
            let subURL = URL(fileURLWithPath: normSub)
            let ext = subURL.pathExtension.lowercased()
            guard subtitleExtensions.contains(ext) else { continue }

            let subComps = directoryComponents(of: normSub)
            guard isInVideoFolderOrSubsSubfolder(subDir: subComps, videoDir: videoComps, videoStem: videoStem) else {
                continue
            }

            let subFile = subURL.lastPathComponent
            let subStem = subURL.deletingPathExtension().lastPathComponent.lowercased()
            let subEp = FilenameParser.parse(subFile).episodeInfo

            let tier: Int
            if subStem == videoStem
                || subStem.hasPrefix(videoStem + ".")
                || subStem.hasPrefix(videoStem + "_")
                || subStem.hasPrefix(videoStem + "-")
                || subStem.hasPrefix(videoStem + " ") {
                tier = 1
                hasSpecificSubs = true
            } else if let vEp = videoEp, let sEp = subEp, vEp.season == sEp.season, vEp.episode == sEp.episode {
                tier = 2
                hasSpecificSubs = true
            } else if let vEp = videoEp, let sEp = subEp, (vEp.season != sEp.season || vEp.episode != sEp.episode) {
                continue
            } else if videoEp == nil, subEp != nil {
                continue
            } else {
                tier = 3
            }

            let rank = languagePriority(for: subFile)
            prelim.append((
                Candidate(originalPath: raw, tier: tier, langRank: rank, sortKey: normSub.lowercased()),
                subEp != nil
            ))
        }

        let filtered = prelim.map(\.0).filter { cand in
            // If video matched exact stem or exact episode subs, still allow folder-wide subs as secondary options,
            // already ranked after tier 1/2.
            _ = hasSpecificSubs
            return true
        }

        let sorted = filtered.sorted { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            if lhs.langRank != rhs.langRank { return lhs.langRank < rhs.langRank }
            return lhs.sortKey.localizedStandardCompare(rhs.sortKey) == .orderedAscending
        }

        var seen = Set<String>()
        var result: [String] = []
        for entry in sorted {
            let key = normalizePath(entry.originalPath).lowercased()
            if seen.insert(key).inserted {
                result.append(entry.originalPath)
            }
        }
        return result
    }

    static func scanLocalDirectory(for videoURL: URL) -> [URL] {
        let fm = FileManager.default
        let folder = videoURL.deletingLastPathComponent()
        let videoStem = videoURL.deletingPathExtension().lastPathComponent.lowercased()
        guard let topItems = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var candidateURLs: [URL] = []
        for item in topItems {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                if isSubtitleFolderName(item.lastPathComponent),
                   let subItems = try? fm.contentsOfDirectory(
                       at: item,
                       includingPropertiesForKeys: [.isDirectoryKey],
                       options: [.skipsHiddenFiles]
                   ) {
                    for subItem in subItems {
                        let subVals = try? subItem.resourceValues(forKeys: [.isDirectoryKey])
                        if subVals?.isDirectory == true {
                            if subItem.lastPathComponent.lowercased() == videoStem,
                               let nested = try? fm.contentsOfDirectory(at: subItem, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                                candidateURLs.append(contentsOf: nested)
                            }
                        } else if subtitleExtensions.contains(subItem.pathExtension.lowercased()) {
                            candidateURLs.append(subItem)
                        }
                    }
                }
            } else if subtitleExtensions.contains(item.pathExtension.lowercased()) {
                candidateURLs.append(item)
            }
        }

        var byPath: [String: URL] = [:]
        for url in candidateURLs {
            byPath[normalizePath(url.path)] = url
        }
        let orderedPaths = match(videoPath: videoURL.path, candidateSubtitlePaths: candidateURLs.map(\.path))
        return orderedPaths.compactMap { byPath[normalizePath($0)] }
    }

    static func isSubtitleFolderName(_ name: String) -> Bool {
        let normalized = name
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return subtitleFolderNames.contains(normalized)
    }

    private static func normalizePath(_ path: String) -> String {
        var result = path.replacingOccurrences(of: "\\", with: "/")
        while result.contains("//") {
            result = result.replacingOccurrences(of: "//", with: "/")
        }
        if result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    private static func directoryComponents(of normalizedPath: String) -> [String] {
        Array(normalizedPath.split(separator: "/").map(String.init).dropLast())
    }

    private static func isInVideoFolderOrSubsSubfolder(subDir: [String], videoDir: [String], videoStem: String) -> Bool {
        if subDir == videoDir { return true }
        guard subDir.count > videoDir.count,
              Array(subDir.prefix(videoDir.count)) == videoDir else {
            return false
        }
        let extra = Array(subDir.dropFirst(videoDir.count))
        if extra.count == 1 {
            return isSubtitleFolderName(extra[0])
        }
        if extra.count == 2 {
            return isSubtitleFolderName(extra[0]) && extra[1].lowercased() == videoStem
        }
        return false
    }

    private static func languagePriority(for filename: String) -> Int {
        let lower = filename
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        let patternVI = #"(?:^|[._\-\s\[\(])(vi|vie|vn|viet|vietsub|vsub|tiengviet|tieng\s*viet|vietnamese)(?:[._\-\s\]\)]|$)"#
        if lower.range(of: patternVI, options: .regularExpression) != nil {
            return 0
        }
        let patternEN = #"(?:^|[._\-\s\[\(])(en|eng|english)(?:[._\-\s\]\)]|$)"#
        if lower.range(of: patternEN, options: .regularExpression) != nil {
            return 1
        }
        return 2
    }
}
