import Foundation
import Libmpv
import QuartzCore
import SwiftUI
import UIKit

struct PlaybackTrack: Identifiable, Equatable {
    let id: Int
    let label: String
    let selected: Bool
}

struct PlaybackStatus: Equatable {
    var ready = false
    var paused = false
    var buffering = false
    var time = 0.0
    var duration = 0.0
    var audio: [PlaybackTrack] = []
    var subtitles: [PlaybackTrack] = []
    var videoSize: String?
    var outputChannels = 0
    var neuralUpscalingActive = false
    var error: String?
}

enum VideoScaling: String, CaseIterable, Identifiable {
    case standard, quality, neural
    var id: Self { self }
    var label: String {
        switch self {
        case .standard: return "Tiêu chuẩn"
        case .quality: return "Lanczos sắc nét"
        case .neural: return "Siêu phân giải FSRCNNX ×2"
        }
    }
    var filter: String { self == .standard ? "bilinear" : "ewa_lanczossharp" }
}

enum AudioOutput: String, CaseIterable, Identifiable {
    case automatic, stereo
    var id: Self { self }
    var label: String { self == .automatic ? "Tự động theo thiết bị" : "Stereo" }
    var option: String { self == .automatic ? "auto" : "stereo" }
}

final class MPVPlayback: ObservableObject {
    @Published private(set) var status = PlaybackStatus()

    private let work = DispatchQueue(label: "com.local.cinema.playback", qos: .userInitiated)
    private var handle: OpaquePointer?
    private var surface: CAMetalLayer?
    private var timer: DispatchSourceTimer?
    private var progress = PlaybackStatus()
    private var initialTime = 0.0
    private var nextTrackRead = Date.distantPast
    private var currentScaler = VideoScaling.standard

    func open(_ url: URL, surface: CAMetalLayer, start: Double, scaler: VideoScaling, audio: AudioOutput) {
        work.async {
            guard self.handle == nil else { return }
            guard let client = mpv_create() else {
                self.fail("Không thể khởi tạo trình phát.")
                return
            }
            self.handle = client
            self.surface = surface
            self.initialTime = start
            var surfaceAddress = Int64(bitPattern: UInt64(UInt(bitPattern: Unmanaged.passUnretained(surface).toOpaque())))
            let output = mpv_set_option(client, "wid", MPV_FORMAT_INT64, &surfaceAddress)
            if output < 0 {
                self.fail("Không thể khởi tạo lớp hiển thị video.", code: output)
                self.finish()
                return
            }

            let options = [
                "config": "no",
                "load-scripts": "no",
                "load-unsafe-playlists": "no",
                "terminal": "no",
                "input-default-bindings": "no",
                "vo": "gpu-next",
                "gpu-api": "vulkan",
                "gpu-context": "moltenvk",
                "hwdec": "videotoolbox",
                "ao": "audiounit",
                "audio-channels": audio.option,
                "keep-open": "yes",
                "sub-auto": "no",
                "audio-file-auto": "no"
            ]
            for (key, value) in options {
                let result = mpv_set_option_string(client, key, value)
                if result < 0 {
                    self.fail("Không thể cấu hình trình phát (\(key)).", code: result)
                    self.finish()
                    return
                }
            }

            let result = mpv_initialize(client)
            if result < 0 {
                self.fail("Không thể khởi tạo trình phát.", code: result)
                self.finish()
                return
            }
            self.applyScaling(scaler)
            self.command("loadfile", url.isFileURL ? url.path : url.absoluteString, "replace")
            let timer = DispatchSource.makeTimerSource(queue: self.work)
            timer.schedule(deadline: .now(), repeating: .milliseconds(160), leeway: .milliseconds(30))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
        }
    }

    func close() { work.async { self.finish() } }

    func togglePause() {
        work.async {
            if self.flag("eof-reached") {
                self.command("seek", "0", "absolute+exact")
                self.set("pause", "no")
            } else {
                self.set("pause", self.flag("pause") ? "no" : "yes")
            }
        }
    }

    func pause() { work.async { self.set("pause", "yes") } }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        work.async { self.command("seek", String(max(0, seconds)), "absolute+exact") }
    }

    func seek(by seconds: Int) {
        work.async { self.command("seek", String(seconds), "relative+exact") }
    }

    func selectAudio(_ id: Int) { work.async { self.set("aid", String(id)) } }
    func selectSubtitle(_ id: Int?) { work.async { self.set("sid", id.map(String.init) ?? "no") } }
    func setSubtitleOffset(_ seconds: Double) { work.async { self.set("sub-delay", String(seconds)) } }
    func setSpeed(_ speed: Double) { work.async { self.set("speed", String(speed)) } }
    func setScaling(_ scale: VideoScaling) { work.async { self.applyScaling(scale) } }
    func setOutput(_ audio: AudioOutput) { work.async { self.set("audio-channels", audio.option) } }

    private func poll() {
        guard let handle else { return }
        while let event = mpv_wait_event(handle, 0)?.pointee, event.event_id != MPV_EVENT_NONE {
            switch event.event_id {
            case MPV_EVENT_FILE_LOADED:
                progress.ready = true
                if initialTime > 0 { command("seek", String(initialTime), "absolute+exact") }
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
            progress.paused = flag("pause") || flag("eof-reached")
            progress.buffering = flag("paused-for-cache")
            progress.time = double("time-pos")
            progress.duration = double("duration")
            if Date() >= nextTrackRead {
                updateTracks()
                updateScalingStatus()
                nextTrackRead = Date().addingTimeInterval(0.75)
            }
        }
        publish()
    }

    private func applyScaling(_ scaling: VideoScaling) {
        currentScaler = scaling
        progress.neuralUpscalingActive = false
        set("scale", scaling.filter)
        if scaling == .neural,
           let shader = Bundle.main.url(forResource: "FSRCNNX_x2_8-0-4-1", withExtension: "glsl",
                                        subdirectory: "Shaders") {
            command("change-list", "glsl-shaders", "set", shader.path)
        } else {
            command("change-list", "glsl-shaders", "clr", "")
        }
        publish()
    }

    private func updateScalingStatus() {
        guard currentScaler == .neural else { return }
        let count = min(max(Int(integer("vo-passes/fresh/count")), 0), 128)
        progress.neuralUpscalingActive = (0..<count).contains { index in
            // The upstream shader's final "aggregation" pass outputs the doubled luma plane.
            string("vo-passes/fresh/\(index)/desc")?.localizedCaseInsensitiveContains("aggregation") == true
        }
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
        let width = integer("width")
        let height = integer("height")
        progress.videoSize = width > 0 && height > 0 ? "\(width) × \(height)" : nil
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

    private func finish() {
        timer?.cancel()
        timer = nil
        if let handle { mpv_terminate_destroy(handle) }
        handle = nil
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

    private func set(_ name: String, _ value: String) {
        guard let handle else { return }
        mpv_set_property_string(handle, name, value)
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
    let attached: (CAMetalLayer) -> Void

    func makeUIView(context: Context) -> RenderView {
        let view = RenderView()
        view.ready = attached
        return view
    }

    func updateUIView(_ uiView: RenderView, context: Context) {}

    final class RenderView: UIView {
        override class var layerClass: AnyClass { RenderLayer.self }
        var ready: ((CAMetalLayer) -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let window, let layer = layer as? CAMetalLayer, bounds.width > 1, bounds.height > 1 else { return }
            let scale = window.screen.nativeScale
            layer.contentsScale = scale
            layer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            if let ready {
                self.ready = nil
                layer.framebufferOnly = true
                DispatchQueue.main.async { ready(layer) }
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
    }
}
