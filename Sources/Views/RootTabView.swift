import SwiftUI

enum MainTab: String, CaseIterable, Identifiable {
    case home, library, sources, settings
    var id: Self { self }

    var title: String {
        switch self {
        case .home: return "Trang chủ"
        case .library: return "Thư viện"
        case .sources: return "Nguồn"
        case .settings: return "Cài đặt"
        }
    }

    var icon: String {
        switch self {
        case .home: return "play.tv"
        case .library: return "square.grid.2x2"
        case .sources: return "externaldrive.connected.to.line.below"
        case .settings: return "gearshape"
        }
    }
}

struct RootTabView: View {
    @ObservedObject var library: MediaLibrary
    @ObservedObject var smbProfiles: SMBProfiles
    @ObservedObject var webdavProfiles: WebDAVProfiles
    @ObservedObject var serverStore: MediaServerStore

    @AppStorage("appTheme") private var appTheme = AppTheme.obsidian
    @AppStorage("serverURL") private var serverURL = "http://192.168.1.1:8080"

    @State private var activeTab: MainTab = .home
    @State private var detailTarget: DetailSelection?
    @State private var playingItem: MediaItem?
    @State private var playAfterSheetDismiss: MediaItem?
    @State private var pendingRemove: MediaItem?
    @State private var activeSheet: GlobalSheet?
    @State private var pickingFile = false
    @State private var importing = false

    var body: some View {
        ZStack(alignment: .bottom) {
            CinemaStyle.background.ignoresSafeArea()

            Group {
                switch activeTab {
                case .home:
                    HomeView(
                        library: library,
                        onOpenDetail: { openDetail($0) },
                        onOpenSeries: { detailTarget = .series($0) },
                        onPlay: { playingItem = $0 },
                        onPickFile: { pickingFile = true },
                        onOpenLink: { activeSheet = .addLink },
                        onOpenSMB: { activeSheet = .smb },
                        onJumpTab: { activeTab = $0 },
                        onRequestRemove: { pendingRemove = $0 },
                        importing: importing
                    )
                case .library:
                    LibraryView(
                        library: library,
                        onOpenDetail: { openDetail($0) },
                        onOpenSeries: { detailTarget = .series($0) },
                        onPlay: { playingItem = $0 },
                        onRequestRemove: { pendingRemove = $0 }
                    )
                case .sources:
                    SourcesView(
                        library: library,
                        smbProfiles: smbProfiles,
                        webdavProfiles: webdavProfiles,
                        serverStore: serverStore,
                        serverURL: $serverURL,
                        onPlayItem: { playingItem = $0 },
                        onPickFile: { pickingFile = true },
                        onOpenAddLink: { activeSheet = .addLink }
                    )
                case .settings:
                    SettingsView(
                        library: library,
                        serverURL: $serverURL
                    )
                }
            }
            .id(appTheme)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                floatingTabBar
            }
        }
        .sheet(item: $detailTarget, onDismiss: {
            if let next = playAfterSheetDismiss {
                playingItem = next
                playAfterSheetDismiss = nil
            }
        }) { target in
            switch target {
            case .item(let item):
                MovieDetailView(item: item, library: library) { playItem in
                    playAfterSheetDismiss = playItem
                    detailTarget = nil
                }
            case .series(let group):
                SeriesDetailView(group: group, library: library) { playItem in
                    playAfterSheetDismiss = playItem
                    detailTarget = nil
                }
            }
        }
        .sheet(item: $activeSheet, onDismiss: {
            if let next = playAfterSheetDismiss {
                playingItem = next
                playAfterSheetDismiss = nil
            }
        }) { sheet in
            switch sheet {
            case .addLink:
                AddLinkView(serverURL: $serverURL) { url, title in
                    library.addLink(url, title: title) != nil
                }
            case .smb:
                SMBSourceView(profiles: smbProfiles, library: library) { location, sidecars in
                    guard let item = library.addSMB(location, sidecars: sidecars) else { return false }
                    playAfterSheetDismiss = item
                    activeSheet = nil
                    return true
                }
            }
        }
        .fullScreenCover(item: $playingItem) { item in
            UnifiedPlayerLauncher(
                item: item,
                library: library,
                smbProfiles: smbProfiles,
                webdavProfiles: webdavProfiles,
                serverStore: serverStore,
                onPlayNext: { nextEp in
                    playingItem = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        playingItem = nextEp
                    }
                }
            )
            .id(item.id)
        }
        .fileImporter(
            isPresented: $pickingFile,
            allowedContentTypes: MediaLibrary.fileTypes,
            allowsMultipleSelection: true,
            onCompletion: importVideos
        )
        .alert("Không thể thực hiện", isPresented: Binding(
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

    private func openDetail(_ item: MediaItem) {
        if let info = item.episodeInfo {
            let key = (item.metadata?.title ?? info.seriesTitle).lowercased()
            if let group = library.seriesGroups.first(where: { $0.id == key }) {
                detailTarget = .series(group)
                return
            }
        }
        detailTarget = .item(item)
    }

    private var floatingTabBar: some View {
        HStack(spacing: 4) {
            ForEach(MainTab.allCases) { tab in
                let selected = activeTab == tab
                Button {
                    activeTab = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 17, weight: .semibold))
                        Text(tab.title)
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(selected ? CinemaStyle.accent : CinemaStyle.muted)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(
                        selected ? Color.white.opacity(0.07) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tab-\(tab.rawValue)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: 460)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .background(CinemaStyle.elevated.opacity(0.75), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(CinemaStyle.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 20, y: 8)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
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

    enum DetailSelection: Identifiable {
        case item(MediaItem)
        case series(SeriesGroup)

        var id: String {
            switch self {
            case .item(let i): return "item-\(i.id.uuidString)"
            case .series(let s): return "series-\(s.id)"
            }
        }
    }

    enum GlobalSheet: Identifiable {
        case addLink, smb
        var id: Self { self }
    }
}

// MARK: - Unified Player Launcher (SMB, WebDAV, Jellyfin/Emby, Plex, Local, HTTP)

struct UnifiedPlayerLauncher: View {
    @Environment(\.dismiss) private var dismiss

    let item: MediaItem
    @ObservedObject var library: MediaLibrary
    @ObservedObject var smbProfiles: SMBProfiles
    @ObservedObject var webdavProfiles: WebDAVProfiles
    @ObservedObject var serverStore: MediaServerStore
    let onPlayNext: (MediaItem) -> Void

    @State private var resolved: ResolvedPlayback?
    @State private var error: String?

    var body: some View {
        Group {
            if let resolved {
                CinemaPlayer(
                    item: item,
                    url: resolved.url,
                    smbSource: resolved.smbSource,
                    httpHeaders: resolved.headers,
                    externalSubtitles: resolved.sidecarSubs,
                    nextEpisode: library.nextEpisode(after: item),
                    onPlayNext: onPlayNext
                ) { position, duration in
                    library.markPlayed(item.id, position: position, duration: duration)
                    Task {
                        await serverStore.syncProgress(for: item, position: position, duration: duration, stopped: false)
                        if let tmdbID = item.metadata?.id, duration > 0 {
                            let pct = (position / duration) * 100.0
                            await TraktService.scrobble(
                                action: pct >= 90 ? "stop" : "pause",
                                tmdbID: tmdbID,
                                kind: item.metadata?.kind ?? "movie",
                                progressPercent: pct,
                                season: item.episodeInfo?.season,
                                episode: item.episodeInfo?.episode
                            )
                        }
                    }
                }
            } else {
                ZStack {
                    CinemaStyle.background.ignoresSafeArea()
                    VStack(spacing: 16) {
                        if let error {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.largeTitle)
                                .foregroundStyle(CinemaStyle.gold)
                            Text(error)
                                .font(.subheadline)
                                .foregroundStyle(CinemaStyle.text)
                                .multilineTextAlignment(.center)
                        } else {
                            ProgressView()
                                .tint(CinemaStyle.accent)
                            Text("Đang chuẩn bị luồng phát…")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(CinemaStyle.muted)
                        }
                        Button("Đóng") { dismiss() }
                            .buttonStyle(.bordered)
                    }
                    .padding(24)
                }
            }
        }
        .task {
            await prepare()
        }
    }

    private func prepare() async {
        switch item.source {
        case .remote(let url):
            resolved = ResolvedPlayback(url: url, smbSource: nil, headers: [:], sidecarSubs: [])
        case .remoteAuth(let url, let headers):
            resolved = ResolvedPlayback(url: url, smbSource: nil, headers: headers, sidecarSubs: [])
        case .file:
            if let url = library.url(for: item) {
                let localSubs = FolderSubtitleMatcher.scanLocalDirectory(for: url)
                resolved = ResolvedPlayback(url: url, smbSource: nil, headers: [:], sidecarSubs: localSubs)
            } else {
                error = "Không tìm thấy tệp video trên máy."
            }
        case .smb(let location):
            do {
                let source = try await smbProfiles.prepare(location)
                try Task.checkCancellation()
                let liveSubs = await smbProfiles.findFolderSubtitles(for: location)
                let storedSubs = item.mediaInfo?.sidecarSubtitles ?? []
                let mergedPaths = mergeSubtitlePaths(primary: liveSubs, fallback: storedSubs)
                if !mergedPaths.isEmpty, mergedPaths != storedSubs {
                    library.setSidecars(item.id, sidecars: mergedPaths)
                }
                let sidecars = await smbProfiles.downloadSidecarSubtitles(
                    for: location,
                    sidecars: mergedPaths
                )
                guard let url = URL(string: source.uri) else {
                    error = "Địa chỉ luồng SMB không hợp lệ."
                    return
                }
                resolved = ResolvedPlayback(url: url, smbSource: source, headers: [:], sidecarSubs: sidecars)
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        case .webdav(let location):
            guard let cfg = webdavProfiles.playbackConfig(for: location),
                  let profile = webdavProfiles.profile(for: location.profileID) else {
                error = "Nguồn WebDAV không còn tồn tại."
                return
            }
            let password = webdavProfiles.password(for: profile)
            let liveSubs = await WebDAVClient.findFolderSubtitles(
                profile: profile,
                password: password,
                videoPath: location.path
            )
            let storedSubs = item.mediaInfo?.sidecarSubtitles ?? []
            let mergedPaths = mergeSubtitlePaths(primary: liveSubs, fallback: storedSubs)
            if !mergedPaths.isEmpty, mergedPaths != storedSubs {
                library.setSidecars(item.id, sidecars: mergedPaths)
            }
            let sidecars = await WebDAVClient.downloadSubtitles(
                profile: profile,
                password: password,
                paths: mergedPaths
            )
            resolved = ResolvedPlayback(url: cfg.url, smbSource: nil, headers: cfg.headers, sidecarSubs: sidecars)
        case .mediaServer(let location):
            if let cfg = serverStore.streamConfig(for: location) {
                resolved = ResolvedPlayback(url: cfg.url, smbSource: nil, headers: cfg.headers, sidecarSubs: [])
            } else {
                error = "Không tìm thấy cấu hình máy chủ Jellyfin/Emby."
            }
        case .plex(let location):
            if let url = serverStore.plexStreamURL(for: location) {
                resolved = ResolvedPlayback(url: url, smbSource: nil, headers: [:], sidecarSubs: [])
            } else {
                error = "Không tìm thấy cấu hình máy chủ Plex."
            }
        }
    }

    private func mergeSubtitlePaths(primary: [String], fallback: [String]) -> [String] {
        var seen = Set<String>()
        var merged: [String] = []
        for path in primary + fallback {
            let key = path.lowercased()
            if seen.insert(key).inserted {
                merged.append(path)
            }
        }
        return merged
    }

    private struct ResolvedPlayback {
        let url: URL
        let smbSource: SMBReadSource?
        let headers: [String: String]
        let sidecarSubs: [URL]
    }
}
