import SwiftUI
import UIKit

final class AppOrientationDelegate: NSObject, UIApplicationDelegate {
    static var orientationMask: UIInterfaceOrientationMask = .allButUpsideDown

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.orientationMask
    }

    @MainActor
    static func setOrientation(_ mask: UIInterfaceOrientationMask) {
        orientationMask = mask
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        for window in scene.windows {
            var controller = window.rootViewController
            controller?.setNeedsUpdateOfSupportedInterfaceOrientations()
            while let presented = controller?.presentedViewController {
                presented.setNeedsUpdateOfSupportedInterfaceOrientations()
                controller = presented
            }
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }
}

@main
struct LocalCinemaApp: App {
    @UIApplicationDelegateAdaptor(AppOrientationDelegate.self) private var appDelegate
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
