import SwiftUI
import SideloadCore
import UniformTypeIdentifiers

@main
struct LocalSideloadApp: App {
    @State private var model = AppModel()
    var body: some Scene {
        WindowGroup("Local Sideload") {
            ContentView(model: model)
                .frame(minWidth: 720, minHeight: 640)
        }
        .defaultSize(width: 860, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open IPA…") { model.chooseFile() }
                    .keyboardShortcut("o")
                    .disabled(model.isBusy)
            }
        }
    }
}

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var showLog = false
    @State private var isDropTarget = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                fileCard
                HStack(alignment: .top, spacing: 16) {
                    teamCard.frame(maxWidth: .infinity)
                    deviceCard.frame(maxWidth: .infinity)
                }
                if model.selectedFile != nil {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            LabeledContent("Bundle ID") {
                                TextField("com.example.app", text: $model.bundleIdentifier)
                                    .textFieldStyle(.roundedBorder).frame(maxWidth: 440)
                                    .font(.system(.body, design: .monospaced))
                            }
                            Toggle("Include app extensions", isOn: $model.includeExtensions)
                                .onChange(of: model.includeExtensions) { _, _ in
                                    if let url = model.selectedFile { Task { await model.load(url) } }
                                }
                            Text(model.includeExtensions
                                 ? "Each extension uses an additional App ID. Watch apps and App Clips are not supported."
                                 : "Extensions, Watch apps, and App Clips are removed from the installation copy.")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("Standard development signing. Push notifications, iCloud, App Groups, and other original app capabilities are not carried over.")
                                .font(.caption).foregroundStyle(.secondary)
                            if let prepared = model.prepared, !prepared.capabilityNames.isEmpty {
                                DisclosureGroup("Original app capabilities") {
                                    Text(prepared.capabilityNames.joined(separator: "\n"))
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }.font(.caption)
                            }
                        }.padding(8)
                    } label: { Label("Installation options", systemImage: "slider.horizontal.3") }
                    .disabled(model.isBusy)
                }
                status
                HStack {
                    Text("Your account stays in Xcode.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showLog = true
                        Task { await model.install() }
                    } label: {
                        Label(model.isBusy ? (model.stage?.rawValue ?? "Working…") : "Sign & Install", systemImage: "arrow.down.to.line")
                            .frame(minWidth: 140)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!model.canInstall)
                }
                DisclosureGroup("Activity", isExpanded: $showLog) {
                    VStack(alignment: .trailing, spacing: 6) {
                        ScrollView {
                            Text(model.activity.isEmpty ? "Activity will appear here." : model.activity)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                        }.frame(height: 180).background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                        Button("Copy log", action: model.copyLog).font(.caption)
                    }
                }.font(.callout)
            }.padding(28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await model.refresh() }
        .onChange(of: model.selectedTeamID) { _, _ in model.updateBundleIdentifier() }
        .onChange(of: model.customTeamID) { _, _ in model.updateBundleIdentifier() }
        .onOpenURL { url in Task { await model.load(url) } }
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isBusy, let url = urls.first else { return false }
            Task { await model.load(url) }; return true
        } isTargeted: { isDropTarget = $0 }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 29, weight: .medium)).foregroundStyle(.tint)
                .frame(width: 56, height: 56).background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 5) {
                Text("Local Sideload").font(.system(size: 25, weight: .semibold))
                Text("Your apps. Your Xcode team.").foregroundStyle(.secondary)
            }
            Spacer()
            Text(model.xcodeVersion).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var fileCard: some View {
        Button(action: model.chooseFile) {
            HStack(spacing: 18) {
                Image(systemName: model.prepared == nil ? "shippingbox" : "app.badge.checkmark")
                    .font(.system(size: 32)).foregroundStyle(.tint).frame(width: 48)
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.prepared?.displayName ?? "Drop an IPA here")
                        .font(.title3.weight(.semibold)).foregroundStyle(.primary)
                    if let prepared = model.prepared {
                        Text("Version \(prepared.version) · \(prepared.bundles.count) app bundle\(prepared.bundles.count == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                        Text(model.selectedFile?.lastPathComponent ?? "")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text(model.isBusy ? "Inspecting the app…" : "or click to choose a file")
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "plus.circle").font(.title2).foregroundStyle(.secondary)
            }.padding(22).frame(maxWidth: .infinity, minHeight: 105)
                .background(.background, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(isDropTarget ? Color.accentColor : Color.secondary.opacity(0.22), style: StrokeStyle(lineWidth: isDropTarget ? 2 : 1, dash: [6, 4])))
        }.buttonStyle(.plain).disabled(model.isBusy)
    }

    private var teamCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Team", selection: $model.selectedTeamID) {
                    Text("Choose a team").tag("")
                    ForEach(model.teams) { Text($0.name).tag($0.id) }
                    Text("Enter Team ID…").tag("custom")
                }.labelsHidden()
                if model.selectedTeamID == "custom" {
                    TextField("10-character Team ID", text: $model.customTeamID).textFieldStyle(.roundedBorder)
                } else {
                    Text(model.teamID.isEmpty ? "Add your account in Xcode → Settings → Accounts." : model.teamID)
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text("Personal Teams: 7-day signing and Apple’s free account limits.")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading).padding(8)
        } label: { Label("Xcode team", systemImage: "person.crop.circle.badge.checkmark") }
        .disabled(model.isBusy)
    }

    private var deviceCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if model.devices.isEmpty {
                    Text(model.isRefreshing ? "Looking for devices…" : "No connected device")
                    Text("Connect and unlock your iPhone or iPad, trust this Mac, and enable Developer Mode.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Device", selection: $model.selectedDeviceID) {
                        ForEach(model.devices) { Text($0.name + " · iOS " + $0.osVersion).tag($0.id) }
                    }.labelsHidden()
                    Text("Keep your device connected and unlocked during installation.")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.isRefreshing {
                        Text("Checking device status…").font(.caption).foregroundStyle(.secondary)
                    } else if let device = model.devices.first(where: { $0.id == model.selectedDeviceID }) {
                        if device.developerModeEnabled == false {
                            Label("Enable Developer Mode in Settings → Privacy & Security on this device.", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        } else if device.developerModeEnabled == nil {
                            Text("Developer Mode hasn’t been verified. Unlock your device and refresh, or try installing.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Label("Developer Mode is enabled", systemImage: "checkmark.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button { Task { await model.refresh() } } label: {
                    Label(model.isRefreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
                }.font(.caption).disabled(model.isRefreshing || model.isBusy)
            }.frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading).padding(8)
        } label: { Label("Device", systemImage: "iphone") }
        .disabled(model.isBusy)
    }

    @ViewBuilder private var status: some View {
        if model.isBusy {
            VStack(alignment: .leading, spacing: 7) {
                ProgressView(value: model.stage?.progress ?? 0.1)
                Text(model.stage?.rawValue ?? "Working…").font(.caption).foregroundStyle(.secondary)
            }
        }
        if let result = model.result {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(result.displayName) is installed.").fontWeight(.medium)
                    if let expiration = result.expiration {
                        Text("Signing expires \(expiration.formatted(date: .abbreviated, time: .shortened)). Reinstall with the same bundle ID to refresh.")
                            .font(.caption)
                    }
                }
            } icon: { Image(systemName: "checkmark.circle.fill") }
                .foregroundStyle(.green).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
        if let error = model.error ?? model.discoveryError {
            Label { Text(error).textSelection(.enabled) } icon: { Image(systemName: "exclamationmark.triangle") }
                .font(.callout).foregroundStyle(.red).padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
