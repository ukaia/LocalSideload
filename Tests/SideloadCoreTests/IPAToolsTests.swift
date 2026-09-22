import Foundation
import XCTest
@testable import SideloadCore

final class IPAToolsTests: XCTestCase {
    func testOptionalRealIPAInspectionAndAdHocSigning() throws {
        guard let source = ProcessInfo.processInfo.environment["LOCALSIDELOAD_TEST_IPA"] else {
            throw XCTSkip("Set LOCALSIDELOAD_TEST_IPA to inspect and ad-hoc sign a temporary copy without credentials or installation.")
        }
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let prepared = try IPATools.prepare(ipa: URL(fileURLWithPath: source), workspace: workspace,
                                            includeExtensions: false, log: { print($0) })
        XCTAssertEqual(prepared.bundles.count, 1)
        XCTAssertFalse(prepared.bundleIdentifier.isEmpty)
        let configured = try IPATools.configure(prepared: prepared, mainBundleID: "com.localsideload.validation", log: { print($0) })
        XCTAssertEqual(configured.bundleIdentifier, "com.localsideload.validation")
        let targets = try IPATools.signingOrder(appURL: configured.appURL, bundles: configured.bundles)
        XCTAssertEqual(targets.last, configured.appURL)
        print("Inspected \(prepared.displayName) \(prepared.version); \(targets.count) signing targets.")
        // Ad-hoc signing verifies resource sealing and nesting without accessing a private key.
        // The placeholder profile is deliberately not installable on a device.
        let profile = workspace.appendingPathComponent("test.mobileprovision")
        try Data("Test profile; not for device installation".utf8).write(to: profile)
        let entitlements = workspace.appendingPathComponent("test-entitlements.plist")
        try PropertyListSerialization.data(fromPropertyList: [String: String](), format: .xml, options: 0)
            .write(to: entitlements)
        try IPATools.sign(prepared: configured,
                          signing: [configured.bundleIdentifier: ProvisionedSigning(profile: profile,
                            entitlements: entitlements, identity: "-", expiration: nil)],
                          log: { print($0) })
    }

    func testArchivePathValidation() throws {
        XCTAssertEqual(try IPATools.validatedArchivePath("./Payload/App.app/Info.plist"), "Payload/App.app/Info.plist")
        XCTAssertEqual(try IPATools.validatedArchivePath("Payload/App.app/"), "Payload/App.app")
        for name in ["../outside", "Payload/../../outside", "/tmp/outside", "C:/outside",
                     "Payload\\..\\outside", "Payload//file", "Payload/line\nbreak", "", "."] {
            XCTAssertThrowsError(try IPATools.validatedArchivePath(name), name)
        }
    }

    func testArchiveExtractionAndHostileEntries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goodIPA = root.appendingPathComponent("good.ipa")
        try zip(entries: [("Payload/App.app/data", "hello", 0o100644)]).write(to: goodIPA)
        let goodDestination = root.appendingPathComponent("good")
        try FileManager.default.createDirectory(at: goodDestination, withIntermediateDirectories: true)
        try IPATools.extract(ipa: goodIPA, destination: goodDestination)
        XCTAssertEqual(try String(contentsOf: goodDestination.appendingPathComponent("Payload/App.app/data"), encoding: .utf8), "hello")

        let fixtures: [[(String, String, UInt16)]] = [
            [("../escaped", "hostile", 0o100644)],
            [("Payload/link", "../../escaped", 0o120777)],
            [("Payload/App.app/data", "a", 0o100644), ("payload/app.app/DATA", "b", 0o100644)]
        ]
        for (index, entries) in fixtures.enumerated() {
            let ipa = root.appendingPathComponent("bad\(index).ipa")
            try zip(entries: entries).write(to: ipa)
            let destination = root.appendingPathComponent("bad\(index)")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            XCTAssertThrowsError(try IPATools.extract(ipa: ipa, destination: destination))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped").path))
        }
    }

    func testBundleIDsKeepExtensionsUnderMainAndPreserveIdentityMapping() throws {
        let ids = ["com.example.app", "com.example.app.share", "org.vendor.widget"]
        let changed = try IPATools.bundleIDMapping(originalMain: ids[0], bundleIDs: ids, newMain: "com.local.test")
        XCTAssertEqual(changed[ids[0]], "com.local.test")
        XCTAssertEqual(changed[ids[1]], "com.local.test.share")
        XCTAssertEqual(changed[ids[2]], "com.local.test.extension.org.vendor.widget")
        let unchanged = try IPATools.bundleIDMapping(originalMain: ids[0], bundleIDs: ids, newMain: ids[0])
        XCTAssertEqual(unchanged, Dictionary(uniqueKeysWithValues: ids.map { ($0, $0) }))
        XCTAssertThrowsError(try IPATools.bundleIDMapping(originalMain: ids[0], bundleIDs: ids, newMain: "invalid id"))
        XCTAssertThrowsError(try IPATools.bundleIDMapping(originalMain: ids[0],
            bundleIDs: [ids[0], "com.example.app.extension.net.other", "net.other"], newMain: "com.local.test"))
    }

    func testOnlyExactKnownBundleReferencesAreChanged() throws {
        let plist: [String: Any] = [
            "WKCompanionAppBundleIdentifier": "com.old.app",
            "CFBundleDisplayName": "com.old.app",
            "URL": "https://com.old.app/path",
            "NSExtension": ["NSExtensionAttributes": ["WKAppBundleIdentifier": "com.old.app.widget"]],
            "Unknown": ["com.old.app"],
            "Unmatched": ["WKCompanionAppBundleIdentifier": "com.old.app.suffix"]
        ]
        let changed = IPATools.remapReferences(plist, mapping: ["com.old.app": "com.new.app", "com.old.app.widget": "com.new.app.widget"])
        XCTAssertEqual(changed["WKCompanionAppBundleIdentifier"] as? String, "com.new.app")
        XCTAssertEqual(changed["CFBundleDisplayName"] as? String, "com.old.app")
        XCTAssertEqual(changed["URL"] as? String, "https://com.old.app/path")
        XCTAssertEqual(changed["Unknown"] as? [String], ["com.old.app"])
        let extensionInfo = try XCTUnwrap(changed["NSExtension"] as? [String: [String: String]])
        XCTAssertEqual(extensionInfo["NSExtensionAttributes"]?["WKAppBundleIdentifier"], "com.new.app.widget")
        XCTAssertEqual((changed["Unmatched"] as? [String: String])?["WKCompanionAppBundleIdentifier"], "com.old.app.suffix")
    }

    func testEncryptionChecksEveryArchitectureAndRejectsMalformedCommands() throws {
        let unencrypted = """
        App (architecture arm64):
        Load command 5
                  cmd LC_ENCRYPTION_INFO_64
              cmdsize 24
             cryptoff 16384
            cryptsize 10000
              cryptid 0
        Load command 6
                  cmd LC_UUID
        """
        XCTAssertFalse(try IPATools.containsEncryptedCode(unencrypted))
        XCTAssertTrue(try IPATools.containsEncryptedCode(unencrypted + "\n" + unencrypted.replacingOccurrences(of: "cryptid 0", with: "cryptid 1")))
        XCTAssertThrowsError(try IPATools.containsEncryptedCode("cmd LC_ENCRYPTION_INFO\ncryptid invalid"))
        XCTAssertThrowsError(try IPATools.containsEncryptedCode("cmd LC_ENCRYPTION_INFO\nLoad command 2\ncmd LC_UUID"))
    }

    func testSigningOrderPlacesEveryChildBeforeItsContainer() {
        let root = URL(fileURLWithPath: "/tmp/App.app")
        let paths = [root, root.appendingPathComponent("Frameworks/Core.framework"),
            root.appendingPathComponent("PlugIns/Share.appex"),
            root.appendingPathComponent("PlugIns/Share.appex/Frameworks/Helper.framework"),
            root.appendingPathComponent("Frameworks/Core.framework/Frameworks/Inner.dylib")]
        let ordered = IPATools.orderedSigningTargets(paths)
        XCTAssertEqual(ordered.last, root)
        for parent in paths {
            for child in paths where child.path.hasPrefix(parent.path + "/") {
                XCTAssertLessThan(ordered.firstIndex(of: child)!, ordered.firstIndex(of: parent)!)
            }
        }
        XCTAssertEqual(IPATools.orderedSigningTargets(paths + paths), ordered)
    }

    // Minimal uncompressed ZIP fixtures let tests express hostile names without creating them on disk.
    private func zip(entries: [(name: String, content: String, mode: UInt16)]) -> Data {
        var local = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let body = Data(entry.content.utf8)
            let offset = local.count
            let checksum = crc32(body)
            local.appendLE(UInt32(0x04034b50)); local.appendLE(UInt16(20))
            local.appendLE(UInt16(0x800)); local.appendLE(UInt16(0))
            local.appendLE(UInt16(0)); local.appendLE(UInt16(0))
            local.appendLE(checksum); local.appendLE(UInt32(body.count)); local.appendLE(UInt32(body.count))
            local.appendLE(UInt16(name.count)); local.appendLE(UInt16(0))
            local.append(name); local.append(body)
            central.appendLE(UInt32(0x02014b50)); central.appendLE(UInt16(0x0314)); central.appendLE(UInt16(20))
            central.appendLE(UInt16(0x800)); central.appendLE(UInt16(0))
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
            central.appendLE(checksum); central.appendLE(UInt32(body.count)); central.appendLE(UInt32(body.count))
            central.appendLE(UInt16(name.count)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
            central.appendLE(UInt32(entry.mode) << 16); central.appendLE(UInt32(offset)); central.append(name)
        }
        var result = local
        result.append(central)
        result.appendLE(UInt32(0x06054b50)); result.appendLE(UInt16(0)); result.appendLE(UInt16(0))
        result.appendLE(UInt16(entries.count)); result.appendLE(UInt16(entries.count))
        result.appendLE(UInt32(central.count)); result.appendLE(UInt32(local.count)); result.appendLE(UInt16(0))
        return result
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) }
        }
        return ~crc
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
