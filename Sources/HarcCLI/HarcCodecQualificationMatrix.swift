import Foundation

enum HarcCodecQualificationRole: CaseIterable, Hashable, Sendable {
    case oldestALAC
    case oldestFLAC
    case currentALAC
    case currentFLAC

    var label: String {
        switch self {
        case .oldestALAC: "oldest device CAF+ALAC"
        case .oldestFLAC: "oldest device FLAC"
        case .currentALAC: "current device CAF+ALAC"
        case .currentFLAC: "current device FLAC"
        }
    }

    var expectedCodec: HarcCodecQualificationReport.Codec {
        switch self {
        case .oldestALAC, .currentALAC: .cafALAC
        case .oldestFLAC, .currentFLAC: .flac
        }
    }

    func expectedDevice(for command: HarcCodecQualificationMatrixCommand) -> String {
        switch self {
        case .oldestALAC, .oldestFLAC: command.oldestDevice
        case .currentALAC, .currentFLAC: command.currentDevice
        }
    }
}

struct HarcCodecQualificationMatrixSummary: Sendable {
    struct Row: Sendable {
        let role: HarcCodecQualificationRole
        let deviceModel: String
        let operatingSystem: String
        let codec: HarcCodecQualificationReport.Codec
        let p95EncodingMilliseconds: Double
        let maximumQueueDepth: Int
        let maximumIncrementalResidentBytes: UInt64
        let totalEncodedBytes: UInt64
    }

    let buildSHA: String
    let bundleShortVersion: String
    let bundleVersion: String
    let rows: [Row]
}

enum HarcCodecQualificationMatrixError: Error, CustomStringConvertible {
    case invalidExpectation(String)
    case missingReport(HarcCodecQualificationRole)
    case unreadableReport(role: HarcCodecQualificationRole, path: String, message: String)
    case invalidReport(role: HarcCodecQualificationRole, reason: String)

    var description: String {
        switch self {
        case .invalidExpectation(let reason):
            "Invalid qualification expectation: \(reason)"
        case .missingReport(let role):
            "Missing \(role.label) report."
        case .unreadableReport(let role, let path, let message):
            "Could not read \(role.label) report at \(path): \(message)"
        case .invalidReport(let role, let reason):
            "Rejected \(role.label) report: \(reason)"
        }
    }
}

enum HarcCodecQualificationMatrixValidator {
    private static let schemaVersion = 5
    private static let canonicalFormat = "16000-hz-mono-signed-int16-little-endian"
    private static let chunkCount = 180
    private static let framesPerChunk: UInt64 = 960_000
    private static let minimumElapsedSeconds = 10_800.0
    private static let maximumIncrementalResidentBytes: UInt64 = 100 * 1_024 * 1_024

    static func loadAndValidate(
        _ command: HarcCodecQualificationMatrixCommand
    ) throws -> HarcCodecQualificationMatrixSummary {
        let paths: [HarcCodecQualificationRole: String] = [
            .oldestALAC: command.oldestALACReport,
            .oldestFLAC: command.oldestFLACReport,
            .currentALAC: command.currentALACReport,
            .currentFLAC: command.currentFLACReport,
        ]
        var reportData: [HarcCodecQualificationRole: Data] = [:]
        for role in HarcCodecQualificationRole.allCases {
            guard let path = paths[role] else {
                throw HarcCodecQualificationMatrixError.missingReport(role)
            }
            do {
                reportData[role] = try Data(contentsOf: URL(fileURLWithPath: path))
            } catch {
                throw HarcCodecQualificationMatrixError.unreadableReport(
                    role: role,
                    path: path,
                    message: error.localizedDescription
                )
            }
        }
        return try validate(command, reportData: reportData)
    }

    static func validate(
        _ command: HarcCodecQualificationMatrixCommand,
        reportData: [HarcCodecQualificationRole: Data]
    ) throws -> HarcCodecQualificationMatrixSummary {
        try validateExpectations(command)

        var reports: [(HarcCodecQualificationRole, HarcCodecQualificationReport)] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for role in HarcCodecQualificationRole.allCases {
            guard let data = reportData[role] else {
                throw HarcCodecQualificationMatrixError.missingReport(role)
            }
            do {
                reports.append((role, try decoder.decode(HarcCodecQualificationReport.self, from: data)))
            } catch {
                throw HarcCodecQualificationMatrixError.invalidReport(
                    role: role,
                    reason: "invalid schema-5 JSON: \(error.localizedDescription)"
                )
            }
        }

        var rows: [HarcCodecQualificationMatrixSummary.Row] = []
        for (role, report) in reports {
            rows.append(try validateReport(report, role: role, command: command))
        }

        let reportIDs = Set(reports.map(\.1.reportUUID))
        guard reportIDs.count == reports.count else {
            throw HarcCodecQualificationMatrixError.invalidExpectation(
                "every matrix cell must use a distinct report UUID"
            )
        }
        let processIDs = Set(reports.map(\.1.processLaunchUUID))
        guard processIDs.count == reports.count else {
            throw HarcCodecQualificationMatrixError.invalidExpectation(
                "each candidate/device run must come from a fresh app process"
            )
        }

        return HarcCodecQualificationMatrixSummary(
            buildSHA: command.buildSHA,
            bundleShortVersion: command.version,
            bundleVersion: command.build,
            rows: rows
        )
    }

    private static func validateExpectations(
        _ command: HarcCodecQualificationMatrixCommand
    ) throws {
        guard command.oldestDevice != command.currentDevice else {
            throw HarcCodecQualificationMatrixError.invalidExpectation(
                "oldest and current hardware identifiers must be different"
            )
        }
        for device in [command.oldestDevice, command.currentDevice] {
            guard isIPhoneHardwareIdentifier(device) else {
                throw HarcCodecQualificationMatrixError.invalidExpectation(
                    "\(device) is not an iPhone hardware identifier"
                )
            }
        }
        guard isLowercaseHex(command.buildSHA, count: 40) else {
            throw HarcCodecQualificationMatrixError.invalidExpectation(
                "build SHA must be exactly 40 lowercase hexadecimal characters"
            )
        }
        guard isTeamIdentifier(command.teamID) else {
            throw HarcCodecQualificationMatrixError.invalidExpectation(
                "team ID must be exactly 10 uppercase alphanumeric characters"
            )
        }
        guard !trimmed(command.version).isEmpty, !trimmed(command.build).isEmpty else {
            throw HarcCodecQualificationMatrixError.invalidExpectation(
                "version and build must be nonempty"
            )
        }
    }

    private static func validateReport(
        _ report: HarcCodecQualificationReport,
        role: HarcCodecQualificationRole,
        command: HarcCodecQualificationMatrixCommand
    ) throws -> HarcCodecQualificationMatrixSummary.Row {
        func reject(_ reason: String) throws -> Never {
            throw HarcCodecQualificationMatrixError.invalidReport(role: role, reason: reason)
        }

        guard report.schemaVersion == schemaVersion else {
            try reject("expected schema \(schemaVersion), got \(report.schemaVersion)")
        }
        guard report.reportUUID != report.processLaunchUUID else {
            try reject("report and process-launch UUIDs must be independent")
        }
        guard report.mode == "threeHourRealTime" else {
            try reject("quick or unknown modes cannot qualify")
        }
        guard report.deviceModel == role.expectedDevice(for: command) else {
            try reject("expected device \(role.expectedDevice(for: command)), got \(report.deviceModel)")
        }
        guard !report.simulatorBuild, !report.iOSAppOnMac else {
            try reject("Simulator and iOS-app-on-Mac evidence is diagnostic only")
        }
        guard report.userInterfaceIdiom == "phone",
              isIPhoneHardwareIdentifier(report.deviceModel) else {
            try reject("report is not from a physical iPhone")
        }
        guard !trimmed(report.operatingSystem).isEmpty else {
            try reject("operating-system identity is empty")
        }
        guard report.bundleIdentifier == "com.harc.HarcMobileSpikes",
              report.bundleShortVersion == command.version,
              report.bundleVersion == command.build,
              report.signingTeamIdentifier == command.teamID,
              report.buildSHA == command.buildSHA else {
            try reject("sealed bundle, version, team, or source identity does not match the matrix")
        }
        guard report.canonicalFormat == canonicalFormat,
              report.chunkDurationSeconds == 60,
              report.scheduledChunkCount == chunkCount else {
            try reject("canonical format or three-hour chunk schedule is incorrect")
        }
        let wallSeconds = report.endedAt.timeIntervalSince(report.startedAt)
        guard report.elapsedMonotonicSeconds.isFinite,
              report.elapsedMonotonicSeconds >= minimumElapsedSeconds,
              wallSeconds.isFinite,
              wallSeconds >= minimumElapsedSeconds else {
            try reject("run did not sustain at least three real-time hours")
        }
        guard report.failures.isEmpty else {
            try reject("report contains \(report.failures.count) chunk failures")
        }
        guard report.trials.count == chunkCount,
              report.aggregates.count == 1 else {
            try reject("expected 180 trials and exactly one codec aggregate")
        }

        let aggregate = report.aggregates[0]
        guard aggregate.codec == role.expectedCodec else {
            try reject("expected \(role.expectedCodec.rawValue), got \(aggregate.codec.rawValue)")
        }

        var encodingMilliseconds: [Double] = []
        var totalEncodedBytes: UInt64 = 0
        for (expectedIndex, trial) in report.trials.enumerated() {
            guard trial.codec == role.expectedCodec,
                  trial.chunkIndex == expectedIndex,
                  trial.canonicalFrames == framesPerChunk else {
                try reject("trial \(expectedIndex) has the wrong codec, index, or frame count")
            }
            guard isLowercaseHex(trial.pcmSHA256, count: 64),
                  isLowercaseHex(trial.decodedPCMSHA256, count: 64),
                  isLowercaseHex(trial.encodedSHA256, count: 64),
                  trial.pcmSHA256 == trial.decodedPCMSHA256,
                  trial.bitExact,
                  trial.encodedBytes > 0 else {
                try reject("trial \(expectedIndex) is not bit-exact or has invalid hashes/length")
            }
            guard trial.encodingMilliseconds.isFinite,
                  trial.encodingMilliseconds >= 0,
                  trial.decodingMilliseconds.isFinite,
                  trial.decodingMilliseconds >= 0 else {
                try reject("trial \(expectedIndex) has invalid timing")
            }
            guard trial.memoryMeasurementAvailable,
                  trial.peakResidentBytes >= trial.residentBytesBefore,
                  trial.peakResidentBytes >= trial.residentBytesAfter else {
                try reject("trial \(expectedIndex) lacks valid memory evidence")
            }
            guard trial.thermalMeasurementAvailable,
                  isSafeThermalState(trial.thermalStateBefore),
                  isSafeThermalState(trial.thermalStateAfter),
                  !trial.seriousOrCriticalThermalObserved else {
                try reject("trial \(expectedIndex) lacks safe thermal evidence")
            }
            let addition = totalEncodedBytes.addingReportingOverflow(trial.encodedBytes)
            guard !addition.overflow else {
                try reject("encoded byte total overflowed")
            }
            totalEncodedBytes = addition.partialValue
            encodingMilliseconds.append(trial.encodingMilliseconds)
        }

        let sorted = encodingMilliseconds.sorted()
        let p95Index = Int(ceil(Double(sorted.count) * 0.95)) - 1
        let observedP95 = sorted[p95Index]
        let observedMaximum = sorted[sorted.count - 1]
        guard aggregate.completedChunks == chunkCount,
              aggregate.failedChunks == 0,
              aggregate.bitExact,
              aggregate.p95EncodingMilliseconds == observedP95,
              aggregate.p95EncodingMilliseconds < 10_000,
              aggregate.maximumEncodingMilliseconds == observedMaximum,
              (1...2).contains(aggregate.maximumQueueDepth),
              aggregate.memoryMeasurementAvailable,
              aggregate.maximumIncrementalResidentBytes < maximumIncrementalResidentBytes,
              aggregate.thermalMeasurementAvailable,
              !aggregate.seriousOrCriticalThermalObserved,
              aggregate.totalEncodedBytes == totalEncodedBytes else {
            try reject("aggregate metrics do not reproduce the trials or exceed a release threshold")
        }

        return HarcCodecQualificationMatrixSummary.Row(
            role: role,
            deviceModel: report.deviceModel,
            operatingSystem: report.operatingSystem,
            codec: aggregate.codec,
            p95EncodingMilliseconds: aggregate.p95EncodingMilliseconds,
            maximumQueueDepth: aggregate.maximumQueueDepth,
            maximumIncrementalResidentBytes: aggregate.maximumIncrementalResidentBytes,
            totalEncodedBytes: aggregate.totalEncodedBytes
        )
    }

    private static func isIPhoneHardwareIdentifier(_ value: String) -> Bool {
        guard value.hasPrefix("iPhone") else { return false }
        let components = value.dropFirst("iPhone".count).split(
            separator: ",",
            omittingEmptySubsequences: false
        )
        let asciiDigits = CharacterSet(charactersIn: "0123456789")
        return components.count == 2 && components.allSatisfy {
            !$0.isEmpty && $0.unicodeScalars.allSatisfy(asciiDigits.contains)
        }
    }

    private static func isTeamIdentifier(_ value: String) -> Bool {
        value.count == 10 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ").contains($0)
        }
    }

    private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.count == count && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }

    private static func isSafeThermalState(_ value: String) -> Bool {
        value == "nominal" || value == "fair"
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct HarcCodecQualificationReport: Decodable, Sendable {
    enum Codec: String, Decodable, Sendable {
        case cafALAC = "caf-alac"
        case flac
    }

    struct Trial: Decodable, Sendable {
        let codec: Codec
        let chunkIndex: Int
        let canonicalFrames: UInt64
        let pcmSHA256: String
        let decodedPCMSHA256: String
        let encodedSHA256: String
        let encodedBytes: UInt64
        let encodingMilliseconds: Double
        let decodingMilliseconds: Double
        let bitExact: Bool
        let residentBytesBefore: UInt64
        let residentBytesAfter: UInt64
        let peakResidentBytes: UInt64
        let memoryMeasurementAvailable: Bool
        let thermalStateBefore: String
        let thermalStateAfter: String
        let thermalMeasurementAvailable: Bool
        let seriousOrCriticalThermalObserved: Bool

        private enum CodingKeys: String, CodingKey {
            case codec
            case chunkIndex
            case canonicalFrames
            case pcmSHA256
            case decodedPCMSHA256 = "decodedPCM_SHA256"
            case encodedSHA256
            case encodedBytes
            case encodingMilliseconds
            case decodingMilliseconds
            case bitExact
            case residentBytesBefore
            case residentBytesAfter
            case peakResidentBytes
            case memoryMeasurementAvailable
            case thermalStateBefore
            case thermalStateAfter
            case thermalMeasurementAvailable
            case seriousOrCriticalThermalObserved
        }
    }

    struct Aggregate: Decodable, Sendable {
        let codec: Codec
        let completedChunks: Int
        let failedChunks: Int
        let p95EncodingMilliseconds: Double
        let maximumEncodingMilliseconds: Double
        let maximumIncrementalResidentBytes: UInt64
        let maximumQueueDepth: Int
        let memoryMeasurementAvailable: Bool
        let thermalMeasurementAvailable: Bool
        let seriousOrCriticalThermalObserved: Bool
        let totalEncodedBytes: UInt64
        let bitExact: Bool
    }

    struct Failure: Decodable, Sendable {
        let codec: Codec
        let chunkIndex: Int
        let message: String
    }

    let schemaVersion: Int
    let reportUUID: UUID
    let processLaunchUUID: UUID
    let mode: String
    let startedAt: Date
    let endedAt: Date
    let elapsedMonotonicSeconds: Double
    let deviceModel: String
    let simulatorBuild: Bool
    let iOSAppOnMac: Bool
    let userInterfaceIdiom: String
    let operatingSystem: String
    let bundleIdentifier: String
    let bundleShortVersion: String
    let bundleVersion: String
    let signingTeamIdentifier: String
    let buildSHA: String
    let canonicalFormat: String
    let chunkDurationSeconds: Int
    let scheduledChunkCount: Int
    let trials: [Trial]
    let aggregates: [Aggregate]
    let failures: [Failure]
}
