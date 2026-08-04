import XCTest
@testable import HarcMobileSpikes

final class CodecSpikeQualificationTests: XCTestCase {
    func testUnavailableMemoryMeasurementCannotQualify() {
        let report = qualifyingReport(memoryMeasurementAvailable: false)
        XCTAssertFalse(report.passesCandidateDeviceThresholds)
    }

    func testUnknownThermalMeasurementCannotQualify() {
        let report = qualifyingReport(thermalMeasurementAvailable: false)
        XCTAssertFalse(report.passesCandidateDeviceThresholds)
    }

    func testSeriousThermalStateCannotQualifyEvenWhenSummaryFlagIsFalse() {
        let report = qualifyingReport(trialThermalState: "serious")
        XCTAssertFalse(report.passesCandidateDeviceThresholds)
    }

    func testCompleteKnownMeasurementsCanQualify() {
        XCTAssertTrue(qualifyingReport().passesCandidateDeviceThresholds)
    }

    func testSimulatorBuildCannotQualifyEvenWithPhysicalLookingLabel() {
        let report = qualifyingReport(simulatorBuild: true)
        XCTAssertFalse(report.passesCandidateDeviceThresholds)
    }

    func testIOSAppOnMacCannotQualifyEvenWithPhysicalLookingLabel() {
        let report = qualifyingReport(iOSAppOnMac: true)
        XCTAssertFalse(report.passesCandidateDeviceThresholds)
    }

    func testNonPhoneIdiomCannotQualify() {
        let report = qualifyingReport(userInterfaceIdiom: "pad")
        XCTAssertFalse(report.passesCandidateDeviceThresholds)
    }

    func testNonIPhoneHardwareIdentifierCannotQualify() {
        for model in ["arm64", "Mac15,3", "iPad16,1", "iPhone17", "iPhone17,1-extra"] {
            XCTAssertFalse(
                qualifyingReport(deviceModel: model).passesCandidateDeviceThresholds,
                "Unexpectedly qualified model identifier: \(model)"
            )
        }
    }

    func testOnlyCurrentQualificationSchemaCanQualify() {
        XCTAssertFalse(qualifyingReport(schemaVersion: 4).passesCandidateDeviceThresholds)
    }

    func testUnsignedOrUnidentifiedBuildCannotQualify() {
        XCTAssertFalse(
            qualifyingReport(signingTeamIdentifier: "").passesCandidateDeviceThresholds
        )
        XCTAssertFalse(
            qualifyingReport(bundleIdentifier: "com.example.Spike").passesCandidateDeviceThresholds
        )
    }

    func testReportAndProcessIdentifiersMustBeIndependent() {
        let identifier = UUID()
        XCTAssertFalse(
            qualifyingReport(
                reportUUID: identifier,
                processLaunchUUID: identifier
            ).passesCandidateDeviceThresholds
        )
    }

    func testSyntheticOneSecondReportCannotQualify() {
        let report = qualifyingReport(
            elapsedMonotonicSeconds: 1,
            wallDurationSeconds: 1,
            chunkDurationSeconds: 1,
            scheduledChunkCount: 1
        )
        XCTAssertFalse(report.passesCandidateDeviceThresholds)
    }

    func testCanonicalEnvelopeMustMatchThePhysicalProtocol() {
        XCTAssertFalse(
            qualifyingReport(canonicalFormat: "unknown").passesCandidateDeviceThresholds
        )
        XCTAssertFalse(
            qualifyingReport(operatingSystem: "  ").passesCandidateDeviceThresholds
        )
        XCTAssertFalse(
            qualifyingReport(wallDurationSeconds: -1).passesCandidateDeviceThresholds
        )
    }

    func testEveryOrdinaryChunkNeedsUniqueValidTrialEvidence() {
        XCTAssertFalse(
            qualifyingReport(trialIndexes: Array(0..<179)).passesCandidateDeviceThresholds
        )
        var duplicateIndexes = Array(0..<180)
        duplicateIndexes[179] = 178
        XCTAssertFalse(
            qualifyingReport(trialIndexes: duplicateIndexes).passesCandidateDeviceThresholds
        )
        var reorderedIndexes = Array(0..<180)
        reorderedIndexes.swapAt(0, 1)
        XCTAssertFalse(
            qualifyingReport(trialIndexes: reorderedIndexes).passesCandidateDeviceThresholds
        )
        XCTAssertFalse(
            qualifyingReport(validTrialHashes: false).passesCandidateDeviceThresholds
        )
    }

    private func qualifyingReport(
        schemaVersion: Int = 5,
        reportUUID: UUID = UUID(),
        processLaunchUUID: UUID = UUID(),
        elapsedMonotonicSeconds: Double = 10_800,
        wallDurationSeconds: TimeInterval = 10_800,
        memoryMeasurementAvailable: Bool = true,
        thermalMeasurementAvailable: Bool = true,
        simulatorBuild: Bool = false,
        iOSAppOnMac: Bool = false,
        userInterfaceIdiom: String = "phone",
        deviceModel: String = "iPhone17,1",
        operatingSystem: String = "iOS",
        bundleIdentifier: String = "com.harc.HarcMobileSpikes",
        signingTeamIdentifier: String = "63TNU5M7P4",
        canonicalFormat: String = "16000-hz-mono-signed-int16-little-endian",
        chunkDurationSeconds: Int = 60,
        scheduledChunkCount: Int = 180,
        trialIndexes: [Int]? = nil,
        validTrialHashes: Bool = true,
        trialThermalState: String = "nominal"
    ) -> CodecSpikeReport {
        let indexes = trialIndexes ?? Array(0..<scheduledChunkCount)
        let pcmHash = validTrialHashes ? String(repeating: "1", count: 64) : "invalid"
        let decodedHash = validTrialHashes ? pcmHash : String(repeating: "2", count: 64)
        let encodedHash = validTrialHashes ? String(repeating: "3", count: 64) : "invalid"
        let trials = indexes.map { index in
            CodecTrialEvidence(
                codec: .cafALAC,
                chunkIndex: index,
                canonicalFrames: 960_000,
                pcmSHA256: pcmHash,
                decodedPCM_SHA256: decodedHash,
                encodedSHA256: encodedHash,
                encodedBytes: 100,
                encodingMilliseconds: 25,
                decodingMilliseconds: 10,
                bitExact: true,
                residentBytesBefore: 100,
                residentBytesAfter: 110,
                peakResidentBytes: 120,
                memoryMeasurementAvailable: true,
                thermalStateBefore: trialThermalState,
                thermalStateAfter: trialThermalState,
                thermalMeasurementAvailable: true,
                seriousOrCriticalThermalObserved: false
            )
        }
        return CodecSpikeReport(
            schemaVersion: schemaVersion,
            reportUUID: reportUUID,
            processLaunchUUID: processLaunchUUID,
            mode: .threeHourRealTime,
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_000 + wallDurationSeconds),
            elapsedMonotonicSeconds: elapsedMonotonicSeconds,
            deviceModel: deviceModel,
            simulatorBuild: simulatorBuild,
            iOSAppOnMac: iOSAppOnMac,
            userInterfaceIdiom: userInterfaceIdiom,
            operatingSystem: operatingSystem,
            bundleIdentifier: bundleIdentifier,
            bundleShortVersion: "0.13.0",
            bundleVersion: "45",
            signingTeamIdentifier: signingTeamIdentifier,
            buildSHA: String(repeating: "a", count: 40),
            canonicalFormat: canonicalFormat,
            chunkDurationSeconds: chunkDurationSeconds,
            scheduledChunkCount: scheduledChunkCount,
            trials: trials,
            aggregates: [
                CodecAggregateEvidence(
                    codec: .cafALAC,
                    completedChunks: indexes.count,
                    failedChunks: 0,
                    p95EncodingMilliseconds: 25,
                    maximumEncodingMilliseconds: 25,
                    maximumIncrementalResidentBytes: 10 * 1_024 * 1_024,
                    maximumQueueDepth: 1,
                    memoryMeasurementAvailable: memoryMeasurementAvailable,
                    thermalMeasurementAvailable: thermalMeasurementAvailable,
                    seriousOrCriticalThermalObserved: false,
                    totalEncodedBytes: UInt64(indexes.count * 100),
                    bitExact: true
                ),
            ],
            failures: []
        )
    }
}
