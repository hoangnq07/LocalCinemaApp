import CryptoKit
import SwiftUI
import UIKit

enum AppTheme: String, CaseIterable, Identifiable, Codable {
    case obsidian
    case teal
    case minimal

    var id: Self { self }

    var title: String {
        switch self {
        case .obsidian: return "Obsidian Cinema"
        case .teal: return "Midnight Teal Pro"
        case .minimal: return "Pure Black Minimal"
        }
    }

    var subtitle: String {
        switch self {
        case .obsidian: return "Apple TV+ / VidHub · Kính mờ & Vàng điện ảnh"
        case .teal: return "Kế thừa Local Cinema · Xanh đen ngọc bích"
        case .minimal: return "SenPlayer OLED · Đen tuyền tiết kiệm pin"
        }
    }

    var palette: CinemaPalette {
        switch self {
        case .obsidian:
            return CinemaPalette(
                background: Color(red: 0.027, green: 0.035, blue: 0.051),
                elevated: Color(red: 0.063, green: 0.078, blue: 0.114),
                surface: Color.white.opacity(0.068),
                surfaceStrong: Color.white.opacity(0.12),
                border: Color.white.opacity(0.11),
                text: Color(red: 0.973, green: 0.980, blue: 0.988),
                muted: Color(red: 0.580, green: 0.639, blue: 0.722),
                ctaBackground: Color.white,
                ctaForeground: Color(red: 0.027, green: 0.035, blue: 0.051),
                accent: Color(red: 0.369, green: 0.918, blue: 0.831),
                gold: Color(red: 0.961, green: 0.718, blue: 0.192),
                danger: Color(red: 0.984, green: 0.443, blue: 0.522),
                glow: Color(red: 0.961, green: 0.718, blue: 0.192).opacity(0.19)
            )
        case .teal:
            return CinemaPalette(
                background: Color(red: 0.027, green: 0.063, blue: 0.078),
                elevated: Color(red: 0.051, green: 0.114, blue: 0.141),
                surface: Color(red: 0.082, green: 0.184, blue: 0.227).opacity(0.68),
                surfaceStrong: Color(red: 0.122, green: 0.267, blue: 0.325).opacity(0.84),
                border: Color(red: 0.369, green: 0.918, blue: 0.831).opacity(0.17),
                text: Color(red: 0.941, green: 0.992, blue: 0.976),
                muted: Color(red: 0.561, green: 0.710, blue: 0.729),
                ctaBackground: Color(red: 0.369, green: 0.918, blue: 0.831),
                ctaForeground: Color(red: 0.020, green: 0.075, blue: 0.090),
                accent: Color(red: 0.369, green: 0.918, blue: 0.831),
                gold: Color(red: 0.984, green: 0.749, blue: 0.141),
                danger: Color(red: 0.984, green: 0.443, blue: 0.522),
                glow: Color(red: 0.369, green: 0.918, blue: 0.831).opacity(0.18)
            )
        case .minimal:
            return CinemaPalette(
                background: Color.black,
                elevated: Color(red: 0.047, green: 0.047, blue: 0.055),
                surface: Color(red: 0.075, green: 0.075, blue: 0.090),
                surfaceStrong: Color(red: 0.118, green: 0.118, blue: 0.141),
                border: Color.white.opacity(0.09),
                text: Color.white,
                muted: Color(red: 0.557, green: 0.557, blue: 0.576),
                ctaBackground: Color(red: 0.039, green: 0.518, blue: 1.0),
                ctaForeground: Color.white,
                accent: Color(red: 0.039, green: 0.518, blue: 1.0),
                gold: Color(red: 1.0, green: 0.839, blue: 0.039),
                danger: Color(red: 1.0, green: 0.271, blue: 0.227),
                glow: Color(red: 0.039, green: 0.518, blue: 1.0).opacity(0.16)
            )
        }
    }
}

struct CinemaPalette: Equatable {
    let background: Color
    let elevated: Color
    let surface: Color
    let surfaceStrong: Color
    let border: Color
    let text: Color
    let muted: Color
    let ctaBackground: Color
    let ctaForeground: Color
    let accent: Color
    let gold: Color
    let danger: Color
    let glow: Color
}

enum CinemaStyle {
    static var currentTheme: AppTheme {
        if let raw = UserDefaults.standard.string(forKey: "appTheme"),
           let theme = AppTheme(rawValue: raw) {
            return theme
        }
        return .obsidian
    }

    static var palette: CinemaPalette { currentTheme.palette }
    static var background: Color { palette.background }
    static var elevated: Color { palette.elevated }
    static var panel: Color { palette.surface }
    static var panelStrong: Color { palette.surfaceStrong }
    static var border: Color { palette.border }
    static var text: Color { palette.text }
    static var muted: Color { palette.muted }
    static var ctaBackground: Color { palette.ctaBackground }
    static var ctaForeground: Color { palette.ctaForeground }
    static var accent: Color { palette.accent }
    static var gold: Color { palette.gold }
    static var danger: Color { palette.danger }
    static var glow: Color { palette.glow }
}

struct ObsidianGlassModifier: ViewModifier {
    var cornerRadius: CGFloat = 18
    var strong: Bool = false

    func body(content: Content) -> some View {
        content
            .background(strong ? CinemaStyle.panelStrong : CinemaStyle.panel,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(CinemaStyle.border, lineWidth: 1)
            )
    }
}

extension View {
    func obsidianGlass(cornerRadius: CGFloat = 18, strong: Bool = false) -> some View {
        modifier(ObsidianGlassModifier(cornerRadius: cornerRadius, strong: strong))
    }
}

enum TechBadgeTone {
    case neutral, gold, accent, danger
}

struct TechBadge: View {
    let text: String
    var tone: TechBadgeTone = .neutral

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.2)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 0.75)
            )
    }

    private var foreground: Color {
        switch tone {
        case .neutral: return CinemaStyle.text
        case .gold: return CinemaStyle.gold
        case .accent: return CinemaStyle.accent
        case .danger: return CinemaStyle.danger
        }
    }

    private var background: Color {
        switch tone {
        case .neutral: return Color.black.opacity(0.62)
        case .gold: return CinemaStyle.gold.opacity(0.18)
        case .accent: return CinemaStyle.accent.opacity(0.18)
        case .danger: return CinemaStyle.danger.opacity(0.18)
        }
    }

    private var stroke: Color {
        switch tone {
        case .neutral: return Color.white.opacity(0.16)
        case .gold: return CinemaStyle.gold.opacity(0.42)
        case .accent: return CinemaStyle.accent.opacity(0.42)
        case .danger: return CinemaStyle.danger.opacity(0.42)
        }
    }
}

actor CinemaImageCache {
    static let shared = CinemaImageCache()

    private let memory = NSCache<NSURL, UIImage>()
    private let directory: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directory = caches.appendingPathComponent("LocalCinemaArtwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.countLimit = 180
    }

    func image(for url: URL) async -> UIImage? {
        if let cached = memory.object(forKey: url as NSURL) {
            return cached
        }
        let diskURL = fileURL(for: url)
        if let data = try? Data(contentsOf: diskURL), let image = UIImage(data: data) {
            memory.setObject(image, forKey: url as NSURL)
            return image
        }
        do {
            let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(status),
                  let image = UIImage(data: data) else {
                return nil
            }
            memory.setObject(image, forKey: url as NSURL)
            try? data.write(to: diskURL, options: .atomic)
            return image
        } catch {
            return nil
        }
    }

    func cacheSizeBytes() -> Int64 {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return urls.reduce(0) { sum, file in
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sum + Int64(size)
        }
    }

    func clear() {
        memory.removeAllObjects()
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }

    private func fileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("img")
    }
}

struct CinemaArtwork: View {
    enum Fallback { case generic, coast }
    let url: URL?
    var fallback: Fallback = .generic
    var titleHint: String? = nil

    @State private var loaded: UIImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let loaded {
                    Image(uiImage: loaded)
                        .resizable()
                        .scaledToFill()
                } else if fallback == .coast {
                    Image("Coast")
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        LinearGradient(
                            colors: [CinemaStyle.elevated, CinemaStyle.background],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        RadialGradient(
                            colors: [CinemaStyle.glow, .clear],
                            center: .topTrailing,
                            startRadius: 4,
                            endRadius: max(geometry.size.width, 120)
                        )
                        VStack(spacing: 8) {
                            Image(systemName: "film.stack")
                                .font(.system(size: 24, weight: .light))
                                .foregroundStyle(CinemaStyle.accent.opacity(0.65))
                            if let titleHint, !titleHint.isEmpty {
                                Text(titleHint)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(CinemaStyle.muted)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 10)
                            }
                        }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .accessibilityHidden(true)
        .task(id: url) {
            loaded = nil
            guard let url else { return }
            loaded = await CinemaImageCache.shared.image(for: url)
        }
    }
}
