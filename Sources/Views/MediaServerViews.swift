import SwiftUI

struct MediaServerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: MediaServerStore
    @ObservedObject var library: MediaLibrary
    let initialKind: MediaServerKind
    var selectedServer: MediaServerProfile? = nil
    let onPlayItem: (MediaItem) -> Void

    @State private var kind: MediaServerKind
    @State private var serverURL = ""
    @State private var username = ""
    @State private var secret = "" // password or Plex Token
    @State private var activeProfile: MediaServerProfile?
    @State private var collections: [ServerCollection] = []
    @State private var selectedCollection: ServerCollection?
    @State private var items: [ServerMediaEntry] = []
    @State private var selectedSeries: ServerMediaEntry?
    @State private var episodes: [ServerMediaEntry] = []
    @State private var loading = false
    @State private var message: String?

    init(
        store: MediaServerStore,
        library: MediaLibrary,
        initialKind: MediaServerKind,
        selectedServer: MediaServerProfile? = nil,
        onPlayItem: @escaping (MediaItem) -> Void
    ) {
        self.store = store
        self.library = library
        self.initialKind = initialKind
        self.selectedServer = selectedServer
        self.onPlayItem = onPlayItem
        _kind = State(initialValue: selectedServer?.kind ?? initialKind)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let selectedSeries, let activeProfile {
                    episodesList(server: activeProfile, series: selectedSeries)
                } else if let selectedCollection, let activeProfile {
                    itemsList(server: activeProfile, collection: selectedCollection)
                } else if let activeProfile {
                    collectionsList(server: activeProfile)
                } else {
                    loginForm
                }
            }
            .scrollContentBackground(.hidden)
            .background(CinemaStyle.background)
            .navigationTitle(currentTitle)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if let selectedServer, activeProfile == nil {
                    activeProfile = selectedServer
                    Task { await loadCollections(selectedServer) }
                }
            }
            .toolbar {
                if activeProfile != nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { goBack() } label: {
                            Label("Quay lại", systemImage: "chevron.left")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Đóng") { dismiss() } }
            }
            .alert("Media Server", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("Đóng", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
        }
    }

    private var currentTitle: String {
        selectedSeries?.title ?? selectedCollection?.title ?? activeProfile?.name ?? kind.label
    }

    private var loginForm: some View {
        Form {
            Section("Loại máy chủ") {
                Picker("Máy chủ", selection: $kind) {
                    ForEach(MediaServerKind.allCases) { k in
                        Text(k.label).tag(k)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Thông tin kết nối") {
                TextField(kind == .plex ? "http://192.168.1.12:32400" : "http://192.168.1.50:8096", text: $serverURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if kind == .plex {
                    SecureField("X-Plex-Token", text: $secret)
                        .textInputAutocapitalization(.never)
                } else {
                    TextField("Tên đăng nhập", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Mật khẩu", text: $secret)
                        .textInputAutocapitalization(.never)
                }
            }

            Section {
                Button("Đăng nhập & Kết nối") {
                    Task { await authenticate() }
                }
                .disabled(serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loading)
                if loading { ProgressView("Đang xác thực…") }
            }
        }
    }

    private func collectionsList(server: MediaServerProfile) -> some View {
        List {
            Section("Thư viện trên \(server.name)") {
                ForEach(collections) { col in
                    Button {
                        Task { await loadItems(server: server, collection: col) }
                    } label: {
                        HStack {
                            Label(col.title, systemImage: "film.stack")
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(CinemaStyle.muted)
                        }
                    }
                }
            }
            Section {
                Button("Gỡ máy chủ này", role: .destructive) {
                    store.remove(server)
                    dismiss()
                }
            }
        }
        .overlay {
            if loading { ProgressView().padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
        }
    }

    private func itemsList(server: MediaServerProfile, collection: ServerCollection) -> some View {
        List {
            Section {
                Button {
                    importEntries(items, server: server)
                } label: {
                    Label("Nhập \(items.count) mục vào Thư viện", systemImage: "square.and.arrow.down.on.square")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(CinemaStyle.accent)
                }
            }
            ForEach(items) { entry in
                Button {
                    if entry.kind == "series" || entry.kind == "show" {
                        Task { await loadEpisodes(server: server, series: entry) }
                    } else {
                        playServerEntry(entry, server: server)
                    }
                } label: {
                    HStack(spacing: 12) {
                        CinemaArtwork(url: entry.posterURL, titleHint: entry.title)
                            .frame(width: 48, height: 70)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                            Text([entry.year, entry.kind == "series" || entry.kind == "show" ? "Phim bộ" : "Phim lẻ"].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption2).foregroundStyle(CinemaStyle.muted)
                        }
                        Spacer()
                        Image(systemName: (entry.kind == "series" || entry.kind == "show") ? "chevron.right" : "play.fill")
                            .font(.caption).foregroundStyle(CinemaStyle.muted)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .overlay {
            if loading { ProgressView().padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
        }
    }

    private func episodesList(server: MediaServerProfile, series: ServerMediaEntry) -> some View {
        List {
            Section {
                Button {
                    importEntries(episodes, server: server, seriesTitle: series.title)
                } label: {
                    Label("Nhập cả bộ (\(episodes.count) tập) vào Thư viện", systemImage: "square.and.arrow.down.on.square")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(CinemaStyle.accent)
                }
            }
            ForEach(episodes) { ep in
                Button {
                    playServerEntry(ep, server: server, seriesTitle: series.title)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            let code = "M\(ep.seasonNumber ?? 1) · T\(ep.episodeNumber ?? 1)"
                            Text("\(code): \(ep.title)")
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                            if ep.watched {
                                Text("Đã xem").font(.caption2).foregroundStyle(CinemaStyle.accent)
                            }
                        }
                        Spacer()
                        Image(systemName: "play.fill").font(.caption).foregroundStyle(CinemaStyle.gold)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .overlay {
            if loading { ProgressView().padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
        }
    }

    private func authenticate() async {
        loading = true
        defer { loading = false }
        do {
            let profile: MediaServerProfile
            let token: String
            if kind == .plex {
                profile = try await PlexClient.connect(serverURL: serverURL, token: secret)
                token = secret
            } else {
                let auth = try await EmbyJellyfinClient.authenticate(
                    kind: kind,
                    serverURL: serverURL,
                    username: username,
                    password: secret
                )
                profile = auth.profile
                token = auth.token
            }
            store.save(profile, token: token)
            activeProfile = profile
            await loadCollections(profile)
        } catch {
            message = error.localizedDescription
        }
    }

    private func loadCollections(_ server: MediaServerProfile) async {
        loading = true
        defer { loading = false }
        let token = store.token(for: server)
        do {
            if server.kind == .plex {
                collections = try await PlexClient.fetchSections(profile: server, token: token)
            } else {
                collections = try await EmbyJellyfinClient.fetchViews(profile: server, token: token)
            }
        } catch {
            message = error.localizedDescription
        }
    }

    private func loadItems(server: MediaServerProfile, collection: ServerCollection) async {
        loading = true
        defer { loading = false }
        let token = store.token(for: server)
        do {
            if server.kind == .plex {
                items = try await PlexClient.fetchItems(profile: server, token: token, sectionKey: collection.id)
            } else {
                items = try await EmbyJellyfinClient.fetchItems(profile: server, token: token, parentID: collection.id)
            }
            selectedCollection = collection
        } catch {
            message = error.localizedDescription
        }
    }

    private func loadEpisodes(server: MediaServerProfile, series: ServerMediaEntry) async {
        loading = true
        defer { loading = false }
        let token = store.token(for: server)
        do {
            if server.kind == .plex {
                episodes = try await PlexClient.fetchChildren(profile: server, token: token, ratingKey: series.id)
            } else {
                episodes = try await EmbyJellyfinClient.fetchEpisodes(profile: server, token: token, seriesID: series.id)
            }
            selectedSeries = series
        } catch {
            message = error.localizedDescription
        }
    }

    private func convertEntry(_ entry: ServerMediaEntry, server: MediaServerProfile, seriesTitle: String? = nil) -> MediaItem? {
        let meta = MovieMetadata(
            id: entry.id.hashValue,
            kind: (entry.episodeNumber != nil || entry.kind == "episode") ? "tv" : "movie",
            title: seriesTitle ?? entry.seriesTitle ?? entry.title,
            overview: entry.overview,
            year: entry.year,
            posterPath: nil,
            backdropPath: nil,
            rating: entry.rating,
            originalTitle: entry.originalTitle,
            genres: entry.genres,
            runtimeMinutes: entry.runtimeMinutes
        )
        let epInfo: EpisodeInfo? = (entry.episodeNumber != nil) ? EpisodeInfo(
            seriesTitle: seriesTitle ?? entry.seriesTitle ?? entry.title,
            season: entry.seasonNumber ?? 1,
            episode: entry.episodeNumber ?? 1,
            episodeTitle: entry.title
        ) : nil

        if server.kind == .plex {
            guard let partKey = entry.partKey else { return nil }
            let loc = PlexMediaLocation(serverID: server.id, ratingKey: entry.id, partKey: partKey)
            return MediaItem(
                title: entry.title,
                source: .plex(loc),
                metadata: meta,
                watched: entry.watched,
                position: entry.positionSeconds,
                duration: entry.durationSeconds,
                mediaInfo: entry.technicalInfo,
                episodeInfo: epInfo
            )
        } else {
            let loc = MediaServerMediaLocation(serverID: server.id, itemID: entry.id, kind: server.kind)
            return MediaItem(
                title: entry.title,
                source: .mediaServer(loc),
                metadata: meta,
                watched: entry.watched,
                position: entry.positionSeconds,
                duration: entry.durationSeconds,
                mediaInfo: entry.technicalInfo,
                episodeInfo: epInfo
            )
        }
    }

    private func playServerEntry(_ entry: ServerMediaEntry, server: MediaServerProfile, seriesTitle: String? = nil) {
        guard let item = convertEntry(entry, server: server, seriesTitle: seriesTitle) else {
            message = "Mục này không có đường dẫn luồng trực tiếp."
            return
        }
        _ = library.batchAdd([item])
        if let saved = library.items.first(where: { $0.source == item.source }) {
            onPlayItem(saved)
        } else {
            onPlayItem(item)
        }
    }

    private func importEntries(_ list: [ServerMediaEntry], server: MediaServerProfile, seriesTitle: String? = nil) {
        let converted = list.compactMap { entry -> MediaItem? in
            if entry.kind == "series" || entry.kind == "show" { return nil }
            return convertEntry(entry, server: server, seriesTitle: seriesTitle)
        }
        let added = library.batchAdd(converted)
        message = "Đã nhập \(added) video từ \(server.kind.label) vào Thư viện."
    }

    private func goBack() {
        if selectedSeries != nil {
            selectedSeries = nil
            episodes = []
        } else if selectedCollection != nil {
            selectedCollection = nil
            items = []
        } else {
            activeProfile = nil
            collections = []
        }
    }
}
