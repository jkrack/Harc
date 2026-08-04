import Foundation
@testable import HarcCLI
import Testing

@Suite("physical codec qualification matrix")
struct HarcCodecQualificationMatrixTests {
    private let buildSHA = String(repeating: "a", count: 40)

    @Test("four fresh physical schema-5 reports qualify")
    func completeMatrix() throws {
        let summary = try HarcCodecQualificationMatrixValidator.validate(
            command(),
            reportData: reports()
        )
        #expect(summary.rows.count == 4)
        #expect(summary.rows.map(\.codec.rawValue) == [
            "caf-alac", "flac", "caf-alac", "flac",
        ])
    }

    @Test("a reused app process cannot satisfy two matrix cells")
    func requiresFreshProcesses() {
        let processID = UUID()
        var evidence = reports()
        evidence[.oldestALAC] = report(
            device: "iPhone14,7",
            codec: "caf-alac",
            processID: processID
        )
        evidence[.oldestFLAC] = report(
            device: "iPhone14,7",
            codec: "flac",
            processID: processID
        )
        #expect(throws: (any Error).self) {
            try HarcCodecQualificationMatrixValidator.validate(
                command(),
                reportData: evidence
            )
        }
    }

    @Test("simulator, build drift, and threshold drift fail closed")
    func invalidEvidence() {
        var simulator = reports()
        simulator[.currentALAC] = report(
            device: "iPhone17,3",
            codec: "caf-alac",
            simulatorBuild: true
        )
        #expect(throws: (any Error).self) {
            try HarcCodecQualificationMatrixValidator.validate(
                command(),
                reportData: simulator
            )
        }

        var wrongBuild = reports()
        wrongBuild[.currentFLAC] = report(
            device: "iPhone17,3",
            codec: "flac",
            reportBuildSHA: String(repeating: "b", count: 40)
        )
        #expect(throws: (any Error).self) {
            try HarcCodecQualificationMatrixValidator.validate(
                command(),
                reportData: wrongBuild
            )
        }

        var slow = reports()
        slow[.oldestALAC] = report(
            device: "iPhone14,7",
            codec: "caf-alac",
            encodingMilliseconds: 10_000
        )
        #expect(throws: (any Error).self) {
            try HarcCodecQualificationMatrixValidator.validate(
                command(),
                reportData: slow
            )
        }

        var seriousThermalState = reports()
        seriousThermalState[.oldestFLAC] = report(
            device: "iPhone14,7",
            codec: "flac",
            thermalState: "serious"
        )
        #expect(throws: (any Error).self) {
            try HarcCodecQualificationMatrixValidator.validate(
                command(),
                reportData: seriousThermalState
            )
        }
    }

    @Test("oldest and current roles require distinct named iPhones")
    func distinctDevices() {
        #expect(throws: (any Error).self) {
            try HarcCodecQualificationMatrixValidator.validate(
                command(currentDevice: "iPhone14,7"),
                reportData: reports()
            )
        }
        #expect(throws: (any Error).self) {
            try HarcCodecQualificationMatrixValidator.validate(
                command(currentDevice: "Simulator iPhone17,3"),
                reportData: reports()
            )
        }
    }

    private func command(
        currentDevice: String = "iPhone17,3"
    ) -> HarcCodecQualificationMatrixCommand {
        HarcCodecQualificationMatrixCommand(
            oldestDevice: "iPhone14,7",
            currentDevice: currentDevice,
            buildSHA: buildSHA,
            teamID: "63TNU5M7P4",
            version: "0.13.0",
            build: "45",
            oldestALACReport: "oldest-alac.json",
            oldestFLACReport: "oldest-flac.json",
            currentALACReport: "current-alac.json",
            currentFLACReport: "current-flac.json"
        )
    }

    private func reports() -> [HarcCodecQualificationRole: Data] {
        [
            .oldestALAC: report(device: "iPhone14,7", codec: "caf-alac"),
            .oldestFLAC: report(device: "iPhone14,7", codec: "flac"),
            .currentALAC: report(device: "iPhone17,3", codec: "caf-alac"),
            .currentFLAC: report(device: "iPhone17,3", codec: "flac"),
        ]
    }

    private func report(
        device: String,
        codec: String,
        processID: UUID = UUID(),
        simulatorBuild: Bool = false,
        reportBuildSHA: String? = nil,
        encodingMilliseconds: Double = 25,
        thermalState: String = "nominal"
    ) -> Data {
        let hash1 = String(repeating: "1", count: 64)
        let hash2 = String(repeating: "2", count: 64)
        let trials: [[String: Any]] = (0..<180).map { index in
            [
                "codec": codec,
                "chunkIndex": index,
                "canonicalFrames": 960_000,
                "pcmSHA256": hash1,
                "decodedPCM_SHA256": hash1,
                "encodedSHA256": hash2,
                "encodedBytes": 100,
                "encodingMilliseconds": encodingMilliseconds,
                "decodingMilliseconds": 10.0,
                "bitExact": true,
                "residentBytesBefore": 100,
                "residentBytesAfter": 110,
                "peakResidentBytes": 120,
                "memoryMeasurementAvailable": true,
                "thermalStateBefore": thermalState,
                "thermalStateAfter": thermalState,
                "thermalMeasurementAvailable": true,
                "seriousOrCriticalThermalObserved": false,
            ]
        }
        let object: [String: Any] = [
            "schemaVersion": 5,
            "reportUUID": UUID().uuidString,
            "processLaunchUUID": processID.uuidString,
            "mode": "threeHourRealTime",
            "startedAt": "2026-08-04T00:00:00Z",
            "endedAt": "2026-08-04T03:00:00Z",
            "elapsedMonotonicSeconds": 10_800.0,
            "deviceModel": device,
            "simulatorBuild": simulatorBuild,
            "iOSAppOnMac": false,
            "userInterfaceIdiom": "phone",
            "operatingSystem": "Version 26.5",
            "bundleIdentifier": "com.harc.HarcMobileSpikes",
            "bundleShortVersion": "0.13.0",
            "bundleVersion": "45",
            "signingTeamIdentifier": "63TNU5M7P4",
            "buildSHA": reportBuildSHA ?? buildSHA,
            "canonicalFormat": "16000-hz-mono-signed-int16-little-endian",
            "chunkDurationSeconds": 60,
            "scheduledChunkCount": 180,
            "trials": trials,
            "aggregates": [[
                "codec": codec,
                "completedChunks": 180,
                "failedChunks": 0,
                "p95EncodingMilliseconds": encodingMilliseconds,
                "maximumEncodingMilliseconds": encodingMilliseconds,
                "maximumIncrementalResidentBytes": 10 * 1_024 * 1_024,
                "maximumQueueDepth": 1,
                "memoryMeasurementAvailable": true,
                "thermalMeasurementAvailable": true,
                "seriousOrCriticalThermalObserved": false,
                "totalEncodedBytes": 18_000,
                "bitExact": true,
            ]],
            "failures": [],
        ]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
