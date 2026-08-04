import Foundation
import HarcCLI
import HarcIdentity
import Testing

@Suite("harcctl command and state boundary")
struct HarcCLIArgumentParserTests {
    @Test("pair defaults to a Mac client and preserves explicit state")
    func pairDefaults() throws {
        #expect(try HarcCLIArgumentParser.parse([
            "pair",
            "--ticket", "harc-pair://v1/example",
            "--state-dir", "/tmp/harc-cli-test",
        ]) == .pair(
            ticketURI: "harc-pair://v1/example",
            clientKind: .macClient,
            deviceLabel: nil,
            stateDirectory: "/tmp/harc-cli-test"
        ))
    }

    @Test("pair supports the mobile minimal-scope identity kind")
    func mobilePair() throws {
        #expect(try HarcCLIArgumentParser.parse([
            "pair",
            "--kind", "mobile",
            "--label", "Field iPhone",
            "--ticket", "ticket",
        ]) == .pair(
            ticketURI: "ticket",
            clientKind: .mobile,
            deviceLabel: "Field iPhone",
            stateDirectory: nil
        ))
    }

    @Test("security-sensitive options are single-valued and strict")
    func strictOptions() {
        #expect(throws: HarcCLIArgumentError.requiredOption("--ticket")) {
            try HarcCLIArgumentParser.parse(["pair"])
        }
        #expect(throws: HarcCLIArgumentError.duplicateOption("--ticket")) {
            try HarcCLIArgumentParser.parse([
                "pair", "--ticket", "one", "--ticket", "two",
            ])
        }
        #expect(throws: HarcCLIArgumentError.unknownOption("--secret-file")) {
            try HarcCLIArgumentParser.parse([
                "pair", "--ticket", "one", "--secret-file", "bad",
            ])
        }
    }

    @Test("fixture duration is finite positive and bounded")
    func fixtureDuration() throws {
        #expect(try HarcCLIArgumentParser.parse([
            "upload-fixture", "--seconds", "0.5",
        ]) == .uploadFixture(seconds: 0.5, stateDirectory: nil))
        #expect(throws: HarcCLIArgumentError.invalidValue(
            option: "--seconds",
            value: "31"
        )) {
            try HarcCLIArgumentParser.parse([
                "upload-fixture", "--seconds", "31",
            ])
        }
    }

    @Test("codec matrix parser requires every physical evidence cell")
    func codecQualificationMatrix() throws {
        let buildSHA = String(repeating: "a", count: 40)
        #expect(try HarcCLIArgumentParser.parse([
            "qualify-codec-matrix",
            "--oldest-device", "iPhone14,7",
            "--current-device", "iPhone17,3",
            "--build-sha", buildSHA,
            "--team-id", "63TNU5M7P4",
            "--version", "0.13.0",
            "--build", "45",
            "--oldest-alac", "/reports/oldest-alac.json",
            "--oldest-flac", "/reports/oldest-flac.json",
            "--current-alac", "/reports/current-alac.json",
            "--current-flac", "/reports/current-flac.json",
        ]) == .qualifyCodecMatrix(HarcCodecQualificationMatrixCommand(
            oldestDevice: "iPhone14,7",
            currentDevice: "iPhone17,3",
            buildSHA: buildSHA,
            teamID: "63TNU5M7P4",
            version: "0.13.0",
            build: "45",
            oldestALACReport: "/reports/oldest-alac.json",
            oldestFLACReport: "/reports/oldest-flac.json",
            currentALACReport: "/reports/current-alac.json",
            currentFLACReport: "/reports/current-flac.json"
        )))

        #expect(throws: HarcCLIArgumentError.requiredOption("--current-device")) {
            try HarcCLIArgumentParser.parse([
                "qualify-codec-matrix",
                "--oldest-device", "iPhone14,7",
            ])
        }
    }

    @Test("route persistence contains only nonsecret connection metadata")
    func routePersistence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("route.json")
        let route = try HarcCLIRoute(
            host: "studio-mini.local",
            port: 8443,
            serverHostname: "studio-mini.local"
        )
        try HarcCLIRouteStore.save(route, to: url)
        #expect(try HarcCLIRouteStore.load(from: url) == route)

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("ticket"))
        #expect(!text.contains("secret"))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
