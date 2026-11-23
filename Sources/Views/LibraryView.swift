import SwiftUI

struct LibraryView: View {
    @ObservedObject var library: MediaLibrary
    let onOpenDetail: (MediaItem) -> Void
    let onOpenSeries: (SeriesGroup) -> Void
    let onPlay: (MediaItem) -> Void
    let onRequestRemove: (MediaItem) -> Void

    @State private var query = ""
    @State private var filter: LibraryFilter = .all
    @State private var sourceFilter = "Tất cả"
    @State private var sortBy: LibrarySort = .recent
    @State private var gridView = true
    @State private var scrapeNotice: String?

    private var distinctSourceTags: [String] {
        Array(Set(library.items.map(\.source.categoryTag))).sorted()
    }

    private var unmatchedCount: Int {
        library.items.filter { $0.metadata == nil }.count
    }

    private var filteredItems: [MediaItem] {
        var list = library.items
        switch filter {
        case .all: break
        case .movies: list = list.filter { $0.episodeInfo == nil && $0.metadata?.kind != "tv" }
        case .series: list = list.filter { $0.episodeInfo != nil || $0.metadata?.kind == "tv" }
        case .unwatched: list = list.filter { !$0.isCompleted }
        case .hdr4k: list = list.filter(\.is4KOrHDR)
        case .favorites: list = list.filter(\.favorite)
        }

        if sourceFilter != "Tất cả" {
            list = list.filter { $0.source.categoryTag == sourceFilter }
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            list = list.filter {
                $0.displayTitle.localizedStandardContains(trimmed)
                || $0.title.localizedStandardContains(trimmed)
                || ($0.metadata?.year?.localizedStandardContains(trimmed) ?? false)
            }
        }

        switch sortBy {
        case .recent:
            return list.sorted { $0.dateAdded > $1.dateAdded }
        case .rating:
            return list.sorted { ($0.metadata?.rating ?? 0) > ($1.metadata?.rating ?? 0) }
        case .year:
            return list.sorted { ($0.metadata?.year ?? "0") > ($1.metadata?.year ?? "0") }
        case .title:
            return list.sorted { $0.cardTitle.localizedStandardCompare($1.cardTitle) == .orderedAscending }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headerRow
                searchField
                filterBar
                if distinctSourceTags.count > 1 {
                    sourceFilterBar
                }
                if !library.items.isEmpty && (library.scrapingProgress != nil || scrapeNotice != nil || unmatchedCount > 0) {
                    tmdbBanner
                }

                if filteredItems.isEmpty {
                    emptyCard
                } else if filter == .series, !library.seriesGroups.isEmpty, query.isEmpty, sourceFilter == "Tất cả" {
                    seriesGridOrList
                } else if gridView {
                    posterGrid
                } else {
                    compactList
                }
            }
            .frame(maxWidth: 860)
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .background(CinemaStyle.background.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text("Thư viện")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(CinemaStyle.text)
                .accessibilityAddTraits(.isHeader)

            TechBadge(text: "\(filteredItems.count)", tone: .accent)

            Spacer()

            Menu {
                Picker("Sắp xếp", selection: $sortBy) {
                    ForEach(LibrarySort.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CinemaStyle.text)
                    .frame(width: 36, height: 36)
                    .obsidianGlass(cornerRadius: 18)
            }
            .accessibilityLabel("Sắp xếp")

            Button { gridView.toggle() } label: {
                Image(systemName: gridView ? "list.bullet" : "square.grid.2x2")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CinemaStyle.text)
                    .frame(width: 36, height: 36)
                    .obsidianGlass(cornerRadius: 18)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(gridView ? "Xem dạng danh sách" : "Xem dạng lưới")
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(CinemaStyle.muted)
            TextField("Tìm tên phim, năm, nguồn…", text: $query)
                .autocorrectionDisabled()
                .foregroundStyle(CinemaStyle.text)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(CinemaStyle.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Xóa tìm kiếm")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .obsidianGlass(cornerRadius: 14)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibraryFilter.allCases) { option in
                    let selected = filter == option
                    Button { filter = option } label: {
                        Text(option.label)
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                selected ? CinemaStyle.ctaBackground : CinemaStyle.panel,
                                in: Capsule()
                            )
                            .foregroundStyle(selected ? CinemaStyle.ctaForeground : CinemaStyle.text)
                            .overlay(Capsule().strokeBorder(CinemaStyle.border))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var sourceFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(["Tất cả"] + distinctSourceTags, id: \.self) { src in
                    let selected = sourceFilter == src
                    Button { sourceFilter = src } label: {
                        Text(src)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                selected ? CinemaStyle.accent.opacity(0.18) : Color.clear,
                                in: Capsule()
                            )
                            .foregroundStyle(selected ? CinemaStyle.accent : CinemaStyle.muted)
                            .overlay(
                                Capsule().strokeBorder(selected ? CinemaStyle.accent : CinemaStyle.border)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var tmdbBanner: some View {
        let matched = library.items.filter { $0.metadata != nil }.count
        return HStack(spacing: 10) {
            Circle()
                .fill(CinemaStyle.accent)
                .frame(width: 7, height: 7)
            Text(library.scrapingProgress ?? scrapeNotice ?? "TMDB · \(matched)/\(library.items.count)")
                .font(.caption.weight(.medium))
                .foregroundStyle(CinemaStyle.muted)
                .lineLimit(1)
            Spacer()
            Button("Quét") {
                Task { await runAutoScrape() }
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(CinemaStyle.accent)
            .disabled(library.scrapingProgress != nil || library.items.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .obsidianGlass(cornerRadius: 12)
    }

    private var posterGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 106, maximum: 160), spacing: 12, alignment: .top)],
            spacing: 16
        ) {
            ForEach(filteredItems) { item in
                Button { onOpenDetail(item) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        ZStack(alignment: .bottomLeading) {
                            CinemaArtwork(url: item.metadata?.posterURL, titleHint: item.cardTitle)
                            VStack {
                                HStack {
                                    if let res = item.mediaInfo?.resolutionLabel {
                                        TechBadge(text: res)
                                    } else if let fmt = item.source.format {
                                        TechBadge(text: fmt)
                                    }
                                    Spacer()
                                    if item.isCompleted {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(CinemaStyle.accent)
                                    } else if item.favorite {
                                        Image(systemName: "heart.fill")
                                            .font(.caption2)
                                            .foregroundStyle(CinemaStyle.danger)
                                    }
                                }
                                Spacer()
                                HStack {
                                    if let hdr = item.mediaInfo?.hdrLabel {
                                        TechBadge(text: hdr, tone: .gold)
                                    }
                                    Spacer()
                                    if let rating = item.metadata?.rating {
                                        Text("★\(rating.formatted(.number.precision(.fractionLength(1))))")
                                            .font(.system(size: 10, weight: .bold))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(.black.opacity(0.76), in: RoundedRectangle(cornerRadius: 5))
                                            .foregroundStyle(CinemaStyle.gold)
                                    }
                                }
                                if item.progress > 0, !item.isCompleted {
                                    ProgressView(value: item.progress)
                                        .tint(CinemaStyle.accent)
                                }
                            }
                            .padding(6)
                        }
                        .frame(height: 164)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(CinemaStyle.border))

                        Text(item.displayTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(CinemaStyle.text)
                            .lineLimit(1)
                        Text(item.metadata?.year ?? item.source.label)
                            .font(.caption2)
                            .foregroundStyle(CinemaStyle.muted)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("media-item-\(item.title)")
                .contextMenu { itemContextMenu(item) }
            }
        }
    }

    private var compactList: some View {
        VStack(spacing: 10) {
            ForEach(filteredItems) { item in
                Button { onOpenDetail(item) } label: {
                    HStack(spacing: 12) {
                        CinemaArtwork(url: item.metadata?.posterURL, titleHint: item.cardTitle)
                            .frame(width: 54, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(CinemaStyle.border))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.displayTitle)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(CinemaStyle.text)
                                .lineLimit(2)
                            Text([item.metadata?.year, item.source.label].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(CinemaStyle.muted)
                            HStack(spacing: 5) {
                                if let res = item.mediaInfo?.resolutionLabel { TechBadge(text: res) }
                                if let hdr = item.mediaInfo?.hdrLabel { TechBadge(text: hdr, tone: .gold) }
                                if let audio = item.mediaInfo?.audioLabel { TechBadge(text: audio) }
                            }
                        }
                        Spacer()
                        if let rating = item.metadata?.rating {
                            Text("★ \(rating.formatted(.number.precision(.fractionLength(1))))")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(CinemaStyle.gold)
                        }
                    }
                    .padding(10)
                    .obsidianGlass(cornerRadius: 16)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("media-item-\(item.title)")
                .contextMenu { itemContextMenu(item) }
            }
        }
    }

    private var seriesGridOrList: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 130, maximum: 180), spacing: 12, alignment: .top)],
            spacing: 16
        ) {
            ForEach(library.seriesGroups) { group in
                Button { onOpenSeries(group) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        ZStack(alignment: .bottomLeading) {
                            CinemaArtwork(url: group.metadata?.posterURL, titleHint: group.title)
                            HStack {
                                TechBadge(text: group.summaryLabel, tone: .accent)
                                Spacer()
                            }
                            .padding(6)
                        }
                        .frame(height: 186)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(CinemaStyle.border))

                        Text(group.title)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(CinemaStyle.text)
                            .lineLimit(2)
                        Text(group.unwatchedCount > 0 ? "\(group.unwatchedCount) tập chưa xem" : "Đã xem hết")
                            .font(.caption2)
                            .foregroundStyle(CinemaStyle.muted)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var emptyCard: some View {
        VStack(spacing: 8) {
            Image(systemName: filter == .favorites ? "heart" : "film")
                .font(.title2)
                .foregroundStyle(CinemaStyle.accent)
            Text(query.isEmpty ? "Chưa có video trong mục này" : "Không tìm thấy kết quả")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(CinemaStyle.text)
            Text("Hãy thêm tệp video, liên kết hoặc kết nối SMB / WebDAV / Jellyfin từ tab Nguồn.")
                .font(.caption)
                .foregroundStyle(CinemaStyle.muted)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .obsidianGlass(cornerRadius: 18)
    }

    private func runAutoScrape() async {
        guard let token = TMDBCredential.read(), !token.isEmpty else {
            scrapeNotice = "Thêm TMDB Read Access Token trong Cài đặt trước khi quét."
            return
        }
        let count = await library.autoScrapeUnmatched(token: token)
        scrapeNotice = count > 0 ? "Đã cập nhật \(count) phim từ TMDB." : "Không có mục mới cần khớp."
    }

    @ViewBuilder
    private func itemContextMenu(_ item: MediaItem) -> some View {
        Button { onPlay(item) } label: { Label("Phát ngay", systemImage: "play.fill") }
        Button { library.toggleFavorite(item.id) } label: {
            Label(item.favorite ? "Bỏ yêu thích" : "Yêu thích", systemImage: item.favorite ? "heart.slash" : "heart")
        }
        Button { library.toggleWatched(item.id) } label: {
            Label(item.isCompleted ? "Đánh dấu chưa xem" : "Đánh dấu đã xem", systemImage: "checkmark.circle")
        }
        Button(role: .destructive) { onRequestRemove(item) } label: {
            Label("Xóa khỏi thư viện", systemImage: "trash")
        }
    }

    private enum LibraryFilter: String, CaseIterable, Identifiable {
        case all, movies, series, unwatched, hdr4k, favorites
        var id: Self { self }
        var label: String {
            switch self {
            case .all: return "Tất cả"
            case .movies: return "Phim lẻ"
            case .series: return "Phim bộ"
            case .unwatched: return "Chưa xem"
            case .hdr4k: return "4K / HDR"
            case .favorites: return "Yêu thích"
            }
        }
    }

    private enum LibrarySort: String, CaseIterable, Identifiable {
        case recent, rating, year, title
        var id: Self { self }
        var label: String {
            switch self {
            case .recent: return "Mới thêm"
            case .rating: return "Điểm TMDB"
            case .year: return "Năm"
            case .title: return "Tên A–Z"
            }
        }
    }
}
