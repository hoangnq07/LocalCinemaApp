import SwiftUI

struct MovieDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let item: MediaItem
    @ObservedObject var library: MediaLibrary
    let play: (MediaItem) -> Void

    @State private var showingSearch = false

    private var current: MediaItem { library.item(item.id) ?? item }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ZStack(alignment: .bottomLeading) {
                        CinemaArtwork(
                            url: current.metadata?.backdropURL ?? current.metadata?.posterURL,
                            fallback: .coast
                        )
                        .frame(height: 240)
                        LinearGradient(
                            colors: [.clear, CinemaStyle.background.opacity(0.65), CinemaStyle.background],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(CinemaStyle.border))

                    HStack(alignment: .bottom, spacing: 14) {
                        CinemaArtwork(url: current.metadata?.posterURL, titleHint: current.cardTitle)
                            .frame(width: 92, height: 136)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(CinemaStyle.border))

                        VStack(alignment: .leading, spacing: 6) {
                            if let rating = current.metadata?.rating {
                                Label(rating.formatted(.number.precision(.fractionLength(1))) + " / 10 TMDB", systemImage: "star.fill")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(CinemaStyle.gold)
                            }
                            Text(current.displayTitle)
                                .font(.title2.weight(.bold))
                                .foregroundStyle(CinemaStyle.text)
                            Text(descriptor)
                                .font(.caption)
                                .foregroundStyle(CinemaStyle.muted)
                        }
                    }

                    techBadgeRow(for: current)

                    HStack(spacing: 10) {
                        Button { play(current) } label: {
                            Label(
                                current.progress > 0 && !current.isCompleted ? "Xem tiếp" : "Phát",
                                systemImage: "play.fill"
                            )
                            .font(.headline)
                            .foregroundStyle(CinemaStyle.ctaForeground)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(CinemaStyle.ctaBackground, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("movie-details-play")

                        if current.progress > 0 {
                            Button {
                                library.resetProgress(current.id)
                                var restarted = current
                                restarted.position = 0
                                play(restarted)
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.headline)
                                    .foregroundStyle(CinemaStyle.text)
                                    .frame(width: 46, height: 46)
                                    .obsidianGlass(cornerRadius: 23, strong: true)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Phát từ đầu")
                        }

                        Button { library.toggleFavorite(current.id) } label: {
                            Image(systemName: current.favorite ? "heart.fill" : "heart")
                                .font(.headline)
                                .foregroundStyle(current.favorite ? CinemaStyle.danger : CinemaStyle.text)
                                .frame(width: 46, height: 46)
                                .obsidianGlass(cornerRadius: 23, strong: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(current.favorite ? "Bỏ yêu thích" : "Thêm vào yêu thích")

                        Button { library.toggleWatched(current.id) } label: {
                            Image(systemName: current.isCompleted ? "checkmark.circle.fill" : "checkmark.circle")
                                .font(.headline)
                                .foregroundStyle(current.isCompleted ? CinemaStyle.accent : CinemaStyle.text)
                                .frame(width: 46, height: 46)
                                .obsidianGlass(cornerRadius: 23, strong: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(current.isCompleted ? "Đánh dấu chưa xem" : "Đánh dấu đã xem")
                    }

                    if let genres = current.metadata?.genres, !genres.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(genres, id: \.self) { genre in
                                    TechBadge(text: genre, tone: .neutral)
                                }
                            }
                        }
                    }

                    if let overview = current.metadata?.overview, !overview.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Nội dung").font(.subheadline.weight(.bold)).foregroundStyle(CinemaStyle.text)
                            Text(overview).font(.subheadline).foregroundStyle(CinemaStyle.muted)
                        }
                    }

                    if let cast = current.metadata?.cast, !cast.isEmpty {
                        castStrip(cast)
                    }

                    HStack(spacing: 10) {
                        Text(current.source.pathDescription)
                            .font(.caption.monospaced())
                            .foregroundStyle(CinemaStyle.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        Button { showingSearch = true } label: {
                            Label("TMDB", systemImage: "magnifyingglass")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(CinemaStyle.accent)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .obsidianGlass(cornerRadius: 10, strong: true)
                        }
                        .buttonStyle(.plain)

                        if current.metadata != nil {
                            Button(role: .destructive) {
                                library.setMetadata(current.id, value: nil)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(CinemaStyle.muted)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Gỡ thông tin")
                        }
                    }
                    .padding(12)
                    .obsidianGlass(cornerRadius: 14)
                }
                .frame(maxWidth: 660, alignment: .leading)
                .padding(18)
                .frame(maxWidth: .infinity)
            }
            .background(CinemaStyle.background.ignoresSafeArea())
            .navigationTitle("Chi tiết")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Đóng") { dismiss() } }
            }
            .sheet(isPresented: $showingSearch) {
                MetadataSearchSheet(query: current.metadataQuery) { value in
                    library.setMetadata(current.id, value: value)
                }
            }
        }
    }

    private var descriptor: String {
        [current.metadata?.kindLabel, current.metadata?.year, current.metadata?.runtimeLabel, current.source.label]
            .compactMap { $0 }
            .joined(separator: "  ·  ")
    }
}

struct SeriesDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let group: SeriesGroup
    @ObservedObject var library: MediaLibrary
    let play: (MediaItem) -> Void

    @State private var selectedSeason: Int
    @State private var showingSearch = false

    init(group: SeriesGroup, library: MediaLibrary, play: @escaping (MediaItem) -> Void) {
        self.group = group
        self.library = library
        self.play = play
        _selectedSeason = State(initialValue: group.latestItem.episodeInfo?.season ?? group.orderedSeasons.first ?? 1)
    }

    private var liveGroup: SeriesGroup {
        library.seriesGroups.first(where: { $0.id == group.id }) ?? group
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ZStack(alignment: .bottomLeading) {
                        CinemaArtwork(
                            url: liveGroup.metadata?.backdropURL ?? liveGroup.metadata?.posterURL,
                            fallback: .coast
                        )
                        .frame(height: 220)
                        LinearGradient(
                            colors: [.clear, CinemaStyle.background.opacity(0.75), CinemaStyle.background],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        VStack(alignment: .leading, spacing: 6) {
                            TechBadge(text: liveGroup.summaryLabel, tone: .accent)
                            Text(liveGroup.title)
                                .font(.title.weight(.bold))
                                .foregroundStyle(CinemaStyle.text)
                        }
                        .padding(16)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(CinemaStyle.border))

                    Button {
                        play(liveGroup.latestItem)
                    } label: {
                        Label("Xem tiếp · \(liveGroup.latestItem.episodeInfo?.shortCode ?? "Tập 1")", systemImage: "play.fill")
                            .font(.headline)
                            .foregroundStyle(CinemaStyle.ctaForeground)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(CinemaStyle.ctaBackground, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    if let overview = liveGroup.metadata?.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.subheadline)
                            .foregroundStyle(CinemaStyle.muted)
                    }

                    // Season Tabs
                    if liveGroup.orderedSeasons.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(liveGroup.orderedSeasons, id: \.self) { season in
                                    Button { selectedSeason = season } label: {
                                        Text("Mùa \(season)")
                                            .font(.caption.weight(.bold))
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 8)
                                            .background(
                                                selectedSeason == season ? CinemaStyle.ctaBackground : CinemaStyle.panel,
                                                in: Capsule()
                                            )
                                            .foregroundStyle(selectedSeason == season ? CinemaStyle.ctaForeground : CinemaStyle.text)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    // Episode Rows
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Mùa \(selectedSeason)")
                            .font(.headline)
                            .foregroundStyle(CinemaStyle.text)

                        ForEach(liveGroup.seasons[selectedSeason] ?? []) { ep in
                            Button { play(ep) } label: {
                                HStack(spacing: 12) {
                                    ZStack {
                                        CinemaArtwork(url: ep.metadata?.backdropURL ?? liveGroup.metadata?.posterURL)
                                        Color.black.opacity(0.35)
                                        Image(systemName: "play.fill")
                                            .font(.subheadline)
                                            .foregroundStyle(.white)
                                        if ep.progress > 0 && !ep.isCompleted {
                                            VStack {
                                                Spacer()
                                                ProgressView(value: ep.progress).tint(CinemaStyle.accent)
                                            }
                                        }
                                    }
                                    .frame(width: 96, height: 58)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(ep.episodeInfo?.episodeTitle?.isEmpty == false
                                             ? "Tập \(ep.episodeInfo?.episode ?? 1): \(ep.episodeInfo?.episodeTitle ?? "")"
                                             : "Tập \(ep.episodeInfo?.episode ?? 1)")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(CinemaStyle.text)
                                            .lineLimit(2)
                                        HStack(spacing: 6) {
                                            if let res = ep.mediaInfo?.resolutionLabel { TechBadge(text: res) }
                                            if let hdr = ep.mediaInfo?.hdrLabel { TechBadge(text: hdr, tone: .gold) }
                                            if ep.isCompleted {
                                                Text("Đã xem")
                                                    .font(.caption2.weight(.bold))
                                                    .foregroundStyle(CinemaStyle.accent)
                                            } else if let rem = ep.remainingText {
                                                Text(rem).font(.caption2).foregroundStyle(CinemaStyle.muted)
                                            }
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(10)
                                .obsidianGlass(cornerRadius: 14)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Button { showingSearch = true } label: {
                        Label("Tìm TMDB cho bộ này", systemImage: "magnifyingglass")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(CinemaStyle.accent)
                    }
                }
                .frame(maxWidth: 660, alignment: .leading)
                .padding(18)
                .frame(maxWidth: .infinity)
            }
            .background(CinemaStyle.background.ignoresSafeArea())
            .navigationTitle(liveGroup.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Đóng") { dismiss() } }
            }
            .sheet(isPresented: $showingSearch) {
                MetadataSearchSheet(query: liveGroup.title) { meta in
                    for ep in liveGroup.episodes {
                        library.setMetadata(ep.id, value: meta)
                    }
                }
            }
        }
    }
}

@ViewBuilder
private func techBadgeRow(for item: MediaItem) -> some View {
    let badges = item.mediaInfo?.badges ?? []
    ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
            if let format = item.source.format {
                TechBadge(text: format, tone: .accent)
            }
            ForEach(badges, id: \.self) { badge in
                let isHDR = badge.contains("HDR") || badge.contains("Dolby Vision")
                TechBadge(text: badge, tone: isHDR ? .gold : .neutral)
            }
            if let subs = item.mediaInfo?.sidecarSubtitles, !subs.isEmpty {
                TechBadge(text: "\(subs.count) phụ đề ngoài", tone: .accent)
            }
        }
    }
}

private func castStrip(_ cast: [CastMember]) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        Text("Diễn viên").font(.subheadline.weight(.bold)).foregroundStyle(CinemaStyle.text)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(cast) { person in
                    VStack(spacing: 6) {
                        CinemaArtwork(url: person.profileURL)
                            .frame(width: 58, height: 58)
                            .clipShape(Circle())
                            .overlay(Circle().strokeBorder(CinemaStyle.border))
                        Text(person.name)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(CinemaStyle.text)
                            .lineLimit(1)
                        if let role = person.character, !role.isEmpty {
                            Text(role)
                                .font(.caption2)
                                .foregroundStyle(CinemaStyle.muted)
                                .lineLimit(1)
                        }
                    }
                    .frame(width: 78)
                }
            }
        }
    }
}

struct MetadataSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var query: String
    let select: (MovieMetadata) -> Void

    @State private var results: [MovieMetadata] = []
    @State private var request: SearchRequest?
    @State private var loading = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Tên phim hoặc chương trình", text: $query)
                            .submitLabel(.search)
                            .onSubmit(search)
                        Button("Tìm", action: search)
                            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if loading {
                    ProgressView().accessibilityLabel("Đang tìm trên TMDB")
                }
                if let message { Text(message).foregroundStyle(CinemaStyle.muted) }
                ForEach(Array(results.enumerated()), id: \.offset) { entry in
                    let result = entry.element
                    Button {
                        Task { await selectWithDetails(result) }
                    } label: {
                        HStack(spacing: 12) {
                            CinemaArtwork(url: result.posterURL)
                                .frame(width: 45, height: 65)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(result.title).font(.headline).foregroundStyle(.primary)
                                Text([result.kindLabel, result.year].compactMap { $0 }.joined(separator: "  ·  "))
                                    .font(.caption).foregroundStyle(CinemaStyle.muted)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .scrollContentBackground(.hidden)
            .background(CinemaStyle.background)
            .navigationTitle("Tìm trên TMDB")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Đóng") { dismiss() } }
            }
            .task(id: request) {
                if let request { await fetch(request.term) }
            }
            .onAppear {
                if request == nil { search() }
            }
        }
    }

    private func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        request = SearchRequest(term: term)
    }

    private func fetch(_ term: String) async {
        guard let token = TMDBCredential.read() else {
            message = "Thêm API Read Access Token trong Cài đặt của Local Cinema để tìm trên TMDB."
            return
        }
        loading = true
        message = nil
        results = []
        defer { if !Task.isCancelled { loading = false } }
        do {
            let response = try await TMDB.search(term, token: token)
            try Task.checkCancellation()
            results = response
            if response.isEmpty { message = "Không tìm thấy phim phù hợp." }
        } catch {
            if !Task.isCancelled { message = error.localizedDescription }
        }
    }

    private func selectWithDetails(_ item: MovieMetadata) async {
        if let token = TMDBCredential.read(),
           let detailed = try? await TMDB.fetchDetails(id: item.id, kind: item.kind, token: token) {
            select(detailed)
        } else {
            select(item)
        }
        dismiss()
    }

    private struct SearchRequest: Equatable {
        let id = UUID()
        let term: String
    }
}
