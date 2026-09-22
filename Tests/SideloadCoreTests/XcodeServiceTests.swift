import Foundation
import Security
import XCTest
@testable import SideloadCore

final class XcodeServiceTests: XCTestCase {
    func testDeviceListUsesUDIDAndKeepsAvailablePhoneWithDeveloperModeDisabled() throws {
        let phone = device(identifier: "core-device-uuid", udid: "00008150-TEST", name: "Phone",
                           reality: "physical", visibility: "default", connection: "connected", developerMode: false)
        let tablet = device(identifier: "tablet-core-id", udid: "tablet-udid", name: "Tablet",
                            reality: "physical", visibility: "default", type: "iPad", connection: "connected", developerMode: true)
        let simulator = device(identifier: "sim-id", udid: "sim-udid", name: "Simulator",
                               reality: "simulated", visibility: "simulators", developerMode: true)
        let unavailable = device(identifier: "old-id", udid: "old-udid", name: "Old phone",
                                 reality: "physical", visibility: "hidden", developerMode: true)
        let television = device(identifier: "tv-id", udid: "tv-udid", name: "TV",
                                reality: "physical", visibility: "default", type: "AppleTV", developerMode: true)
        let deprecatedOnly: [String: Any] = ["identifier": "obsolete", "hardwareProperties": ["reality": "physical"]]
        let data = try JSONSerialization.data(withJSONObject: [
            "result": ["devices": [phone, tablet, simulator, unavailable, television, deprecatedOnly, phone]]
        ])
        var requested: [String] = []
        let result = try XcodeService.devices(from: data) { id in
            requested.append(id)
            return try JSONSerialization.data(withJSONObject: ["result": id == "00008150-TEST" ? phone : tablet])
        }
        XCTAssertEqual(result.map(\.id), ["00008150-TEST", "tablet-udid"])
        XCTAssertEqual(result.map(\.osVersion), ["27.2", "27.2"])
        XCTAssertEqual(result[0].developerModeEnabled, false)
        XCTAssertEqual(result[1].developerModeEnabled, true)
        XCTAssertEqual(requested.sorted(), ["00008150-TEST", "tablet-udid"])
    }

    func testLiveDetailsReplaceStaleDisabledListStatus() throws {
        let cached = device(identifier: "core-id", udid: "phone-udid", name: "Old name",
                            reality: "physical", visibility: "default", developerMode: false)
        let current = device(identifier: "core-id", udid: "phone-udid", name: "Current name",
                             reality: "physical", visibility: "default", connection: "connected", developerMode: true)
        let data = try JSONSerialization.data(withJSONObject: ["result": ["devices": [cached]]])
        let result = try XcodeService.devices(from: data) { id in
            XCTAssertEqual(id, "phone-udid")
            return try JSONSerialization.data(withJSONObject: ["result": current])
        }
        XCTAssertEqual(result, [ConnectedDevice(id: "phone-udid", name: "Current name", osVersion: "27.2",
                                               developerModeEnabled: true)])
    }

    func testDeveloperModeRequiresConnectedDetailsAndExplicitStatus() throws {
        let cases: [(connection: String, reported: Bool?, expected: Bool?)] = [
            ("connected", true, true), ("connected", false, false), ("connected", nil, nil),
            ("disconnected", true, nil), ("disconnected", false, nil), ("connecting", true, nil)
        ]
        for testCase in cases {
            let record = device(identifier: "core-id", udid: "phone-udid", name: "Phone",
                                reality: "physical", visibility: "default", connection: testCase.connection,
                                developerMode: testCase.reported)
            let data = try JSONSerialization.data(withJSONObject: ["result": ["devices": [record]]])
            let result = try XcodeService.devices(from: data) { _ in
                try JSONSerialization.data(withJSONObject: ["result": record])
            }
            XCTAssertEqual(result.first?.developerModeEnabled, testCase.expected,
                           "Connection: \(testCase.connection), reported: \(String(describing: testCase.reported))")
        }
    }

    func testFailedMalformedAndMismatchedDetailsKeepDevicesWithUnknownStatus() throws {
        let records = ["Failed", "Malformed", "Mismatched", "Working"].map { name in
            device(identifier: "core-\(name)", udid: name, name: name,
                   reality: "physical", visibility: "default", connection: "connected", developerMode: true)
        }
        let data = try JSONSerialization.data(withJSONObject: ["result": ["devices": records]])
        let result = try XcodeService.devices(from: data) { id in
            switch id {
            case "Failed": throw SideloadError("Device details timed out.")
            case "Malformed": return Data("not JSON".utf8)
            default: return try JSONSerialization.data(withJSONObject: ["result": records[3]])
            }
        }
        XCTAssertEqual(result.map(\.id), ["Failed", "Malformed", "Mismatched", "Working"])
        XCTAssertNil(result[0].developerModeEnabled)
        XCTAssertNil(result[1].developerModeEnabled)
        XCTAssertNil(result[2].developerModeEnabled)
        XCTAssertEqual(result[3].developerModeEnabled, true)
    }

    func testMalformedDeviceEnvelopeIsAnErrorRatherThanAnEmptyDeviceList() {
        XCTAssertThrowsError(try XcodeService.devices(from: Data("{\"error\":\"service failed\"}".utf8)) { _ in
            XCTFail("Malformed lists must not trigger device queries.")
            return Data()
        })
    }

    func testTeamMetadataUsesExplicitTeamIDAndDeduplicates() {
        let records: [String: Any] = [
            "cached-key-not-team-id": [
                ["teamID": "ABCDEFGHIJ", "teamName": "Personal Team", "isFreeProvisioningTeam": true],
                ["teamID": "0123456789", "teamName": "Company", "isFreeProvisioningTeam": false],
                ["teamID": "invalid", "teamName": "Bad data"]
            ],
            "second-account": [["teamID": "0123456789", "teamName": "Company"]]
        ]
        XCTAssertEqual(XcodeService.teams(from: records), [
            DeveloperTeam(id: "0123456789", name: "Company"),
            DeveloperTeam(id: "ABCDEFGHIJ", name: "Personal Team")
        ])
    }

    func testCertificateTeamComesFromOUInsteadOfCommonNameSuffix() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let certificate = directory.appendingPathComponent("fixture.der")
        // Entirely synthetic certificate, generated offline; no user keychain access.
        try CommandRunner.run("/usr/bin/openssl", [
            "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
            "-subj", "/CN=Apple Development: Fixture (USERID0001)/OU=TEAMID0001/O=Fixture Team",
            "-keyout", directory.appendingPathComponent("fixture.key").path,
            "-outform", "DER", "-out", certificate.path
        ])
        let data = try Data(contentsOf: certificate)
        let parsed = try XCTUnwrap(SecCertificateCreateWithData(nil, data as CFData))
        let identity = try XCTUnwrap(XcodeService.signingIdentity(certificate: parsed))
        XCTAssertEqual(identity.teamID, "TEAMID0001")
        XCTAssertNotEqual(identity.teamID, "USERID0001")
        XCTAssertEqual(identity.fingerprint.count, 40)
    }

    func testGeneratedAppAndExtensionProjectsBuildWithoutSigningOrAccounts() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for isExtension in [false, true] {
            let original = directory.appendingPathComponent(isExtension ? "Original.appex" : "Original.app", isDirectory: true)
            try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
            let attributes: [String: Any] = [
                "NSExtensionPointIdentifier": "com.apple.share-services",
                "NSExtensionPrincipalClass": "ProvisioningExtension",
                "NSExtensionAttributes": ["NSExtensionActivationRule": "TRUEPREDICATE"]
            ]
            let originalInfo: [String: Any] = ["NSExtension": attributes]
            try PropertyListSerialization.data(fromPropertyList: originalInfo, format: .binary, options: 0)
                .write(to: original.appendingPathComponent("Info.plist"))
            let bundle = AppBundle(url: original,
                                   bundleIdentifier: isExtension ? "com.example.localfixture.share" : "com.example.localfixture",
                                   displayName: "Fixture", isExtension: isExtension)
            let buildDirectory = directory.appendingPathComponent(isExtension ? "Extension" : "App", isDirectory: true)
            let project = try XcodeService.writeProject(bundle: bundle, teamID: "TEAMID0001", directory: buildDirectory)
            if isExtension {
                let generated = try PropertyListSerialization.propertyList(
                    from: Data(contentsOf: buildDirectory.appendingPathComponent("Info.plist")), format: nil) as? [String: Any]
                XCTAssertEqual(generated?["NSExtension"] as? NSDictionary, attributes as NSDictionary)
            }
            let derived = buildDirectory.appendingPathComponent("DerivedData", isDirectory: true)
            try CommandRunner.run("/usr/bin/xcrun", [
                "xcodebuild", "-project", project.path, "-scheme", "Provisioning", "-configuration", "Debug",
                "-destination", "generic/platform=iOS", "-derivedDataPath", derived.path,
                "CODE_SIGNING_ALLOWED=NO", "-quiet", "build"
            ])
            let suffix = isExtension ? "appex" : "app"
            let executable = derived.appendingPathComponent("Build/Products/Debug-iphoneos/Provisioning.\(suffix)/Provisioning")
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: executable.deletingLastPathComponent()
                .appendingPathComponent("embedded.mobileprovision").path))
        }
    }

    func testExtensionWithoutNSExtensionPointIsRejected() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("Unsupported.appex", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["EXAppExtensionAttributes": [:]], format: .xml, options: 0)
            .write(to: original.appendingPathComponent("Info.plist"))
        let bundle = AppBundle(url: original, bundleIdentifier: "com.example.unsupported",
                               displayName: "Unsupported", isExtension: true)
        XCTAssertThrowsError(try XcodeService.writeProject(bundle: bundle, teamID: "TEAMID0001",
                                                         directory: directory.appendingPathComponent("Project")))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("XcodeServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func device(identifier: String, udid: String, name: String, reality: String,
                        visibility: String, type: String = "iPhone", connection: String = "disconnected",
                        developerMode: Bool?) -> [String: Any] {
        var state: [String: Any] = ["name": name]
        if let developerMode {
            state["developerModeStatus"] = developerMode ? ["enabled": ["mode": 1]] : ["disabled": [:]]
        }
        return ["identifier": identifier, "visibilityClass": visibility, "properties": [
            "hardware": ["reality": reality, "platform": "iOS", "deviceType": type, "udid": udid],
            // A USB phone can be available while its development tunnel is still disconnected.
            "connection": ["state": connection, "pairingState": "paired"],
            "state": state,
            "software": ["osVersionNumber": ["stringValue": "27.2"]]
        ]]
    }
}
