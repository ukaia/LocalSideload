import Foundation

public struct InstallResult: Sendable {
    public let bundleIdentifier: String
    public let displayName: String
    public let expiration: Date?
}

public enum SideloadStage: String, Sendable {
    case preparing = "Preparing app"
    case provisioning = "Signing with Xcode"
    case signing = "Signing app contents"
    case installing = "Installing on device"
    case complete = "Installed"

    public var progress: Double {
        switch self {
        case .preparing: 0.1
        case .provisioning: 0.3
        case .signing: 0.65
        case .installing: 0.85
        case .complete: 1
        }
    }
}

public enum SideloadJob {
    public static func install(prepared: PreparedIPA, bundleIdentifier: String, teamID: String,
                               deviceID: String, workspace: URL,
                               stage: @Sendable (SideloadStage) -> Void,
                               log: JobLog) throws -> InstallResult {
        guard teamID.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
            throw SideloadError("Choose an Xcode team or enter its 10-character Team ID.")
        }
        guard bundleIdentifier.count <= 255,
              bundleIdentifier.range(of: "^[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil else {
            throw SideloadError("Enter a valid bundle identifier, such as com.example.myapp.")
        }
        guard !deviceID.isEmpty else { throw SideloadError("Choose a connected iPhone or iPad.") }
        stage(.preparing)
        // The inspected copy stays pristine, including when a failed job is retried
        // with a different team or bundle ID.
        let runDirectory = workspace.appendingPathComponent("SigningJob", isDirectory: true)
        if FileManager.default.fileExists(atPath: runDirectory.path) {
            try FileManager.default.removeItem(at: runDirectory)
        }
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let appCopy = runDirectory.appendingPathComponent(prepared.appURL.lastPathComponent, isDirectory: true)
        try FileManager.default.copyItem(at: prepared.appURL, to: appCopy)
        let bundles = prepared.bundles.map { bundle in
            let relative = String(bundle.url.path.dropFirst(prepared.appURL.path.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return AppBundle(url: relative.isEmpty ? appCopy : appCopy.appendingPathComponent(relative),
                             bundleIdentifier: bundle.bundleIdentifier, displayName: bundle.displayName,
                             isExtension: bundle.isExtension)
        }
        let signingCopy = PreparedIPA(appURL: appCopy, bundles: bundles, displayName: prepared.displayName,
                                      bundleIdentifier: prepared.bundleIdentifier, version: prepared.version,
                                      capabilityNames: prepared.capabilityNames)
        let configured = try IPATools.configure(prepared: signingCopy, mainBundleID: bundleIdentifier, log: log)
        stage(.provisioning)
        var profiles: [String: ProvisionedSigning] = [:]
        for (index, bundle) in configured.bundles.enumerated() {
            log("Preparing Xcode signing for \(bundle.displayName) (\(index + 1)/\(configured.bundles.count)).")
            let output = runDirectory.appendingPathComponent("Provisioning-\(index)", isDirectory: true)
            profiles[bundle.bundleIdentifier] = try XcodeService.provision(
                bundle: bundle, teamID: teamID, deviceID: deviceID, workspace: output, log: log)
        }
        stage(.signing)
        try IPATools.sign(prepared: configured, signing: profiles, log: log)
        stage(.installing)
        let resultFile = runDirectory.appendingPathComponent("install-result.json")
        try CommandRunner.run("/usr/bin/xcrun", ["devicectl", "device", "install", "app",
                                               "--device", deviceID, "--timeout", "180",
                                               "--json-output", resultFile.path,
                                               configured.appURL.path], log: log)
        let result = try JSONSerialization.jsonObject(with: Data(contentsOf: resultFile)) as? [String: Any]
        guard let info = result?["info"] as? [String: Any], info["outcome"] as? String == "success" else {
            throw SideloadError("Xcode did not confirm that installation succeeded. Check the activity log.")
        }
        stage(.complete)
        log("Installed \(configured.displayName) successfully.")
        return InstallResult(bundleIdentifier: configured.bundleIdentifier, displayName: configured.displayName,
                             expiration: profiles.values.compactMap(\.expiration).min())
    }
}
