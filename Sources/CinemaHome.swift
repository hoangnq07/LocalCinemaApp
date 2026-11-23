import SwiftUI

enum CinemaStyle {
    static let background = Color(red: 0.04, green: 0.065, blue: 0.08)
    static let panel = Color(red: 0.08, green: 0.12, blue: 0.15)
    static let accent = Color(red: 0.41, green: 0.92, blue: 0.78)
    static let muted = Color(red: 0.65, green: 0.72, blue: 0.75)
    static let border = Color.white.opacity(0.09)
}

struct CinemaHome: View {
    @ObservedObject var library: MediaLibrary
    @AppStorage("serverURL") private var serverURL = "http://192.168.1.1:8080"
    @State private var section: SectionChoice = .library
    @State private var page: Page?
    @State private var playing: MediaItem?
    @State private var playAfterClosingDetails: MediaItem?
    @State private var pendingRemove: MediaItem?
    @State private var importing = false
    @State private var pickingFile = false
    @State private var query = ""

    private var visibleItems: [MediaItem] {
        let collection = section == .favorites ? library.items.filter(\.favorite) : library.items
        let filter = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filter.isEmpty else { return collection }
        return collection.filter {
            $0.displayTitle.localizedStandardContains(filter) || $0.title.localizedStandardContains(filter)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                header
                if section == .library {
                    hero
                    sources
                    if !library.recent.isEmpty, query.isEmpty { continueWatching }
                }
                collection
            }
            .frame(maxWidth: 820)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .background(CinemaStyle.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
        .scrollDismissesKeyboard(.interactively)
        .sheet(item: $page, onDismiss: {
            playing = playAfterClosingDetails
            playAfterClosingDetails = nil
        }) { value in
            switch value {
            case .link:
                AddLinkView(serverURL: $serverURL) { url, title in
                    library.addLink(url, title: title) != nil
                }
            case .settings:
                CinemaSettings(serverURL: $serverURL)
            case .details(let id):
                if let item = library.item(id) {
                    MovieDetails(item: item, library: library) {
                        playAfterClosingDetails = item
                        page = nil
                    }
                }
            }
        }
        .fullScreenCover(item: $playing) { item in
            CinemaPlayer(item: item, url: library.url(for: item)) { position, duration in
                library.markPlayed(item.id, position: position, duration: duration)
            }
        }
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: MediaLibrary.fileTypes,
                      allowsMultipleSelection: true, onCompletion: importVideos)
        .alert("Không thể lưu thay đổi", isPresented: Binding(
            get: { library.storageError != nil },
            set: { if !$0 { library.storageError = nil } }
        )) {
            Button("Đóng", role: .cancel) {}
        } message: {
            Text(library.storageError ?? "")
        }
        .confirmationDialog("Xóa khỏi thư viện?", isPresented: Binding(
            get: { pendingRemove != nil },
            set: { if !$0 { pendingRemove = nil } }
        ), titleVisibility: .visible, presenting: pendingRemove) { item in
            Button("Xóa", role: .destructive) { library.remove(item) }
        } message: { item in
            Text("“\(item.displayTitle)” sẽ được gỡ khỏi Local Cinema.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.rectangle")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(CinemaStyle.accent)
                .frame(width: 44, height: 44)
                .background(CinemaStyle.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityHidden(true)
            Text("Local Cinema")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button {
                page = .settings
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44)
                    .background(CinemaStyle.panel, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cài đặt")
        }
    }

    private var hero: some View {
        let featured = library.recent.first ?? library.items.first
        return ZStack(alignment: .bottomLeading) {
            GeometryReader { geometry in
                CinemaArtwork(url: featured?.metadata?.backdropURL, fallback: .coast)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            }
            .frame(minHeight: 280)
            LinearGradient(colors: [.clear, .black.opacity(0.25), .black.opacity(0.91)],
                           startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 9) {
                Text(featured?.displayTitle ?? "Rạp phim của bạn")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                if let featured {
                    Text([featured.metadata?.year, featured.source.format].compactMap { $0 }.joined(separator: "  ·  "))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(CinemaStyle.muted)
                } else {
                    Text("Mở phim từ iPhone hoặc máy chủ của bạn.")
                        .font(.subheadline)
                        .foregroundStyle(CinemaStyle.muted)
                }
                Button {
                    if let featured { playing = featured } else { page = .link }
                } label: {
                    Label(featured == nil ? "Mở liên kết" : (featured?.progress ?? 0) > 0 ? "Xem tiếp" : "Phát phim",
                          systemImage: featured == nil ? "link" : "play.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(CinemaStyle.background)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .background(CinemaStyle.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 7)
            }
            .padding(22)
        }
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(CinemaStyle.border))
    }

    private var sources: some View {
        HStack(spacing: 10) {
            sourceButton("Tệp trên máy", icon: "folder") { pickingFile = true }
            sourceButton("Máy chủ LAN", icon: "server.rack") { page = .link }
        }
        .disabled(importing)
        .overlay(alignment: .trailing) {
            if importing { ProgressView().padding(.trailing, 12).accessibilityLabel("Đang nhập tệp") }
        }
    }

    private func sourceButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                Text(title).font(.subheadline.weight(.semibold))
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(CinemaStyle.accent)
            }
            .frame(maxWidth: .infinity, minHeight: 53)
            .background(CinemaStyle.panel, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(CinemaStyle.border))
        }
        .buttonStyle(.plain)
    }

    private var continueWatching: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("Đang xem")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(library.recent.prefix(10)) { item in
                        Button { playing = item } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                CinemaArtwork(url: item.metadata?.backdropURL)
                                    .frame(width: 178, height: 95)
                                    .clipShape(RoundedRectangle(cornerRadius: 13))
                                    .overlay(alignment: .bottomLeading) {
                                        ProgressView(value: item.progress).padding(7)
                                    }
                                Text(item.displayTitle)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                            }
                            .frame(width: 178, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var collection: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading(section == .favorites ? "Yêu thích" : "Thư viện")
            if !library.items.isEmpty {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(CinemaStyle.muted)
                    TextField("Tìm trong thư viện", text: $query)
                        .autocorrectionDisabled()
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Xóa tìm kiếm")
                    }
                }
                .padding(13)
                .background(CinemaStyle.panel, in: RoundedRectangle(cornerRadius: 14))
            }
            if visibleItems.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: section == .favorites ? "heart" : "film")
                        .font(.title2)
                        .foregroundStyle(CinemaStyle.accent)
                    Text(emptyTitle).font(.subheadline.weight(.semibold))
                    if library.items.isEmpty && section == .library {
                        Text("Chọn một tệp video hoặc thêm liên kết để bắt đầu.")
                            .foregroundStyle(CinemaStyle.muted)
                            .font(.footnote)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(22)
                .frame(maxWidth: .infinity)
                .background(CinemaStyle.panel, in: RoundedRectangle(cornerRadius: 18))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 183), spacing: 13, alignment: .top)],
                          alignment: .leading, spacing: 18) {
                    ForEach(visibleItems) { item in
                        Button { page = .details(item.id) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                CinemaArtwork(url: item.metadata?.posterURL)
                                    .frame(height: 155)
                                    .frame(maxWidth: .infinity)
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                                    .overlay(alignment: .bottomLeading) {
                                        if let format = item.source.format {
                                            Text(format)
                                                .font(.caption2.bold())
                                                .padding(.horizontal, 7)
                                                .padding(.vertical, 4)
                                                .background(.black.opacity(0.75), in: Capsule())
                                                .padding(7)
                                        }
                                    }
                                Text(item.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(2)
                                Text(item.metadata?.year ?? item.source.label)
                                    .font(.caption).lineLimit(1).foregroundStyle(CinemaStyle.muted)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { playing = item } label: { Label("Phát", systemImage: "play.fill") }
                            Button {
                                library.toggleFavorite(item.id)
                            } label: {
                                Label(item.favorite ? "Bỏ yêu thích" : "Yêu thích",
                                      systemImage: item.favorite ? "heart.slash" : "heart")
                            }
                            Button(role: .destructive) { pendingRemove = item } label: {
                                Label("Xóa khỏi thư viện", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    private var emptyTitle: String {
        if !query.isEmpty { return "Không tìm thấy video" }
        return section == .favorites ? "Chưa có phim yêu thích" : "Chưa có phim"
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            tab(.library, title: "Thư viện", icon: "square.grid.2x2")
            tab(.favorites, title: "Yêu thích", icon: "heart")
        }
        .frame(maxWidth: 480)
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background {
            CinemaStyle.background
                .overlay(alignment: .top) { Rectangle().fill(CinemaStyle.border).frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private func tab(_ value: SectionChoice, title: String, icon: String) -> some View {
        Button {
            section = value
            query = ""
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 19, weight: .semibold))
                Text(title).font(.caption2.weight(.semibold))
            }
            .foregroundStyle(section == value ? CinemaStyle.accent : CinemaStyle.muted)
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(section == value ? .isSelected : [])
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.title3.bold()).accessibilityAddTraits(.isHeader)
    }

    private func importVideos(_ result: Result<[URL], Error>) {
        Task {
            importing = true
            defer { importing = false }
            do {
                var failures: [String] = []
                for url in try result.get() {
                    do {
                        try await library.importFile(url)
                    } catch {
                        failures.append("\(url.lastPathComponent) — \(error.localizedDescription)")
                    }
                }
                if !failures.isEmpty { library.storageError = failures.joined(separator: "\n") }
            } catch {
                library.storageError = error.localizedDescription
            }
        }
    }

    private enum SectionChoice { case library, favorites }

    private enum Page: Identifiable {
        case link, settings, details(UUID)

        var id: String {
            switch self {
            case .link: return "link"
            case .settings: return "settings"
            case .details(let id): return id.uuidString
            }
        }
    }
}

struct CinemaArtwork: View {
    enum Fallback { case generic, coast }
    let url: URL?
    var fallback: Fallback = .generic

    var body: some View {
        GeometryReader { geometry in
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else if fallback == .coast {
                    Image("Coast").resizable().scaledToFill()
                } else {
                    ZStack {
                        LinearGradient(colors: [CinemaStyle.panel, CinemaStyle.background],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "film")
                            .font(.system(size: 25, weight: .light))
                            .foregroundStyle(CinemaStyle.accent.opacity(0.48))
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .accessibilityHidden(true)
    }
}
