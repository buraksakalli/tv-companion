# AGENTS.md

Guidance for AI coding agents working in this repository. Humans: see [README.md](README.md) and [CONTRIBUTING.md](CONTRIBUTING.md).

## Project

TV Companion is a macOS 14+ menu bar app (SwiftUI `MenuBarExtra` + AppKit) that controls LG webOS TVs over the local network. It is written in Swift 6 with strict concurrency and has **no third-party dependencies**.

## Commands

```sh
make project   # xcodegen generate (the .xcodeproj is generated and git-ignored)
make build     # Release build into ./build
make test      # unit tests (Swift Testing)
make run       # build and open the app
scripts/release.sh --unsigned   # test DMG packaging (signed releases need the maintainer's Developer ID)
```

- Run `make test` after every change. A change isn't done until it passes.
- Edit `project.yml` to change targets or settings; never edit the generated `.xcodeproj`.
- Never publish a release, push a tag, or run notarization unless the maintainer asks you to.
- Signing defaults to ad-hoc (`Config/Signing.xcconfig`). Don't add a team ID or signing identity to tracked files; personal overrides go in the git-ignored `Config/Local.xcconfig`.

## Layout

```
Sources/TVCompanion/
├── AppModel.swift        @MainActor @Observable state + all user actions; settings persisted in UserDefaults
├── TVCompanionApp.swift  MenuBarExtra + Settings scenes
├── Protocol/             SSAP endpoints (SSAP.swift), WebOSClient actor, JSONValue, cert pinning, pointer socket
├── Network/              Wake-on-LAN, SSDP discovery
├── System/               Keychain, sleep/wake events (IOKit), Carbon hot key, TV Mouse, debug tools
└── Views/                MenuView, SettingsView, shared components + Theme, TV illustration
Tests/TVCompanionTests/   Swift Testing suites (pure logic: parsing, framing, validation)
```

## Architecture rules

- **Concurrency:** `WebOSClient` is an `actor`. The UI and `AppModel` are `@MainActor`. Keep it compiling warning-free under Swift 6 strict concurrency. `@unchecked Sendable` is only for classes whose mutable state is protected by a lock (`CertificatePinningDelegate`, `OnceFlag`), or whose stored properties are all immutable `let`s of thread-safe types (`PointerSocket`). Don't use it, or `nonisolated(unsafe)`, to silence an isolation error.
- **Adding a TV command:**
  1. Add the URI to `enum SSAP` in `Protocol/SSAP.swift`.
  2. Add a typed wrapper in the `extension WebOSClient` in `WebOSClient.swift`.
  3. Call it from `AppModel`.
  4. If the command needs a new webOS permission, add it to `SSAP.permissions`. Existing pairings won't have that permission until the user re-pairs, and the TV answers with a 401 error. Handle the 401 with a clear "Re-pair" message, like `toggleTVMouse` does.
- **Parsing:** TV payload shapes vary between webOS versions. Parse defensively, for example `AudioStatus` accepts both the flat and the nested shapes. Add a test with a sample payload for each shape you support.
- **UI:** reuse `Theme`, `.card()`, `PressableStyle` and the components in `Views/Components.swift`. The menu is a fixed 380 pt wide and always uses the dark colour scheme.

## Security (non-negotiable)

- Only use `wss://` on port 3001. Never add plaintext `ws://` or port 3000.
- Never disable or bypass certificate pinning (`CertificatePinning.swift`). Don't accept any certificate other than the pinned one.
- The pairing client key lives only in the Keychain. Never log it, print it, or put it in UserDefaults.
- `PointerSocket.validatedURL` must keep rejecting socket URLs that point to another host, use another scheme, or contain userinfo.
- TV Mouse captures input only through a **local** `NSEvent` monitor on the app's own panel. Don't add global monitors or event taps, and don't add features that need the Accessibility or Input Monitoring permission.
- Keep the webOS permission list minimal.
- No network calls except to the user's TV. That rules out analytics, crash reporters and update checks.

## Testing and verification

- Unit tests can't reach a TV. Test the pure logic: parsers, frame encoding, URL and host validation, and key mapping.
- To check the UI visually, use a Debug build: `build/Build/Products/Debug/TVCompanion.app/Contents/MacOS/TVCompanion --snapshot <dir>`. It writes one PNG per menu state (on, muted, screen off, off, setup) using fake data from `AppModel.applyPreview`. If you change the UI, regenerate `docs/screenshots/`.
- `--probe` (Debug build) writes connection diagnostics to `~/Library/Logs/TVCompanion/probe.log`.
- Behaviour on a real TV (pairing, power, TV Mouse) can't be verified in CI. Say plainly that it's untested; don't claim it works.

## Gotchas

- **macOS Local Network privacy:** an ad-hoc build gets a new identity every time it's rebuilt, and macOS can then silently block local network access. The symptom is `URLError -1009` or POSIX error 50 ("Network is down"). The app maps this to `WebOSError.localNetworkBlocked`. The fix is to toggle the app in System Settings → Privacy & Security → Local Network. It's not a code bug.
- Wake-on-LAN only works when the TV setting *Turn on via Wi-Fi* is enabled, and after the app has learned the TV's MAC address.
- System sleep is held for at most 5 s (`SystemEvents`). Never extend that hold or block sleep indefinitely.

## Conventions

- Write test data with obviously fake values: `192.168.1.40`, MAC addresses like `a4:36:c7:…`. Never use real IP addresses, MAC addresses, client keys or fingerprints.
- Keep the code small and readable. Comment *why* something is done, not *what* it does.
- Write short commit messages that say what changed and why.
