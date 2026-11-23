import AVFoundation
import Foundation
import Libmpv
import MediaPlayer
import QuartzCore
import SwiftUI
import UIKit

struct PlaybackTrack: Identifiable, Equatable {
    let id: Int
    let label: String
    let selected: Bool
}

struct PlaybackChapter: Identifiable, Equatable {
    let id: Int
    let title: String
    let time: Double
}

struct PlaybackStats: Equatable {
    var videoCodec = "—"
    var pixelFormat = "—"
    var fps = 0.0
    var estimatedFPS = 0.0
    var droppedFrames = 0
    var colorPrimaries = "—"
    var gamma = "—"
    var sigPeak = 1.0
    var edrHeadroom = 1.0
    var cacheMB = 0.0
    var cacheAheadSec = 0.0
    var activePassesSummary = "Bilinear"
}

struct PlaybackConfiguration: Equatable {
    var startTime: Double = 0
    var upscaler: VideoUpscaler = .lanczos
    var hdrMode: HDRDisplayMode = .autoEDR
    var sdrToHDR: SDRtoHDRMode = .off
    var interpolation: MotionInterpolation = .off
    var interpolationFPS: InterpolationFPS = .auto
    var deband: Bool = false
    var audioOutput: AudioOutput = .automatic
    var hwdec: Bool = true
    var httpHeaders: [String: String] = [:]
    var externalSubtitles: [URL] = []
}

struct PlaybackStatus: Equatable {
    var ready = false
    var paused = false
    var buffering = false
    var eofReached = false
    var time = 0.0
    var duration = 0.0
    var demuxerCacheDuration = 0.0
    var audio: [PlaybackTrack] = []
    var subtitles: [PlaybackTrack] = []
    var chapters: [PlaybackChapter] = []
    var videoSize: String?
    var videoWidth = 0
    var videoHeight = 0
    var outputChannels = 0
    var neuralUpscalingActive = false
    var casSharpenActive = false
    var sdrToHDRActive = false
    var nativeHDRActive = false
    var sourceIsHDR = false
    var interpolationActive = false
    var edrAvailable = false
    var sdrToHDRBypassedForNativeHDR = false
    var thermalThrottled = false
    var thermalNotice: String?
    var snapshotMessage: String?
    var stats = PlaybackStats()
    var error: String?
}

final class MPVPlayback: ObservableObject {
    @Published private(set) var status = PlaybackStatus()

    private let work = DispatchQueue(label: "com.local.cinema.playback", qos: .userInitiated)
    private var handle: OpaquePointer?
    private weak var surface: CAMetalLayer?
    private var smbSource: SMBReadSource?
    private var timer: DispatchSourceTimer?

    private var progress = PlaybackStatus()
    private var initialConfig = PlaybackConfiguration()
    private var nextTrackRead = Date.distantPast
    private var currentUpscaler: VideoUpscaler = .lanczos
    private var currentHDRMode: HDRDisplayMode = .autoEDR
    private var currentSDRToHDR: SDRtoHDRMode = .off
    private var currentInterpolation: MotionInterpolation = .off
    private var currentInterpolationFPS: InterpolationFPS = .auto
    private var appliedUpscaler: VideoUpscaler?
    private var appliedHDRMode: HDRDisplayMode?
    private var appliedSDRToHDR: SDRtoHDRMode?
    private var appliedInterpolation: MotionInterpolation?
    private var appliedInterpolationFPS: InterpolationFPS?
    private var currentThermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    private var thermalObserver: NSObjectProtocol?
    private var edrAvailable = false
    private var screenMaxFPS = 60
    private var pendingExternalSubtitles: [URL] = []
    private var currentTitle = ""
    private var remoteTargetsConfigured = false
    private var isReconfiguringSurface = false
    private var lastConfiguredSize: CGSize = .zero

    deinit {
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
    }

    func open(
        _ url: URL,
        title: String,
        source: SMBReadSource? = nil,
        surface: CAMetalLayer,
        edrAvailable: Bool,
        screenMaxFPS: Int,
        config: PlaybackConfiguration
    ) {
        currentTitle = title
        let initialDrawableSize = surface.drawableSize
        configureAudioSession()
        setupRemoteCommands()

        work.async {
            guard self.handle == nil else { return }
            self.lastConfiguredSize = initialDrawableSize
            guard let client = mpv_create() else {
                self.fail("Không thể khởi tạo trình phát.")
                return
            }
            self.handle = client
            self.surface = surface
            self.initialConfig = config
            self.edrAvailable = edrAvailable
            self.screenMaxFPS = max(60, screenMaxFPS)
            self.pendingExternalSubtitles = config.externalSubtitles
            self.progress.edrAvailable = edrAvailable
            self.progress.stats.edrHeadroom = edrAvailable ? 2.0 : 1.0

            var surfaceAddress = Int64(bitPattern: UInt64(UInt(bitPattern: Unmanaged.passUnretained(surface).toOpaque())))
            let output = mpv_set_option(client, "wid", MPV_FORMAT_INT64, &surfaceAddress)
            if output < 0 {
                self.fail("Không thể khởi tạo lớp hiển thị video.", code: output)
                self.finish()
                return
            }

            let requiredOptions: [String: String] = [
                "config": "no",
                "load-scripts": "no",
                "load-unsafe-playlists": "no",
                "terminal": "no",
                "input-default-bindings": "no",
                "vo": "gpu-next",
                "gpu-api": "vulkan",
                "gpu-context": "moltenvk",
                "hwdec": config.hwdec ? "videotoolbox" : "no",
                "ao": "audiounit",
                "keep-open": "yes",
                "sub-auto": "no",
                "audio-file-auto": "no"
            ]
            for (key, value) in requiredOptions {
                let result = mpv_set_option_string(client, key, value)
                if result < 0 {
                    self.fail("Không thể cấu hình trình phát (\(key)).", code: result)
                    self.finish()
                    return
                }
            }

            self.setOption("audio-channels", config.audioOutput.option)
            self.setOption("volume-max", "200")
            self.setOption("demuxer-max-bytes", "67108864")
            self.setOption("demuxer-readahead-secs", "20")
            self.setOption("deband", config.deband ? "yes" : "no")
            self.setOption("sub-scale-by-window", "yes")
            self.setOption("sub-outline-size", "2")
            self.setOption("secondary-sub-pos", "8")

            if !config.httpHeaders.isEmpty {
                let headerString = config.httpHeaders.map { "\($0.key): \($0.value)" }.joined(separator: ",")
                self.setOption("http-header-fields", headerString)
            }

            let initResult = mpv_initialize(client)
            if initResult < 0 {
                self.fail("Không thể khởi tạo trình phát.", code: initResult)
                self.finish()
                return
            }

            if let source {
                self.smbSource = source
                let status = source.register(on: client)
                guard status >= 0 else {
                    self.fail("Không thể khởi tạo luồng SMB.", code: status)
                    self.finish()
                    return
                }
            }

            self.currentUpscaler = config.upscaler
            self.currentHDRMode = config.hdrMode
            self.currentSDRToHDR = config.sdrToHDR
            self.currentInterpolation = config.interpolation
            self.currentInterpolationFPS = config.interpolationFPS
            self.currentThermalState = ProcessInfo.processInfo.thermalState
            if self.thermalObserver == nil {
                self.thermalObserver = NotificationCenter.default.addObserver(
                    forName: ProcessInfo.thermalStateDidChangeNotification,
                    object: nil,
                    queue: nil
                ) { [weak self] _ in
                    self?.work.async { self?.handleThermalStateChange() }
                }
            }
            self.reconcileEnhancements(force: true)

            let path = source?.uri ?? (url.isFileURL ? url.path : url.absoluteString)
            self.command("loadfile", path, "replace")

            let timer = DispatchSource.makeTimerSource(queue: self.work)
            timer.schedule(deadline: .now(), repeating: .milliseconds(160), leeway: .milliseconds(30))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
        }
    }

    func close() {
        clearNowPlaying()
        work.async { self.finish() }
    }

    /// Forces libmpv's `gpu-next` + `moltenvk` driver to tear down and recreate its Vulkan swapchain
    /// against the updated `CAMetalLayer.drawableSize` after orientation/container changes.
    func handleSurfaceResize(_ drawableSize: CGSize) {
        work.async {
            guard self.handle != nil,
                  self.progress.ready,
                  self.progress.error == nil,
                  !self.isReconfiguringSurface,
                  drawableSize.width > 1,
                  drawableSize.height > 1 else {
                return
            }
            guard abs(drawableSize.width - self.lastConfiguredSize.width) > 2
                || abs(drawableSize.height - self.lastConfiguredSize.height) > 2 else {
                return
            }
            self.lastConfiguredSize = drawableSize
            self.isReconfiguringSurface = true
            self.setOptional("vo", "null")

            let layer = self.surface
            DispatchQueue.main.async {
                if let layer {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    layer.contentsGravity = .resizeAspect
                    layer.drawableSize = drawableSize
                    CATransaction.commit()
                }
                self.work.async { [weak self] in
                    guard let self else { return }
                    defer { self.isReconfiguringSurface = false }
                    guard self.handle != nil else { return }
                    self.setOptional("vo", "gpu-next")
                    self.reconcileEnhancements(force: true)
                }
            }
        }
    }

    func togglePause() {
        work.async {
            if self.flag("eof-reached") {
                self.command("seek", "0", "absolute+exact")
                self.setOptional("pause", "no")
            } else {
                self.setOptional("pause", self.flag("pause") ? "no" : "yes")
            }
        }
    }

    func pause() {
        work.async { self.setOptional("pause", "yes") }
    }

    func play() {
        work.async { self.setOptional("pause", "no") }
    }

    func handleEnterBackground(keepAudio: Bool) {
        work.async {
            self.setOptional("vid", "no")
            if !keepAudio {
                self.setOptional("pause", "yes")
            }
        }
    }

    func handleEnterForeground() {
        work.async {
            self.setOptional("vid", "auto")
        }
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        work.async { self.command("seek", String(max(0, seconds)), "absolute+exact") }
    }

    func seek(by seconds: Int) {
        work.async { self.command("seek", String(seconds), "relative+exact") }
    }

    func frameStep(forward: Bool) {
        work.async {
            self.setOptional("pause", "yes")
            self.command(forward ? "frame-step" : "frame-back-step")
        }
    }

    // MARK: - AI Upscaling, HDR/SDR-to-HDR & Interpolation Controls

    func setUpscaler(_ upscaler: VideoUpscaler) {
        work.async {
            self.currentUpscaler = upscaler
            self.reconcileEnhancements()
        }
    }

    func setHDRDisplayMode(_ mode: HDRDisplayMode) {
        work.async {
            self.currentHDRMode = mode
            self.reconcileEnhancements()
        }
    }

    func setSDRtoHDR(_ mode: SDRtoHDRMode) {
        work.async {
            self.currentSDRToHDR = mode
            self.reconcileEnhancements()
        }
    }

    func setInterpolation(_ mode: MotionInterpolation, fps: InterpolationFPS) {
        work.async {
            self.currentInterpolation = mode
            self.currentInterpolationFPS = fps
            self.reconcileEnhancements()
        }
    }

    func setDeband(_ enabled: Bool) {
        work.async { self.setOptional("deband", enabled ? "yes" : "no") }
    }

    func setAspectMode(_ mode: AspectMode) {
        work.async {
            switch mode {
            case .fit:
                self.setOptional("keepaspect", "yes")
                self.setOptional("panscan", "0")
                self.setOptional("video-aspect-override", "-1")
            case .fill:
                self.setOptional("keepaspect", "yes")
                self.setOptional("panscan", "1")
                self.setOptional("video-aspect-override", "-1")
            case .stretch:
                self.setOptional("keepaspect", "no")
                self.setOptional("panscan", "0")
                self.setOptional("video-aspect-override", "-1")
            case .ratio16x9:
                self.setOptional("keepaspect", "yes")
                self.setOptional("panscan", "0")
                self.setOptional("video-aspect-override", "16:9")
            case .ratio21x9:
                self.setOptional("keepaspect", "yes")
                self.setOptional("panscan", "0")
                self.setOptional("video-aspect-override", "21:9")
            case .ratio4x3:
                self.setOptional("keepaspect", "yes")
                self.setOptional("panscan", "0")
                self.setOptional("video-aspect-override", "4:3")
            }
        }
    }

    func setZoom(_ zoom: Double) {
        work.async { self.setOptional("video-zoom", String(format: "%.2f", min(max(zoom, -0.5), 1.5))) }
    }

    func setColorAdjustments(brightness: Double, contrast: Double, saturation: Double, gamma: Double, sharpen: Double) {
        work.async {
            self.setOptional("brightness", String(Int(brightness)))
            self.setOptional("contrast", String(Int(contrast)))
            self.setOptional("saturation", String(Int(saturation)))
            self.setOptional("gamma", String(Int(gamma)))
            self.setOptional("sharpen", String(format: "%.2f", sharpen))
        }
    }

    // MARK: - Audio & Subtitles & Utilities

    func selectAudio(_ id: Int) { work.async { self.setOptional("aid", String(id)) } }
    func setOutput(_ audio: AudioOutput) { work.async { self.setOptional("audio-channels", audio.option) } }
    func setVolume(_ percent: Double) { work.async { self.setOptional("volume", String(Int(min(max(percent, 0), 200)))) } }
    func setAudioDelay(_ seconds: Double) { work.async { self.setOptional("audio-delay", String(format: "%.2f", seconds)) } }

    func setNightMode(_ enabled: Bool) {
        work.async {
            self.setOptional("audio-normalize-downmix", enabled ? "yes" : "no")
            if enabled {
                self.setOptional("af", "lavfi=[dynaudnorm=f=150:g=15:p=0.9]")
            } else {
                self.setOptional("af", "")
            }
        }
    }

    func selectSubtitle(_ id: Int?) {
        work.async { self.setOptional("sid", id.map(String.init) ?? "no") }
    }

    func selectSecondarySubtitle(_ id: Int?) {
        work.async { self.setOptional("secondary-sid", id.map(String.init) ?? "no") }
    }

    func addExternalSubtitle(_ url: URL) {
        work.async {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let cleanTitle = Self.cleanSubtitleTitle(from: url)
            self.command("sub-add", url.path, "select", cleanTitle)
            self.updateTracks()
            self.publish()
        }
    }

    private static func cleanSubtitleTitle(from url: URL) -> String {
        let name = url.lastPathComponent
        if name.count > 37,
           name[name.index(name.startIndex, offsetBy: 36)] == "_",
           UUID(uuidString: String(name.prefix(36))) != nil {
            return String(name.dropFirst(37))
        }
        return name
    }

    func setSubtitleOffset(_ seconds: Double) {
        work.async { self.setOptional("sub-delay", String(format: "%.2f", seconds)) }
    }

    func setSubtitleStyle(scale: Double, pos: Int, color: SubtitleColorOption, borderSize: Double, backgroundOpacity: Double) {
        work.async {
            self.setOptional("sub-scale", String(format: "%.2f", scale))
            self.setOptional("sub-pos", String(min(max(pos, 5), 100)))
            self.setOptional("sub-color", color.mpvColor)
            self.setOptional("sub-outline-size", String(format: "%.1f", borderSize))
            let alpha = Int(min(max(backgroundOpacity, 0), 1) * 255)
            let bgHex = String(format: "#%02X000000", alpha)
            self.setOptional("sub-back-color", bgHex)
        }
    }

    func setSpeed(_ speed: Double) {
        work.async { self.setOptional("speed", String(format: "%.2f", speed)) }
    }

    func setABLoop(a: Double?, b: Double?) {
        work.async {
            self.setOptional("ab-loop-a", a.map { String(format: "%.2f", $0) } ?? "no")
            self.setOptional("ab-loop-b", b.map { String(format: "%.2f", $0) } ?? "no")
        }
    }

    func takeSnapshot(completion: @escaping @Sendable (Data?) -> Void) {
        work.async {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("LocalCinema_Shot_\(UUID().uuidString).png")
            self.command("screenshot-to-file", tmp.path, "subtitles")
            let data = try? Data(contentsOf: tmp)
            try? FileManager.default.removeItem(at: tmp)
            if data != nil {
                self.progress.snapshotMessage = "Đã lưu khung hình vào Ảnh"
                self.publish()
            }
            DispatchQueue.main.async {
                completion(data)
            }
        }
    }

    func clearSnapshotMessage() {
        work.async {
            self.progress.snapshotMessage = nil
            self.publish()
        }
    }

    // MARK: - Private Pipeline Application

    private func handleThermalStateChange() {
        currentThermalState = ProcessInfo.processInfo.thermalState
        reconcileEnhancements()
    }

    private func reconcileEnhancements(force: Bool = false) {
        let decision = EnhancementPolicy.resolve(
            upscaler: currentUpscaler,
            hdrMode: currentHDRMode,
            sdrToHDR: currentSDRToHDR,
            interpolation: currentInterpolation,
            interpolationFPS: currentInterpolationFPS,
            sourceIsHDR: progress.sourceIsHDR,
            edrAvailable: edrAvailable,
            thermalState: currentThermalState
        )

        if force || appliedUpscaler != decision.effectiveUpscaler {
            applyUpscaler(decision.effectiveUpscaler)
            appliedUpscaler = decision.effectiveUpscaler
        }
        if force || appliedHDRMode != currentHDRMode || appliedSDRToHDR != decision.effectiveSDRToHDR {
            applyColorPipeline(hdrMode: currentHDRMode, sdrToHDR: decision.effectiveSDRToHDR)
            appliedHDRMode = currentHDRMode
            appliedSDRToHDR = decision.effectiveSDRToHDR
        }
        if force
            || appliedInterpolation != decision.effectiveInterpolation
            || appliedInterpolationFPS != decision.effectiveInterpolationFPS
        {
            applyInterpolation(decision.effectiveInterpolation, fps: decision.effectiveInterpolationFPS)
            appliedInterpolation = decision.effectiveInterpolation
            appliedInterpolationFPS = decision.effectiveInterpolationFPS
        }

        progress.nativeHDRActive = decision.nativeHDRActive
        progress.sdrToHDRBypassedForNativeHDR = decision.sdrToHDRBypassedForNativeHDR
        progress.thermalThrottled = decision.thermalThrottled
        progress.thermalNotice = decision.thermalNotice
        publish()
    }

    private func applyUpscaler(_ upscaler: VideoUpscaler) {
        progress.neuralUpscalingActive = false
        progress.casSharpenActive = false
        setOptional("scale", upscaler.filter)

        let fsrcnnx = Bundle.main.url(forResource: "FSRCNNX_x2_8-0-4-1", withExtension: "glsl", subdirectory: "Shaders")
        let cas = Bundle.main.url(forResource: "CAS_Sharpen", withExtension: "glsl", subdirectory: "Shaders")

        switch upscaler {
        case .standard, .lanczos:
            command("change-list", "glsl-shaders", "clr", "")
        case .aiFSRCNNX:
            if let fsrcnnx {
                command("change-list", "glsl-shaders", "set", fsrcnnx.path)
            } else {
                command("change-list", "glsl-shaders", "clr", "")
            }
        case .aiCinemaDetail:
            if let fsrcnnx {
                command("change-list", "glsl-shaders", "set", fsrcnnx.path)
                if let cas {
                    command("change-list", "glsl-shaders", "append", cas.path)
                }
            } else if let cas {
                command("change-list", "glsl-shaders", "set", cas.path)
            } else {
                command("change-list", "glsl-shaders", "clr", "")
            }
        }
        publish()
    }

    private func applyColorPipeline(hdrMode: HDRDisplayMode, sdrToHDR: SDRtoHDRMode) {
        if sdrToHDR != .off {
            setOptional("inverse-tone-mapping", "yes")
            setOptional("hdr-compute-peak", "yes")
            setOptional("tone-mapping", "bt.2390")
            setOptional("target-peak", String(sdrToHDR.targetPeakNits))
            if edrAvailable {
                setOptional("target-colorspace-hint", "yes")
                setOptional("target-trc", "pq")
                setOptional("target-prim", "bt.2020")
                updateLayerEDR(true)
            } else {
                setOptional("target-colorspace-hint", "no")
                setOptional("target-trc", "auto")
                setOptional("target-prim", "auto")
                updateLayerEDR(false)
            }
            progress.sdrToHDRActive = true
        } else {
            setOptional("inverse-tone-mapping", "no")
            setOptional("target-peak", "auto")
            setOptional("target-trc", "auto")
            setOptional("target-prim", "auto")
            setOptional("tone-mapping", "auto")
            progress.sdrToHDRActive = false

            let wantEDR = (hdrMode == .autoEDR && edrAvailable)
            setOptional("target-colorspace-hint", wantEDR ? "yes" : "no")
            updateLayerEDR(wantEDR)
        }
        publish()
    }

    private func applyInterpolation(_ mode: MotionInterpolation, fps: InterpolationFPS) {
        if mode == .off {
            setOptional("interpolation", "no")
            setOptional("video-sync", "audio")
            setOptional("display-fps-override", "0")
            progress.interpolationActive = false
        } else {
            setOptional("video-sync", "display-resample")
            setOptional("interpolation", "yes")
            setOptional("tscale", mode.tscale)
            setOptional("interpolation-threshold", "0.01")
            let targetFPS = fps.overrideHz > 0 ? fps.overrideHz : max(60, screenMaxFPS)
            setOptional("display-fps-override", String(targetFPS))
            progress.interpolationActive = true
        }
        publish()
    }

    private func updateLayerEDR(_ enabled: Bool) {
        let layer = self.surface
        DispatchQueue.main.async {
            layer?.wantsExtendedDynamicRangeContent = enabled
        }
    }

    // MARK: - Event Polling & Telemetry

    private func poll() {
        guard let handle else { return }
        while let event = mpv_wait_event(handle, 0)?.pointee, event.event_id != MPV_EVENT_NONE {
            switch event.event_id {
            case MPV_EVENT_FILE_LOADED:
                progress.ready = true
                if initialConfig.startTime > 0 {
                    command("seek", String(initialConfig.startTime), "absolute+exact")
                }
                for (index, subURL) in pendingExternalSubtitles.enumerated() {
                    let cleanTitle = Self.cleanSubtitleTitle(from: subURL)
                    command("sub-add", subURL.path, index == 0 ? "select" : "auto", cleanTitle)
                }
                pendingExternalSubtitles.removeAll()
                updateTracks()
                updateChapters()
            case MPV_EVENT_END_FILE:
                if let end = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee,
                   end.reason == MPV_END_FILE_REASON_ERROR {
                    fail("Không thể phát video. Kiểm tra liên kết, tệp và kết nối mạng.", code: end.error)
                }
            case MPV_EVENT_SHUTDOWN:
                finish()
                return
            default:
                break
            }
        }

        if progress.ready, progress.error == nil {
            let eof = flag("eof-reached")
            progress.eofReached = eof
            progress.paused = flag("pause") || eof
            progress.buffering = flag("paused-for-cache")
            progress.time = double("time-pos")
            progress.duration = double("duration")
            progress.demuxerCacheDuration = double("demuxer-cache-duration")

            if Date() >= nextTrackRead {
                updateTracks()
                updateChapters()
                updateEnhancementAndStats()
                nextTrackRead = Date().addingTimeInterval(0.65)
                updateNowPlaying(time: progress.time, duration: progress.duration, paused: progress.paused)
            }
        }
        publish()
    }

    private func updateEnhancementAndStats() {
        let passes = voPassDescriptions()
        let foundAggregation = passes.contains { $0.localizedCaseInsensitiveContains("aggregation") }
        let foundCAS = passes.contains { $0.localizedCaseInsensitiveContains("cas") }

        let sigPeak = double("video-params/sig-peak")
        let primaries = string("video-params/primaries") ?? "bt.709"
        let gamma = string("video-params/gamma") ?? "bt.1886"
        let isHDRSource = EnhancementPolicy.isHDRSource(sigPeak: sigPeak, primaries: primaries, gamma: gamma)
        let liveThermal = ProcessInfo.processInfo.thermalState

        if isHDRSource != progress.sourceIsHDR || liveThermal != currentThermalState {
            progress.sourceIsHDR = isHDRSource
            currentThermalState = liveThermal
            reconcileEnhancements()
        }

        let activeUpscaler = appliedUpscaler ?? currentUpscaler
        progress.neuralUpscalingActive = activeUpscaler.usesNeuralShader && foundAggregation
        progress.casSharpenActive = (activeUpscaler == .aiCinemaDetail) && foundCAS

        var stats = PlaybackStats()
        stats.videoCodec = (string("video-codec") ?? string("video-format") ?? "—").uppercased()
        stats.pixelFormat = string("video-params/pixelformat") ?? "—"
        stats.fps = double("container-fps")
        stats.estimatedFPS = double("estimated-vf-fps")
        stats.droppedFrames = Int(integer("frame-drop-count"))
        stats.colorPrimaries = primaries.uppercased()
        stats.gamma = gamma.uppercased()
        stats.sigPeak = sigPeak > 0 ? sigPeak : 1.0
        stats.edrHeadroom = edrAvailable ? 2.0 : 1.0
        stats.cacheMB = Double(integer("demuxer-cache-state/fw-bytes")) / (1024.0 * 1024.0)
        stats.cacheAheadSec = progress.demuxerCacheDuration
        let thermalTag = progress.thermalThrottled ? " · Thermal" : ""
        stats.activePassesSummary = passes.isEmpty
            ? "\(activeUpscaler.shortLabel)\(thermalTag)"
            : "\(activeUpscaler.shortLabel)\(thermalTag) (\(passes.count) passes)"
        progress.stats = stats
    }

    private func updateTracks() {
        let count = min(Int(integer("track-list/count")), 256)
        var audio: [PlaybackTrack] = []
        var subtitles: [PlaybackTrack] = []
        if count > 0 {
            for index in 0..<count {
                let path = "track-list/\(index)"
                guard let type = string("\(path)/type"), type == "audio" || type == "sub" else { continue }
                let id = Int(integer("\(path)/id"))
                let title = string("\(path)/title") ?? string("\(path)/lang") ?? "Track \(id)"
                let codec = string("\(path)/codec")?.uppercased()
                let channels = Int(integer("\(path)/demux-channel-count"))
                let label = [title, codec, channels > 0 ? Self.channelsLabel(channels) : nil]
                    .compactMap { $0 }.joined(separator: "  ·  ")
                let track = PlaybackTrack(id: id, label: label, selected: flag("\(path)/selected"))
                if type == "audio" { audio.append(track) } else { subtitles.append(track) }
            }
        }
        progress.audio = audio
        progress.subtitles = subtitles
        progress.outputChannels = Int(integer("audio-out-params/channel-count"))
        let width = Int(integer("width"))
        let height = Int(integer("height"))
        progress.videoWidth = width
        progress.videoHeight = height
        progress.videoSize = width > 0 && height > 0 ? "\(width) × \(height)" : nil
    }

    private func updateChapters() {
        let count = min(max(Int(integer("chapter-list/count")), 0), 100)
        var list: [PlaybackChapter] = []
        for idx in 0..<count {
            let title = string("chapter-list/\(idx)/title") ?? "Chương \(idx + 1)"
            let time = double("chapter-list/\(idx)/time")
            list.append(PlaybackChapter(id: idx, title: title, time: time))
        }
        progress.chapters = list
    }

    static func channelsLabel(_ channels: Int) -> String {
        switch channels {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(channels) kênh"
        }
    }

    // MARK: - Background Audio & Now Playing

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay, .allowBluetoothA2DP])
        try? session.setActive(true)
    }

    private func setupRemoteCommands() {
        guard !remoteTargetsConfigured else { return }
        remoteTargetsConfigured = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] _ in
            self?.seek(by: 10)
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            self?.seek(by: -10)
            return .success
        }
    }

    private func updateNowPlaying(time: Double, duration: Double, paused: Bool) {
        let title = currentTitle
        DispatchQueue.main.async {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = [
                MPMediaItemPropertyTitle: title,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: time,
                MPMediaItemPropertyPlaybackDuration: duration,
                MPNowPlayingInfoPropertyPlaybackRate: paused ? 0.0 : 1.0
            ]
        }
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - C API Helpers

    private func finish() {
        timer?.cancel()
        timer = nil
        if let observer = thermalObserver {
            NotificationCenter.default.removeObserver(observer)
            thermalObserver = nil
        }
        appliedUpscaler = nil
        appliedHDRMode = nil
        appliedSDRToHDR = nil
        appliedInterpolation = nil
        appliedInterpolationFPS = nil
        if let handle { mpv_terminate_destroy(handle) }
        handle = nil
        smbSource = nil
        surface = nil
    }

    private func fail(_ message: String, code: Int32? = nil) {
        let detail = code.flatMap { mpv_error_string($0) }.map { String(cString: $0) }
        progress.error = detail.map { "\(message)\n\($0)" } ?? message
        publish()
    }

    private func publish() {
        let value = progress
        DispatchQueue.main.async { [weak self] in
            if self?.status != value { self?.status = value }
        }
    }

    @discardableResult
    private func setOption(_ name: String, _ value: String) -> Int32 {
        guard let handle else { return -1 }
        return mpv_set_option_string(handle, name, value)
    }

    @discardableResult
    private func setOptional(_ name: String, _ value: String) -> Int32 {
        guard let handle else { return -1 }
        return mpv_set_property_string(handle, name, value)
    }

    private func flag(_ name: String) -> Bool {
        guard let handle else { return false }
        var value: Int32 = 0
        return mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value) >= 0 && value != 0
    }

    private func double(_ name: String) -> Double {
        guard let handle else { return 0 }
        var value = 0.0
        guard mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0, value.isFinite else { return 0 }
        return value
    }

    private func integer(_ name: String) -> Int64 {
        guard let handle else { return 0 }
        var value: Int64 = 0
        return mpv_get_property(handle, name, MPV_FORMAT_INT64, &value) >= 0 ? value : 0
    }

    private func string(_ name: String) -> String? {
        guard let handle, let value = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(value) }
        return String(cString: value)
    }

    private func voPassDescriptions() -> [String] {
        var node = mpv_node()
        guard let handle, mpv_get_property(handle, "vo-passes", MPV_FORMAT_NODE, &node) >= 0 else {
            return []
        }
        defer { mpv_free_node_contents(&node) }

        guard node.format == MPV_FORMAT_NODE_MAP,
              let root = node.u.list?.pointee,
              root.num > 0,
              let rootKeys = root.keys,
              let rootValues = root.values
        else { return [] }

        var result: [String] = []
        for i in 0..<Int(root.num) {
            let key = rootKeys[i].map { String(cString: $0) }
            guard key == "fresh" || key == "redraw" else { continue }
            guard rootValues[i].format == MPV_FORMAT_NODE_ARRAY,
                  let list = rootValues[i].u.list?.pointee,
                  list.num > 0,
                  let items = list.values
            else { continue }

            for j in 0..<Int(list.num) {
                guard items[j].format == MPV_FORMAT_NODE_MAP,
                      let passMap = items[j].u.list?.pointee,
                      passMap.num > 0,
                      let pKeys = passMap.keys,
                      let pVals = passMap.values
                else { continue }

                for k in 0..<Int(passMap.num) {
                    let pKey = pKeys[k].map { String(cString: $0) }
                    guard pKey == "desc",
                          pVals[k].format == MPV_FORMAT_STRING,
                          let cStr = pVals[k].u.string
                    else { continue }
                    result.append(String(cString: cStr))
                }
            }
        }
        return result
    }

    private func command(_ arguments: String...) {
        guard let handle else { return }
        let buffers = arguments.map { strdup($0) }
        defer { buffers.forEach { free($0) } }
        guard buffers.allSatisfy({ $0 != nil }) else { return }
        var argv: [UnsafePointer<CChar>?] = buffers.map { $0.map { UnsafePointer($0) } }
        argv.append(nil)
        let status = mpv_command(handle, &argv)
        if status < 0, arguments.first == "loadfile" {
            fail("Không thể mở video.", code: status)
        }
    }
}

struct MPVSurface: UIViewRepresentable {
    var onResize: ((CGSize) -> Void)? = nil
    let attached: (CAMetalLayer, Bool, Int) -> Void

    func makeUIView(context: Context) -> RenderView {
        let view = RenderView()
        view.ready = attached
        view.onResize = onResize
        return view
    }

    func updateUIView(_ uiView: RenderView, context: Context) {
        uiView.onResize = onResize
    }

    final class RenderView: UIView {
        override class var layerClass: AnyClass { RenderLayer.self }
        var ready: ((CAMetalLayer, Bool, Int) -> Void)?
        var onResize: ((CGSize) -> Void)?
        private var lastDrawableSize: CGSize = .zero
        private var resizeWorkItem: DispatchWorkItem?

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let window, let layer = layer as? CAMetalLayer, bounds.width > 1, bounds.height > 1 else { return }
            let screen = window.screen
            let scale = screen.nativeScale
            let targetSize = CGSize(width: floor(bounds.width * scale), height: floor(bounds.height * scale))

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contentsScale = scale
            layer.contentsGravity = .resizeAspect
            layer.drawableSize = targetSize
            CATransaction.commit()

            if let ready {
                self.ready = nil
                self.lastDrawableSize = targetSize
                layer.framebufferOnly = true
                let edrAvailable = screen.potentialEDRHeadroom > 1.05
                let maxFPS = screen.maximumFramesPerSecond
                DispatchQueue.main.async { ready(layer, edrAvailable, maxFPS) }
            } else if abs(targetSize.width - lastDrawableSize.width) > 2
                || abs(targetSize.height - lastDrawableSize.height) > 2 {
                lastDrawableSize = targetSize
                resizeWorkItem?.cancel()
                let workItem = DispatchWorkItem { [weak self] in
                    self?.onResize?(targetSize)
                }
                resizeWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: workItem)
            }
        }
    }

    private final class RenderLayer: CAMetalLayer {
        override var drawableSize: CGSize {
            get { super.drawableSize }
            set {
                guard newValue.width > 1, newValue.height > 1 else { return }
                super.drawableSize = newValue
            }
        }

        override var wantsExtendedDynamicRangeContent: Bool {
            get { super.wantsExtendedDynamicRangeContent }
            set {
                if Thread.isMainThread {
                    super.wantsExtendedDynamicRangeContent = newValue
                } else {
                    DispatchQueue.main.sync {
                        super.wantsExtendedDynamicRangeContent = newValue
                    }
                }
            }
        }
    }
}
