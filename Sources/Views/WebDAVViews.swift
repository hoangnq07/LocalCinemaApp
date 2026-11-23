import SwiftUI

struct WebDAVSourceView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var profiles: WebDAVProfiles
    @ObservedObject var library: MediaLibrary
    var initialProfile: WebDAVProfile? = nil
    let play: (WebDAVMediaLocation, [String]) -> Bool

    @State private var editingID: UUID?
    @State private var name = ""
    @State private var baseURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var activeProfile: WebDAVProfile?
    @State private var pathStack: [String] = []
    @State private var entries: [WebDAVEntry] = []
    @State private var loading = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Group {
                if let activeProfile {
                    browserList(activeProfile)
                } else {
                    connectForm
                }
            }
            .scrollContentBackground(.hidden)
            .background(CinemaStyle.background)
            .navigationTitle(pathStack.last ?? activeProfile?.name ?? "WebDAV / Alist")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if let initialProfile, activeProfile == nil {
                    select(initialProfile, connectNow: true)
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
            .alert("WebDAV", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("Đóng", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
        }
    }

    private var connectForm: some View {
        Form {
            if !profiles.saved.isEmpty {
                Section("Kết nối đã lưu") {
                    ForEach(profiles.saved) { profile in
                        Button { select(profile, connectNow: true) } label: {
                            HStack {
                                Label(profile.name, systemImage: "globe")
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption)
                            }
                        }
                        .contextMenu {
                            Button("Sửa") { select(profile, connectNow: false) }
                            Button("Xóa", role: .destructive) { profiles.remove(profile) }
                        }
                    }
                }
            }

            Section("Kết nối WebDAV mới") {
                TextField("Tên hiển thị (VD: Alist 4K)", text: $name)
                TextField("https://alist.example.com/dav", text: $baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Tên đăng nhập", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Mật khẩu", text: $password)
                    .textInputAutocapitalization(.never)
            }

            Section {
                Button("Kết nối") { Task { await connect() } }
                    .disabled(baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loading)
                if loading { ProgressView("Đang duyệt WebDAV…") }
            }
        }
    }

    private func browserList(_ profile: WebDAVProfile) -> some View {
        List {
            Section {
                Button {
                    Task { await scanCurrentFolder(profile) }
                } label: {
                    Label("Quét thư mục này vào Thư viện", systemImage: "square.and.arrow.down.on.square")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(CinemaStyle.accent)
                }
            }

            let subPaths = entries.filter(\.isSubtitle).map(\.path)
            let visible = entries.filter { $0.isDirectory || $0.isVideo }
            if visible.isEmpty {
                Text("Không có thư mục hoặc tệp video.")
                    .foregroundStyle(CinemaStyle.muted)
            }
            ForEach(visible) { entry in
                let matchedSubs = entry.isDirectory
                    ? []
                    : FolderSubtitleMatcher.match(videoPath: entry.path, candidateSubtitlePaths: subPaths)
                Button {
                    if entry.isDirectory {
                        Task { await loadFolder(profile, path: entry.path, pushName: entry.name) }
                    } else {
                        let loc = WebDAVMediaLocation(profileID: profile.id, path: entry.path)
                        _ = play(loc, matchedSubs)
                    }
                } label: {
                    HStack {
                        Image(systemName: entry.isDirectory ? "folder.fill" : "play.rectangle.fill")
                            .foregroundStyle(entry.isDirectory ? CinemaStyle.accent : CinemaStyle.gold)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name).lineLimit(2)
                            HStack(spacing: 6) {
                                if let size = entry.size, !entry.isDirectory {
                                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                        .font(.caption2)
                                        .foregroundStyle(CinemaStyle.muted)
                                }
                                if !matchedSubs.isEmpty {
                                    Text("CC · \(matchedSubs.count) phụ đề")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(CinemaStyle.accent)
                                }
                            }
                        }
                        Spacer()
                        Image(systemName: entry.isDirectory ? "chevron.right" : "play.fill")
                            .font(.caption)
                            .foregroundStyle(CinemaStyle.muted)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .overlay {
            if loading { ProgressView().padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
        }
    }

    private func select(_ profile: WebDAVProfile, connectNow: Bool) {
        editingID = profile.id
        name = profile.name
        baseURL = profile.baseURL
        username = profile.username
        password = profiles.password(for: profile)
        if connectNow {
            Task { await connect() }
        }
    }

    private func connect() async {
        loading = true
        defer { loading = false }
        let profile = WebDAVProfile(
            id: editingID ?? UUID(),
            name: name.isEmpty ? (URL(string: baseURL)?.host ?? "WebDAV") : name,
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        do {
            let list = try await WebDAVClient.listDirectory(profile: profile, password: password, folderPath: "/")
            try profiles.save(profile, password: password)
            activeProfile = profile
            pathStack = []
            entries = list
        } catch {
            message = error.localizedDescription
        }
    }

    private func loadFolder(_ profile: WebDAVProfile, path: String, pushName: String?) async {
        loading = true
        defer { loading = false }
        do {
            let list = try await WebDAVClient.listDirectory(profile: profile, password: profiles.password(for: profile), folderPath: path)
            if let pushName { pathStack.append(pushName) }
            entries = list
        } catch {
            message = error.localizedDescription
        }
    }

    private func scanCurrentFolder(_ profile: WebDAVProfile) async {
        loading = true
        defer { loading = false }
        let currentPath = "/" + pathStack.joined(separator: "/")
        do {
            let scanned = try await WebDAVClient.scanFolder(profile: profile, password: profiles.password(for: profile), folderPath: currentPath)
            let items = scanned.map { pair -> MediaItem in
                let parsed = FilenameParser.parse(pair.entry.name, fileSize: pair.entry.size, sidecars: pair.sidecars)
                let loc = WebDAVMediaLocation(profileID: profile.id, path: pair.entry.path)
                return MediaItem(title: parsed.cleanTitle, source: .webdav(loc), mediaInfo: parsed.technicalInfo, episodeInfo: parsed.episodeInfo)
            }
            let added = library.batchAdd(items)
            message = "Đã nhập \(added) video từ WebDAV vào Thư viện."
        } catch {
            message = error.localizedDescription
        }
    }

    private func goBack() {
        guard let activeProfile else { return }
        if pathStack.isEmpty {
            self.activeProfile = nil
            entries = []
        } else {
            pathStack.removeLast()
            let path = "/" + pathStack.joined(separator: "/")
            Task { await loadFolder(activeProfile, path: path, pushName: nil) }
        }
    }
}
