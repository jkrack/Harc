import Foundation
import HarcHost
import HarcHostTransport

enum HarcHostRuntimeConfigurationFactory {
    static func make(
        canonicalDatabaseURL: URL,
        canonicalAudioRoot: URL
    ) throws -> HarcResidentHostRuntimeConfigurationV1 {
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Harc", isDirectory: true)
        let rollbackRoot = applicationSupport.appendingPathComponent(
            "BackgroundUploadRollback",
            isDirectory: true
        )
        let temporaryRoot = applicationSupport.appendingPathComponent(
            "UploadTemporary",
            isDirectory: true
        )
        for directory in [applicationSupport, rollbackRoot, temporaryRoot] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        let hostDatabaseURL = HarcHostStore.defaultDatabaseURL()
        let ports: HarcHostListenerPorts
        if let persisted = try HarcHostStore.inspectListenerPorts(
            onDiskAt: hostDatabaseURL
        ) {
            ports = persisted
        } else {
            ports = try freshListenerPorts()
        }

        return HarcResidentHostRuntimeConfigurationV1(
            storage: HarcResidentHostStorageConfiguration(
                canonicalDatabaseURL: canonicalDatabaseURL,
                hostDatabaseURL: hostDatabaseURL,
                stagingRoot: HarcHostStore.defaultStagingRoot(),
                listenerPorts: ports
            ),
            canonicalAudioRoot: canonicalAudioRoot,
            backgroundRollbackRoot: rollbackRoot,
            temporaryUploadParent: temporaryRoot,
            displayName: Host.current().localizedName ?? "Harc Host",
            localDNSTarget: localDNSTarget()
        )
    }

    private static func freshListenerPorts() throws -> HarcHostListenerPorts {
        let control = UInt16.random(in: 49_152 ... 65_535)
        var upload = UInt16.random(in: 49_152 ... 65_535)
        while upload == control {
            upload = UInt16.random(in: 49_152 ... 65_535)
        }
        return try HarcHostListenerPorts(
            controlPort: control,
            uploadPort: upload
        )
    }

    private static func localDNSTarget() -> String {
        let rawLabel = ProcessInfo.processInfo.hostName
            .lowercased()
            .split(separator: ".", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? "harc-host"
        let scalars = rawLabel.unicodeScalars.map { scalar -> Character in
            let value = scalar.value
            if (48 ... 57).contains(value) || (97 ... 122).contains(value)
                || value == 45 {
                return Character(String(scalar))
            }
            return "-"
        }
        var label = String(scalars)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if label.isEmpty { label = "harc-host" }
        if label.count > 63 { label = String(label.prefix(63)) }
        return label + ".local"
    }
}

actor HarcHostProcessingWorkerBox {
    private var worker: HarcHostProcessingWorker?

    func install(_ worker: HarcHostProcessingWorker) throws {
        guard self.worker == nil else {
            throw HarcHostApplicationRuntimeError.processingWorkerAlreadyInstalled
        }
        self.worker = worker
    }

    func requireWorker() throws -> HarcHostProcessingWorker {
        guard let worker else {
            throw HarcHostApplicationRuntimeError.processingWorkerMissing
        }
        return worker
    }
}

actor HarcHostMCPServerBox {
    private var server: HarcLocalMCPIPCServer?

    func install(_ server: HarcLocalMCPIPCServer) throws {
        guard self.server == nil else {
            throw HarcHostApplicationRuntimeError.mcpServerAlreadyInstalled
        }
        self.server = server
    }

    func requireServer() throws -> HarcLocalMCPIPCServer {
        guard let server else {
            throw HarcHostApplicationRuntimeError.mcpServerMissing
        }
        return server
    }

    func installedServer() -> HarcLocalMCPIPCServer? {
        server
    }
}

enum HarcHostApplicationRuntimeError: LocalizedError {
    case processingWorkerAlreadyInstalled
    case processingWorkerMissing
    case mcpServerAlreadyInstalled
    case mcpServerMissing
    case clientModeNotImplemented

    var errorDescription: String? {
        switch self {
        case .processingWorkerAlreadyInstalled:
            "The Host processing worker was installed more than once."
        case .processingWorkerMissing:
            "The Host processing worker was not installed."
        case .mcpServerAlreadyInstalled:
            "The Host MCP server was installed more than once."
        case .mcpServerMissing:
            "The Host MCP server was not installed."
        case .clientModeNotImplemented:
            "Desktop Client mode is not available in this build."
        }
    }
}
