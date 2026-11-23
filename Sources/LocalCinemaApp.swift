import AVKit
import Foundation
import SwiftUI

@main
struct LocalCinemaApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @AppStorage("serverURL") private var serverURL = "http://192.168.1.1:8080"
    @State private var streamURL = ""
    @State private var playback: Playback?

    private var videoURL: URL? {
        let input = streamURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.hasPrefix("/"), !input.hasPrefix("//") {
            let server = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let baseURL = URL(string: server), baseURL.isHTTPURL else {
                return nil
            }
            return URL(string: input, relativeTo: baseURL)?.absoluteURL
        }

        guard let url = URL(string: input), url.isHTTPURL else {
            return nil
        }
        return url
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Máy chủ nội bộ") {
                    TextField("http://192.168.1.1:8080", text: $serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Phát thử video (MP4/MOV)") {
                    TextField("Link HTTP(S) hoặc /stream/...", text: $streamURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button("Phát bằng AVPlayer") {
                        if let videoURL {
                            playback = Playback(player: AVPlayer(url: videoURL))
                        }
                    }
                    .disabled(videoURL == nil)
                }
            }
            .navigationTitle("Local Cinema")
            .sheet(item: $playback) { video in
                VideoPlayer(player: video.player)
                    .ignoresSafeArea()
                    .onAppear { video.player.play() }
                    .onDisappear { video.player.pause() }
            }
        }
    }
}

private struct Playback: Identifiable {
    let id = UUID()
    let player: AVPlayer
}

private extension URL {
    var isHTTPURL: Bool {
        let scheme = scheme?.lowercased()
        return (scheme == "http" || scheme == "https") && host?.isEmpty == false
    }
}
