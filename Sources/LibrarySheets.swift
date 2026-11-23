import SwiftUI

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

struct CinemaSettings: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var serverURL: String
    @State private var token = ""
    @State private var status: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Máy chủ LAN") {
                    TextField("http://192.168.1.1:8080", text: $serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    SecureField("API Read Access Token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Lưu mã truy cập") {
                        if TMDBCredential.save(token) {
                            status = token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "Đã xóa mã truy cập." : "Đã lưu mã truy cập."
                        } else {
                            status = "Không thể ghi vào Keychain."
                        }
                    }
                    if let status { Text(status).font(.footnote).foregroundStyle(CinemaStyle.muted) }
                    Link("Lấy mã truy cập TMDB", destination: URL(string: "https://www.themoviedb.org/settings/api")!)
                } header: {
                    Text("Thông tin phim trực tuyến")
                } footer: {
                    Text("Dùng TMDB để tìm poster, nội dung và điểm đánh giá. Mã truy cập được lưu trong Keychain trên máy.")
                }
                Section("Giới thiệu") {
                    Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                        .font(.footnote)
                    Link("The Movie Database", destination: URL(string: "https://www.themoviedb.org")!)
                    Link("MPVKit và thông tin giấy phép",
                         destination: URL(string: "https://github.com/mpvkit/MPVKit/tree/1.0.0")!)
                }
            }
            .scrollContentBackground(.hidden)
            .background(CinemaStyle.background)
            .navigationTitle("Cài đặt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Xong") { dismiss() } }
            }
            .onAppear { token = TMDBCredential.read() ?? "" }
        }
    }
}

struct MovieDetails: View {
    @Environment(\.dismiss) private var dismiss
    let item: MediaItem
    @ObservedObject var library: MediaLibrary
    let play: () -> Void
    @State private var showingSearch = false

    private var current: MediaItem { library.item(item.id) ?? item }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    CinemaArtwork(url: current.metadata?.backdropURL ?? current.metadata?.posterURL,
                                  fallback: .coast)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                    VStack(alignment: .leading, spacing: 7) {
                        Text(current.displayTitle).font(.largeTitle.bold())
                        Text(descriptor).font(.subheadline).foregroundStyle(CinemaStyle.muted)
                    }
                    HStack(spacing: 10) {
                        Button(action: play) {
                            Label(current.progress > 0 && current.progress < 0.98 ? "Xem tiếp" : "Phát phim",
                                  systemImage: "play.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 46)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(CinemaStyle.accent)
                        .foregroundStyle(CinemaStyle.background)

                        Button { library.toggleFavorite(current.id) } label: {
                            Image(systemName: current.favorite ? "heart.fill" : "heart")
                                .font(.title3)
                                .frame(width: 46, height: 46)
                                .background(CinemaStyle.panel, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(CinemaStyle.accent)
                        .accessibilityLabel(current.favorite ? "Bỏ yêu thích" : "Thêm vào yêu thích")
                    }
                    if let metadata = current.metadata {
                        if let rating = metadata.rating {
                            Label(rating.formatted(.number.precision(.fractionLength(1))) + " / 10",
                                  systemImage: "star.fill")
                                .foregroundStyle(.yellow)
                        }
                        if !metadata.overview.isEmpty {
                            Text(metadata.overview).foregroundStyle(CinemaStyle.muted)
                        }
                    }
                    Button {
                        showingSearch = true
                    } label: {
                        Label(current.metadata == nil ? "Tìm thông tin phim" : "Đổi thông tin phim",
                              systemImage: "magnifyingglass")
                    }
                    if current.metadata != nil {
                        Button("Gỡ thông tin phim", role: .destructive) {
                            library.setMetadata(current.id, value: nil)
                        }
                        .font(.footnote)
                    }
                }
                .frame(maxWidth: 600, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .background(CinemaStyle.background.ignoresSafeArea())
            .navigationTitle("Chi tiết")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Đóng") { dismiss() } }
            }
            .sheet(isPresented: $showingSearch) {
                MetadataSearch(query: current.displayTitle) { value in
                    library.setMetadata(current.id, value: value)
                }
            }
        }
    }

    private var descriptor: String {
        [current.metadata?.kindLabel, current.metadata?.year, current.source.format, current.source.label]
            .compactMap { $0 }
            .joined(separator: "  ·  ")
    }
}

private struct MetadataSearch: View {
    @Environment(\.dismiss) private var dismiss
    @State var query: String
    let select: (MovieMetadata) -> Void
    @State private var results: [MovieMetadata] = []
    @State private var searchTerm: String?
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
                        select(result)
                        dismiss()
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
            .task(id: searchTerm) {
                if let searchTerm { await fetch(searchTerm) }
            }
        }
    }

    private func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        if term == searchTerm {
            Task { await fetch(term) }
        } else {
            searchTerm = term
        }
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
}
