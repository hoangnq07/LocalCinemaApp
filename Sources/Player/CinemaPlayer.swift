import SwiftUI
import UIKit

struct CinemaPlayer: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

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

    @StateObject private var player = MPVPlayback()

    @State private var controls = true
    @State private var locked = false
    @State private var scrubTime: Double?
    @State private var showRemaining = false
    @State private var activeDrawer: PlayerDrawerTab?
    @State private var showStats = false
    @State private var isLandscape = false

    @State private var aspectMode = AspectMode.fit
    @State private var zoom = 0.0
    @State private var colorPreset = ColorPreset.original
    @State private var brightness = 0.0
    @State private var contrast = 0.0
    @State private var saturation = 0.0
    @State private var gamma = 0.0
    @State private var sharpen = 0.0

    @State private var primarySubID: Int?
    @State private var secondarySubID: Int?
    @State private var subtitleScale = 1.0
    @State private var subtitlePos = 92
    @State private var subtitleColor = SubtitleColorOption.white
    @State private var subtitleBorder = 2.0
    @State private var subtitleBgOpacity = 0.0
    @State private var subtitleOffset = 0.0

    @State private var volumeBoost = 100.0
    @State private var audioDelay = 0.0
    @State private var nightMode = false

    @State private var speed = 1.0
    @State private var sleepTimer = SleepTimerOption.off
    @State private var sleepDeadline: Date?
    @State private var abLoopA: Double?
    @State private var abLoopB: Double?

    @State private var gestureHUD: GestureHUDState?
    @State private var boost2xActive = false
    @State private var savedSpeedBeforeBoost = 1.0
    @State private var dragStartTime: Double?
    @State private var dragStartVolume: Double = 100
    @State private var dragStartBrightness: CGFloat = 0.5
    @State private var lastSaved = 0.0
    @State private var closing = false
    @State private var hideTask: Task<Void, Never>?
    @State private var upNextDismissed = false

    let item: MediaItem
    let url: URL
    var smbSource: SMBReadSource? = nil
    var httpHeaders: [String: String] = [:]
    var externalSubtitles: [URL] = []
    var nextEpisode: MediaItem? = nil
    var onPlayNext: ((MediaItem) -> Void)? = nil
    let save: (Double, Double) -> Void

    private var status: PlaybackStatus { player.status }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                MPVSurface(onResize: { newSize in
                    player.handleSurfaceResize(newSize)
                }) { layer, edrAvailable, maxFPS in
                    guard !closing else { return }
                    let config = PlaybackConfiguration(
                        startTime: item.progress < 0.95 ? item.position : 0,
                        upscaler: upscaler,
                        hdrMode: hdrMode,
                        sdrToHDR: sdrToHDR,
                        interpolation: interpolation,
                        interpolationFPS: interpolationFPS,
                        deband: deband,
                        audioOutput: audioOutput,
                        hwdec: hwdecEnabled,
                        httpHeaders: httpHeaders,
                        externalSubtitles: externalSubtitles
                    )
                    player.open(
                        url,
                        title: item.displayTitle,
                        source: smbSource,
                        surface: layer,
                        edrAvailable: edrAvailable,
                        screenMaxFPS: maxFPS,
                        config: config
                    )
                }
                .ignoresSafeArea()
                .accessibilityHidden(true)

                gestureStage(size: geometry.size)

                if locked {
                    lockedOverlay
                } else if controls || status.error != nil || !status.ready {
                    hudOverlay(size: geometry.size)
                }

                if showStats, status.ready {
                    statsOverlay
                }

                if let gestureHUD {
                    gesturePill(gestureHUD)
                }

                if let snapMsg = status.snapshotMessage {
                    toastBanner(snapMsg)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                player.clearSnapshotMessage()
                            }
                        }
                }

                if shouldShowUpNext, let nextEpisode {
                    upNextCard(nextEpisode)
                }

                if let activeDrawer, !locked {
                    drawerOverlay(tab: activeDrawer, size: geometry.size)
                }
            }
            .onChange(of: geometry.size) { newSize in
                isLandscape = newSize.width > newSize.height
            }
        }
        .statusBarHidden(!controls)
        .persistentSystemOverlays(controls ? .automatic : .hidden)
        .onChange(of: status.ready) { ready in
            if ready { scheduleAutoHide() }
        }
        .onChange(of: status.time) { position in
            if abs(position - lastSaved) >= 15 { persist() }
            if let deadline = sleepDeadline, Date() >= deadline {
                player.pause()
                sleepDeadline = nil
                sleepTimer = .off
            }
        }
        .onChange(of: status.eofReached) { eof in
            if eof, sleepTimer == .endOfVideo {
                dismiss()
            }
        }
        .onChange(of: sleepTimer) { option in
            if option.rawValue > 0 {
                sleepDeadline = Date().addingTimeInterval(TimeInterval(option.rawValue * 60))
            } else {
                sleepDeadline = nil
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                player.handleEnterBackground(keepAudio: backgroundAudio)
                persist()
            } else if phase == .active {
                player.handleEnterForeground()
            }
        }
        .onDisappear {
            hideTask?.cancel()
            closing = true
            persist()
            player.close()
            AppOrientationDelegate.setOrientation(.allButUpsideDown)
        }
    }

    // MARK: - Gesture Layer

    private func gestureStage(size: CGSize) -> some View {
        HStack(spacing: 0) {
            tapZone(side: .left)
            tapZone(side: .center)
            tapZone(side: .right)
        }
        .contentShape(Rectangle())
        .gesture(
            LongPressGesture(minimumDuration: 0.35)
                .sequenced(before: DragGesture(minimumDistance: 0))
                .onChanged { value in
                    if case .second(true, _) = value, !locked, status.ready, !boost2xActive {
                        boost2xActive = true
                        savedSpeedBeforeBoost = speed
                        player.setSpeed(2.0)
                        showHUD(icon: "forward.fill", text: "Đang phát 2.0×")
                    }
                }
                .onEnded { _ in
                    if boost2xActive {
                        boost2xActive = false
                        player.setSpeed(savedSpeedBeforeBoost)
                        gestureHUD = nil
                    }
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onChanged { value in
                    guard !locked, status.ready else { return }
                    let dx = value.translation.width
                    let dy = value.translation.height
                    if abs(dx) > abs(dy) {
                        if dragStartTime == nil { dragStartTime = status.time }
                        let base = dragStartTime ?? status.time
                        let delta = Double(dx / max(size.width, 1)) * 120.0
                        let target = min(max(0, base + delta), max(status.duration, 1))
                        scrubTime = target
                        showHUD(icon: delta >= 0 ? "goforward" : "gobackward",
                                text: "\(formattedTime(target)) (\(delta >= 0 ? "+" : "")\(Int(delta))s)")
                    } else {
                        let isLeft = value.startLocation.x < size.width * 0.5
                        if isLeft {
                            if dragStartBrightness == 0.5 && value.translation.height.magnitude < 30 {
                                dragStartBrightness = UIScreen.main.brightness
                            }
                            let delta = -dy / 220.0
                            let next = min(max(0.05, dragStartBrightness + delta), 1.0)
                            UIScreen.main.brightness = next
                            showHUD(icon: "sun.max.fill", text: "Độ sáng \(Int(next * 100))%")
                        } else {
                            if dragStartVolume == 100 && value.translation.height.magnitude < 30 {
                                dragStartVolume = volumeBoost
                            }
                            let delta = Double(-dy / 2.2)
                            let next = min(max(0, dragStartVolume + delta), 200)
                            volumeBoost = next
                            player.setVolume(next)
                            showHUD(icon: "speaker.wave.3.fill", text: "Âm lượng \(Int(next))%")
                        }
                    }
                }
                .onEnded { _ in
                    if let target = scrubTime {
                        player.seek(to: target)
                        scrubTime = nil
                    }
                    dragStartTime = nil
                    dragStartVolume = volumeBoost
                    dragStartBrightness = UIScreen.main.brightness
                    clearHUDDelayed()
                }
        )
        .simultaneousGesture(
            MagnificationGesture()
                .onEnded { scale in
                    guard !locked else { return }
                    let target: AspectMode = scale > 1.1 ? .fill : .fit
                    aspectMode = target
                    player.setAspectMode(target)
                    showHUD(icon: "aspectratio", text: target.label)
                    clearHUDDelayed()
                }
        )
        .accessibilityHidden(true)
    }

    private enum ZoneSide { case left, center, right }

    private func tapZone(side: ZoneSide) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                guard !locked, status.ready else { return }
                switch side {
                case .left:
                    player.seek(by: -doubleTapSkip)
                    showHUD(icon: "gobackward.\(doubleTapSkip)", text: "Lùi \(doubleTapSkip) giây")
                    clearHUDDelayed()
                case .right:
                    player.seek(by: doubleTapSkip)
                    showHUD(icon: "goforward.\(doubleTapSkip)", text: "Tiến \(doubleTapSkip) giây")
                    clearHUDDelayed()
                case .center:
                    player.togglePause()
                    showHUD(icon: status.paused ? "play.fill" : "pause.fill",
                            text: status.paused ? "Phát" : "Tạm dừng")
                    clearHUDDelayed()
                }
            }
            .onTapGesture(count: 1) {
                guard !locked, status.error == nil, status.ready else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    controls.toggle()
                }
                if controls { scheduleAutoHide() }
            }
    }

    // MARK: - HUD Overlay

    private func hudOverlay(size: CGSize) -> some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            centerControls
            Spacer(minLength: 0)
            bottomBar
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.64), .clear, .clear, .black.opacity(0.74)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
        )
    }

    private var hasActiveEnhancements: Bool {
        status.neuralUpscalingActive
            || status.sdrToHDRActive
            || status.nativeHDRActive
            || status.interpolationActive
            || status.thermalThrottled
    }

    private var topBar: some View {
        let btnSize: CGFloat = isLandscape ? 38 : 34
        return HStack(spacing: 8) {
            iconButton("Đóng trình phát", icon: "xmark", size: isLandscape ? 38 : 36) {
                dismiss()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if status.videoSize != nil || hasActiveEnhancements {
                    HStack(spacing: 5) {
                        if let size = status.videoSize {
                            Text(size)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(CinemaStyle.muted)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        if hasActiveEnhancements {
                            HStack(spacing: 3.5) {
                                if status.neuralUpscalingActive {
                                    Circle().fill(CinemaStyle.accent).frame(width: 5.5, height: 5.5)
                                }
                                if status.sdrToHDRActive || status.nativeHDRActive {
                                    Circle().fill(CinemaStyle.gold).frame(width: 5.5, height: 5.5)
                                }
                                if status.interpolationActive {
                                    Circle().fill(CinemaStyle.accent.opacity(0.85)).frame(width: 5.5, height: 5.5)
                                }
                                if status.thermalThrottled {
                                    Circle().fill(CinemaStyle.danger).frame(width: 5.5, height: 5.5)
                                }
                            }
                            .accessibilityHidden(true)
                        }
                    }
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(.black.opacity(0.54), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75))
            .layoutPriority(1)

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                iconButton("Phát âm thanh nền", icon: "headphones", size: btnSize, active: backgroundAudio) {
                    backgroundAudio.toggle()
                    showHUD(icon: "headphones", text: backgroundAudio ? "Phát nền: Bật" : "Phát nền: Tắt")
                    clearHUDDelayed()
                }
                iconButton("Thống kê kỹ thuật", icon: "info.circle", size: btnSize, active: showStats) {
                    showStats.toggle()
                }
                .accessibilityIdentifier("player-stats-toggle")
                iconButton("Khóa cảm ứng", icon: "lock", size: btnSize) {
                    locked = true
                    activeDrawer = nil
                }
                iconButton("Xoay màn hình", icon: "rotate.right", size: btnSize) {
                    toggleOrientation()
                }
                .accessibilityIdentifier("player-rotate-toggle")
            }
        }
    }

    @ViewBuilder
    private var centerControls: some View {
        if let error = status.error {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(CinemaStyle.gold)
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                Button("Đóng") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(CinemaStyle.accent)
                    .foregroundStyle(CinemaStyle.ctaForeground)
            }
            .multilineTextAlignment(.center)
            .padding(20)
            .background(.black.opacity(0.84), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else if !status.ready || status.buffering {
            VStack(spacing: 10) {
                ProgressView().tint(.white)
                Text(status.ready ? "Đang tải bộ đệm…" : "Đang mở luồng phát…")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
            }
            .padding(18)
            .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            HStack(spacing: 28) {
                iconButton("Lùi 10 giây", icon: "gobackward.10", size: 50) {
                    player.seek(by: -10)
                    scheduleAutoHide()
                }
                Button {
                    player.togglePause()
                    scheduleAutoHide()
                } label: {
                    Image(systemName: status.paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 64, height: 64)
                        .background(Color.white, in: Circle())
                        .shadow(color: .black.opacity(0.45), radius: 14)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(status.paused ? "Phát" : "Tạm dừng")
                iconButton("Tiến 10 giây", icon: "goforward.10", size: 50) {
                    player.seek(by: 10)
                    scheduleAutoHide()
                }
            }
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if status.ready, status.error == nil {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Button {
                        showRemaining.toggle()
                    } label: {
                        Text(timeLabel)
                            .monospacedDigit()
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("player-time-readout")

                    if status.duration > 0 {
                        ZStack(alignment: .leading) {
                            GeometryReader { geo in
                                let bufferRatio = min(1.0, (status.time + status.demuxerCacheDuration) / status.duration)
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.white.opacity(0.20))
                                        .frame(height: 4)
                                    Capsule()
                                        .fill(Color.white.opacity(0.36))
                                        .frame(width: max(0, geo.size.width * bufferRatio), height: 4)
                                    ForEach(status.chapters) { chapter in
                                        let ratio = min(max(chapter.time / status.duration, 0), 1)
                                        Capsule()
                                            .fill(CinemaStyle.gold)
                                            .frame(width: 3, height: 8)
                                            .offset(x: geo.size.width * ratio)
                                    }
                                }
                                .frame(height: 24)
                            }
                            .frame(height: 24)
                            .allowsHitTesting(false)

                            Slider(value: Binding(
                                get: { min(scrubTime ?? status.time, status.duration) },
                                set: { scrubTime = $0 }
                            ), in: 0...status.duration, onEditingChanged: { editing in
                                if !editing, let scrubTime {
                                    player.seek(to: scrubTime)
                                    self.scrubTime = nil
                                    scheduleAutoHide()
                                }
                            })
                            .tint(CinemaStyle.accent)
                            .accessibilityLabel("Tiến độ video")
                        }
                    } else {
                        Spacer()
                    }
                }

                HStack {
                    drawerIconButton(
                        .video,
                        title: "Hình ảnh & AI",
                        icon: "wand.and.stars",
                        id: "player-drawer-video",
                        hasDot: status.neuralUpscalingActive || status.sdrToHDRActive || status.interpolationActive
                    )
                    Spacer()
                    drawerIconButton(
                        .subtitles,
                        title: "Phụ đề",
                        icon: "captions.bubble",
                        id: "player-drawer-sub",
                        hasDot: !status.subtitles.isEmpty
                    )
                    Spacer()
                    drawerIconButton(
                        .audio,
                        title: "Âm thanh",
                        icon: "speaker.wave.2",
                        id: "player-drawer-audio",
                        hasDot: nightMode || Int(volumeBoost) != 100
                    )
                    Spacer()
                    hudActionIcon(
                        "Tỉ lệ khung hình",
                        icon: "aspectratio",
                        id: "player-drawer-aspect",
                        active: aspectMode != .fit
                    ) {
                        let modes = AspectMode.allCases
                        let nextIdx = ((modes.firstIndex(of: aspectMode) ?? 0) + 1) % modes.count
                        aspectMode = modes[nextIdx]
                        player.setAspectMode(aspectMode)
                        showHUD(icon: "aspectratio", text: aspectMode.label)
                        clearHUDDelayed()
                        scheduleAutoHide()
                    }
                    Spacer()
                    hudActionIcon(
                        "Tốc độ phát",
                        icon: "gauge.with.dots.needle.67percent",
                        id: "player-drawer-speed",
                        active: speed != 1.0
                    ) {
                        let steps = [1.0, 1.25, 1.5, 2.0]
                        let next = steps.first { $0 > speed + 0.05 } ?? 1.0
                        speed = next
                        player.setSpeed(next)
                        showHUD(icon: "gauge.with.dots.needle.67percent", text: "\(next.formatted())×")
                        clearHUDDelayed()
                        scheduleAutoHide()
                    }
                    Spacer()
                    drawerIconButton(
                        .chapters,
                        title: "Tiện ích",
                        icon: "ellipsis",
                        id: "player-drawer-chapters",
                        hasDot: sleepTimer != .off || abLoopA != nil
                    )
                }
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.black.opacity(0.76), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(CinemaStyle.border, lineWidth: 1)
            )
        }
    }

    private func drawerIconButton(
        _ tab: PlayerDrawerTab,
        title: String,
        icon: String,
        id: String,
        hasDot: Bool
    ) -> some View {
        let selected = activeDrawer == tab
        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                activeDrawer = selected ? nil : tab
            }
            hideTask?.cancel()
        } label: {
            ZStack(alignment: .bottom) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(selected ? CinemaStyle.ctaForeground : .white)
                    .frame(width: 40, height: 40)
                    .background(selected ? CinemaStyle.accent : Color.white.opacity(0.14), in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(selected ? 0 : 0.14), lineWidth: 0.75))

                if hasDot && !selected {
                    Circle()
                        .fill(CinemaStyle.gold)
                        .frame(width: 4.5, height: 4.5)
                        .offset(y: -4)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }

    private func hudActionIcon(
        _ title: String,
        icon: String,
        id: String,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack(alignment: .bottom) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.14), in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75))

                if active {
                    Circle()
                        .fill(CinemaStyle.accent)
                        .frame(width: 4.5, height: 4.5)
                        .offset(y: -4)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }

    // MARK: - Auxiliary Overlays

    private var lockedOverlay: some View {
        VStack {
            Spacer()
            HStack {
                Button {
                    locked = false
                    controls = true
                    scheduleAutoHide()
                } label: {
                    Label("Đã khóa · Chạm để mở", systemImage: "lock.fill")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.black.opacity(0.78), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.25)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(20)
        }
    }

    private var statsOverlay: some View {
        VStack {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Stats for Nerds · libmpv + MoltenVK")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                    Text("Video: \(status.stats.videoCodec) · \(status.videoSize ?? "—") · \(String(format: "%.2f", status.stats.fps)) fps (est \(String(format: "%.1f", status.stats.estimatedFPS)))")
                    Text("Màu: \(status.stats.colorPrimaries) / \(status.stats.gamma) · Peak \(String(format: "%.2f", status.stats.sigPeak)) · EDR \(String(format: "%.1f×", status.stats.edrHeadroom))")
                    Text("AI/Scaler: \(status.stats.activePassesSummary) · Nội suy: \(status.interpolationActive ? interpolation.shortLabel : "Tắt")")
                    Text("Bộ đệm: \(String(format: "%.1f MB", status.stats.cacheMB)) (\(String(format: "%.1fs", status.stats.cacheAheadSec))) · Drop: \(status.stats.droppedFrames)")
                    if status.thermalThrottled {
                        Text("Nhiệt: Đã giảm tải GPU để bảo vệ máy")
                            .foregroundStyle(CinemaStyle.gold)
                    } else if status.sdrToHDRBypassedForNativeHDR {
                        Text("HDR: Nguồn HDR gốc · bỏ qua SDR→HDR")
                            .foregroundStyle(CinemaStyle.gold)
                    }
                }
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(CinemaStyle.accent)
                .padding(12)
                .background(.black.opacity(0.84), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(CinemaStyle.border, lineWidth: 1)
                )
                .accessibilityIdentifier("player-stats-overlay")
                Spacer()
            }
            .padding(.top, 72)
            .padding(.horizontal, 18)
            Spacer()
        }
        .allowsHitTesting(false)
    }

    private func gesturePill(_ hud: GestureHUDState) -> some View {
        Label(hud.text, systemImage: hud.icon)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.black.opacity(0.82), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.22)))
            .allowsHitTesting(false)
    }

    private func toastBanner(_ text: String) -> some View {
        VStack {
            Text(text)
                .font(.caption.weight(.bold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(CinemaStyle.elevated, in: Capsule())
                .overlay(Capsule().strokeBorder(CinemaStyle.accent))
                .foregroundStyle(.white)
                .padding(.top, 56)
            Spacer()
        }
        .allowsHitTesting(false)
    }

    private var shouldShowUpNext: Bool {
        !upNextDismissed && nextEpisode != nil && status.duration > 60 && (status.duration - status.time) <= 25
    }

    private func upNextCard(_ episode: MediaItem) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 8) {
                    Text("TẬP TIẾP THEO")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(CinemaStyle.accent)
                    Text(episode.displayTitle)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Button("Phát ngay") {
                            onPlayNext?(episode)
                        }
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.white, in: Capsule())
                        .foregroundStyle(.black)

                        Button("Ẩn") {
                            upNextDismissed = true
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(CinemaStyle.muted)
                    }
                }
                .frame(width: 220)
                .padding(12)
                .background(CinemaStyle.elevated.opacity(0.95), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(CinemaStyle.border))
            }
            .padding(.bottom, 86)
            .padding(.horizontal, 18)
        }
    }

    private func drawerOverlay(tab: PlayerDrawerTab, size: CGSize) -> some View {
        let isWide = size.width > size.height
        return ZStack(alignment: isWide ? .trailing : .bottom) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture {
                    activeDrawer = nil
                    scheduleAutoHide()
                }
            PlayerDrawerContainer(
                tab: tab,
                item: item,
                status: status,
                player: player,
                upscaler: $upscaler,
                hdrMode: $hdrMode,
                sdrToHDR: $sdrToHDR,
                interpolation: $interpolation,
                interpolationFPS: $interpolationFPS,
                deband: $deband,
                aspectMode: $aspectMode,
                zoom: $zoom,
                colorPreset: $colorPreset,
                brightness: $brightness,
                contrast: $contrast,
                saturation: $saturation,
                gamma: $gamma,
                sharpen: $sharpen,
                primarySubID: $primarySubID,
                secondarySubID: $secondarySubID,
                subtitleScale: $subtitleScale,
                subtitlePos: $subtitlePos,
                subtitleColor: $subtitleColor,
                subtitleBorder: $subtitleBorder,
                subtitleBgOpacity: $subtitleBgOpacity,
                subtitleOffset: $subtitleOffset,
                audioOutput: $audioOutput,
                volumeBoost: $volumeBoost,
                audioDelay: $audioDelay,
                nightMode: $nightMode,
                speed: $speed,
                sleepTimer: $sleepTimer,
                abLoopA: $abLoopA,
                abLoopB: $abLoopB,
                onSnapshot: {
                    player.takeSnapshot { data in
                        if let data, let image = UIImage(data: data) {
                            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                        }
                    }
                },
                onClose: {
                    activeDrawer = nil
                    scheduleAutoHide()
                }
            )
            .frame(
                maxWidth: isWide ? 340 : .infinity,
                maxHeight: isWide ? .infinity : min(size.height * 0.62, 460)
            )
            .padding(12)
        }
    }

    // MARK: - Helpers

    private var timeLabel: String {
        let current = scrubTime ?? status.time
        if status.duration > 0 {
            if showRemaining {
                let rem = max(0, status.duration - current)
                return "-\(formattedTime(rem)) / \(formattedTime(status.duration))"
            }
            return "\(formattedTime(current)) / \(formattedTime(status.duration))"
        }
        return formattedTime(current)
    }

    private func formattedTime(_ value: Double) -> String {
        let seconds = Int(max(0, min(value, 359_999)))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func iconButton(_ title: String, icon: String, size: CGFloat, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(active ? CinemaStyle.ctaForeground : .white)
                .frame(width: size, height: size)
                .background(active ? CinemaStyle.accent : Color.black.opacity(0.60), in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func toggleOrientation() {
        isLandscape.toggle()
        AppOrientationDelegate.setOrientation(isLandscape ? .landscapeRight : .portrait)
    }

    private func persist() {
        guard status.ready, status.duration > 0 else { return }
        save(status.time, status.duration)
        lastSaved = status.time
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        guard activeDrawer == nil, !showStats else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, activeDrawer == nil, !showStats, status.ready, !status.paused else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.25)) {
                    controls = false
                }
            }
        }
    }

    private func showHUD(icon: String, text: String) {
        gestureHUD = GestureHUDState(icon: icon, text: text)
    }

    private func clearHUDDelayed() {
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run { gestureHUD = nil }
        }
    }

    private struct GestureHUDState: Equatable {
        let icon: String
        let text: String
    }
}
