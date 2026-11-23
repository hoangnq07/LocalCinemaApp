import SwiftUI

struct HomeView: View {
    @ObservedObject var library: MediaLibrary
    let onOpenDetail: (MediaItem) -> Void
    let onOpenSeries: (SeriesGroup) -> Void
    let onPlay: (MediaItem) -> Void
    let onPickFile: () -> Void
    let onOpenLink: () -> Void
    let onOpenSMB: () -> Void
    let onJumpTab: (MainTab) -> Void
    let onRequestRemove: (MediaItem) -> Void
    let importing: Bool

    @State private var heroSelection = 0

    private var heroSlides: [MediaItem] {
        var seen = Set<UUID>()
        var picks: [MediaItem] = []
        for item in library.continueWatching + library.recentlyAdded {
            if seen.insert(item.id).inserted {
                picks.append(item)
            }
            if picks.count >= 5 { break }
        }
        return picks
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                heroSection
                quickSourcesRow
                if !library.continueWatching.isEmpty {
                    continueWatchingShelf
                }
                if !library.recentlyAdded.isEmpty {
                    recentlyAddedShelf
                }
                if !library.seriesGroups.isEmpty {
                    seriesShelf
                }
                if !library.favorites.isEmpty {
                    favoritesShelf
                }
            }
            .frame(maxWidth: 860)
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .background(
            ZStack(alignment: .top) {
                CinemaStyle.background.ignoresSafeArea()
                RadialGradient(
                    colors: [CinemaStyle.glow, .clear],
                    center: .top,
                    startRadius: 20,
                    endRadius: 360
                )
                .frame(height: 360)
                .ignoresSafeArea()
            }
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(CinemaStyle.elevated)
                    .frame(width: 36, height: 36)
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.6), CinemaStyle.accent, CinemaStyle.gold],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.25
                            )
                    )
                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(CinemaStyle.text)
            }
            .accessibilityHidden(true)

            Text("Local Cinema")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(CinemaStyle.text)
                .accessibilityAddTraits(.isHeader)

            if !library.items.isEmpty {
                TechBadge(text: "\(library.items.count)", tone: .accent)
            }

            Spacer()

            Button { onJumpTab(.library) } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(CinemaStyle.text)
                    .frame(width: 38, height: 38)
                    .obsidianGlass(cornerRadius: 19)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tìm trong thư viện")

            Button { onJumpTab(.sources) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(CinemaStyle.text)
                    .frame(width: 38, height: 38)
                    .obsidianGlass(cornerRadius: 19)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Thêm nguồn phim")
        }
    }

    // MARK: - Hero Carousel

    @ViewBuilder
    private var heroSection: some View {
        if heroSlides.isEmpty {
            emptyHeroCard
        } else {
            VStack(spacing: 10) {
                TabView(selection: $heroSelection) {
                    ForEach(Array(heroSlides.enumerated()), id: \.element.id) { index, item in
                        heroCard(for: item)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 315)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(CinemaStyle.border, lineWidth: 1)
                )

                if heroSlides.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(heroSlides.indices, id: \.self) { idx in
                            Capsule()
                                .fill(idx == heroSelection ? CinemaStyle.accent : Color.white.opacity(0.24))
                                .frame(width: idx == heroSelection ? 20 : 6, height: 6)
                                .animation(.easeInOut(duration: 0.2), value: heroSelection)
                        }
                    }
                }
            }
        }
    }

    private var emptyHeroCard: some View {
        ZStack(alignment: .bottomLeading) {
            CinemaArtwork(url: nil, fallback: .coast)
                .frame(height: 244)
            LinearGradient(
                colors: [.clear, .black.opacity(0.32), CinemaStyle.background.opacity(0.95)],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 8) {
                TechBadge(text: "4K HDR · AI", tone: .gold)
                Text("Rạp phim cá nhân")
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .foregroundStyle(CinemaStyle.text)
                Text("SMB · WebDAV · Jellyfin · Plex")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(CinemaStyle.muted)
                    .lineLimit(1)
                HStack(spacing: 10) {
                    Button(action: onPickFile) {
                        Label("Chọn tệp", systemImage: "folder.fill")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(CinemaStyle.ctaForeground)
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .background(CinemaStyle.ctaBackground, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button(action: onOpenLink) {
                        Label("Liên kết", systemImage: "link")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(CinemaStyle.text)
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .obsidianGlass(cornerRadius: 21, strong: true)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
            }
            .padding(20)
        }
        .frame(height: 244)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(CinemaStyle.border))
    }

    private func heroCard(for item: MediaItem) -> some View {
        ZStack(alignment: .bottomLeading) {
            CinemaArtwork(url: item.metadata?.backdropURL ?? item.metadata?.posterURL, fallback: .coast)
            LinearGradient(
                colors: [.black.opacity(0.15), .black.opacity(0.45), CinemaStyle.background.opacity(0.96)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TechBadge(text: item.source.label, tone: .neutral)
                    Spacer()
                    Button { library.toggleFavorite(item.id) } label: {
                        Image(systemName: item.favorite ? "heart.fill" : "heart")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(item.favorite ? CinemaStyle.danger : .white)
                            .frame(width: 36, height: 36)
                            .obsidianGlass(cornerRadius: 18, strong: true)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                HStack(spacing: 6) {
                    if let res = item.mediaInfo?.resolutionLabel { TechBadge(text: res) }
                    if let hdr = item.mediaInfo?.hdrLabel { TechBadge(text: hdr, tone: .gold) }
                    if let audio = item.mediaInfo?.audioLabel { TechBadge(text: audio) }
                    if let format = item.source.format { TechBadge(text: format) }
                    if let rating = item.metadata?.rating {
                        Text("★ \(rating.formatted(.number.precision(.fractionLength(1))))")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(CinemaStyle.gold)
                    }
                }

                Text(item.cardTitle)
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .foregroundStyle(CinemaStyle.text)
                    .lineLimit(2)

                if let sub = item.metadata?.tagline ?? item.remainingText {
                    Text(sub)
                        .font(.caption)
                        .foregroundStyle(CinemaStyle.muted)
                        .lineLimit(1)
                }

                HStack(spacing: 10) {
                    Button { onPlay(item) } label: {
                        Label(
                            item.progress > 0 && !item.isCompleted ? "Xem tiếp" : "Phát ngay",
                            systemImage: "play.fill"
                        )
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(CinemaStyle.ctaForeground)
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .background(CinemaStyle.ctaBackground, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button { onOpenDetail(item) } label: {
                        Text("Chi tiết")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(CinemaStyle.text)
                            .padding(.horizontal, 18)
                            .frame(minHeight: 42)
                            .obsidianGlass(cornerRadius: 21, strong: true)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(18)
        }
    }

    // MARK: - Quick Sources

    private var quickSourcesRow: some View {
        HStack(spacing: 10) {
            sourceShortcut("Tệp", icon: "folder", id: "quick-files", action: onPickFile)
            sourceShortcut("Liên kết", icon: "link", id: "quick-link", action: onOpenLink)
            sourceShortcut("SMB", icon: "server.rack", id: "quick-smb", action: onOpenSMB)
        }
        .disabled(importing)
        .overlay(alignment: .trailing) {
            if importing { ProgressView().padding(.trailing, 10) }
        }
    }

    private func sourceShortcut(_ title: String, icon: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(CinemaStyle.text)
                    .lineLimit(1)
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(CinemaStyle.accent)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .obsidianGlass(cornerRadius: 14)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    // MARK: - Shelves

    private var continueWatchingShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            shelfHeader("Xem tiếp", actionTitle: "Tất cả") { onJumpTab(.library) }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(library.continueWatching.prefix(12)) { item in
                        Button { onPlay(item) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ZStack(alignment: .bottom) {
                                    CinemaArtwork(url: item.metadata?.backdropURL ?? item.metadata?.posterURL, titleHint: item.cardTitle)
                                    LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            if let hdr = item.mediaInfo?.hdrLabel {
                                                TechBadge(text: hdr, tone: .gold)
                                            }
                                            Spacer()
                                            Image(systemName: "play.circle.fill")
                                                .font(.title3)
                                                .foregroundStyle(.white.opacity(0.92))
                                        }
                                        ProgressView(value: item.progress)
                                            .tint(CinemaStyle.accent)
                                    }
                                    .padding(8)
                                }
                                .frame(width: 192, height: 108)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(CinemaStyle.border))

                                Text(item.displayTitle)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(CinemaStyle.text)
                                    .lineLimit(1)
                                Text(item.remainingText ?? item.source.label)
                                    .font(.caption2)
                                    .foregroundStyle(CinemaStyle.muted)
                                    .lineLimit(1)
                            }
                            .frame(width: 192, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { itemContextMenu(item) }
                    }
                }
            }
        }
    }

    private var recentlyAddedShelf: some View {
        VStack(alignment: .leading, spacing: 10) {
            shelfHeader("Mới thêm")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(library.recentlyAdded.prefix(14)) { item in
                        posterCard(item)
                    }
                }
            }
        }
    }

    private var seriesShelf: some View {
        VStack(alignment: .leading, spacing: 10) {
            shelfHeader("Phim bộ")
            VStack(spacing: 10) {
                ForEach(library.seriesGroups.prefix(6)) { group in
                    Button { onOpenSeries(group) } label: {
                        HStack(spacing: 12) {
                            CinemaArtwork(url: group.metadata?.posterURL, titleHint: group.title)
                                .frame(width: 54, height: 78)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(CinemaStyle.border))

                            VStack(alignment: .leading, spacing: 4) {
                                Text(group.title)
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(CinemaStyle.text)
                                    .lineLimit(1)
                                Text(group.summaryLabel)
                                    .font(.caption)
                                    .foregroundStyle(CinemaStyle.muted)
                                HStack(spacing: 6) {
                                    if group.unwatchedCount > 0 {
                                        TechBadge(text: "\(group.unwatchedCount) tập chưa xem", tone: .accent)
                                    } else {
                                        TechBadge(text: "Đã xem hết", tone: .neutral)
                                    }
                                    if let hdr = group.latestItem.mediaInfo?.hdrLabel {
                                        TechBadge(text: hdr, tone: .gold)
                                    }
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(CinemaStyle.muted)
                        }
                        .padding(10)
                        .obsidianGlass(cornerRadius: 16)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var favoritesShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            shelfHeader("Yêu thích")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(library.favorites.prefix(12)) { item in
                        posterCard(item)
                    }
                }
            }
        }
    }

    private func posterCard(_ item: MediaItem) -> some View {
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
                                    .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 5))
                                    .foregroundStyle(CinemaStyle.gold)
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(width: 114, height: 168)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(CinemaStyle.border))

                Text(item.cardTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CinemaStyle.text)
                    .lineLimit(1)
                Text(item.metadata?.year ?? item.source.categoryTag)
                    .font(.caption2)
                    .foregroundStyle(CinemaStyle.muted)
                    .lineLimit(1)
            }
            .frame(width: 114, alignment: .leading)
        }
        .buttonStyle(.plain)
        .contextMenu { itemContextMenu(item) }
    }

    private func shelfHeader(_ title: String, actionTitle: String? = nil, action: (() -> Void)? = nil) -> some View {
        HStack {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(CinemaStyle.text)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(CinemaStyle.accent)
            }
        }
    }

    @ViewBuilder
    private func itemContextMenu(_ item: MediaItem) -> some View {
        Button { onPlay(item) } label: { Label("Phát ngay", systemImage: "play.fill") }
        Button { onOpenDetail(item) } label: { Label("Xem chi tiết", systemImage: "info.circle") }
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
}
