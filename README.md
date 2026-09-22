# Local Sideload

A native Mac app that signs an unencrypted IPA using an account already added to Xcode, then installs it on a paired iPhone or iPad. Accounts and private signing keys stay managed by Xcode and the macOS Keychain. The app does not request an Apple password.

## Download

Download the app ZIP from [GitHub Releases](https://github.com/ukaia/LocalSideload/releases/latest), unzip it, and move **Local Sideload.app** to Applications. The release build is for Apple silicon Macs and requires macOS 15+ and Xcode 27. It is ad hoc signed and not notarized. Source and build instructions are included below.

## Use

1. Install full Xcode and add your Apple account under **Xcode → Settings → Accounts**. Select that Xcode with `xcode-select` if multiple versions are installed.
2. Connect and unlock your iPhone/iPad, trust the Mac, and enable **Settings → Privacy & Security → Developer Mode** on the device.
3. Open Local Sideload, choose or drop an IPA, and select your team and device.
4. Review the bundle ID and extension options, then choose **Sign & Install**. Xcode may ask for Keychain access or require you to refresh an expired account session in its Settings.

Both Personal Teams and paid developer teams are supported through Xcode. Team membership, capability permissions, device registration, App ID quotas, and profile expiration remain enforced by Apple. The app defaults to Xcode's selected team; a Team ID can also be entered directly.

## Signing behavior

- A private working copy is extracted with macOS's libarchive. Archive traversal, links, duplicate entries, and encrypted executables are rejected.
- A stable bundle ID is suggested for each app/team. Reuse it for future installs. A new ID creates a separate installation and does not transfer another app's data or service identity.
- Xcode builds a minimal target with the selected bundle ID to create a development profile using its existing account. Each included extension gets its own target/profile.
- The app copies Xcode's generated profile and final signing entitlements, signs nested code from the inside out, verifies the result, and installs it using `devicectl`.
- This uses **standard development entitlements**. Original push notifications, iCloud containers, App Groups, associated domains, and managed capabilities are not carried over. Apps that depend on them may lose functionality or fail at runtime.
- Extensions are omitted by default, with an explicit option to include them. Watch apps and App Clips are omitted with extensions disabled, and rejected if extension inclusion is selected.
- Reinstall before the displayed profile expiration to refresh. There is no automatic refresh daemon.
- IPAs must be unencrypted and compatible with the selected iOS device. The app does not decrypt App Store downloads.

## Build and test

Requires macOS 15+, Xcode 27, and its iOS SDK. The current `devicectl` JSON schema is used directly.

```sh
swift test
zsh build.sh
```

The result is `build/Local Sideload.app`. The local build is ad hoc signed and not notarized for distribution. It is intentionally not sandboxed because it must invoke Xcode and access local signing identities.

No downloaded runtime dependencies are needed. `Sources/CArchive` contains the public headers from [libarchive 3.8.1](https://github.com/libarchive/libarchive/tree/v3.8.1/libarchive), retaining their BSD license notices, and links to macOS's system libarchive.

Apple references: [Provisioning profiles](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles), [membership limits](https://developer.apple.com/support/compare-memberships/), and local `xcodebuild -help` / `xcrun devicectl device install app --help`.
