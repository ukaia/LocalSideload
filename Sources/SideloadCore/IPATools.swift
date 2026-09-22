import Foundation
import Darwin
import CArchive

public enum IPATools {
    public static func prepare(ipa: URL, workspace: URL, includeExtensions: Bool,
                               log: JobLog) throws -> PreparedIPA {
        let files = FileManager.default
        guard ipa.pathExtension.lowercased() == "ipa",
              try ipa.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw SideloadError("Choose an IPA file to install.")
        }
        let extraction = workspace.appendingPathComponent("IPA-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: extraction, withIntermediateDirectories: true,
                                 attributes: [.posixPermissions: 0o700])
        do {
            log("Opening \(ipa.lastPathComponent)…")
            try extract(ipa: ipa, destination: extraction)
            let payload = extraction.appendingPathComponent("Payload", isDirectory: true)
            guard files.fileExists(atPath: payload.path) else {
                throw SideloadError("This IPA has no Payload folder. Download a complete iPhone or iPad IPA.")
            }
            let apps = try files.contentsOfDirectory(at: payload, includingPropertiesForKeys: [.isDirectoryKey])
                .filter { $0.pathExtension == "app" && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            guard apps.count == 1, let app = apps.first else {
                throw SideloadError("The IPA must contain exactly one app in its Payload folder.")
            }
            if !includeExtensions {
                for name in ["PlugIns", "Extensions", "Watch", "AppClips"] {
                    let folder = app.appendingPathComponent(name, isDirectory: true)
                    if files.fileExists(atPath: folder.path) {
                        let children = try files.contentsOfDirectory(atPath: folder.path).sorted()
                        log("Omitting \(name): \(children.joined(separator: ", "))")
                        try files.removeItem(at: folder)
                    }
                }
                // Some repackaged IPAs place extensions outside PlugIns.
                let remainingExtensions = try descendants(of: app).filter { $0.pathExtension == "appex" }
                for ext in remainingExtensions.sorted(by: { $0.pathComponents.count < $1.pathComponents.count })
                    where files.fileExists(atPath: ext.path) {
                    log("Omitting extension: \(ext.lastPathComponent)")
                    try files.removeItem(at: ext)
                }
            }
            let children = try descendants(of: app)
            if let nestedApp = children.first(where: { $0.pathExtension == "app" }) {
                throw SideloadError("\(nestedApp.lastPathComponent) is a nested app. Watch apps and App Clips are not supported. Turn off Include extensions and try again.")
            }
            let mainInfo = try info(at: app)
            if let platforms = mainInfo["CFBundleSupportedPlatforms"] as? [String],
               !platforms.contains("iPhoneOS") {
                throw SideloadError("This archive is not an iPhone or iPad device app.")
            }
            let bundleURLs = [app] + children.filter { $0.pathExtension == "appex" }.sorted { $0.path < $1.path }
            let bundles = try bundleURLs.map { try describe($0, isExtension: $0 != app) }
            guard Set(bundles.map(\.bundleIdentifier)).count == bundles.count else {
                throw SideloadError("The IPA contains duplicate app or extension bundle identifiers.")
            }
            log("Checking \(bundles[0].displayName) and its embedded code…")
            for binary in try machOFiles(in: app) {
                let output = try CommandRunner.run("/usr/bin/xcrun", ["otool", "-arch", "all", "-l", binary.path]).output
                if try containsEncryptedCode(output) {
                    throw SideloadError("\(binary.lastPathComponent) contains App Store encrypted code. An encrypted IPA cannot be signed for installation; use an unencrypted build supplied by its developer.")
                }
            }
            var entitlements = Set<String>()
            for bundle in bundles {
                let result = try CommandRunner.run("/usr/bin/codesign",
                    ["--display", "--entitlements", ":-", bundle.url.path], allowFailure: true)
                if let plist = entitlementDictionary(from: result.output) {
                    entitlements.formUnion(plist.keys)
                }
            }
            return PreparedIPA(appURL: app, bundles: bundles, displayName: bundles[0].displayName,
                               bundleIdentifier: bundles[0].bundleIdentifier,
                               version: mainInfo["CFBundleShortVersionString"] as? String
                                ?? mainInfo["CFBundleVersion"] as? String ?? "Unknown",
                               capabilityNames: entitlements.sorted())
        } catch {
            try? files.removeItem(at: extraction)
            throw error
        }
    }

    public static func configure(prepared: PreparedIPA, mainBundleID: String,
                                 log: JobLog) throws -> PreparedIPA {
        let mapping = try bundleIDMapping(originalMain: prepared.bundleIdentifier,
                                          bundleIDs: prepared.bundles.map(\.bundleIdentifier),
                                          newMain: mainBundleID)
        for bundle in prepared.bundles {
            var properties = try info(at: bundle.url)
            properties = remapReferences(properties, mapping: mapping)
            properties["CFBundleIdentifier"] = mapping[bundle.bundleIdentifier]
            try writeInfo(properties, at: bundle.url)
            if bundle.bundleIdentifier != mapping[bundle.bundleIdentifier] {
                log("Bundle ID: \(bundle.bundleIdentifier) → \(mapping[bundle.bundleIdentifier]!)")
            }
        }
        return PreparedIPA(appURL: prepared.appURL,
            bundles: prepared.bundles.map {
                AppBundle(url: $0.url, bundleIdentifier: mapping[$0.bundleIdentifier]!,
                          displayName: $0.displayName, isExtension: $0.isExtension)
            }, displayName: prepared.displayName, bundleIdentifier: mainBundleID,
            version: prepared.version, capabilityNames: prepared.capabilityNames)
    }

    public static func sign(prepared: PreparedIPA, signing: [String: ProvisionedSigning],
                            log: JobLog) throws {
        let files = FileManager.default
        for bundle in prepared.bundles {
            guard let material = signing[bundle.bundleIdentifier],
                  files.fileExists(atPath: material.profile.path),
                  files.fileExists(atPath: material.entitlements.path), !material.identity.isEmpty else {
                throw SideloadError("Xcode has not supplied signing credentials for \(bundle.bundleIdentifier).")
            }
        }
        guard let mainSigning = signing[prepared.bundleIdentifier] else {
            throw SideloadError("The main app has no signing credentials.")
        }
        for stale in try descendants(of: prepared.appURL)
            .filter({ $0.lastPathComponent == "_CodeSignature" || $0.lastPathComponent == "embedded.mobileprovision" })
            .sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
            try files.removeItem(at: stale)
        }
        for bundle in prepared.bundles {
            let material = signing[bundle.bundleIdentifier]!
            try files.copyItem(at: material.profile,
                               to: bundle.url.appendingPathComponent("embedded.mobileprovision"))
        }
        let targets = try signingOrder(appURL: prepared.appURL, bundles: prepared.bundles)
        let bundleByPath = Dictionary(uniqueKeysWithValues: prepared.bundles.map { ($0.url.path, $0) })
        for target in targets {
            let bundle = bundleByPath[target.path]
            let material = bundle.map { signing[$0.bundleIdentifier]! } ?? mainSigning
            var arguments = ["--force", "--sign", material.identity, "--timestamp=none", "--generate-entitlement-der"]
            if bundle != nil { arguments += ["--entitlements", material.entitlements.path] }
            arguments.append(target.path)
            log("Signing \(target.lastPathComponent)…")
            try CommandRunner.run("/usr/bin/codesign", arguments, log: log)
        }
        log("Verifying all app signatures…")
        try CommandRunner.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--verbose=2", prepared.appURL.path], log: log)
    }

    // Keep archive validation independent of extraction so it can be tested with hostile names.
    static func validatedArchivePath(_ name: String) throws -> String {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"),
              !name.contains("\0"), !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw SideloadError("The IPA contains an unsafe archive path.")
        }
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(".."), !components.first!.contains(":"),
              !components.dropLast().contains("") else {
            throw SideloadError("The IPA contains an unsafe archive path: \(name)")
        }
        let clean = components.filter { $0 != "." && !$0.isEmpty }.joined(separator: "/")
        guard !clean.isEmpty else { throw SideloadError("The IPA contains an empty archive path.") }
        return clean
    }

    static func extract(ipa: URL, destination: URL) throws {
        // macOS temporary folders commonly start with /var, which links to /private/var.
        // Resolve the existing destination before forbidding links in archive-created paths.
        guard let resolvedPath = realpath(destination.path, nil) else {
            throw SideloadError("Could not resolve the IPA extraction folder: \(String(cString: strerror(errno)))")
        }
        let extractionPath = String(cString: resolvedPath)
        free(resolvedPath)
        guard let reader = archive_read_new(), let writer = archive_write_disk_new() else {
            throw SideloadError("Could not open the IPA archive reader.")
        }
        defer { archive_read_free(reader); archive_write_free(writer) }
        archive_read_support_format_zip(reader)
        archive_write_disk_set_options(writer, ARCHIVE_EXTRACT_SECURE_SYMLINKS | ARCHIVE_EXTRACT_SECURE_NODOTDOT)
        guard archive_read_open_filename(reader, ipa.path, 64 * 1024) == ARCHIVE_OK else {
            throw archiveError(reader)
        }
        var entry: OpaquePointer?
        var paths = Set<String>()
        var expandedSize: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let status = archive_read_next_header(reader, &entry)
            if status == ARCHIVE_EOF { break }
            guard status == ARCHIVE_OK, let entry, let rawName = archive_entry_pathname_utf8(entry),
                  let name = String(validatingCString: rawName) else { throw archiveError(reader) }
            let path = try validatedArchivePath(name)
            let key = path.precomposedStringWithCanonicalMapping.lowercased()
            guard paths.insert(key).inserted else {
                throw SideloadError("The IPA contains duplicate archive paths: \(path)")
            }
            guard paths.count <= 100_000 else { throw SideloadError("The IPA contains too many files.") }
            let type = archive_entry_filetype(entry)
            guard (type == S_IFREG || type == S_IFDIR), archive_entry_symlink(entry) == nil,
                  archive_entry_hardlink(entry) == nil else {
                throw SideloadError("The IPA contains a symbolic link or special file, which is unsupported: \(path)")
            }
            let declaredSize = archive_entry_size(entry)
            guard declaredSize >= 0, declaredSize <= 8 * 1_024 * 1_024 * 1_024 - expandedSize else {
                throw SideloadError("The IPA expands beyond the 8 GB archive limit.")
            }
            // validatedArchivePath has already removed dots and rejected absolute paths.
            // Keep the POSIX path here: URL standardization can shorten /private/var to /var.
            archive_entry_set_pathname(entry, extractionPath + "/" + path)
            // Discard archive owner/write bits while retaining executable permissions.
            archive_entry_set_perm(entry, type == S_IFDIR ? 0o755 : (archive_entry_perm(entry) & 0o111) | 0o644)
            guard archive_write_header(writer, entry) == ARCHIVE_OK else { throw archiveError(writer) }
            while true {
                let readCount = archive_read_data(reader, &buffer, buffer.count)
                if readCount == 0 { break }
                guard readCount > 0 else { throw archiveError(reader) }
                expandedSize += Int64(readCount)
                guard expandedSize <= 8 * 1_024 * 1_024 * 1_024 else {
                    throw SideloadError("The IPA expands beyond the 8 GB archive limit.")
                }
                guard archive_write_data(writer, &buffer, readCount) == readCount else { throw archiveError(writer) }
            }
            guard archive_write_finish_entry(writer) == ARCHIVE_OK else { throw archiveError(writer) }
        }
        guard !paths.isEmpty else { throw SideloadError("The IPA archive is empty.") }
    }

    private static func archiveError(_ archive: OpaquePointer) -> SideloadError {
        let detail = archive_error_string(archive).map { String(cString: $0) } ?? "Invalid ZIP archive"
        return SideloadError("Could not extract the IPA: \(detail)")
    }

    static func bundleIDMapping(originalMain: String, bundleIDs: [String], newMain: String) throws -> [String: String] {
        let expression = #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$"#
        guard newMain.range(of: expression, options: .regularExpression) != nil, newMain.count <= 255 else {
            throw SideloadError("Use a bundle ID such as com.yourname.app containing letters, numbers, dots, and hyphens.")
        }
        var mapping: [String: String] = [:]
        for identifier in bundleIDs {
            let mapped: String
            if newMain == originalMain { mapped = identifier }
            else if identifier == originalMain { mapped = newMain }
            else if identifier.hasPrefix(originalMain + ".") { mapped = newMain + identifier.dropFirst(originalMain.count) }
            else { mapped = newMain + ".extension." + identifier }
            guard mapped.count <= 255, mapped.range(of: expression, options: .regularExpression) != nil else {
                throw SideloadError("The extension bundle ID cannot be represented under the new app ID: \(identifier)")
            }
            mapping[identifier] = mapped
        }
        guard Set(mapping.values).count == mapping.count else {
            throw SideloadError("The new app ID would give two extensions the same bundle identifier.")
        }
        return mapping
    }

    static func remapReferences(_ properties: [String: Any], mapping: [String: String]) -> [String: Any] {
        let referenceKeys: Set<String> = ["WKCompanionAppBundleIdentifier", "WKAppBundleIdentifier",
            "WKWatchKitAppBundleIdentifier", "NSExtensionContainingAppBundleIdentifier", "NSApplicationBundleIdentifier"]
        func visit(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] {
                return dictionary.reduce(into: [String: Any]()) { output, item in
                        if referenceKeys.contains(item.key), let id = item.value as? String, let replacement = mapping[id] {
                            output[item.key] = replacement
                        } else { output[item.key] = visit(item.value) }
                    }
            }
            if let array = value as? [Any] { return array.map(visit) }
            return value
        }
        return visit(properties) as! [String: Any]
    }

    static func containsEncryptedCode(_ output: String) throws -> Bool {
        var inEncryptionCommand = false
        var commandHadCryptID = false
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.first == "cmd" || line.hasPrefix("Load command") {
                if inEncryptionCommand && !commandHadCryptID {
                    throw SideloadError("Could not read the app's Mach-O encryption information.")
                }
                inEncryptionCommand = fields.first == "cmd" && fields.count > 1 &&
                    ["LC_ENCRYPTION_INFO", "LC_ENCRYPTION_INFO_64"].contains(String(fields[1]))
                commandHadCryptID = false
            }
            if inEncryptionCommand, fields.first == "cryptid" {
                guard fields.count == 2, let cryptID = UInt32(fields[1]) else {
                    throw SideloadError("Could not read the app's Mach-O encryption information.")
                }
                commandHadCryptID = true
                if cryptID != 0 { return true }
            }
        }
        if inEncryptionCommand && !commandHadCryptID {
            throw SideloadError("Could not read the app's Mach-O encryption information.")
        }
        return false
    }

    static func signingOrder(appURL: URL, bundles: [AppBundle]) throws -> [URL] {
        let bundleExecutables = try Set(bundles.map { try executableURL(in: $0.url).path })
        let frameworkURLs = try descendants(of: appURL).filter { $0.pathExtension == "framework" }
        let frameworkExecutables = try Set(frameworkURLs.map { try executableURL(in: $0).path })
        let binaries = try machOFiles(in: appURL).filter {
            !bundleExecutables.contains($0.path) && !frameworkExecutables.contains($0.path)
        }
        return orderedSigningTargets(binaries + frameworkURLs + bundles.map(\.url))
    }

    static func orderedSigningTargets(_ targets: [URL]) -> [URL] {
        Array(Set(targets)).sorted {
            if $0.pathComponents.count != $1.pathComponents.count {
                return $0.pathComponents.count > $1.pathComponents.count
            }
            return $0.path < $1.path
        }
    }

    private static func describe(_ url: URL, isExtension: Bool) throws -> AppBundle {
        let properties = try info(at: url)
        guard let identifier = properties["CFBundleIdentifier"] as? String, !identifier.isEmpty else {
            throw SideloadError("\(url.lastPathComponent) has no bundle identifier.")
        }
        let executable = try executableURL(in: url)
        guard try isMachO(executable) else { throw SideloadError("\(url.lastPathComponent) has no valid Mach-O executable.") }
        return AppBundle(url: url, bundleIdentifier: identifier,
                         displayName: properties["CFBundleDisplayName"] as? String
                            ?? properties["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent,
                         isExtension: isExtension)
    }

    private static func info(at bundle: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: bundle.appendingPathComponent("Info.plist"))
        guard let properties = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw SideloadError("\(bundle.lastPathComponent) has an invalid Info.plist.")
        }
        return properties
    }

    private static func writeInfo(_ properties: [String: Any], at bundle: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: properties, format: .binary, options: 0)
        try data.write(to: bundle.appendingPathComponent("Info.plist"), options: .atomic)
    }

    private static func executableURL(in bundle: URL) throws -> URL {
        guard let name = try info(at: bundle)["CFBundleExecutable"] as? String,
              !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\") else {
            throw SideloadError("\(bundle.lastPathComponent) has an invalid executable name.")
        }
        return bundle.appendingPathComponent(name)
    }

    private static func descendants(of root: URL) throws -> [URL] {
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], errorHandler: { _, error in
                enumerationError = error
                return false
            }) else { throw SideloadError("Could not read the extracted app.") }
        let urls = enumerator.compactMap { $0 as? URL }
        if let enumerationError { throw enumerationError }
        return urls
    }

    private static func machOFiles(in root: URL) throws -> [URL] {
        try descendants(of: root).filter {
            guard try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return false }
            return try isMachO($0)
        }
    }

    private static func isMachO(_ url: URL) throws -> Bool {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard let header = try file.read(upToCount: 4), header.count == 4 else { return false }
        let bytes = Array(header)
        return [[0xFE, 0xED, 0xFA, 0xCE], [0xCE, 0xFA, 0xED, 0xFE],
                [0xFE, 0xED, 0xFA, 0xCF], [0xCF, 0xFA, 0xED, 0xFE],
                [0xCA, 0xFE, 0xBA, 0xBE], [0xBE, 0xBA, 0xFE, 0xCA],
                [0xCA, 0xFE, 0xBA, 0xBF], [0xBF, 0xBA, 0xFE, 0xCA]].contains(bytes)
    }

    private static func entitlementDictionary(from output: String) -> [String: Any]? {
        guard let start = output.range(of: "<?xml") ?? output.range(of: "<plist"),
              let end = output.range(of: "</plist>", range: start.lowerBound..<output.endIndex) else { return nil }
        let data = Data(output[start.lowerBound..<end.upperBound].utf8)
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
