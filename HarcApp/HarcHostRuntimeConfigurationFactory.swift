import Foundation
import HarcClientTransport
import HarcCore
import HarcDomain
import HarcHost
import HarcHostTransport
import HarcRemoteTransport
import LocalAuthentication
import Security

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
        let remoteRelay = try HarcRemoteRelayHostConfigurationStore
            .loadOrCreateIfEnabled(localControlPort: ports.controlPort)
        let remoteRelayRouteDeliveryPersistence = remoteRelay == nil
            ? nil
            : HarcRemoteRelayRouteDeliveryKeychainStore()

        return HarcResidentHostRuntimeConfigurationV1(
            storage: HarcResidentHostStorageConfiguration(
                canonicalDatabaseURL: canonicalDatabaseURL,
                hostDatabaseURL: hostDatabaseURL,
                stagingRoot: HarcHostStore.defaultStagingRoot(),
                listenerPorts: ports,
                localOSAuthenticationBoundary:
                    HarcMacLocalOSAuthenticationBoundary()
            ),
            canonicalAudioRoot: canonicalAudioRoot,
            backgroundRollbackRoot: rollbackRoot,
            temporaryUploadParent: temporaryRoot,
            displayName: Host.current().localizedName ?? "Harc Host",
            localDNSTarget: localDNSTarget(),
            acceptedEdgeEngineRevisions: [
                "harc-stt.\(HarcVersion.sttEngineVersion)"
            ],
            remoteRelay: remoteRelay,
            remoteRelayRouteDeliveryPersistence:
                remoteRelayRouteDeliveryPersistence
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

private actor HarcRemoteRelayRouteDeliveryKeychainStore:
    HarcRemoteRelayRouteDeliveryPersistence
{
    private struct Record: Codable, Sendable {
        let claimID: UUID
        let route: HarcRemoteRelayRouteV1
        let expiresAtMilliseconds: UInt64
    }

    private struct BindingRecord: Codable, Sendable {
        let deviceID: DeviceID
        let route: HarcRemoteRelayRouteV1
        let expiresAtMilliseconds: UInt64
    }

    private static let service = "com.harc.Harc.remote-relay.host-v1"
    private static let account = "approved-route-deliveries-v1"
    private static let bindingAccount = "approved-route-bindings-v1"

    func save(
        _ route: HarcRemoteRelayRouteV1,
        forClaimID claimID: UUID,
        expiresAtMilliseconds: UInt64
    ) async throws {
        let now = Self.nowMilliseconds()
        var records = try loadRecords().filter {
            $0.expiresAtMilliseconds > now && $0.claimID != claimID
        }
        guard expiresAtMilliseconds > now else {
            try saveRecords(records)
            return
        }
        records.append(
            Record(
                claimID: claimID,
                route: route,
                expiresAtMilliseconds: expiresAtMilliseconds
            )
        )
        try saveRecords(records)
    }

    func load(forClaimID claimID: UUID) async throws
        -> HarcRemoteRelayRouteV1?
    {
        let now = Self.nowMilliseconds()
        let stored = try loadRecords()
        let records = stored.filter { $0.expiresAtMilliseconds > now }
        if records.count != stored.count { try saveRecords(records) }
        return records.first { $0.claimID == claimID }?.route
    }

    func remove(forClaimID claimID: UUID) async throws {
        let now = Self.nowMilliseconds()
        let records = try loadRecords().filter {
            $0.expiresAtMilliseconds > now && $0.claimID != claimID
        }
        try saveRecords(records)
    }

    func saveBinding(
        _ route: HarcRemoteRelayRouteV1,
        forDeviceID deviceID: DeviceID,
        expiresAtMilliseconds: UInt64
    ) async throws {
        let now = Self.nowMilliseconds()
        var records = try loadBindingRecords().filter {
            $0.expiresAtMilliseconds > now && $0.deviceID != deviceID
        }
        guard expiresAtMilliseconds > now else {
            try saveBindingRecords(records)
            return
        }
        records.append(
            BindingRecord(
                deviceID: deviceID,
                route: route,
                expiresAtMilliseconds: expiresAtMilliseconds
            )
        )
        try saveBindingRecords(records)
    }

    func loadBinding(forDeviceID deviceID: DeviceID) async throws
        -> HarcRemoteRelayRouteV1?
    {
        let now = Self.nowMilliseconds()
        let stored = try loadBindingRecords()
        let records = stored.filter { $0.expiresAtMilliseconds > now }
        if records.count != stored.count { try saveBindingRecords(records) }
        return records.first { $0.deviceID == deviceID }?.route
    }

    func removeBinding(forDeviceID deviceID: DeviceID) async throws {
        let now = Self.nowMilliseconds()
        let records = try loadBindingRecords().filter {
            $0.expiresAtMilliseconds > now && $0.deviceID != deviceID
        }
        try saveBindingRecords(records)
    }

    private func loadRecords() throws -> [Record] {
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecUseAuthenticationContext as String: authenticationContext,
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else {
            throw HarcRemoteRelayHostConfigurationStoreError.keychain(status)
        }
        do {
            return try JSONDecoder().decode([Record].self, from: data)
        } catch {
            throw HarcRemoteRelayHostConfigurationStoreError.invalidStoredItem
        }
    }

    private func saveRecords(_ records: [Record]) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        guard !records.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw HarcRemoteRelayHostConfigurationStoreError
                    .keychain(status)
            }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(records)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw HarcRemoteRelayHostConfigurationStoreError
                .keychain(updateStatus)
        }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = kCFBooleanFalse
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw HarcRemoteRelayHostConfigurationStoreError
                .keychain(addStatus)
        }
    }

    private func loadBindingRecords() throws -> [BindingRecord] {
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.bindingAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecUseAuthenticationContext as String: authenticationContext,
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else {
            throw HarcRemoteRelayHostConfigurationStoreError.keychain(status)
        }
        do {
            return try JSONDecoder().decode([BindingRecord].self, from: data)
        } catch {
            throw HarcRemoteRelayHostConfigurationStoreError.invalidStoredItem
        }
    }

    private func saveBindingRecords(_ records: [BindingRecord]) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.bindingAccount,
        ]
        guard !records.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw HarcRemoteRelayHostConfigurationStoreError.keychain(status)
            }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(records)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw HarcRemoteRelayHostConfigurationStoreError
                .keychain(updateStatus)
        }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = kCFBooleanFalse
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw HarcRemoteRelayHostConfigurationStoreError
                .keychain(addStatus)
        }
    }

    private static func nowMilliseconds() -> UInt64 {
        UInt64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
    }
}

private enum HarcRemoteRelayHostConfigurationStore {
    private static let service = "com.harc.Harc.remote-relay.host-v1"
    private static let account = "opaque-host-route-v1"

    static func loadOrCreateIfEnabled(
        localControlPort: UInt16,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> HarcRemoteRelayHostConfigurationV1? {
        guard HarcRemoteRelayFeaturePolicy.isEnabled(
            environment: environment
        ) else { return nil }
        let configuredOrigin = environment["HARC_REMOTE_RELAY_ORIGIN"]
            ?? Bundle.main.object(
                forInfoDictionaryKey: "HarcRemoteRelayOrigin"
            ) as? String
        guard let configuredOrigin,
              let origin = URL(string: configuredOrigin) else {
            return nil
        }

        if let stored = try load() {
            guard stored.serviceOrigin == origin else {
                let replacement = try HarcRemoteRelayHostConfigurationV1
                    .generate(
                        serviceOrigin: origin,
                        localControlPort: localControlPort
                    )
                try save(replacement, replacing: true)
                return replacement
            }
            if stored.localControlPort == localControlPort { return stored }
            let updated = try HarcRemoteRelayHostConfigurationV1(
                serviceOrigin: stored.serviceOrigin,
                hostRouteID: stored.hostRouteID,
                hostCapability: stored.hostCapability,
                localControlPort: localControlPort
            )
            try save(updated, replacing: true)
            return updated
        }

        let created = try HarcRemoteRelayHostConfigurationV1.generate(
            serviceOrigin: origin,
            localControlPort: localControlPort
        )
        try save(created, replacing: false)
        return created
    }

    private static func load() throws
        -> HarcRemoteRelayHostConfigurationV1?
    {
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecUseAuthenticationContext as String: authenticationContext,
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw HarcRemoteRelayHostConfigurationStoreError.keychain(status)
        }
        do {
            return try JSONDecoder().decode(
                HarcRemoteRelayHostConfigurationV1.self,
                from: data
            )
        } catch {
            throw HarcRemoteRelayHostConfigurationStoreError.invalidStoredItem
        }
    }

    private static func save(
        _ configuration: HarcRemoteRelayHostConfigurationV1,
        replacing: Bool
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(configuration)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status: OSStatus
        if replacing {
            status = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
        } else {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] =
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            attributes[kSecAttrSynchronizable as String] = kCFBooleanFalse
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw HarcRemoteRelayHostConfigurationStoreError.keychain(status)
        }
    }
}

private enum HarcRemoteRelayHostConfigurationStoreError: LocalizedError {
    case keychain(OSStatus)
    case invalidStoredItem

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            "Harc Remote could not access its this-Mac Keychain identity (OSStatus \(status))."
        case .invalidStoredItem:
            "The stored Harc Remote Host identity is invalid."
        }
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
