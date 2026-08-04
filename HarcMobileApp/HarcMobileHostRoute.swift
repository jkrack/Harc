import Foundation
import HarcAudioMobile
import HarcProtocol

struct HarcMobileHostRoute: Codable, Equatable, Sendable {
    let host: String
    let port: UInt16
    let serverHostname: String

    init(ticket: PairingTicketV1) throws {
        guard let endpoint = ticket.endpoints.first(where: {
            $0.kind == .dnsHost
        }),
              let host = endpoint.textValue,
              !host.isEmpty,
              endpoint.port > 0 else {
            throw HarcMobileHostRouteError.noDNSRoute
        }
        self.host = host
        port = endpoint.port
        serverHostname = host
    }
}

enum HarcMobileHostRouteError: LocalizedError {
    case noDNSRoute

    var errorDescription: String? {
        "The pairing code does not contain a directly connectable Host route."
    }
}

enum HarcMobileHostRouteStore {
    static func load(from url: URL) throws -> HarcMobileHostRoute {
        try JSONDecoder().decode(
            HarcMobileHostRoute.self,
            from: Data(contentsOf: url, options: .mappedIfSafe)
        )
    }

    static func save(_ route: HarcMobileHostRoute, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(route).write(to: url, options: .atomic)
        try FoundationHarcMobileCaptureStorageAttributes().applyAndVerify(
            .transferArtifact,
            to: url
        )
    }
}
