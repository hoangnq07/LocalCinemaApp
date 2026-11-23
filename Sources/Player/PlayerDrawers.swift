import SwiftUI
import UniformTypeIdentifiers

enum PlayerDrawerTab: String, Identifiable {
    case video, subtitles, audio, chapters
    var id: Self { self }

    var title: String {
        switch self {
        case .video: return "Hình ảnh & AI"
        case .subtitles: return "Phụ đề"
        case .audio: return "Âm thanh"
        case .chapters: return "Tiện ích"
        }
    }
}

struct PlayerDrawerContainer: View {
    let tab: PlayerDrawerTab
    let item: MediaItem
    let status: PlaybackStatus
    @ObservedObject var player: MPVPlayback

    @Binding var upscaler: VideoUpscaler
    @Binding var hdrMode: HDRDisplayMode
    @Binding var sdrToHDR: SDRtoHDRMode
    @Binding var interpolation: MotionInterpolation
    @Binding var interpolationFPS: InterpolationFPS
    @Binding var deband: Bool
    @Binding var aspectMode: AspectMode
    @Binding var zoom: Double
    @Binding var colorPreset: ColorPreset
    @Binding var brightness: Double
    @Binding var contrast: Double
    @Binding var saturation: Double
    @Binding var gamma: Double
    @Binding var sharpen: Double

    @Binding var primarySubID: Int?
    @Binding var secondarySubID: Int?
    @Binding var subtitleScale: Double
    @Binding var subtitlePos: Int
    @Binding var subtitleColor: SubtitleColorOption
    @Binding var subtitleBorder: Double
    @Binding var subtitleBgOpacity: Double
    @Binding var subtitleOffset: Double

    @Binding var audioOutput: AudioOutput
    @Binding var volumeBoost: Double
    @Binding var audioDelay: Double
    @Binding var nightMode: Bool

    @Binding var speed: Double
    @Binding var sleepTimer: SleepTimerOption
    @Binding var abLoopA: Double?
    @Binding var abLoopB: Double?

    let onSnapshot: () -> Void
    let onClose: () -> Void

    @State private var subTabMode = 0 // 0: tracks & style, 1: OpenSubtitles
    @State private var pickingSubtitle = false
    @State private var subQuery = ""
    @State private var subResults: [OpenSubtitleItem] = []
    @State private var subLoading = false
    @State private var subMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(tab.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(CinemaStyle.text)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(CinemaStyle.text)
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.14), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Đóng ngăn kéo")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) {
                Rectangle().fill(CinemaStyle.border).frame(height: 1)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch tab {
                    case .video: videoDrawer
                    case .subtitles: subtitlesDrawer
                    case .audio: audioDrawer
                    case .chapters: chaptersDrawer
                    }
                }
                .padding(14)
            }
        }
        .background(CinemaStyle.elevated.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(CinemaStyle.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.55), radius: 24, y: 12)
        .fileImporter(
            isPresented: $pickingSubtitle,
            allowedContentTypes: [UTType.text, UTType.data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let first = urls.first {
                player.addExternalSubtitle(first)
            }
        }
    }

    // MARK: - Video & AI Drawer

    private var videoDrawer: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let notice = status.thermalNotice {
                HStack(spacing: 8) {
                    Image(systemName: "thermometer.sun.fill")
                        .foregroundStyle(CinemaStyle.gold)
                    Text(notice)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(CinemaStyle.gold)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CinemaStyle.gold.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(CinemaStyle.gold.opacity(0.35), lineWidth: 1)
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("AI Upscale")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(VideoUpscaler.allCases) { option in
                        chipButton(option.shortLabel, selected: upscaler == option) {
                            upscaler = option
                            player.setUpscaler(option)
                        }
                        .accessibilityIdentifier("upscaler-\(option.rawValue)")
                    }
                }
                if upscaler.usesNeuralShader {
                    Text(status.neuralUpscalingActive
                         ? "FSRCNNX ×2 đang chạy"
                         : "Tự bật khi upscale ≥1.3×.")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(status.neuralUpscalingActive ? CinemaStyle.accent : CinemaStyle.muted)
                }
            }

            Divider().overlay(CinemaStyle.border)

            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("SDR → HDR")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(SDRtoHDRMode.allCases) { mode in
                        chipButton(mode.shortLabel, selected: sdrToHDR == mode, highlightGold: mode != .off) {
                            sdrToHDR = mode
                            player.setSDRtoHDR(mode)
                        }
                        .accessibilityIdentifier("sdr-to-hdr-\(mode.rawValue)")
                    }
                }
                if sdrToHDR != .off {
                    Text(status.sdrToHDRBypassedForNativeHDR
                         ? "HDR gốc · giữ nguyên EDR"
                         : "SDR → HDR · \(sdrToHDR.targetPeakNits) nit")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(CinemaStyle.gold)
                }
            }

            Divider().overlay(CinemaStyle.border)

            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Nội suy FPS")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(MotionInterpolation.allCases) { mode in
                        chipButton(mode.shortLabel, selected: interpolation == mode) {
                            interpolation = mode
                            player.setInterpolation(mode, fps: interpolationFPS)
                        }
                        .accessibilityIdentifier("interp-\(mode.rawValue)")
                    }
                }
                if interpolation != .off {
                    Text(status.interpolationActive ? "Nội suy · \(interpolation.shortLabel)" : "Đang khởi tạo nội suy…")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(CinemaStyle.accent)
                    HStack(spacing: 6) {
                        Text("Tần số:")
                            .font(.caption2)
                            .foregroundStyle(CinemaStyle.muted)
                        ForEach(InterpolationFPS.allCases) { fps in
                            chipButton(fps.label, selected: interpolationFPS == fps) {
                                interpolationFPS = fps
                                player.setInterpolation(interpolation, fps: fps)
                            }
                        }
                    }
                }

                sectionHeader("HDR gốc")
                    .padding(.top, 4)
                ForEach(HDRDisplayMode.allCases) { mode in
                    optionRow(title: mode.label, selected: hdrMode == mode) {
                        hdrMode = mode
                        player.setHDRDisplayMode(mode)
                    }
                }
            }

            Divider().overlay(CinemaStyle.border)

            Toggle("Deband màu", isOn: $deband)
                .font(.caption.weight(.semibold))
                .tint(CinemaStyle.accent)
                .onChange(of: deband) { value in
                    player.setDeband(value)
                }

            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Khung hình")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: 6)], spacing: 6) {
                    ForEach(AspectMode.allCases) { mode in
                        chipButton(mode.label, selected: aspectMode == mode) {
                            aspectMode = mode
                            player.setAspectMode(mode)
                        }
                    }
                }
                sliderRow("Thu phóng (\(Int(zoom * 100))%)", value: $zoom, range: -0.3...0.8, step: 0.05) {
                    player.setZoom($0)
                }
            }

            Divider().overlay(CinemaStyle.border)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    sectionHeader("Màu sắc")
                    Spacer()
                    Button("Đặt lại") {
                        applyColorPreset(.original)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(CinemaStyle.accent)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 66), spacing: 6)], spacing: 6) {
                    ForEach(ColorPreset.allCases) { preset in
                        chipButton(preset.label, selected: colorPreset == preset) {
                            applyColorPreset(preset)
                        }
                    }
                }
                sliderRow("Độ sáng (\(Int(brightness)))", value: $brightness, range: -30...30, step: 1) { _ in pushColors() }
                sliderRow("Tương phản (\(Int(contrast)))", value: $contrast, range: -30...30, step: 1) { _ in pushColors() }
                sliderRow("Bão hòa (\(Int(saturation)))", value: $saturation, range: -30...40, step: 1) { _ in pushColors() }
                sliderRow("Gamma (\(Int(gamma)))", value: $gamma, range: -20...20, step: 1) { _ in pushColors() }
                sliderRow("Độ nét (\(String(format: "%.1f", sharpen)))", value: $sharpen, range: 0...1.5, step: 0.1) { _ in pushColors() }
            }
        }
    }

    // MARK: - Subtitles Drawer

    private var subtitlesDrawer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Chế độ phụ đề", selection: $subTabMode) {
                Text("Track & Kiểu chữ").tag(0)
                Text("Tìm Online").tag(1)
            }
            .pickerStyle(.segmented)

            if subTabMode == 0 {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        sectionHeader("Phụ đề chính (Dưới)")
                        Spacer()
                        Button {
                            pickingSubtitle = true
                        } label: {
                            Label("Mở .SRT/.ASS", systemImage: "folder.badge.plus")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(CinemaStyle.accent)
                        }
                        .buttonStyle(.plain)
                    }

                    let anySelected = status.subtitles.contains(where: \.selected)
                    optionRow(title: "Tắt phụ đề chính", selected: !anySelected && primarySubID == nil) {
                        primarySubID = nil
                        player.selectSubtitle(nil)
                    }
                    ForEach(status.subtitles) { track in
                        optionRow(title: track.label, selected: track.selected) {
                            primarySubID = track.id
                            player.selectSubtitle(track.id)
                        }
                    }

                    if status.subtitles.count >= 2 {
                        sectionHeader("Phụ đề phụ (Dual Sub · Trên)")
                            .padding(.top, 4)
                        optionRow(title: "Tắt phụ đề phụ", selected: secondarySubID == nil) {
                            secondarySubID = nil
                            player.selectSecondarySubtitle(nil)
                        }
                        ForEach(status.subtitles) { track in
                            optionRow(title: track.label, selected: secondarySubID == track.id) {
                                secondarySubID = track.id
                                player.selectSecondarySubtitle(track.id)
                            }
                        }
                    }
                }

                Divider().overlay(CinemaStyle.border)

                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader("Giao diện & Đồng bộ")
                    sliderRow("Cỡ chữ (\(Int(subtitleScale * 100))%)", value: $subtitleScale, range: 0.6...1.8, step: 0.05) { _ in
                        pushSubStyle()
                    }
                    sliderRow("Vị trí dọc (\(subtitlePos)%)", value: Binding(
                        get: { Double(subtitlePos) },
                        set: { subtitlePos = Int($0) }
                    ), range: 50...100, step: 1) { _ in
                        pushSubStyle()
                    }
                    sliderRow("Độ dày viền (\(String(format: "%.1f", subtitleBorder)))", value: $subtitleBorder, range: 0...4, step: 0.5) { _ in
                        pushSubStyle()
                    }
                    sliderRow("Nền hộp (\(Int(subtitleBgOpacity * 100))%)", value: $subtitleBgOpacity, range: 0...0.9, step: 0.1) { _ in
                        pushSubStyle()
                    }

                    HStack(spacing: 6) {
                        Text("Màu chữ:")
                            .font(.caption2)
                            .foregroundStyle(CinemaStyle.muted)
                        ForEach(SubtitleColorOption.allCases) { option in
                            chipButton(option.label, selected: subtitleColor == option) {
                                subtitleColor = option
                                pushSubStyle()
                            }
                        }
                    }

                    HStack {
                        Text("Độ trễ: \(String(format: "%.2f", subtitleOffset))s")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                        Spacer()
                        Button("-0.25s") { shiftSub(-0.25) }.buttonStyle(.bordered)
                        Button("0") { shiftSub(-subtitleOffset) }.buttonStyle(.bordered)
                        Button("+0.25s") { shiftSub(0.25) }.buttonStyle(.bordered)
                    }
                    .font(.caption2)
                }
            } else {
                openSubtitlesSearchPanel
            }
        }
    }

    private var openSubtitlesSearchPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Tên phim (tiếng Anh / Việt)", text: $subQuery)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                Button("Tìm") {
                    Task { await searchOnlineSubtitles() }
                }
                .buttonStyle(.borderedProminent)
                .tint(CinemaStyle.accent)
                .foregroundStyle(CinemaStyle.ctaForeground)
                .font(.caption.weight(.bold))
            }
            if subLoading {
                ProgressView("Đang tìm trên OpenSubtitles…").font(.caption)
            }
            if let subMessage {
                Text(subMessage).font(.caption2).foregroundStyle(CinemaStyle.muted)
            }
            ForEach(subResults) { sub in
                VStack(alignment: .leading, spacing: 6) {
                    Text(sub.releaseName).font(.caption.weight(.semibold)).lineLimit(2)
                    HStack {
                        Text("\(sub.language.uppercased()) · ↓ \(sub.downloadCount)")
                            .font(.caption2)
                            .foregroundStyle(CinemaStyle.muted)
                        Spacer()
                        Button("Tải & Áp dụng") {
                            Task { await downloadOnlineSubtitle(sub) }
                        }
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(CinemaStyle.accent, in: Capsule())
                        .foregroundStyle(CinemaStyle.ctaForeground)
                    }
                }
                .padding(10)
                .obsidianGlass(cornerRadius: 12)
            }
        }
        .onAppear {
            if subQuery.isEmpty { subQuery = item.metadataQuery }
        }
    }

    // MARK: - Audio Drawer

    private var audioDrawer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if status.outputChannels > 0 {
                Text("Đầu ra PCM hiện tại · \(MPVPlayback.channelsLabel(status.outputChannels))")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(CinemaStyle.accent)
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Track âm thanh")
                if status.audio.isEmpty {
                    Text("Không có thông tin track bổ sung.").font(.caption2).foregroundStyle(CinemaStyle.muted)
                } else {
                    ForEach(status.audio) { track in
                        optionRow(title: track.label, selected: track.selected) {
                            player.selectAudio(track.id)
                        }
                    }
                }
            }

            Divider().overlay(CinemaStyle.border)

            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Cấu hình kênh đầu ra")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(AudioOutput.allCases) { output in
                        chipButton(output.shortLabel, selected: audioOutput == output) {
                            audioOutput = output
                            player.setOutput(output)
                        }
                    }
                }
            }

            sliderRow("Khuếch đại âm lượng (\(Int(volumeBoost))%)", value: $volumeBoost, range: 50...200, step: 10) {
                player.setVolume($0)
            }

            HStack {
                Text("Độ trễ âm: \(String(format: "%.2f", audioDelay))s")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                Spacer()
                Button("-0.1s") { shiftAudio(-0.1) }.buttonStyle(.bordered)
                Button("0") { shiftAudio(-audioDelay) }.buttonStyle(.bordered)
                Button("+0.1s") { shiftAudio(0.1) }.buttonStyle(.bordered)
            }
            .font(.caption2)

            Toggle("Chế độ ban đêm (Rõ lời thoại)", isOn: $nightMode)
                .font(.caption.weight(.semibold))
                .tint(CinemaStyle.accent)
                .onChange(of: nightMode) { value in
                    player.setNightMode(value)
                }
        }
    }

    // MARK: - Chapters & Tools Drawer

    private var chaptersDrawer: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Tốc độ phát")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 54), spacing: 6)], spacing: 6) {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0], id: \.self) { value in
                        chipButton(value.formatted() + "×", selected: abs(speed - value) < 0.01) {
                            speed = value
                            player.setSpeed(value)
                        }
                    }
                }
            }

            Divider().overlay(CinemaStyle.border)

            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Hẹn giờ tắt")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 6)], spacing: 6) {
                    ForEach(SleepTimerOption.allCases) { option in
                        chipButton(option.label, selected: sleepTimer == option) {
                            sleepTimer = option
                        }
                    }
                }
            }

            Divider().overlay(CinemaStyle.border)

            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Công cụ & Lặp A–B")
                HStack(spacing: 8) {
                    Button(abLoopA == nil ? "Đặt điểm A" : "A: \(formatShort(abLoopA!))") {
                        abLoopA = status.time
                        player.setABLoop(a: abLoopA, b: abLoopB)
                    }
                    .buttonStyle(.bordered)
                    Button(abLoopB == nil ? "Đặt điểm B" : "B: \(formatShort(abLoopB!))") {
                        abLoopB = status.time
                        player.setABLoop(a: abLoopA, b: abLoopB)
                    }
                    .buttonStyle(.bordered)
                    if abLoopA != nil || abLoopB != nil {
                        Button("Xóa") {
                            abLoopA = nil
                            abLoopB = nil
                            player.setABLoop(a: nil, b: nil)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .font(.caption2)

                HStack(spacing: 8) {
                    Button { player.frameStep(forward: false) } label: {
                        Label("-1 khung", systemImage: "backward.frame")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button { player.frameStep(forward: true) } label: {
                        Label("+1 khung", systemImage: "forward.frame")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button(action: onSnapshot) {
                        Label("Chụp hình", systemImage: "camera")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(CinemaStyle.accent)
                    .foregroundStyle(CinemaStyle.ctaForeground)
                }
                .font(.caption2.weight(.semibold))
            }

            if !status.chapters.isEmpty {
                Divider().overlay(CinemaStyle.border)
                VStack(alignment: .leading, spacing: 6) {
                    sectionHeader("Chương phim (\(status.chapters.count))")
                    ForEach(status.chapters) { chapter in
                        Button {
                            player.seek(to: chapter.time)
                        } label: {
                            HStack {
                                Text(chapter.title).font(.caption).lineLimit(1)
                                Spacer()
                                Text(formatShort(chapter.time))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(CinemaStyle.muted)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .obsidianGlass(cornerRadius: 10)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func applyColorPreset(_ preset: ColorPreset) {
        colorPreset = preset
        brightness = preset.brightness
        contrast = preset.contrast
        saturation = preset.saturation
        gamma = preset.gamma
        if preset == .original { sharpen = 0 }
        pushColors()
    }

    private func pushColors() {
        player.setColorAdjustments(brightness: brightness, contrast: contrast, saturation: saturation, gamma: gamma, sharpen: sharpen)
    }

    private func pushSubStyle() {
        player.setSubtitleStyle(scale: subtitleScale, pos: subtitlePos, color: subtitleColor, borderSize: subtitleBorder, backgroundOpacity: subtitleBgOpacity)
    }

    private func shiftSub(_ delta: Double) {
        subtitleOffset += delta
        player.setSubtitleOffset(subtitleOffset)
    }

    private func shiftAudio(_ delta: Double) {
        audioDelay += delta
        player.setAudioDelay(audioDelay)
    }

    private func searchOnlineSubtitles() async {
        guard let apiKey = OpenSubtitlesCredential.read(), !apiKey.isEmpty else {
            subMessage = "Nhập API Key OpenSubtitles trong Cài đặt để tìm phụ đề trực tuyến."
            return
        }
        subLoading = true
        subMessage = nil
        defer { subLoading = false }
        do {
            let found = try await OpenSubtitlesService.search(
                query: subQuery,
                tmdbID: item.metadata?.id,
                apiKey: apiKey
            )
            subResults = found
            if found.isEmpty { subMessage = "Không tìm thấy phụ đề phù hợp." }
        } catch {
            subMessage = error.localizedDescription
        }
    }

    private func downloadOnlineSubtitle(_ sub: OpenSubtitleItem) async {
        guard let apiKey = OpenSubtitlesCredential.read(), !apiKey.isEmpty else { return }
        subLoading = true
        defer { subLoading = false }
        do {
            let url = try await OpenSubtitlesService.download(fileID: sub.fileID, apiKey: apiKey)
            player.addExternalSubtitle(url)
            subTabMode = 0
        } catch {
            subMessage = error.localizedDescription
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .textCase(.uppercase)
            .foregroundStyle(CinemaStyle.muted)
    }

    private func optionRow(title: String, selected: Bool, badge: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption.weight(selected ? .bold : .medium))
                    .foregroundStyle(selected ? CinemaStyle.accent : CinemaStyle.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let badge {
                    TechBadge(text: badge, tone: .accent)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(CinemaStyle.accent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                selected ? CinemaStyle.accent.opacity(0.14) : Color.white.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private func chipButton(_ title: String, selected: Bool, highlightGold: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption2.weight(.bold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .padding(.horizontal, 6)
                .background(
                    selected ? (highlightGold ? CinemaStyle.gold : CinemaStyle.accent) : Color.white.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .foregroundStyle(selected ? CinemaStyle.ctaForeground : CinemaStyle.text)
        }
        .buttonStyle(.plain)
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, onChange: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(CinemaStyle.muted)
            Slider(value: value, in: range, step: step)
                .tint(CinemaStyle.accent)
                .onChange(of: value.wrappedValue) { newVal in
                    onChange(newVal)
                }
        }
    }

    private func formatShort(_ sec: Double) -> String {
        let s = Int(max(0, sec))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
