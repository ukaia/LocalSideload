import Foundation

public typealias JobLog = @Sendable (String) -> Void

public struct DeveloperTeam: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct ConnectedDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let osVersion: String
    public let developerModeEnabled: Bool?
    public init(id: String, name: String, osVersion: String, developerModeEnabled: Bool?) {
        self.id = id; self.name = name; self.osVersion = osVersion
        self.developerModeEnabled = developerModeEnabled
    }
}

public struct AppBundle: Sendable {
    public let url: URL
    public let bundleIdentifier: String
    public let displayName: String
    public let isExtension: Bool
    public init(url: URL, bundleIdentifier: String, displayName: String, isExtension: Bool) {
        self.url = url; self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName; self.isExtension = isExtension
    }
}

public struct PreparedIPA: Sendable {
    public let appURL: URL
    public let bundles: [AppBundle]
    public let displayName: String
    public let bundleIdentifier: String
    public let version: String
    public let capabilityNames: [String]
    public init(appURL: URL, bundles: [AppBundle], displayName: String, bundleIdentifier: String,
                version: String, capabilityNames: [String]) {
        self.appURL = appURL; self.bundles = bundles; self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier; self.version = version
        self.capabilityNames = capabilityNames
    }
}

public struct ProvisionedSigning: Sendable {
    public let profile: URL
    public let entitlements: URL
    public let identity: String
    public let expiration: Date?
    public init(profile: URL, entitlements: URL, identity: String, expiration: Date?) {
        self.profile = profile; self.entitlements = entitlements
        self.identity = identity; self.expiration = expiration
    }
}

public struct SideloadError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
