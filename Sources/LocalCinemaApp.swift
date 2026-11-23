import SwiftUI

@main
struct LocalCinemaApp: App {
    @StateObject private var library = MediaLibrary()

    var body: some Scene {
        WindowGroup {
            CinemaHome(library: library)
                .preferredColorScheme(.dark)
                .tint(CinemaStyle.accent)
        }
    }
}
