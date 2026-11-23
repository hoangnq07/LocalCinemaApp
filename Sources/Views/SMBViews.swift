import AMSMB2
import SwiftUI

struct SMBSourceView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var profiles: SMBProfiles
    @ObservedObject var library: MediaLibrary
    var initialAddress: String? = nil
    let play: (SMBMediaLocation, [String]) -> Bool

    @State private var address = ""
    @State private var user = ""
    @State private var password = ""
    @State private var domain = ""
    @State private var editingID: UUID?
    @State private var connection: SMBProfile?
    @State private var client: SMB2Manager?
    @State private var level: Level?
    @State private var entries: [Entry] = []
    @State private var loading = false
    @State private var scanning = false
    @State private var message: String?
    @State private var removeProfile: SMBProfile?
    @FocusState private var focusedField: Field?

    var body: some View {
        NavigationStack {
            Group {
                if let level {
                    contents(level)
                } else {
                    connectForm
                }
            }
            .scrollContentBackground(.hidden)
            .background(CinemaStyle.background)
            .navigationTitle(level?.title ?? "Nguồn SMB")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if address.isEmpty, let initialAddress {
                    address = initialAddress
                }
            }
            .toolbar {
                if level != nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { goBack() } label: {
                            Label("Quay lại", systemImage: "chevron.left")
                        }
                        .disabled(loading || scanning)
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Đóng") { dismiss() } }
            }
            .alert("Kết nối SMB", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("Đóng", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
            .confirmationDialog("Gỡ kết nối SMB đã lưu?", isPresented: Binding(
                get: { removeProfile != nil },
                set: { if !$0 { removeProfile = nil } }
            ), presenting: removeProfile) { profile in
                Button("Gỡ kết nối", role: .destructive) {
                    do { try profiles.remove(profile) }
                    catch { message = error.localizedDescription }
                }
            } message: { profile in
                Text(profile.address)
            }
        }
    }

    private var connectForm: some View {
        Form {
            if !profiles.saved.isEmpty {
                Section("Máy chủ đã lưu") {
                    ForEach(profiles.saved) { profile in
                        Button { select(profile, andConnect: true) } label: {
                            HStack {
                                Label(profile.address, systemImage: "externaldrive.connected.to.line.below")
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption)
                            }
                        }
                        .contextMenu {
                            Button("Sửa kết nối") { select(profile, andConnect: false) }
                            Button("Gỡ kết nối", role: .destructive) { removeProfile = profile }
                        }
                    }
                }
            }

            Section(editingID == nil ? "Kết nối mới" : "Sửa kết nối") {
                TextField("smb://192.168.1.20/Phim", text: $address)
                    .focused($focusedField, equals: .address)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("smb-address")
                TextField("Tên người dùng (trống nếu Guest)", text: $user)
                    .focused($focusedField, equals: .user)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("smb-user")
                SecureField("Mật khẩu SMB", text: $password)
                    .focused($focusedField, equals: .password)
                    .textContentType(.oneTimeCode)
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("smb-password")
                TextField("Domain hoặc Workgroup (tùy chọn)", text: $domain)
                    .focused($focusedField, equals: .domain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            Section {
                Button("Kết nối", action: connect)
                    .disabled(SMBAddress(address) == nil)
                if editingID != nil {
                    Button("Thêm kết nối khác") {
                        editingID = nil
                        address = ""
                        user = ""
                        password = ""
                        domain = ""
                    }
                }
                if loading { ProgressView("Đang kết nối…") }
            } footer: {
                Text("Nhập cả tên thư mục chia sẻ nếu NAS giới hạn quyền liệt kê. Mật khẩu được lưu trong Keychain.")
            }
        }
        .disabled(loading)
    }

    private func contents(_ level: Level) -> some View {
        List {
            if case .folder(let share, let path) = level, let connection {
                Section {
                    Button {
                        Task { await scanIntoLibrary(profile: connection, share: share, path: path) }
                    } label: {
                        HStack {
                            Label(scanning ? "Đang quét vào Thư viện…" : "Quét thư mục vào Thư viện",
                                  systemImage: "square.and.arrow.down.on.square")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(CinemaStyle.accent)
                            Spacer()
                            if scanning { ProgressView() }
                        }
                    }
                    .disabled(scanning)
                }
            }

            if entries.isEmpty {
                Text("Không có thư mục hoặc video được hỗ trợ.")
                    .foregroundStyle(CinemaStyle.muted)
            }
            ForEach(entries) { entry in
                Button {
                    switch level {
                    case .shares:
                        changeLevel(.folder(share: entry.name, path: []))
                    case .folder(let share, let path):
                        if entry.directory {
                            changeLevel(.folder(share: share, path: path + [entry.name]))
                        } else if let connection {
                            let location = SMBMediaLocation(
                                connectionID: connection.id,
                                share: share,
                                path: Self.filePath(path + [entry.name])
                            )
                            if !play(location, entry.sidecars) {
                                message = "Không thể lưu video vào thư viện."
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: entry.directory ? "folder.fill" : "play.rectangle.fill")
                            .foregroundStyle(entry.directory ? CinemaStyle.accent : CinemaStyle.gold)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name).lineLimit(2)
                            if !entry.sidecars.isEmpty {
                                Text("CC · \(entry.sidecars.count) phụ đề")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(CinemaStyle.accent)
                            }
                        }
                        Spacer()
                        Image(systemName: entry.directory ? "chevron.right" : "play.fill")
                            .font(.caption)
                            .foregroundStyle(CinemaStyle.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("smb-entry-\(entry.name)")
            }
        }
        .disabled(loading)
        .overlay {
            if loading {
                ProgressView()
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func select(_ profile: SMBProfile, andConnect: Bool) {
        editingID = profile.id
        address = profile.address
        user = profile.user
        domain = profile.domain
        password = profiles.password(for: profile)
        if andConnect { connect() }
    }

    private func connect() {
        guard let target = SMBAddress(address), !loading else { return }
        focusedField = nil
        let secret = password
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedID = editingID ?? profiles.existingProfileID(matchingAddress: trimmedAddress, user: trimmedUser) ?? UUID()
        let profile = SMBProfile(
            id: resolvedID,
            address: trimmedAddress,
            user: trimmedUser,
            domain: domain.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let destination = target.folders.first.map {
            Level.folder(share: $0, path: Array(target.folders.dropFirst()))
        } ?? .shares
        loading = true
        Task {
            defer { loading = false }
            do {
                let session = try profile.makeClient(password: secret)
                let results = try await Self.fetch(destination, using: session)
                try profiles.save(profile, password: secret)
                client = session
                connection = profile
                editingID = profile.id
                level = destination
                entries = results
            } catch {
                message = "Không mở được SMB. Kiểm tra địa chỉ, tên thư mục chia sẻ và tài khoản.\n\(error.localizedDescription)"
            }
        }
    }

    private func changeLevel(_ destination: Level) {
        guard let client, !loading else { return }
        loading = true
        Task {
            defer { loading = false }
            do {
                let results = try await Self.fetch(destination, using: client)
                entries = results
                level = destination
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func goBack() {
        if case .folder(let share, let path) = level, !path.isEmpty {
            changeLevel(.folder(share: share, path: Array(path.dropLast())))
        } else if case .folder = level, SMBAddress(address)?.folders.isEmpty == true {
            changeLevel(.shares)
        } else {
            level = nil
            entries = []
            client = nil
            connection = nil
        }
    }

    private func scanIntoLibrary(profile: SMBProfile, share: String, path: [String]) async {
        scanning = true
        defer { scanning = false }
        do {
            let folderPath = Self.filePath(path)
            let files = try await profiles.scanFolder(profile: profile, share: share, folderPath: folderPath)
            let items = files.map { file -> MediaItem in
                let parsed = FilenameParser.parse(file.name, fileSize: file.fileSize, sidecars: file.sidecarSubtitles)
                let loc = SMBMediaLocation(connectionID: profile.id, share: share, path: file.path)
                return MediaItem(
                    title: parsed.cleanTitle,
                    source: .smb(loc),
                    mediaInfo: parsed.technicalInfo,
                    episodeInfo: parsed.episodeInfo
                )
            }
            let added = library.batchAdd(items)
            message = "Đã thêm \(added) video từ \(share) vào Thư viện."
        } catch {
            message = error.localizedDescription
        }
    }

    private static func fetch(_ level: Level, using client: SMB2Manager) async throws -> [Entry] {
        switch level {
        case .shares:
            return try await client.listShares()
                .filter { SMBAddress.validComponent($0.name) }
                .map { Entry(name: $0.name, directory: true, sidecars: []) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .folder(let share, let path):
            try await client.connectShare(name: share)
            let rows = try await client.contentsOfDirectory(atPath: filePath(path))
            var subtitlePaths: [String] = []
            var subFolderPaths: [[String]] = []
            var rawEntries: [(name: String, folder: Bool)] = []

            for row in rows {
                guard let name = row[.nameKey] as? String, SMBAddress.validComponent(name) else { continue }
                let folder = (row[.isDirectoryKey] as? NSNumber)?.boolValue == true
                let url = URL(fileURLWithPath: name)
                let suffix = url.pathExtension.lowercased()
                if !folder && MediaLibrary.subtitleExtensions.contains(suffix) {
                    subtitlePaths.append(filePath(path + [name]))
                } else if folder || MediaLibrary.fileExtensions.contains(suffix) {
                    rawEntries.append((name, folder))
                    if folder && FolderSubtitleMatcher.isSubtitleFolderName(name) {
                        subFolderPaths.append(path + [name])
                    }
                }
            }

            for subPath in subFolderPaths.prefix(2) {
                if let subRows = try? await client.contentsOfDirectory(atPath: filePath(subPath)) {
                    for sRow in subRows {
                        guard let sName = sRow[.nameKey] as? String,
                              SMBAddress.validComponent(sName),
                              (sRow[.isDirectoryKey] as? NSNumber)?.boolValue != true else { continue }
                        if MediaLibrary.subtitleExtensions.contains(URL(fileURLWithPath: sName).pathExtension.lowercased()) {
                            subtitlePaths.append(filePath(subPath + [sName]))
                        }
                    }
                }
            }

            return rawEntries.map { row in
                if row.folder {
                    return Entry(name: row.name, directory: true, sidecars: [])
                }
                let videoPath = filePath(path + [row.name])
                let sidecars = FolderSubtitleMatcher.match(videoPath: videoPath, candidateSubtitlePaths: subtitlePaths)
                return Entry(name: row.name, directory: false, sidecars: sidecars)
            }.sorted { left, right in
                if left.directory != right.directory { return left.directory }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
        }
    }

    private static func filePath(_ components: [String]) -> String {
        "/" + components.joined(separator: "/")
    }

    private enum Level {
        case shares
        case folder(share: String, path: [String])

        var title: String {
            switch self {
            case .shares: return "Thư mục chia sẻ"
            case .folder(let share, let path): return path.last ?? share
            }
        }
    }

    private struct Entry: Identifiable {
        var id: String { name }
        let name: String
        let directory: Bool
        let sidecars: [String]
    }

    private enum Field { case address, user, password, domain }
}
