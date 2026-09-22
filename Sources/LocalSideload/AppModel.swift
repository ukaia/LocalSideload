import AppKit
import Foundation
import Observation
import SideloadCore
import UniformTypeIdentifiers

@MainActor @Observable
final class AppModel {
    var teams: [DeveloperTeam] = []
    var devices: [ConnectedDevice] = []
    var selectedTeamID = ""
    var customTeamID = ""
    var selectedDeviceID = ""
    var includeExtensions = false
    var bundleIdentifier = ""
    var selectedFile: URL?
    var prepared: PreparedIPA?
    var workspace: URL?
    var isBusy = false
    var isRefreshing = false
    var stage: SideloadStage?
    var error: String?
    var discoveryError: String?
    var result: InstallResult?
    var activity = ""
    var xcodeVersion = "Checking Xcode…"

    var teamID: String {
        (selectedTeamID == "custom" ? customTeamID : selectedTeamID)
            .trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
    var canInstall: Bool {
        prepared != nil && teamID.count == 10 && !selectedDeviceID.isEmpty && !isBusy && !isRefreshing
            && devices.contains { $0.id == selectedDeviceID && $0.developerModeEnabled != false }
    }

    func append(_ line: String) {
        activity += line + "\n"
        // Keep the UI responsive during long compiler logs.
        if activity.count > 100_000 { activity = String(activity.suffix(80_000)) }
    }

    func refresh() async {
        guard !isRefreshing, !isBusy else { return }
        isRefreshing = true
        discoveryError = nil
        defer { isRefreshing = false }
        let found = await Task.detached(priority: .userInitiated) {
            var messages: [String] = []
            let version: String
            do {
                version = try CommandRunner.run("/usr/bin/xcodebuild", ["-version"]).output
                    .split(separator: "\n").first.map(String.init) ?? "Xcode"
            } catch { version = "Xcode unavailable"; messages.append(error.localizedDescription) }
            let teams: [DeveloperTeam]
            do { teams = try XcodeService.teams() }
            catch { teams = []; messages.append(error.localizedDescription) }
            let devices: [ConnectedDevice]
            do { devices = try XcodeService.devices() }
            catch { devices = []; messages.append(error.localizedDescription) }
            return (version, teams, devices, messages)
        }.value
        xcodeVersion = found.0
        teams = found.1
        devices = found.2
        if selectedTeamID.isEmpty {
            let saved = UserDefaults.standard.string(forKey: "selectedTeam")
            let xcodeTeam = UserDefaults(suiteName: "com.apple.dt.Xcode")?
                .string(forKey: "IDEProvisioningTeamManagerLastSelectedTeamID")
            selectedTeamID = [saved, xcodeTeam].compactMap { $0 }.first(where: { id in teams.contains { $0.id == id } })
                ?? teams.first?.id ?? "custom"
            updateBundleIdentifier()
        }
        if !devices.contains(where: { $0.id == selectedDeviceID }) {
            selectedDeviceID = devices.first?.id ?? ""
        }
        if !found.3.isEmpty { discoveryError = found.3.joined(separator: "\n") }
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose an IPA"
        panel.message = "Select the iOS app you want to install."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.init(filenameExtension: "ipa") ?? .archive]
        if panel.runModal() == .OK, let url = panel.url { Task { await load(url) } }
    }

    func load(_ url: URL) async {
        guard !isBusy else { return }
        guard url.pathExtension.lowercased() == "ipa" else {
            error = "Choose an .ipa file."; return
        }
        isBusy = true
        error = nil; result = nil; stage = .preparing; activity = ""
        prepared = nil; selectedFile = url
        defer { isBusy = false; stage = nil }
        let previous = workspace
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalSideload", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        workspace = directory
        let extensions = includeExtensions
        let logger: JobLog = { [weak self] line in Task { @MainActor in self?.append(line) } }
        do {
            prepared = try await Task.detached(priority: .userInitiated) {
                if let previous { try? FileManager.default.removeItem(at: previous) }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                       attributes: [.posixPermissions: 0o700])
                return try IPATools.prepare(ipa: url, workspace: directory, includeExtensions: extensions, log: logger)
            }.value
            updateBundleIdentifier()
        } catch { self.error = error.localizedDescription; append(error.localizedDescription) }
    }

    func updateBundleIdentifier() {
        guard let prepared else { return }
        bundleIdentifier = prepared.bundleIdentifier + ".localsideload." + (teamID.isEmpty ? "app" : teamID.lowercased())
        if selectedTeamID != "custom" { UserDefaults.standard.set(selectedTeamID, forKey: "selectedTeam") }
        result = nil
    }

    func install() async {
        guard let prepared, let workspace, canInstall else { return }
        isBusy = true; error = nil; result = nil
        defer { isBusy = false }
        let team = teamID, device = selectedDeviceID, identifier = bundleIdentifier
        let logger: JobLog = { [weak self] line in Task { @MainActor in self?.append(line) } }
        let stageUpdate: @Sendable (SideloadStage) -> Void = { [weak self] value in
            Task { @MainActor in self?.stage = value }
        }
        do {
            result = try await Task.detached(priority: .userInitiated) {
                try SideloadJob.install(prepared: prepared, bundleIdentifier: identifier, teamID: team,
                                        deviceID: device, workspace: workspace, stage: stageUpdate, log: logger)
            }.value
        } catch { self.error = error.localizedDescription; append(error.localizedDescription); stage = nil }
    }

    func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(activity, forType: .string)
    }
}
