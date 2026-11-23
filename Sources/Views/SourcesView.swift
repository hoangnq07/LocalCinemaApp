import SwiftUI
import UniformTypeIdentifiers

struct SourcesView: View {
    @ObservedObject var library: MediaLibrary
    @ObservedObject var smbProfiles: SMBProfiles
    @ObservedObject var webdavProfiles: WebDAVProfiles
    @ObservedObject var serverStore: MediaServerStore
    @Binding var serverURL: String
    let onPlayItem: (MediaItem) -> Void
    let onPickFile: () -> Void
    let onOpenAddLink: () -> Void

    @StateObject private var discovery = LANDiscovery()
    @State private var sheet: SourceSheet?
    @State private var playAfterSheetDismiss: MediaItem?
    @State private var pendingActionAfterSheet: (() -> Void)?
    @State private var pickingPlaylist = false
    @State private var notice: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerRow
                lanDiscoveryCard
                mediaServersSection
                networkSharesSection
                localAndPlaylistSection
            }
            .frame(maxWidth: 860)
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .background(CinemaStyle.background.ignoresSafeArea())
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
        .sheet(item: $sheet, onDismiss: {
            if let item = playAfterSheetDismiss {
                playAfterSheetDismiss = nil
                onPlayItem(item)
            } else if let pending = pendingActionAfterSheet {
                pendingActionAfterSheet = nil
                pending()
            }
        }) { target in
            switch target {
            case .addMenu:
                AddSourceMenuSheet(
                    onPickSMB: { sheet = .smb(prefill: nil) },
                    onPickWebDAV: { sheet = .webdav(prefill: nil) },
                    onPickServer: { kind in sheet = .mediaServer(kind: kind, existing: nil) },
                    onPickLink: {
                        pendingActionAfterSheet = onOpenAddLink
                        sheet = nil
                    },
                    onPickPlaylist: {
                        pendingActionAfterSheet = { pickingPlaylist = true }
                        sheet = nil
                    },
                    onPickFile: {
                        pendingActionAfterSheet = onPickFile
                        sheet = nil
                    }
                )
            case .smb(let prefill):
                SMBSourceView(profiles: smbProfiles, library: library, initialAddress: prefill) { location, sidecars in
                    guard let item = library.addSMB(location, sidecars: sidecars) else { return false }
                    playAfterSheetDismiss = item
                    sheet = nil
                    return true
                }
            case .webdav(let profile):
                WebDAVSourceView(profiles: webdavProfiles, library: library, initialProfile: profile) { location, sidecars in
                    guard let item = library.addWebDAV(location, sidecars: sidecars) else { return false }
                    playAfterSheetDismiss = item
                    sheet = nil
                    return true
                }
            case .mediaServer(let kind, let existing):
                MediaServerView(
                    store: serverStore,
                    library: library,
                    initialKind: kind,
                    selectedServer: existing
                ) { item in
                    playAfterSheetDismiss = item
                    sheet = nil
                }
            }
        }
        .fileImporter(
            isPresented: $pickingPlaylist,
            allowedContentTypes: [UTType.text, UTType.data],
            allowsMultipleSelection: true,
            onCompletion: importPlaylistFiles
        )
        .alert("Nguồn phát", isPresented: Binding(
            get: { notice != nil },
            set: { if !$0 { notice = nil } }
        )) {
            Button("Đóng", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    private var headerRow: some View {
        HStack {
            Text("Nguồn")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(CinemaStyle.text)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button { sheet = .addMenu } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(CinemaStyle.ctaForeground)
                    .frame(width: 38, height: 38)
                    .background(CinemaStyle.ctaBackground, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Thêm nguồn")
        }
    }

    private var lanDiscoveryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(discovery.scanning ? Color.green : CinemaStyle.muted)
                    .frame(width: 7, height: 7)
                Text("LAN")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(CinemaStyle.accent)
                Text(discovery.hosts.isEmpty
                     ? (discovery.scanning ? "Đang tìm máy chủ…" : "Chưa thấy thiết bị")
                     : "\(discovery.hosts.count) máy chủ")
                    .font(.caption)
                    .foregroundStyle(CinemaStyle.muted)
                Spacer()
                Button { discovery.start() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(CinemaStyle.accent)
                        .frame(width: 28, height: 28)
                        .obsidianGlass(cornerRadius: 14, strong: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Quét lại")
            }
            if !discovery.hosts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(discovery.hosts) { host in
                            Button {
                                if host.serviceType == "_smb._tcp" {
                                    sheet = .smb(prefill: host.hostURI)
                                } else {
                                    sheet = .webdav(prefill: nil)
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    TechBadge(text: host.kindLabel, tone: .accent)
                                    Text(host.name).font(.caption.weight(.semibold)).foregroundStyle(CinemaStyle.text)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .obsidianGlass(cornerRadius: 12)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .obsidianGlass(cornerRadius: 14)
    }

    private var mediaServersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MEDIA SERVER")
                .font(.caption2.weight(.bold))
                .foregroundStyle(CinemaStyle.muted)

            if serverStore.servers.isEmpty {
                HStack(spacing: 8) {
                    quickConnectPill("Jellyfin") { sheet = .mediaServer(kind: .jellyfin, existing: nil) }
                    quickConnectPill("Emby") { sheet = .mediaServer(kind: .emby, existing: nil) }
                    quickConnectPill("Plex") { sheet = .mediaServer(kind: .plex, existing: nil) }
                }
            } else {
                ForEach(serverStore.servers) { server in
                    Button {
                        sheet = .mediaServer(kind: server.kind, existing: server)
                    } label: {
                        sourceRowCard(
                            badge: server.kind.label.uppercased(),
                            title: server.name,
                            subtitle: server.serverURL,
                            tag: "Direct"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var networkSharesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("NAS & CLOUD")
                .font(.caption2.weight(.bold))
                .foregroundStyle(CinemaStyle.muted)

            HStack(spacing: 8) {
                Button { sheet = .smb(prefill: nil) } label: {
                    sourceActionTile("SMB", subtitle: "\(smbProfiles.saved.count) máy chủ", icon: "server.rack")
                }
                .buttonStyle(.plain)

                Button { sheet = .webdav(prefill: nil) } label: {
                    sourceActionTile("WebDAV", subtitle: "\(webdavProfiles.saved.count) kết nối", icon: "globe")
                }
                .buttonStyle(.plain)
            }

            ForEach(smbProfiles.saved) { profile in
                Button { sheet = .smb(prefill: profile.address) } label: {
                    sourceRowCard(badge: "SMB", title: profile.address, subtitle: profile.user.isEmpty ? "Guest" : profile.user, tag: "SMB")
                }
                .buttonStyle(.plain)
            }

            ForEach(webdavProfiles.saved) { profile in
                Button { sheet = .webdav(prefill: profile) } label: {
                    sourceRowCard(badge: "DAV", title: profile.name, subtitle: profile.baseURL, tag: "DAV")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var localAndPlaylistSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TỆP & DANH SÁCH")
                .font(.caption2.weight(.bold))
                .foregroundStyle(CinemaStyle.muted)

            HStack(spacing: 8) {
                Button(action: onPickFile) {
                    sourceActionTile("Chọn tệp", subtitle: "MKV, MP4…", icon: "folder")
                }
                .buttonStyle(.plain)

                Button(action: onOpenAddLink) {
                    sourceActionTile("Liên kết", subtitle: "HTTP / LAN", icon: "link")
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                Button { pickingPlaylist = true } label: {
                    sourceActionTile("M3U / STRM", subtitle: "IPTV Playlist", icon: "list.bullet.rectangle")
                }
                .buttonStyle(.plain)

                Button {
                    library.scanDocumentsFolder()
                    notice = "Đã quét lại thư mục Tệp (Documents) của ứng dụng."
                } label: {
                    sourceActionTile("Quét Tệp", subtitle: "Documents", icon: "arrow.clockwise")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func quickConnectPill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("+ \(title)")
                .font(.caption.weight(.bold))
                .foregroundStyle(CinemaStyle.text)
                .frame(maxWidth: .infinity, minHeight: 42)
                .obsidianGlass(cornerRadius: 14)
        }
        .buttonStyle(.plain)
    }

    private func sourceActionTile(_ title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(CinemaStyle.accent)
                .frame(width: 34, height: 34)
                .background(CinemaStyle.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(CinemaStyle.text)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(CinemaStyle.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, minHeight: 60, maxHeight: 60, alignment: .leading)
        .obsidianGlass(cornerRadius: 14)
    }

    private func sourceRowCard(badge: String, title: String, subtitle: String, tag: String) -> some View {
        HStack(spacing: 12) {
            Text(badge)
                .font(.caption2.weight(.bold))
                .foregroundStyle(CinemaStyle.accent)
                .frame(width: 44, height: 40)
                .background(CinemaStyle.panelStrong, in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(CinemaStyle.text).lineLimit(1)
                    TechBadge(text: tag, tone: .accent)
                }
                Text(subtitle).font(.caption2).foregroundStyle(CinemaStyle.muted).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(CinemaStyle.muted)
        }
        .padding(11)
        .obsidianGlass(cornerRadius: 16)
    }

    private func importPlaylistFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        var total = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let ext = url.pathExtension.lowercased()
            if ext == "strm" {
                if let entry = PlaylistParser.parseSTRM(text, fallbackTitle: url.deletingPathExtension().lastPathComponent) {
                    if library.addLink(entry.url, title: entry.title, headers: entry.headers) != nil {
                        total += 1
                    }
                }
            } else {
                for entry in PlaylistParser.parseM3U(text) {
                    if library.addLink(entry.url, title: entry.title, headers: entry.headers) != nil {
                        total += 1
                    }
                }
            }
        }
        notice = total > 0 ? "Đã thêm \(total) luồng từ danh sách phát." : "Không tìm thấy liên kết phát hợp lệ trong tệp."
    }

    private enum SourceSheet: Identifiable {
        case addMenu
        case smb(prefill: String?)
        case webdav(prefill: WebDAVProfile?)
        case mediaServer(kind: MediaServerKind, existing: MediaServerProfile?)

        var id: String {
            switch self {
            case .addMenu: return "addMenu"
            case .smb(let p): return "smb-\(p ?? "new")"
            case .webdav(let p): return "webdav-\(p?.id.uuidString ?? "new")"
            case .mediaServer(let k, let e): return "ms-\(k.rawValue)-\(e?.id.uuidString ?? "new")"
            }
        }
    }
}

struct AddSourceMenuSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onPickSMB: () -> Void
    let onPickWebDAV: () -> Void
    let onPickServer: (MediaServerKind) -> Void
    let onPickLink: () -> Void
    let onPickPlaylist: () -> Void
    let onPickFile: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Máy chủ Media") {
                    Button { onPickServer(.jellyfin) } label: { Label("Jellyfin Server", systemImage: "tv") }
                    Button { onPickServer(.emby) } label: { Label("Emby Server", systemImage: "play.tv") }
                    Button { onPickServer(.plex) } label: { Label("Plex Media Server", systemImage: "sparkles.tv") }
                }
                Section("Chia sẻ mạng LAN / Cloud") {
                    Button(action: onPickSMB) { Label("SMB / CIFS (NAS Windows, macOS)", systemImage: "server.rack") }
                    Button(action: onPickWebDAV) { Label("WebDAV / Alist HTTPS", systemImage: "globe") }
                }
                Section("Tệp & Liên kết") {
                    Button(action: onPickFile) { Label("Nhập tệp video từ Tệp", systemImage: "folder") }
                    Button(action: onPickLink) { Label("Liên kết HTTP(S) / LAN", systemImage: "link") }
                    Button(action: onPickPlaylist) { Label("Danh sách IPTV (.m3u / .m3u8 / .strm)", systemImage: "list.bullet.rectangle") }
                }
            }
            .scrollContentBackground(.hidden)
            .background(CinemaStyle.background)
            .navigationTitle("Thêm nguồn phát")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Đóng") { dismiss() } }
            }
        }
    }
}

struct AddLinkView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var serverURL: String
    let add: (URL, String) -> Bool
    @State private var link = ""
    @State private var title = ""

    private var url: URL? { MediaLibrary.resolveLink(link, server: serverURL) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Địa chỉ video") {
                    TextField("https://… hoặc /stream/…", text: $link)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Tên hiển thị (tùy chọn)", text: $title)
                }
                Section {
                    TextField("http://192.168.1.1:8080", text: $serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Máy chủ LAN")
                } footer: {
                    Text("Dùng địa chỉ này khi liên kết bắt đầu bằng /stream/.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(CinemaStyle.background)
            .navigationTitle("Mở liên kết")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Hủy") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Thêm") {
                        if let url, add(url, title.trimmingCharacters(in: .whitespacesAndNewlines)) { dismiss() }
                    }
                    .fontWeight(.semibold)
                    .disabled(url == nil)
                }
            }
        }
    }
}
