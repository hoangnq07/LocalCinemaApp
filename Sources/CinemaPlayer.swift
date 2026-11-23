import SwiftUI

struct CinemaPlayer: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("videoScaling") private var scaling = VideoScaling.standard
    @AppStorage("audioOutput") private var audioOutput = AudioOutput.automatic
    @StateObject private var player = MPVPlayback()
    @State private var controls = true
    @State private var scrubTime: Double?
    @State private var speed: Double = 1
    @State private var subtitleOffset = 0.0
    @State private var lastSaved = 0.0
    @State private var closing = false

    let item: MediaItem
    let url: URL
    let save: (Double, Double) -> Void

    private var status: PlaybackStatus { player.status }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MPVSurface { layer in
                guard !closing else { return }
                player.open(url, surface: layer, start: item.progress < 0.98 ? item.position : 0,
                            scaler: scaling, audio: audioOutput)
            }
            .ignoresSafeArea()
            .onTapGesture {
                if status.error == nil, status.ready {
                    withAnimation(.easeInOut(duration: 0.2)) { controls.toggle() }
                }
            }
            .accessibilityHidden(true)

            if controls || status.error != nil || !status.ready {
                VStack {
                    topBar
                    Spacer(minLength: 0)
                    centerControls
                    Spacer(minLength: 0)
                    bottomBar
                }
                .padding(.horizontal, 19)
                .padding(.vertical, 8)
            }
        }
        .statusBarHidden(!controls)
        .onChange(of: status.time) { position in
            if abs(position - lastSaved) >= 15 { persist() }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                player.pause()
                persist()
            }
        }
        .onDisappear {
            closing = true
            persist()
            player.close()
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            iconButton("Đóng trình phát", icon: "xmark", size: 42, action: { dismiss() })
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle).font(.headline).lineLimit(1)
                if let size = status.videoSize {
                    Text(size).font(.caption).foregroundStyle(CinemaStyle.muted)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
            Spacer()
        }
    }

    @ViewBuilder
    private var centerControls: some View {
        if let error = status.error {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.title2)
                Text(error).font(.subheadline)
                Button("Đóng") { dismiss() }.buttonStyle(.bordered)
            }
            .multilineTextAlignment(.center)
            .padding(20)
            .background(.black.opacity(0.80), in: RoundedRectangle(cornerRadius: 16))
        } else if !status.ready || status.buffering {
            VStack(spacing: 11) {
                ProgressView().tint(.white)
                Text(status.ready ? "Đang tải video…" : "Đang mở video…").font(.footnote)
            }
            .padding(18)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
        } else {
            HStack(spacing: 23) {
                iconButton("Lùi 10 giây", icon: "gobackward.10", size: 48) { player.seek(by: -10) }
                iconButton(status.paused ? "Phát" : "Tạm dừng", icon: status.paused ? "play.fill" : "pause.fill",
                           size: 62, action: { player.togglePause() })
                iconButton("Tiến 10 giây", icon: "goforward.10", size: 48) { player.seek(by: 10) }
            }
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if status.ready, status.error == nil {
            VStack(spacing: 7) {
                if status.duration > 0 {
                    Slider(value: Binding(
                        get: { min(scrubTime ?? status.time, status.duration) },
                        set: { scrubTime = $0 }
                    ), in: 0...status.duration, onEditingChanged: { editing in
                        if !editing, let scrubTime {
                            player.seek(to: scrubTime)
                            self.scrubTime = nil
                        }
                    })
                    .tint(CinemaStyle.accent)
                    .accessibilityLabel("Tiến độ video")
                }
                HStack(spacing: 12) {
                    Text(timeLabel)
                        .monospacedDigit().font(.caption.weight(.semibold))
                    Spacer()
                    audioMenu
                    subtitleMenu
                    settingsMenu
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(.black.opacity(0.73), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var audioMenu: some View {
        Menu {
            if status.outputChannels > 0 {
                Text("Đầu ra PCM · \(MPVPlayback.channelsLabel(status.outputChannels))")
            }
            Picker("Đầu ra", selection: $audioOutput) {
                ForEach(AudioOutput.allCases) { output in Text(output.label).tag(output) }
            }
            if !status.audio.isEmpty {
                Section("Track âm thanh") {
                    ForEach(status.audio) { track in
                        checkButton(track.label, selected: track.selected) { player.selectAudio(track.id) }
                    }
                }
            }
        } label: {
            menuIcon("speaker.wave.2")
        }
        .accessibilityLabel("Âm thanh")
        .onChange(of: audioOutput) { player.setOutput($0) }
    }

    private var subtitleMenu: some View {
        Menu {
            checkButton("Tắt phụ đề", selected: !status.subtitles.contains(where: \.selected)) {
                player.selectSubtitle(nil)
            }
            ForEach(status.subtitles) { track in
                checkButton(track.label, selected: track.selected) { player.selectSubtitle(track.id) }
            }
            if !status.subtitles.isEmpty {
                Menu("Đồng bộ phụ đề") {
                    Text("\(subtitleOffset.formatted(.number.precision(.fractionLength(2)))) giây")
                    Button("Hiện sớm 0,25 giây") { shiftSubtitles(-0.25) }
                    Button("Hiện muộn 0,25 giây") { shiftSubtitles(0.25) }
                    Button("Đặt lại") { shiftSubtitles(-subtitleOffset) }
                }
            }
        } label: {
            menuIcon("captions.bubble")
        }
        .accessibilityLabel("Phụ đề")
    }

    private var settingsMenu: some View {
        Menu {
            Picker("Nâng độ phân giải khi hiển thị", selection: $scaling) {
                ForEach(VideoScaling.allCases) { option in Text(option.label).tag(option) }
            }
            Picker("Tốc độ phát", selection: $speed) {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                    Text(value.formatted() + "×").tag(value)
                }
            }
        } label: {
            menuIcon("slider.horizontal.3")
        }
        .accessibilityLabel("Tùy chọn phát")
        .onChange(of: scaling) { player.setScaling($0) }
        .onChange(of: speed) { player.setSpeed($0) }
    }

    private var timeLabel: String {
        let current = formattedTime(scrubTime ?? status.time)
        return status.duration > 0 ? "\(current) / \(formattedTime(status.duration))" : current
    }

    private func formattedTime(_ value: Double) -> String {
        let seconds = Int(max(0, min(value, 359_999)))
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func iconButton(_ title: String, icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.41, weight: .semibold))
                .frame(width: size, height: size)
                .background(.black.opacity(0.66), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func menuIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 18, weight: .semibold))
            .frame(minWidth: 40, minHeight: 42)
            .foregroundStyle(.white)
    }

    private func checkButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    private func persist() {
        guard status.ready, status.duration > 0 else { return }
        save(status.time, status.duration)
        lastSaved = status.time
    }

    private func shiftSubtitles(_ delta: Double) {
        subtitleOffset += delta
        player.setSubtitleOffset(subtitleOffset)
    }
}
