import CryptoKit
import Foundation
import Security

public enum XcodeService {
    public static func teams() throws -> [DeveloperTeam] {
        let metadata = UserDefaults(suiteName: "com.apple.dt.Xcode")?
            .dictionary(forKey: "IDEProvisioningTeamByIdentifier") ?? [:]
        var found = Dictionary(uniqueKeysWithValues: teams(from: metadata).map { ($0.id, $0) })
        for identity in try signingIdentities() {
            if found[identity.teamID] == nil {
                found[identity.teamID] = DeveloperTeam(id: identity.teamID, name: identity.name)
            }
        }
        return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func devices() throws -> [ConnectedDevice] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalSideload-devices-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("devices.json")
        try CommandRunner.run("/usr/bin/xcrun", ["devicectl", "list", "devices", "--timeout", "20",
                                                "--json-output", output.path])
        return try devices(from: Data(contentsOf: output)) { id in
            let details = directory.appendingPathComponent("details-\(UUID().uuidString).json")
            try CommandRunner.run("/usr/bin/xcrun", [
                "devicectl", "device", "info", "details", "--device", id,
                "--timeout", "20", "--json-output", details.path
            ])
            return try Data(contentsOf: details)
        }
    }

    public static func provision(bundle: AppBundle, teamID: String, deviceID: String,
                                 workspace: URL, log: JobLog) throws -> ProvisionedSigning {
        guard validTeamID(teamID) else { throw SideloadError("Enter a valid 10-character development team ID.") }
        guard !deviceID.isEmpty, !deviceID.contains(",") else {
            throw SideloadError("Select a connected iPhone or iPad.")
        }
        let directory = workspace.appendingPathComponent("Provision-\(UUID().uuidString)", isDirectory: true)
        let project = try writeProject(bundle: bundle, teamID: teamID, directory: directory)
        let derivedData = directory.appendingPathComponent("DerivedData", isDirectory: true)
        log("Preparing development signing for \(bundle.bundleIdentifier)…")
        try CommandRunner.run("/usr/bin/xcrun", [
            "xcodebuild", "-project", project.path, "-scheme", "Provisioning",
            "-configuration", "Debug", "-destination", "platform=iOS,id=\(deviceID)",
            "-destination-timeout", "30", "-derivedDataPath", derivedData.path,
            "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration", "build"
        ], directory: directory, log: log)

        let product = derivedData.appendingPathComponent("Build/Products/Debug-iphoneos")
            .appendingPathComponent(bundle.isExtension ? "Provisioning.appex" : "Provisioning.app")
        let profile = directory.appendingPathComponent("development.mobileprovision")
        let embedded = product.appendingPathComponent("embedded.mobileprovision")
        guard FileManager.default.fileExists(atPath: embedded.path) else {
            throw SideloadError("Xcode did not produce a development provisioning profile.")
        }
        try FileManager.default.copyItem(at: embedded, to: profile)
        let profileDetails = directory.appendingPathComponent("profile.plist")
        try CommandRunner.run("/usr/bin/security", ["cms", "-D", "-i", profile.path, "-o", profileDetails.path])
        guard let properties = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: profileDetails), format: nil) as? [String: Any],
              let profileTeams = properties["TeamIdentifier"] as? [String], profileTeams.contains(teamID),
              let certificates = properties["DeveloperCertificates"] as? [Data] else {
            throw SideloadError("The profile returned by Xcode does not match the selected team.")
        }
        let allowedIdentities = Set(certificates.map(fingerprint))
        guard let identity = try signingIdentities().first(where: {
            $0.teamID == teamID && allowedIdentities.contains($0.fingerprint)
        }) else {
            throw SideloadError("The profile's signing certificate has no matching private key in your keychain. Open Xcode Settings → Apple Accounts to manage certificates.")
        }

        let entitlements = directory.appendingPathComponent("signing.entitlements")
        try CommandRunner.run("/usr/bin/codesign", ["--display", "--entitlements", entitlements.path,
                                                   "--xml", product.path])
        guard FileManager.default.fileExists(atPath: entitlements.path),
              let signed = try PropertyListSerialization.propertyList(
                from: Data(contentsOf: entitlements), format: nil) as? [String: Any],
              signed["com.apple.developer.team-identifier"] as? String == teamID,
              let applicationID = signed["application-identifier"] as? String,
              applicationID.hasSuffix(".\(bundle.bundleIdentifier)") else {
            throw SideloadError("Xcode did not produce matching development signing entitlements.")
        }
        return ProvisionedSigning(profile: profile, entitlements: entitlements,
                                  identity: identity.fingerprint, expiration: properties["ExpirationDate"] as? Date)
    }

    // Read only Xcode's team display metadata. Account credentials remain in Xcode.
    static func teams(from metadata: [String: Any]) -> [DeveloperTeam] {
        var result: [String: DeveloperTeam] = [:]
        for records in metadata.values {
            guard let records = records as? [[String: Any]] else { continue }
            for record in records {
                guard let id = record["teamID"] as? String, validTeamID(id),
                      let name = record["teamName"] as? String, !name.isEmpty else { continue }
                result[id] = DeveloperTeam(id: id, name: name)
            }
        }
        return result.values.sorted { $0.id < $1.id }
    }

    static func devices(from data: Data, details: (String) throws -> Data) throws -> [ConnectedDevice] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let records = result["devices"] as? [[String: Any]] else {
            throw SideloadError("Xcode returned an unrecognized device list.")
        }
        var devices: [String: ConnectedDevice] = [:]
        for record in records {
            guard let properties = record["properties"] as? [String: Any],
                  let hardware = properties["hardware"] as? [String: Any],
                  hardware["reality"] as? String == "physical",
                  hardware["platform"] as? String == "iOS",
                  let type = hardware["deviceType"] as? String, ["iPhone", "iPad"].contains(type),
                  record["visibilityClass"] as? String == "default",
                  let id = hardware["udid"] as? String, !id.isEmpty,
                  let state = properties["state"] as? [String: Any],
                  let name = state["name"] as? String else { continue }
            let software = properties["software"] as? [String: Any]
            let version = software?["osVersionNumber"] as? [String: Any]
            devices[id] = ConnectedDevice(id: id, name: name, osVersion: version?["stringValue"] as? String ?? "",
                                          developerModeEnabled: nil)
        }
        return devices.values.map { device in
            // Listing devices can return stale state even after the phone has restarted.
            // A failed refresh must leave that device selectable with an unknown status.
            guard let data = try? details(device.id),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let properties = result["properties"] as? [String: Any],
                  let hardware = properties["hardware"] as? [String: Any],
                  hardware["udid"] as? String == device.id else { return device }
            let connection = properties["connection"] as? [String: Any]
            let state = properties["state"] as? [String: Any]
            let software = properties["software"] as? [String: Any]
            let version = software?["osVersionNumber"] as? [String: Any]
            let status = state?["developerModeStatus"] as? [String: Any]
            var developerModeEnabled: Bool?
            // The details command also returns cached information when it cannot connect.
            if connection?["state"] as? String == "connected" {
                if status?["enabled"] as? [String: Any] != nil {
                    developerModeEnabled = true
                } else if status?["disabled"] as? [String: Any] != nil {
                    developerModeEnabled = false
                }
            }
            return ConnectedDevice(id: device.id, name: state?["name"] as? String ?? device.name,
                                   osVersion: version?["stringValue"] as? String ?? device.osVersion,
                                   developerModeEnabled: developerModeEnabled)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    struct SigningIdentity {
        let teamID: String
        let name: String
        let fingerprint: String
    }

    private static func signingIdentities() throws -> [SigningIdentity] {
        let query: [String: Any] = [kSecClass as String: kSecClassIdentity,
                                    kSecMatchLimit as String: kSecMatchLimitAll,
                                    kSecReturnRef as String: true]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw SideloadError("Unable to read development certificate identities from your keychain (\(status)).")
        }
        return (result as? [SecIdentity] ?? []).compactMap { identity in
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
                  let certificate else { return nil }
            return signingIdentity(certificate: certificate)
        }
    }

    static func signingIdentity(certificate: SecCertificate) -> SigningIdentity? {
        var commonName: CFString?
        guard SecCertificateCopyCommonName(certificate, &commonName) == errSecSuccess,
              let commonName else { return nil }
        let name = commonName as String
        let prefixes = ["Apple Development:", "Apple Distribution:", "iPhone Developer:", "iPhone Distribution:"]
        guard prefixes.contains(where: name.hasPrefix),
              let values = SecCertificateCopyValues(certificate, [kSecOIDX509V1SubjectName] as CFArray, nil)
                as? [String: Any],
              let subject = values[kSecOIDX509V1SubjectName as String] as? [String: Any],
              let fields = subject[kSecPropertyKeyValue as String] as? [[String: Any]],
              let unit = fields.first(where: { $0[kSecPropertyKeyLabel as String] as? String == kSecOIDOrganizationalUnitName as String }),
              let teamID = unit[kSecPropertyKeyValue as String] as? String, validTeamID(teamID) else { return nil }
        return SigningIdentity(teamID: teamID, name: name,
                               fingerprint: fingerprint(SecCertificateCopyData(certificate) as Data))
    }

    private static func fingerprint(_ certificate: Data) -> String {
        Insecure.SHA1.hash(data: certificate).map { String(format: "%02X", $0) }.joined()
    }

    private static func validTeamID(_ id: String) -> Bool {
        id.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil
    }

    @discardableResult
    static func writeProject(bundle: AppBundle, teamID: String, directory: URL) throws -> URL {
        let manager = FileManager.default
        let project = directory.appendingPathComponent("Provisioning.xcodeproj", isDirectory: true)
        let schemes = project.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true)
        try manager.createDirectory(at: schemes, withIntermediateDirectories: true)
        let suffix = bundle.isExtension ? "appex" : "app"
        var info: [String: Any] = [
            "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)", "CFBundleExecutable": "$(EXECUTABLE_NAME)",
            "CFBundleName": "Provisioning", "CFBundlePackageType": bundle.isExtension ? "XPC!" : "APPL",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0", "LSRequiresIPhoneOS": true
        ]
        if bundle.isExtension {
            let original = try PropertyListSerialization.propertyList(
                from: Data(contentsOf: bundle.url.appendingPathComponent("Info.plist")), format: nil) as? [String: Any]
            guard let attributes = original?["NSExtension"] as? [String: Any],
                  let point = attributes["NSExtensionPointIdentifier"] as? String, !point.isEmpty else {
                throw SideloadError("This extension does not declare a supported NSExtension point: \(bundle.displayName).")
            }
            info["NSExtension"] = attributes
        }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: directory.appendingPathComponent("Info.plist"), options: .atomic)
        let source = bundle.isExtension
            ? "#import <Foundation/Foundation.h>\n@interface ProvisioningExtension : NSObject @end\n@implementation ProvisioningExtension @end\n"
            : "int main(int argc, char **argv) { return 0; }\n"
        try source.write(to: directory.appendingPathComponent("main.m"), atomically: true, encoding: .utf8)

        let root = "000000000000000000000001", group = "000000000000000000000002"
        let products = "000000000000000000000003", target = "000000000000000000000004"
        let product = "000000000000000000000005", file = "000000000000000000000006"
        let sourceBuild = "000000000000000000000007", sources = "000000000000000000000008"
        let frameworks = "000000000000000000000009", projectConfig = "00000000000000000000000A"
        let targetConfig = "00000000000000000000000B", projectConfigs = "00000000000000000000000C"
        let targetConfigs = "00000000000000000000000D"
        var settings: [String: Any] = [
            "PRODUCT_NAME": "Provisioning", "PRODUCT_BUNDLE_IDENTIFIER": bundle.bundleIdentifier,
            "INFOPLIST_FILE": "Info.plist", "GENERATE_INFOPLIST_FILE": "NO",
            "SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "iphoneos", "IPHONEOS_DEPLOYMENT_TARGET": "15.0",
            "TARGETED_DEVICE_FAMILY": "1,2", "DEVELOPMENT_TEAM": teamID,
            "CODE_SIGN_STYLE": "Automatic", "CODE_SIGN_IDENTITY": "Apple Development",
            "CLANG_ENABLE_MODULES": "YES", "OTHER_LDFLAGS": ["-framework", "Foundation"],
            "SKIP_INSTALL": "YES", "DEBUG_INFORMATION_FORMAT": "dwarf"
        ]
        if bundle.isExtension { settings["APPLICATION_EXTENSION_API_ONLY"] = "YES" }
        let objects: [String: Any] = [
            root: ["isa": "PBXProject", "attributes": ["LastUpgradeCheck": "2700",
                    "TargetAttributes": [target: ["ProvisioningStyle": "Automatic", "DevelopmentTeam": teamID]]],
                   "buildConfigurationList": projectConfigs, "compatibilityVersion": "Xcode 14.0",
                   "developmentRegion": "en", "knownRegions": ["en", "Base"], "mainGroup": group,
                   "productRefGroup": products, "projectDirPath": "", "projectRoot": "", "targets": [target]],
            group: ["isa": "PBXGroup", "children": [file, products], "sourceTree": "<group>"],
            products: ["isa": "PBXGroup", "children": [product], "name": "Products", "sourceTree": "<group>"],
            target: ["isa": "PBXNativeTarget", "buildConfigurationList": targetConfigs,
                     "buildPhases": [sources, frameworks], "buildRules": [], "dependencies": [],
                     "name": "Provisioning", "productName": "Provisioning", "productReference": product,
                     "productType": bundle.isExtension ? "com.apple.product-type.app-extension" : "com.apple.product-type.application"],
            product: ["isa": "PBXFileReference", "explicitFileType": bundle.isExtension ? "wrapper.app-extension" : "wrapper.application",
                      "includeInIndex": 0, "path": "Provisioning.\(suffix)", "sourceTree": "BUILT_PRODUCTS_DIR"],
            file: ["isa": "PBXFileReference", "lastKnownFileType": "sourcecode.c.objc", "path": "main.m", "sourceTree": "<group>"],
            sourceBuild: ["isa": "PBXBuildFile", "fileRef": file],
            sources: ["isa": "PBXSourcesBuildPhase", "buildActionMask": 2147483647,
                      "files": [sourceBuild], "runOnlyForDeploymentPostprocessing": 0],
            frameworks: ["isa": "PBXFrameworksBuildPhase", "buildActionMask": 2147483647,
                         "files": [], "runOnlyForDeploymentPostprocessing": 0],
            projectConfig: ["isa": "XCBuildConfiguration", "name": "Debug", "buildSettings": [:]],
            targetConfig: ["isa": "XCBuildConfiguration", "name": "Debug", "buildSettings": settings],
            projectConfigs: ["isa": "XCConfigurationList", "buildConfigurations": [projectConfig],
                             "defaultConfigurationIsVisible": 0, "defaultConfigurationName": "Debug"],
            targetConfigs: ["isa": "XCConfigurationList", "buildConfigurations": [targetConfig],
                            "defaultConfigurationIsVisible": 0, "defaultConfigurationName": "Debug"]
        ]
        let document: [String: Any] = ["archiveVersion": "1", "classes": [:], "objectVersion": "56",
                                       "objects": objects, "rootObject": root]
        try PropertyListSerialization.data(fromPropertyList: document, format: .xml, options: 0)
            .write(to: project.appendingPathComponent("project.pbxproj"), options: .atomic)
        let scheme = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme LastUpgradeVersion="2700" version="1.3">
          <BuildAction parallelizeBuildables="NO" buildImplicitDependencies="YES">
            <BuildActionEntries><BuildActionEntry buildForRunning="YES" buildForTesting="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
              <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="\(target)" BuildableName="Provisioning.\(suffix)" BlueprintName="Provisioning" ReferencedContainer="container:Provisioning.xcodeproj"/>
            </BuildActionEntry></BuildActionEntries>
          </BuildAction>
        </Scheme>
        """
        try scheme.write(to: schemes.appendingPathComponent("Provisioning.xcscheme"), atomically: true, encoding: .utf8)
        return project
    }
}
