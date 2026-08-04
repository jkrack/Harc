import Foundation
import HarcDomain
import HarcHost
import HarcHostTransport
import HarcStore

/// Chooses the canonical-library authority at the moment each MCP tool call
/// begins. A long-lived stdio helper must not retain a Standalone writer lease:
/// doing so would prevent the app from transitioning that library to Host.
actor HarcMCPModeRoutingCaller: HarcMCPToolCalling {
    typealias MetadataInspector = @Sendable (URL) throws -> LibraryWriterMode?
    typealias StandaloneFactory = @Sendable (URL) async throws -> any HarcMCPToolCalling
    typealias HostFactory = @Sendable () throws -> any HarcMCPToolCalling

    private static let readOnlyTools: Set<String> = [
        "search_notes",
        "get_recording",
        "list_recent",
    ]

    private let databaseURL: URL
    private let permitsDefaultHostSocket: Bool
    private let metadataInspector: MetadataInspector
    private let standaloneFactory: StandaloneFactory
    private let hostFactory: HostFactory
    private var hostCaller: (any HarcMCPToolCalling)?

    init(databaseURL: URL) {
        let normalizedURL = databaseURL.resolvingSymlinksInPath().standardizedFileURL
        let normalizedDefault = RecordingStore.defaultURL()
            .resolvingSymlinksInPath().standardizedFileURL
        self.init(
            databaseURL: databaseURL,
            permitsDefaultHostSocket: normalizedURL == normalizedDefault,
            metadataInspector: { url in
                var isDirectory = ObjCBool(false)
                guard FileManager.default.fileExists(
                    atPath: url.path,
                    isDirectory: &isDirectory
                ), !isDirectory.boolValue else {
                    return nil
                }
                return try RecordingStore.inspectLibraryMetadata(
                    onDiskAt: url
                ).writerMode
            },
            standaloneFactory: { url in
                HarcMCPToolService(
                    store: try await RecordingStore
                        .onDiskForExternalAuthorityRouting(url: url)
                )
            },
            hostFactory: {
                let authorizer = try HarcMCPCodeSigningPeerAuthorizer(
                    expectedOwnIdentifier: "com.harc.Harc.mcp"
                )
                return HarcLocalMCPIPCClient(authorizer: authorizer)
            }
        )
    }

    init(
        databaseURL: URL,
        permitsDefaultHostSocket: Bool,
        metadataInspector: @escaping MetadataInspector,
        standaloneFactory: @escaping StandaloneFactory,
        hostFactory: @escaping HostFactory
    ) {
        self.databaseURL = databaseURL
        self.permitsDefaultHostSocket = permitsDefaultHostSocket
        self.metadataInspector = metadataInspector
        self.standaloneFactory = standaloneFactory
        self.hostFactory = hostFactory
    }

    func call(_ request: HarcMCPToolRequest) async -> HarcMCPToolResponse {
        guard HarcMCPToolService.allowedToolNames.contains(request.name) else {
            return Self.failure("Unknown tool: \(request.name)")
        }

        do {
            if try currentWriterMode() == .host {
                return try await callHost(request)
            }

            // Do not cache this caller. Releasing it after one request releases
            // its Standalone lifetime lease so Host adoption can proceed.
            let caller: any HarcMCPToolCalling
            do {
                caller = try await standaloneFactory(databaseURL)
            } catch {
                // If adoption won the race before any tool was issued, every
                // operation is safe to redirect exactly once through Host.
                if Self.isAuthorityUnavailable(error) {
                    return try await callHost(request)
                }
                if try currentWriterMode() == .host {
                    return try await callHost(request)
                }
                throw error
            }

            let response = await caller.call(request)
            if response.failureReason == .authorityUnavailable {
                // The store guarantees this reason is emitted only when lock
                // or marker validation rejected access before the tool body.
                return try await callHost(request)
            }
            guard response.isError,
                  Self.readOnlyTools.contains(request.name),
                  try currentWriterMode() == .host else {
                return response
            }
            // Read-only calls are safe to replay if Host adoption happened
            // while the direct service was executing. Mutations are never
            // replayed after issuance because append_note is not idempotent.
            return try await callHost(request)
        } catch {
            return Self.failure(Self.publicMessage(for: error))
        }
    }

    private func currentWriterMode() throws -> LibraryWriterMode {
        try metadataInspector(databaseURL) ?? .standalone
    }

    private func callHost(
        _ request: HarcMCPToolRequest
    ) async throws -> HarcMCPToolResponse {
        guard permitsDefaultHostSocket else {
            throw HarcMCPRoutingError.nonDefaultHostLibrary
        }
        let caller: any HarcMCPToolCalling
        if let hostCaller {
            caller = hostCaller
        } else {
            let created = try hostFactory()
            hostCaller = created
            caller = created
        }
        return await caller.call(request)
    }

    private static func publicMessage(for error: Error) -> String {
        if let routingError = error as? HarcMCPRoutingError {
            return routingError.localizedDescription
        }
        if let storeError = error as? StoreError,
           case .migrationFailed(let reason) = storeError {
            return "Harc's database is newer than this helper. Update Harc, then reconnect. (\(reason))"
        }
        return "The Harc library is unavailable. Open Harc and try again."
    }

    private static func isAuthorityUnavailable(_ error: Error) -> Bool {
        guard let storeError = error as? StoreError else { return false }
        return storeError == .writerLeaseUnavailable
            || storeError == .staleHostWriterMarker
    }

    private static func failure(_ text: String) -> HarcMCPToolResponse {
        HarcMCPToolResponse(text: text, isError: true)
    }
}

private enum HarcMCPRoutingError: LocalizedError {
    case nonDefaultHostLibrary

    var errorDescription: String? {
        switch self {
        case .nonDefaultHostLibrary:
            "A Host-owned --db override cannot use the default Harc Host socket. Use the canonical library configured in Harc."
        }
    }
}
