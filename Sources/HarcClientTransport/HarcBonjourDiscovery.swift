#if canImport(Network)
import Dispatch
import Foundation
import HarcProtocol
import Network

public enum HarcBonjourDiscoveryParseError: Error, Equatable, Sendable {
    case endpointIsNotBonjourService
    case unexpectedServiceType(String)
    case invalidServiceName
    case invalidDomain
    case missingTXTRecord
    case invalidTXTRecord(HarcBonjourHintsV1Error)
}

/// An unauthenticated local-network route candidate. Every field remains
/// untrusted until the client completes pinned TLS and `GetHostInfo` against an
/// already adopted host authority.
public struct HarcUntrustedBonjourCandidateV1: Equatable, Sendable {
    public let endpoint: NWEndpoint
    public let serviceName: String
    public let domain: String
    public let hints: HarcBonjourServiceHintsV1

    public init(
        endpoint: NWEndpoint,
        serviceName: String,
        domain: String,
        hints: HarcBonjourServiceHintsV1
    ) {
        self.endpoint = endpoint
        self.serviceName = serviceName
        self.domain = domain
        self.hints = hints
    }
}

public struct HarcBonjourDiscoverySnapshotV1: Equatable, Sendable {
    public let candidates: [HarcUntrustedBonjourCandidateV1]
    public let rejectedResultCount: Int

    public init(
        candidates: [HarcUntrustedBonjourCandidateV1],
        rejectedResultCount: Int
    ) {
        self.candidates = candidates
        self.rejectedResultCount = rejectedResultCount
    }
}

public enum HarcBonjourDiscoveryParserV1 {
    public static func parse(
        endpoint: NWEndpoint,
        txtRecord: NWTXTRecord?
    ) throws -> HarcUntrustedBonjourCandidateV1 {
        guard case .service(
            let serviceName,
            let type,
            let domain,
            _
        ) = endpoint else {
            throw HarcBonjourDiscoveryParseError.endpointIsNotBonjourService
        }
        guard type == HarcBonjourServiceHintsV1.serviceType else {
            throw HarcBonjourDiscoveryParseError.unexpectedServiceType(type)
        }
        guard isValidServiceName(serviceName) else {
            throw HarcBonjourDiscoveryParseError.invalidServiceName
        }
        guard isValidDomain(domain) else {
            throw HarcBonjourDiscoveryParseError.invalidDomain
        }
        guard let txtRecord else {
            throw HarcBonjourDiscoveryParseError.missingTXTRecord
        }

        let hints: HarcBonjourServiceHintsV1
        do {
            hints = try HarcBonjourServiceHintsV1(
                txtRecord: txtRecord.dictionary
            )
        } catch let error as HarcBonjourHintsV1Error {
            throw HarcBonjourDiscoveryParseError.invalidTXTRecord(error)
        }
        return HarcUntrustedBonjourCandidateV1(
            endpoint: endpoint,
            serviceName: serviceName,
            domain: domain,
            hints: hints
        )
    }

    public static func parse(
        result: NWBrowser.Result
    ) throws -> HarcUntrustedBonjourCandidateV1 {
        let txtRecord: NWTXTRecord?
        switch result.metadata {
        case .bonjour(let record):
            txtRecord = record
        case .none:
            txtRecord = nil
        @unknown default:
            txtRecord = nil
        }
        return try parse(endpoint: result.endpoint, txtRecord: txtRecord)
    }

    public static func snapshot(
        from results: Set<NWBrowser.Result>
    ) -> HarcBonjourDiscoverySnapshotV1 {
        var candidates: [HarcUntrustedBonjourCandidateV1] = []
        var rejected = 0
        for result in results {
            do {
                candidates.append(try parse(result: result))
            } catch {
                rejected += 1
            }
        }
        candidates.sort {
            if $0.hints.displayName != $1.hints.displayName {
                return $0.hints.displayName < $1.hints.displayName
            }
            if $0.serviceName != $1.serviceName {
                return $0.serviceName < $1.serviceName
            }
            return $0.domain < $1.domain
        }
        return HarcBonjourDiscoverySnapshotV1(
            candidates: candidates,
            rejectedResultCount: rejected
        )
    }

    private static func isValidServiceName(_ value: String) -> Bool {
        let bytes = value.utf8.count
        return (1 ... 63).contains(bytes)
            && value == value.precomposedStringWithCanonicalMapping
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }

    private static func isValidDomain(_ value: String) -> Bool {
        let bytes = value.utf8.count
        return (1 ... 255).contains(bytes)
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }
}

public enum HarcBonjourDiscoveryStateV1: Equatable, Sendable {
    case ready
    case waiting(String)
    case failed(String)
    case cancelled
}

public enum HarcBonjourDiscoveryEventV1: Equatable, Sendable {
    case state(HarcBonjourDiscoveryStateV1)
    case snapshot(HarcBonjourDiscoverySnapshotV1)
}

public enum HarcBonjourDiscoveryBrowserError: Error, Equatable, Sendable {
    case alreadyStarted
}

/// Foreground/background policy remains with the caller: construction is
/// inert, and only the explicit `start()` call can trigger local-network
/// permission. The browser uses Network.framework's Bonjour descriptor and
/// never opens a custom multicast socket.
public actor HarcBonjourDiscoveryBrowserV1 {
    private let browser: NWBrowser
    private let callbackQueue: DispatchQueue
    private var started = false

    public init(
        callbackQueue: DispatchQueue = DispatchQueue(
            label: "com.harc.bonjour-browser"
        )
    ) {
        self.callbackQueue = callbackQueue
        self.browser = NWBrowser(
            for: .bonjourWithTXTRecord(
                type: HarcBonjourServiceHintsV1.serviceType,
                domain: nil
            ),
            using: .tcp
        )
    }

    public func start() throws -> AsyncStream<HarcBonjourDiscoveryEventV1> {
        guard !started else {
            throw HarcBonjourDiscoveryBrowserError.alreadyStarted
        }
        started = true

        let (stream, continuation) = AsyncStream.makeStream(
            of: HarcBonjourDiscoveryEventV1.self,
            bufferingPolicy: .bufferingNewest(8)
        )
        browser.stateUpdateHandler = { state in
            switch state {
            case .setup:
                return
            case .ready:
                continuation.yield(.state(.ready))
            case .waiting(let error):
                continuation.yield(
                    .state(.waiting(error.debugDescription))
                )
            case .failed(let error):
                continuation.yield(
                    .state(.failed(error.debugDescription))
                )
                continuation.finish()
            case .cancelled:
                continuation.yield(.state(.cancelled))
                continuation.finish()
            @unknown default:
                continuation.yield(
                    .state(.failed("Unknown Network.framework browser state"))
                )
                continuation.finish()
            }
        }
        browser.browseResultsChangedHandler = { results, _ in
            continuation.yield(
                .snapshot(
                    HarcBonjourDiscoveryParserV1.snapshot(from: results)
                )
            )
        }
        continuation.onTermination = { [browser] _ in browser.cancel() }
        browser.start(queue: callbackQueue)
        return stream
    }

    public func cancel() {
        browser.cancel()
    }
}
#endif
