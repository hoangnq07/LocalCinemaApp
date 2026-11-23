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
    var osdWidth = 0
    var osdHeight = 0
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
    private var isClosed = false
    private var isReconfiguringSurface = false
    private var lastConfiguredSize: CGSize = .zero
    private var openedURL: URL?
    private var openedSource: SMBReadSource?
    private var allExternalSubtitles: [URL] = []
    private var pendingSeekOnLoad: Double?
    private var pendingRestoreAid: Int?
    private var pendingRestoreSid: Int?
    private var pendingRestoreSecondarySid: Int?
    private var pendingRestorePaused: Bool?
    private var pendingResize: (layer: CAMetalLayer, size: CGSize, cleanupOld: () -> Void)?
    private var inFlightStageACleanup: (() -> Void)?

    private var currentDeband = false
    private var currentAudioOutput: AudioOutput = .automatic
    private var currentSpeed = 1.0
    private var currentVolume = 100.0
    private var currentAudioDelay = 0.0
    private var currentNightMode = false
    private var currentAspectMode: AspectMode = .fit
    private var currentZoom = 0.0
    private var currentBrightness = 0.0
    private var currentContrast = 0.0
    private var currentSaturation = 0.0
    private var currentGamma = 0.0
    private var currentSharpen = 0.0
    private var currentSubScale = 1.0
    private var currentSubPos = 92
    private var currentSubColor: SubtitleColorOption = .white
    private var currentSubBorder = 2.0
    private var currentSubBgOpacity = 0.0
    private var currentSubOffset = 0.0
    private var currentABLoopA: Double?
    private var currentABLoopB: Double?

    static func dimensionsMatch(osdWidth: Int, osdHeight: Int, target: CGSize) -> Bool {
        guard osdWidth > 0, osdHeight > 0, target.width > 1, target.height > 1 else { return false }
        let targetIsLandscape = target.width > target.height
        let osdIsLandscape = osdWidth > osdHeight
        if abs(target.width - target.height) > 20 && targetIsLandscape != osdIsLandscape {
            return false
        }
        let tolW = max(32.0, target.width * 0.15)
        let tolH = max(32.0, target.height * 0.15)
        return abs(Double(osdWidth) - target.width) <= tolW
            && abs(Double(osdHeight) - target.height) <= tolH
    }

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
            self.isClosed = false
            self.openedURL = url
            self.openedSource = source
            self.initialConfig = config
            self.edrAvailable = edrAvailable
            self.screenMaxFPS = max(60, screenMaxFPS)
            self.allExternalSubtitles = config.externalSubtitles
            self.pendingExternalSubtitles = config.externalSubtitles
            self.pendingSeekOnLoad = config.startTime > 0 ? config.startTime : nil
            self.pendingRestoreAid = nil
            self.pendingRestoreSid = nil
            self.pendingRestoreSecondarySid = nil
            self.pendingRestorePaused = nil

            self.currentUpscaler = config.upscaler
            self.currentHDRMode = config.hdrMode
            self.currentSDRToHDR = config.sdrToHDR
            self.currentInterpolation = config.interpolation
            self.currentInterpolationFPS = config.interpolationFPS
            self.currentDeband = config.deband
            self.currentAudioOutput = config.audioOutput
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

            self.progress.edrAvailable = edrAvailable
            self.progress.stats.edrHeadroom = edrAvailable ? 2.0 : 1.0

            self.startEngine(
                url: url,
                source: source,
                surface: surface,
                drawableSize: initialDrawableSize,
                config: config,
                startPaused: false
            )
        }
    }

    private func startEngine(
        url: URL,
        source: SMBReadSource?,
        surface: CAMetalLayer,
        drawableSize: CGSize,
        config: PlaybackConfiguration,
        startPaused: Bool
    ) {
        lastConfiguredSize = drawableSize
        guard let client = mpv_create() else {
            fail("Không thể khởi tạo trình phát.")
            return
        }
        handle = client
        self.surface = surface

        var surfaceAddress = Int64(bitPattern: UInt64(UInt(bitPattern: Unmanaged.passUnretained(surface).toOpaque())))
        let output = mpv_set_option(client, "wid", MPV_FORMAT_INT64, &surfaceAddress)
        if output < 0 {
            fail("Không thể khởi tạo lớp hiển thị video.", code: output)
            finish()
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
                fail("Không thể cấu hình trình phát (\(key)).", code: result)
                finish()
                return
            }
        }

        setOption("audio-channels", currentAudioOutput.option)
        setOption("volume-max", "200")
        setOption("demuxer-max-bytes", "67108864")
        setOption("demuxer-readahead-secs", "20")
        setOption("deband", currentDeband ? "yes" : "no")
        setOption("sub-scale-by-window", "yes")
        setOption("sub-outline-size", "2")
        setOption("secondary-sub-pos", "8")
        if startPaused {
            setOption("pause", "yes")
        }

        if !config.httpHeaders.isEmpty {
            let headerString = config.httpHeaders.map { "\($0.key): \($0.value)" }.joined(separator: ",")
            setOption("http-header-fields", headerString)
        }

        let initResult = mpv_initialize(client)
        if initResult < 0 {
            fail("Không thể khởi tạo trình phát.", code: initResult)
            finish()
            return
        }

        if let source {
            smbSource = source
            let status = source.register(on: client)
            guard status >= 0 else {
                fail("Không thể khởi tạo luồng SMB.", code: status)
                finish()
                return
            }
        }

        reconcileEnhancements(force: true)
        applyAllRuntimeSettings()

        let path = source?.uri ?? (url.isFileURL ? url.path : url.absoluteString)
        command("loadfile", path, "replace")

        let timer = DispatchSource.makeTimerSource(queue: work)
        timer.schedule(deadline: .now(), repeating: .milliseconds(160), leeway: .milliseconds(30))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }

    func close() {
        clearNowPlaying()
        work.async {
            self.isClosed = true
            self.finish()
        }
    }

    /// Rebinds libmpv's `gpu-next` + `moltenvk` output onto a fresh `CAMetalLayer` sized for the new
    /// orientation, verifying live `osd-dimensions` and transparently reopening the session at the
    /// current position if MoltenVK retains the stale portrait swapchain.
    func handleSurfaceResize(newLayer: CAMetalLayer, drawableSize: CGSize, cleanupOldLayer: @escaping () -> Void) {
        work.async {
            guard !self.isClosed,
                  let handle = self.handle,
                  self.progress.ready,
                  self.progress.error == nil,
                  drawableSize.width > 1,
                  drawableSize.height > 1 else {
                self.runCleanup(cleanupOldLayer)
                return
            }
            if self.isReconfiguringSurface {
                self.runCleanup(self.pendingResize?.cleanupOld)
                self.pendingResize = (newLayer, drawableSize, cleanupOldLayer)
                return
            }
            guard abs(drawableSize.width - self.lastConfiguredSize.width) > 2
                || abs(drawableSize.height - self.lastConfiguredSize.height) > 2 else {
                self.runCleanup(cleanupOldLayer)
                return
            }

            self.isReconfiguringSurface = true
            self.lastConfiguredSize = drawableSize
            self.surface = newLayer

            var newAddr = Int64(bitPattern: UInt64(UInt(bitPattern: Unmanaged.passUnretained(newLayer).toOpaque())))
            let widStatus = mpv_set_property(handle, "wid", MPV_FORMAT_INT64, &newAddr)
            if widStatus >= 0 {
                self.reconcileEnhancements(force: true)
                self.applyAllRuntimeSettings()
                self.inFlightStageACleanup = cleanupOldLayer
                self.work.asyncAfter(deadline: .now() + 0.30) { [weak self] in
                    guard let self else { return }
                    let activeCleanup = self.inFlightStageACleanup
                    self.inFlightStageACleanup = nil
                    guard !self.isClosed, self.handle != nil else {
                        self.runCleanup(activeCleanup)
                        self.finishSurfaceReconfiguration()
                        return
                    }
                    let osdW = Int(self.integer("osd-dimensions/w"))
                    let osdH = Int(self.integer("osd-dimensions/h"))
                    if Self.dimensionsMatch(osdWidth: osdW, osdHeight: osdH, target: drawableSize) {
                        self.progress.stats.osdWidth = osdW
                        self.progress.stats.osdHeight = osdH
                        self.publish()
                        self.runCleanup(activeCleanup)
                        self.finishSurfaceReconfiguration()
                    } else {
                        self.reopenOnSurface(
                            newLayer,
                            drawableSize: drawableSize,
                            cleanupOldLayer: activeCleanup ?? cleanupOldLayer
                        )
                    }
                }
            } else {
                self.reopenOnSurface(newLayer, drawableSize: drawableSize, cleanupOldLayer: cleanupOldLayer)
            }
        }
    }

    private func reopenOnSurface(
        _ newLayer: CAMetalLayer,
        drawableSize: CGSize,
        cleanupOldLayer: @escaping () -> Void
    ) {
        guard !isClosed, let url = openedURL else {
            runCleanup(cleanupOldLayer)
            finishSurfaceReconfiguration()
            return
        }

        let liveTime = double("time-pos")
        let dur = max(double("duration"), progress.duration)
        let eof = flag("eof-reached")
        let resumeTime: Double
        if eof && dur > 1.5 {
            resumeTime = max(0, dur - 1.5)
        } else if dur > 1.5 {
            resumeTime = min(max(0, liveTime), dur - 0.5)
        } else {
            resumeTime = max(0, liveTime)
        }
        let wasPaused = flag("pause") && !eof

        pendingRestoreAid = Int(string("aid") ?? "")
        let sidStr = string("sid")
        if sidStr == "no" || sidStr == nil {
            pendingRestoreSid = 0
        } else if let sidInt = Int(sidStr ?? ""), sidInt > 0 {
            pendingRestoreSid = sidInt
        } else {
            pendingRestoreSid = nil
        }
        if let secInt = Int(string("secondary-sid") ?? ""), secInt > 0 {
            pendingRestoreSecondarySid = secInt
        } else {
            pendingRestoreSecondarySid = nil
        }
        pendingRestorePaused = wasPaused ? true : nil
        pendingSeekOnLoad = resumeTime > 0 ? resumeTime : nil

        timer?.cancel()
        timer = nil
        appliedUpscaler = nil
        appliedHDRMode = nil
        appliedSDRToHDR = nil
        appliedInterpolation = nil
        appliedInterpolationFPS = nil
        if let oldHandle = handle {
            mpv_terminate_destroy(oldHandle)
        }
        handle = nil

        runCleanup(cleanupOldLayer)

        pendingExternalSubtitles = allExternalSubtitles
        nextTrackRead = Date.distantPast

        startEngine(
            url: url,
            source: openedSource,
            surface: newLayer,
            drawableSize: drawableSize,
            config: initialConfig,
            startPaused: wasPaused
        )
        finishSurfaceReconfiguration()
    }

    private func finishSurfaceReconfiguration() {
        isReconfiguringSurface = false
        guard !isClosed, let next = pendingResize else {
            if let stale = pendingResize {
                pendingResize = nil
                runCleanup(stale.cleanupOld)
            }
            return
        }
        pendingResize = nil
        handleSurfaceResize(newLayer: next.layer, drawableSize: next.size, cleanupOldLayer: next.cleanupOld)
    }

    private func runCleanup(_ cleanup: (() -> Void)?) {
        guard let cleanup else { return }
        DispatchQueue.main.async(execute: cleanup)
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
        work.async {
            self.currentDeband = enabled
            self.setOptional("deband", enabled ? "yes" : "no")
        }
    }

    func setAspectMode(_ mode: AspectMode) {
        work.async {
            self.currentAspectMode = mode
            self.applyAspectMode(mode)
        }
    }

    func setZoom(_ zoom: Double) {
        work.async {
            self.currentZoom = zoom
            self.setOptional("video-zoom", String(format: "%.2f", min(max(zoom, -0.5), 1.5)))
        }
    }

    func setColorAdjustments(brightness: Double, contrast: Double, saturation: Double, gamma: Double, sharpen: Double) {
        work.async {
            self.currentBrightness = brightness
            self.currentContrast = contrast
            self.currentSaturation = saturation
            self.currentGamma = gamma
            self.currentSharpen = sharpen
            self.applyColorAdjustments()
        }
    }

    // MARK: - Audio & Subtitles & Utilities

    func selectAudio(_ id: Int) { work.async { self.setOptional("aid", String(id)) } }
    func setOutput(_ audio: AudioOutput) {
        work.async {
            self.currentAudioOutput = audio
            self.setOptional("audio-channels", audio.option)
        }
    }
    func setVolume(_ percent: Double) {
        work.async {
            self.currentVolume = percent
            self.setOptional("volume", String(Int(min(max(percent, 0), 200))))
        }
    }
    func setAudioDelay(_ seconds: Double) {
        work.async {
            self.currentAudioDelay = seconds
            self.setOptional("audio-delay", String(format: "%.2f", seconds))
        }
    }

    func setNightMode(_ enabled: Bool) {
        work.async {
            self.currentNightMode = enabled
            self.applyNightMode(enabled)
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
            if !self.allExternalSubtitles.contains(url) {
                self.allExternalSubtitles.append(url)
            }
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
        work.async {
            self.currentSubOffset = seconds
            self.setOptional("sub-delay", String(format: "%.2f", seconds))
        }
    }

    func setSubtitleStyle(scale: Double, pos: Int, color: SubtitleColorOption, borderSize: Double, backgroundOpacity: Double) {
        work.async {
            self.currentSubScale = scale
            self.currentSubPos = pos
            self.currentSubColor = color
            self.currentSubBorder = borderSize
            self.currentSubBgOpacity = backgroundOpacity
            self.applySubtitleStyle()
        }
    }

    func setSpeed(_ speed: Double) {
        work.async {
            self.currentSpeed = speed
            self.setOptional("speed", String(format: "%.2f", speed))
        }
    }

    func setABLoop(a: Double?, b: Double?) {
        work.async {
            self.currentABLoopA = a
            self.currentABLoopB = b
            self.setOptional("ab-loop-a", a.map { String(format: "%.2f", $0) } ?? "no")
            self.setOptional("ab-loop-b", b.map { String(format: "%.2f", $0) } ?? "no")
        }
    }

    private func applyAspectMode(_ mode: AspectMode) {
        switch mode {
        case .fit:
            setOptional("keepaspect", "yes")
            setOptional("panscan", "0")
            setOptional("video-aspect-override", "-1")
        case .fill:
            setOptional("keepaspect", "yes")
            setOptional("panscan", "1")
            setOptional("video-aspect-override", "-1")
        case .stretch:
            setOptional("keepaspect", "no")
            setOptional("panscan", "0")
            setOptional("video-aspect-override", "-1")
        case .ratio16x9:
            setOptional("keepaspect", "yes")
            setOptional("panscan", "0")
            setOptional("video-aspect-override", "16:9")
        case .ratio21x9:
            setOptional("keepaspect", "yes")
            setOptional("panscan", "0")
            setOptional("video-aspect-override", "21:9")
        case .ratio4x3:
            setOptional("keepaspect", "yes")
            setOptional("panscan", "0")
            setOptional("video-aspect-override", "4:3")
        }
    }

    private func applyColorAdjustments() {
        setOptional("brightness", String(Int(currentBrightness)))
        setOptional("contrast", String(Int(currentContrast)))
        setOptional("saturation", String(Int(currentSaturation)))
        setOptional("gamma", String(Int(currentGamma)))
        setOptional("sharpen", String(format: "%.2f", currentSharpen))
    }

    private func applyNightMode(_ enabled: Bool) {
        setOptional("audio-normalize-downmix", enabled ? "yes" : "no")
        setOptional("af", enabled ? "lavfi=[dynaudnorm=f=150:g=15:p=0.9]" : "")
    }

    private func applySubtitleStyle() {
        setOptional("sub-scale", String(format: "%.2f", currentSubScale))
        setOptional("sub-pos", String(min(max(currentSubPos, 5), 100)))
        setOptional("sub-color", currentSubColor.mpvColor)
        setOptional("sub-outline-size", String(format: "%.1f", currentSubBorder))
        let alpha = Int(min(max(currentSubBgOpacity, 0), 1) * 255)
        let bgHex = String(format: "#%02X000000", alpha)
        setOptional("sub-back-color", bgHex)
    }

    private func applyAllRuntimeSettings() {
        setOptional("deband", currentDeband ? "yes" : "no")
        applyAspectMode(currentAspectMode)
        setOptional("video-zoom", String(format: "%.2f", min(max(currentZoom, -0.5), 1.5)))
        applyColorAdjustments()
        setOptional("audio-channels", currentAudioOutput.option)
        setOptional("volume", String(Int(min(max(currentVolume, 0), 200))))
        setOptional("audio-delay", String(format: "%.2f", currentAudioDelay))
        applyNightMode(currentNightMode)
        setOptional("sub-delay", String(format: "%.2f", currentSubOffset))
        applySubtitleStyle()
        setOptional("speed", String(format: "%.2f", currentSpeed))
        setOptional("ab-loop-a", currentABLoopA.map { String(format: "%.2f", $0) } ?? "no")
        setOptional("ab-loop-b", currentABLoopB.map { String(format: "%.2f", $0) } ?? "no")
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
                if let seekTarget = pendingSeekOnLoad, seekTarget > 0 {
                    command("seek", String(format: "%.3f", seekTarget), "absolute+exact")
                }
                pendingSeekOnLoad = nil
                for (index, subURL) in pendingExternalSubtitles.enumerated() {
                    let cleanTitle = Self.cleanSubtitleTitle(from: subURL)
                    command("sub-add", subURL.path, index == 0 ? "select" : "auto", cleanTitle)
                }
                pendingExternalSubtitles.removeAll()
                if let aid = pendingRestoreAid {
                    setOptional("aid", String(aid))
                    pendingRestoreAid = nil
                }
                if let sid = pendingRestoreSid {
                    setOptional("sid", sid == 0 ? "no" : String(sid))
                    pendingRestoreSid = nil
                }
                if let secSid = pendingRestoreSecondarySid {
                    setOptional("secondary-sid", String(secSid))
                    pendingRestoreSecondarySid = nil
                }
                if pendingRestorePaused == true {
                    setOptional("pause", "yes")
                }
                pendingRestorePaused = nil
                updateTracks()
                updateChapters()
                updateEnhancementAndStats()
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
            let liveOsdW = Int(integer("osd-dimensions/w"))
            let liveOsdH = Int(integer("osd-dimensions/h"))
            if liveOsdW > 0, liveOsdH > 0 {
                progress.stats.osdWidth = liveOsdW
                progress.stats.osdHeight = liveOsdH
            }

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
        stats.osdWidth = Int(integer("osd-dimensions/w"))
        stats.osdHeight = Int(integer("osd-dimensions/h"))
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
        runCleanup(inFlightStageACleanup)
        inFlightStageACleanup = nil
        if let pending = pendingResize {
            pendingResize = nil
            runCleanup(pending.cleanupOld)
        }
        isReconfiguringSurface = false
        if let handle { mpv_terminate_destroy(handle) }
        handle = nil
        openedURL = nil
        openedSource = nil
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
    var onResize: ((CAMetalLayer, CGSize, @escaping () -> Void) -> Void)? = nil
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
        var ready: ((CAMetalLayer, Bool, Int) -> Void)?
        var onResize: ((CAMetalLayer, CGSize, @escaping () -> Void) -> Void)?
        private var activeMetalLayer: RenderLayer?
        private var lastDrawableSize: CGSize = .zero
        private var resizeWorkItem: DispatchWorkItem?

        override init(frame: CGRect) {
            super.init(frame: frame)
            configureView()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            configureView()
        }

        deinit {
            resizeWorkItem?.cancel()
        }

        private func configureView() {
            backgroundColor = .black
            clipsToBounds = true
        }

        private func makeMetalLayer(bounds: CGRect, scale: CGFloat, drawableSize: CGSize, edr: Bool) -> RenderLayer {
            let metalLayer = RenderLayer()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            metalLayer.frame = bounds
            metalLayer.contentsScale = scale
            metalLayer.drawableSize = drawableSize
            metalLayer.framebufferOnly = true
            metalLayer.backgroundColor = UIColor.black.cgColor
            metalLayer.contentsGravity = .resizeAspect
            metalLayer.wantsExtendedDynamicRangeContent = edr
            CATransaction.commit()
            return metalLayer
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let window, bounds.width > 1, bounds.height > 1 else { return }
            let screen = window.screen
            let scale = screen.nativeScale
            let targetSize = CGSize(width: floor(bounds.width * scale), height: floor(bounds.height * scale))

            if let ready {
                self.ready = nil
                self.lastDrawableSize = targetSize
                let metalLayer = makeMetalLayer(bounds: bounds, scale: scale, drawableSize: targetSize, edr: false)
                layer.addSublayer(metalLayer)
                activeMetalLayer = metalLayer
                let edrAvailable = screen.potentialEDRHeadroom > 1.05
                let maxFPS = screen.maximumFramesPerSecond
                DispatchQueue.main.async { ready(metalLayer, edrAvailable, maxFPS) }
                return
            }

            if let activeMetalLayer {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                activeMetalLayer.frame = bounds
                CATransaction.commit()
            }

            guard abs(targetSize.width - lastDrawableSize.width) > 2
                || abs(targetSize.height - lastDrawableSize.height) > 2 else {
                return
            }

            resizeWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, let window = self.window, self.bounds.width > 1, self.bounds.height > 1 else { return }
                let finalScale = window.screen.nativeScale
                let finalSize = CGSize(
                    width: floor(self.bounds.width * finalScale),
                    height: floor(self.bounds.height * finalScale)
                )
                guard abs(finalSize.width - self.lastDrawableSize.width) > 2
                    || abs(finalSize.height - self.lastDrawableSize.height) > 2 else {
                    return
                }
                self.lastDrawableSize = finalSize
                let oldLayer = self.activeMetalLayer
                let newLayer = self.makeMetalLayer(
                    bounds: self.bounds,
                    scale: finalScale,
                    drawableSize: finalSize,
                    edr: oldLayer?.wantsExtendedDynamicRangeContent ?? false
                )
                self.layer.addSublayer(newLayer)
                self.activeMetalLayer = newLayer
                self.onResize?(newLayer, finalSize) {
                    oldLayer?.removeFromSuperlayer()
                }
            }
            resizeWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
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
