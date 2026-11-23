import Foundation
import Network

struct DiscoveredLANHost: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let serviceType: String
    let suggestedScheme: String

    var kindLabel: String {
        switch serviceType {
        case "_smb._tcp": return "SMB"
        case "_webdav._tcp", "_webdavs._tcp": return "WebDAV"
        default: return "HTTP / Media"
        }
    }

    var hostURI: String {
        let cleaned = name.replacingOccurrences(of: " ", with: "-")
        return "\(suggestedScheme)://\(cleaned).local"
    }
}

@MainActor
final class LANDiscovery: ObservableObject {
    @Published private(set) var hosts: [DiscoveredLANHost] = []
    @Published private(set) var scanning = false

    private var browsers: [NWBrowser] = []
    private let queue = DispatchQueue(label: "com.local.cinema.mdns")

    func start() {
        stop()
        scanning = true
        let descriptors: [(String, String)] = [
            ("_smb._tcp", "smb"),
            ("_webdav._tcp", "http"),
            ("_webdavs._tcp", "https"),
            ("_http._tcp", "http")
        ]
        for (serviceType, scheme) in descriptors {
            let params = NWParameters()
            params.includePeerToPeer = true
            let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: params)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                let mapped: [DiscoveredLANHost] = results.compactMap { result in
                    guard case .service(let name, let type, _, _) = result.endpoint else { return nil }
                    return DiscoveredLANHost(
                        id: "\(type)::\(name)",
                        name: name,
                        serviceType: type,
                        suggestedScheme: scheme
                    )
                }
                Task { @MainActor [weak self] in
                    self?.merge(mapped, serviceType: serviceType)
                }
            }
            browser.start(queue: queue)
            browsers.append(browser)
        }
    }

    func stop() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        scanning = false
    }

    private func merge(_ incoming: [DiscoveredLANHost], serviceType: String) {
        let others = hosts.filter { $0.serviceType != serviceType }
        let combined = (others + incoming).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        hosts = combined
    }
}
