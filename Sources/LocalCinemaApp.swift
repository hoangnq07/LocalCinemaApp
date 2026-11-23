import SwiftUI

@main
struct LocalCinemaApp: App {
    @StateObject private var library = MediaLibrary()
    @StateObject private var smbProfiles = SMBProfiles()
    @StateObject private var webdavProfiles = WebDAVProfiles()
    @StateObject private var serverStore = MediaServerStore()

    var body: some Scene {
        WindowGroup {
            RootTabView(
                library: library,
                smbProfiles: smbProfiles,
                webdavProfiles: webdavProfiles,
                serverStore: serverStore
            )
            .preferredColorScheme(.dark)
            .tint(CinemaStyle.accent)
        }
    }
}
