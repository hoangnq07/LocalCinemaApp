import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var library: MediaLibrary
    @Binding var serverURL: String

    @AppStorage("appTheme") private var appTheme = AppTheme.obsidian
    @AppStorage("videoUpscaler") private var upscaler = VideoUpscaler.lanczos
    @AppStorage("hdrDisplayMode") private var hdrMode = HDRDisplayMode.autoEDR
    @AppStorage("sdrToHDRMode") private var sdrToHDR = SDRtoHDRMode.off
    @AppStorage("motionInterpolation") private var interpolation = MotionInterpolation.off
    @AppStorage("interpolationFPS") private var interpolationFPS = InterpolationFPS.auto
    @AppStorage("debandEnabled") private var deband = false
    @AppStorage("audioOutput") private var audioOutput = AudioOutput.automatic
    @AppStorage("hwdecEnabled") private var hwdecEnabled = true
    @AppStorage("backgroundAudio") private var backgroundAudio = true
    @AppStorage("doubleTapSkip") private var doubleTapSkip = 10

    @State private var tmdbToken = ""
    @State private var openSubKey = ""
    @State private var traktClientID = ""
    @State private var traktSecret = ""
    @State private var traktCode: TraktDeviceCode?
    @State private var traktConnected = false

    @State private var cacheSizeText = "0 MB"
    @State private var statusMessage: String?
    @State private var exportingBackup = false
    @State private var importingBackup = false
    @State private var backupDocument = JSONBackupDocument(data: Data())

    var body: some View {
        NavigationStack {
            Form {
                Section("Giao diện") {
                    Picker("Chủ đề", selection: $appTheme) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }
                }

                Section("Trình phát") {
                    Picker("AI Upscale", selection: $upscaler) {
                        ForEach(VideoUpscaler.allCases) { option in
                            Text(option.shortLabel).tag(option)
                        }
                    }
                    Picker("HDR gốc", selection: $hdrMode) {
                        ForEach(HDRDisplayMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    Picker("SDR → HDR", selection: $sdrToHDR) {
                        ForEach(SDRtoHDRMode.allCases) { mode in
                            Text(mode.shortLabel).tag(mode)
                        }
                    }
                    Picker("Nội suy FPS", selection: $interpolation) {
                        ForEach(MotionInterpolation.allCases) { mode in
                            Text(mode.shortLabel).tag(mode)
                        }
                    }
                    if interpolation != .off {
                        Picker("Tần số quét", selection: $interpolationFPS) {
                            ForEach(InterpolationFPS.allCases) { fps in
                                Text(fps.label).tag(fps)
                            }
                        }
                    }
                    Toggle("Deband màu", isOn: $deband)
                    Toggle("VideoToolbox", isOn: $hwdecEnabled)
                    Toggle("Phát nền", isOn: $backgroundAudio)
                    Picker("Tua nhanh", selection: $doubleTapSkip) {
                        Text("10s").tag(10)
                        Text("15s").tag(15)
                        Text("30s").tag(30)
                    }
                    Picker("Âm thanh", selection: $audioOutput) {
                        ForEach(AudioOutput.allCases) { out in
                            Text(out.label).tag(out)
                        }
                    }
                }

                Section("Máy chủ LAN") {
                    TextField("http://192.168.1.1:8080", text: $serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("TMDB") {
                    SecureField("TMDB Read Access Token", text: $tmdbToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Lưu mã TMDB") {
                        let ok = TMDBCredential.save(tmdbToken)
                        statusMessage = ok ? "Đã cập nhật TMDB Token vào Keychain." : "Không thể ghi vào Keychain."
                    }
                    Link("Lấy mã TMDB", destination: URL(string: "https://www.themoviedb.org/settings/api")!)
                }

                Section("OpenSubtitles & Trakt.tv") {
                    SecureField("OpenSubtitles API Key", text: $openSubKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Lưu API Key OpenSubtitles") {
                        let ok = OpenSubtitlesCredential.save(openSubKey)
                        statusMessage = ok ? "Đã lưu API Key OpenSubtitles." : "Lỗi Keychain."
                    }

                    if traktConnected {
                        HStack {
                            Label("Trakt.tv đã kết nối", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(CinemaStyle.accent)
                            Spacer()
                            Button("Ngắt kết nối", role: .destructive) {
                                TraktCredential.disconnect()
                                traktConnected = false
                            }
                        }
                    } else {
                        TextField("Trakt Client ID", text: $traktClientID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Trakt Client Secret", text: $traktSecret)
                            .textInputAutocapitalization(.never)
                        Button("Lấy mã ghép nối Trakt.tv") {
                            Task { await startTraktPairing() }
                        }
                        .disabled(traktClientID.isEmpty || traktSecret.isEmpty)

                        if let code = traktCode {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Mở \(code.verificationURL) và nhập mã: \(code.userCode)")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(CinemaStyle.gold)
                                Button("Xác nhận đã nhập mã") {
                                    Task { await completeTraktPairing(code: code) }
                                }
                            }
                        }
                    }
                }

                Section("Sao lưu JSON") {
                    Button("Xuất sao lưu thư viện") {
                        do {
                            let data = try library.exportBackupJSON()
                            backupDocument = JSONBackupDocument(data: data)
                            exportingBackup = true
                        } catch {
                            statusMessage = error.localizedDescription
                        }
                    }
                    Button("Khôi phục từ tệp JSON") {
                        importingBackup = true
                    }
                }

                Section("Bộ nhớ & Giấy phép") {
                    HStack {
                        Text("Cache ảnh")
                        Spacer()
                        Text(cacheSizeText).foregroundStyle(CinemaStyle.muted)
                    }
                    Button("Xóa cache ảnh", role: .destructive) {
                        Task {
                            await CinemaImageCache.shared.clear()
                            await refreshCacheSize()
                            statusMessage = "Đã xóa bộ nhớ đệm ảnh."
                        }
                    }
                    Link("MPVKit và thông tin giấy phép",
                         destination: URL(string: "https://github.com/mpvkit/MPVKit/tree/1.0.0")!)
                    Link("FSRCNNX và thông tin giấy phép",
                         destination: URL(string: "https://github.com/igv/FSRCNN-TensorFlow/releases/tag/1.1")!)
                    Link("CAS Adaptive Sharpen (MIT)",
                         destination: URL(string: "https://github.com/hoangnq07/LocalCinemaApp")!)
                    Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                        .font(.footnote)
                        .foregroundStyle(CinemaStyle.muted)
                }
            }
            .scrollContentBackground(.hidden)
            .background(CinemaStyle.background)
            .navigationTitle("Cài đặt")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                tmdbToken = TMDBCredential.read() ?? ""
                openSubKey = OpenSubtitlesCredential.read() ?? ""
                traktClientID = TraktCredential.clientID ?? ""
                traktSecret = TraktCredential.clientSecret ?? ""
                traktConnected = (TraktCredential.accessToken?.isEmpty == false)
                Task { await refreshCacheSize() }
            }
            .fileExporter(
                isPresented: $exportingBackup,
                document: backupDocument,
                contentType: .json,
                defaultFilename: "LocalCinema-Backup"
            ) { result in
                if case .success = result {
                    statusMessage = "Đã xuất tệp sao lưu JSON thành công."
                }
            }
            .fileImporter(
                isPresented: $importingBackup,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let first = urls.first else { return }
                let scoped = first.startAccessingSecurityScopedResource()
                defer { if scoped { first.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: first)
                    let count = try library.importBackupJSON(data)
                    statusMessage = "Đã khôi phục \(count) mục vào thư viện."
                } catch {
                    statusMessage = error.localizedDescription
                }
            }
            .alert("Thông báo", isPresented: Binding(
                get: { statusMessage != nil },
                set: { if !$0 { statusMessage = nil } }
            )) {
                Button("Đóng", role: .cancel) {}
            } message: {
                Text(statusMessage ?? "")
            }
        }
    }

    private func refreshCacheSize() async {
        let bytes = await CinemaImageCache.shared.cacheSizeBytes()
        cacheSizeText = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func startTraktPairing() async {
        TraktCredential.saveClient(id: traktClientID, secret: traktSecret)
        do {
            traktCode = try await TraktService.requestDeviceCode(clientID: traktClientID)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func completeTraktPairing(code: TraktDeviceCode) async {
        do {
            if let token = try await TraktService.pollDeviceToken(
                code: code.deviceCode,
                clientID: traktClientID,
                clientSecret: traktSecret
            ), !token.isEmpty {
                traktConnected = true
                traktCode = nil
                statusMessage = "Đã kết nối Trakt.tv thành công."
            } else {
                statusMessage = "Bạn chưa hoàn tất nhập mã trên trang Trakt.tv."
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

struct JSONBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
