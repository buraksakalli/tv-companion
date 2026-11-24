import AppKit
import Foundation
import Observation
import ServiceManagement
import os

enum DisplaySleepAction: String, CaseIterable, Identifiable {
    case nothing, screenOff, powerOff
    var id: String { rawValue }
    var label: String {
        switch self {
        case .nothing: "Do nothing"
        case .screenOff: "Turn screen off (TV stays on, audio continues)"
        case .powerOff: "Turn TV off"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    // MARK: Persisted settings (non-secret)
    var host: String = "" { didSet { save("host", host) } }
    var macAddress: String = "" { didSet { save("macAddress", macAddress) } }
    var macInputId: String = "" { didSet { save("macInputId", macInputId) } }
    /// Model name from SSDP discovery, e.g. "OLED65C5". Empty when the IP was typed by hand.
    var tvModel: String = "" { didSet { save("tvModel", tvModel) } }
    private(set) var certificateFingerprint: String? { didSet { save("certFingerprint", certificateFingerprint) } }

    var automationsEnabled = true { didSet { save("automationsEnabled", automationsEnabled) } }
    var turnOnWhenMacWakes = true { didSet { save("turnOnWhenMacWakes", turnOnWhenMacWakes) } }
    var switchInputOnWake = true { didSet { save("switchInputOnWake", switchInputOnWake) } }
    var onlyWakeIfWeTurnedItOff = true { didSet { save("onlyWakeIfWeTurnedItOff", onlyWakeIfWeTurnedItOff) } }
    var displaySleepAction: DisplaySleepAction = .powerOff { didSet { save("displaySleepAction", displaySleepAction.rawValue) } }
    var turnOffOnSystemSleep = true { didSet { save("turnOffOnSystemSleep", turnOffOnSystemSleep) } }
    var onlyTurnOffWhenShowingMac = true { didSet { save("onlyTurnOffWhenShowingMac", onlyTurnOffWhenShowingMac) } }
    var pointerSensitivity = 1.5 {
        didSet { save("pointerSensitivity", pointerSensitivity); tvMouse.sensitivity = pointerSensitivity }
    }
    var invertScroll = false {
        didSet { save("invertScroll", invertScroll); tvMouse.invertScroll = invertScroll }
    }
    /// Set when this app turned the TV off, so wake only undoes our own action.
    var tvModelLabel: String { tvModel.isEmpty ? "webOS" : tvModel }

    private var weTurnedItOff = false { didSet { save("weTurnedItOff", weTurnedItOff) } }

    // MARK: Live state
    private(set) var power: TVPower = .unknown("")
    private(set) var inputs: [TVInput] = []
    private(set) var foregroundAppId: String?
    private(set) var volume: Int?
    private(set) var isMuted = false
    @ObservationIgnored private var pendingVolume: Int?
    @ObservationIgnored private var volumeSender: Task<Void, Never>?
    private(set) var isBusy = false
    private(set) var awaitingPairingApproval = false
    private(set) var lastError: String?
    private(set) var localNetworkBlocked = false
    private(set) var activity: [String] = []
    private(set) var discovered: [DiscoveredTV] = []
    private(set) var isDiscovering = false

    var isConfigured: Bool { !host.isEmpty }
    private(set) var isPaired = false
    var macInput: TVInput? { inputs.first { $0.id == macInputId } }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch { report(error) }
        }
    }

    let tvMouse = TVMouseController()
    private var tvMouseHotKey: HotKey?
    private var client: WebOSClient?
    private let events = SystemEvents()
    private let defaults = UserDefaults.standard
    private let log = Logger(subsystem: "com.buraksakalli.tvcompanion", category: "model")
    private var loading = true
    private var automationInFlight = false
    @ObservationIgnored private var previewMode = false

    init() {
        load()
        loading = false
        refreshPairedFlag()
        events.handler = { [weak self] event, done in
            guard let self else { return done() }
            Task { await self.handle(event); done() }
        }
        #if DEBUG
        if SnapshotRenderer.requested {
            previewMode = true
            Task { await SnapshotRenderer.run(model: self) }
            return
        }
        #endif
        if ConnectionProbe.requested {
            let host = self.host
            Task {
                await ConnectionProbe.run(host: host)
                NSApp.terminate(nil)
            }
            return
        }
        events.start()
        tvMouse.sensitivity = pointerSensitivity
        tvMouse.invertScroll = invertScroll
        tvMouse.onEnded = { [weak self] error in
            if let error { self?.lastError = error; self?.note("⚠︎ TV Mouse: \(error)") }
        }
        // ⌃⌥M toggles TV Mouse from anywhere.
        tvMouseHotKey = HotKey(keyCode: 46, modifiers: 0x1000 | 0x0800 /* controlKey | optionKey */) { [weak self] in
            Task { await self?.toggleTVMouse() }
        }
        if isConfigured { Task { await refresh() } }
    }

    // MARK: Connection

    private func refreshPairedFlag() {
        isPaired = isConfigured && Keychain.clientKey(for: host) != nil
    }

    private func connectedClient(
        pairingAllowed: Bool = false, connectTimeout: Duration = .seconds(6)
    ) async throws -> WebOSClient {
        if let client, await client.isConnected { return client }
        guard isConfigured else { throw WebOSError.invalidHost }

        let key = Keychain.clientKey(for: host)
        if key == nil && !pairingAllowed {
            throw WebOSError.pairingRejected("Not paired yet. Use “Pair with TV” in Settings.")
        }
        let client = WebOSClient(host: host, pinnedFingerprint: certificateFingerprint)
        let registration = try await client.connect(
            clientKey: key,
            connectTimeout: connectTimeout,
            onPairingPrompt: { [weak self] in
                Task { @MainActor in self?.awaitingPairingApproval = true }
            },
            onDisconnect: { [weak self] in
                Task { @MainActor in self?.socketClosed() }
            }
        )
        awaitingPairingApproval = false
        if registration.clientKey != key {
            Keychain.setClientKey(registration.clientKey, for: host)
            refreshPairedFlag()
        }
        if certificateFingerprint == nil { certificateFingerprint = registration.certificateFingerprint }
        self.client = client
        await learnMACIfNeeded(client)
        return client
    }

    private func socketClosed() {
        client = nil
        power = .unreachable
    }

    private func learnMACIfNeeded(_ client: WebOSClient) async {
        guard MACAddress(macAddress) == nil else { return }
        let fromTV = try? await client.macAddress()
        if let mac = fromTV.flatMap(MACAddress.init) ?? LocalInterfaces.arpMAC(for: host) {
            macAddress = mac.description
            note("Learned TV MAC address for Wake-on-LAN")
        }
    }

    // MARK: User actions

    /// Full refresh (includes the input list). `live` skips inputs for cheap polling.
    func refresh(live: Bool = false) async {
        guard isConfigured, isPaired, !previewMode else { return }
        do {
            let c = try await connectedClient(connectTimeout: .seconds(3))
            power = try await c.powerState()
            if !live || inputs.isEmpty { inputs = try await c.inputs() }
            foregroundAppId = try? await c.foregroundAppId()
            if power == .on || power == .screenOff, let audio = try? await c.audioStatus(), volumeSender == nil {
                volume = audio.volume
                isMuted = audio.muted
            }
            if macInputId.isEmpty, let guess = inputs.first(where: { $0.connected && $0.id.hasPrefix("HDMI") }) {
                macInputId = guess.id
            }
            lastError = nil
        } catch {
            power = .unreachable
        }
    }

    func pair() async {
        await run("Pairing") {
            await self.client?.disconnect()
            self.client = nil
            Keychain.deleteClientKey(for: self.host)
            self.refreshPairedFlag()
            self.certificateFingerprint = nil
            let c = try await self.connectedClient(pairingAllowed: true)
            try? await c.toast("TV Companion paired with this Mac")
            self.note("Paired with TV at \(self.host)")
        }
        awaitingPairingApproval = false
        await refresh()
    }

    func forgetTV() async {
        await client?.disconnect()
        client = nil
        if isConfigured { Keychain.deleteClientKey(for: host) }
        refreshPairedFlag()
        certificateFingerprint = nil
        macAddress = ""
        macInputId = ""
        inputs = []
        power = .unknown("")
        note("Forgot TV pairing")
    }

    func discover() async {
        isDiscovering = true
        discovered = await SSDPDiscovery.discover()
        isDiscovering = false
        if discovered.isEmpty { lastError = "No LG TVs found. Make sure the TV is on and on the same network." }
    }

    func selectHost(_ newHost: String, name: String? = nil) async {
        let trimmed = newHost.trimmingCharacters(in: .whitespaces)
        if let name { tvModel = DiscoveredTV.model(fromName: name) }
        guard trimmed != host else { return }
        if name == nil { tvModel = "" }
        await client?.disconnect()
        client = nil
        host = trimmed
        certificateFingerprint = nil
        macAddress = ""
        macInputId = ""
        inputs = []
        refreshPairedFlag()
    }

    func turnOn(switchToMac: Bool) async {
        await run("Turn on") { try await self.wakeTV(switchToMac: switchToMac) }
    }

    func turnOff() async {
        await run("Turn off") { try await self.powerOffTV() }
    }

    func screenOff() async { await run("Screen off") { try await self.connectedClient().screenOff() } }
    func screenOn() async { await run("Screen on") { try await self.connectedClient().screenOn() } }
    func volumeUp() async {
        if let volume { return setVolume(volume + 1) }
        await run("Volume") { try await self.connectedClient().volumeUp() }
    }

    func volumeDown() async {
        if let volume { return setVolume(volume - 1) }
        await run("Volume") { try await self.connectedClient().volumeDown() }
    }

    func toggleMute() async {
        let target = !isMuted
        isMuted = target
        await run("Mute") { try await self.connectedClient().setMute(target) }
    }

    /// Optimistic volume: UI updates now, the TV gets the latest value with light
    /// coalescing so dragging the slider doesn't queue up dozens of requests.
    func setVolume(_ value: Int) {
        let clamped = min(max(value, 0), 100)
        volume = clamped
        pendingVolume = clamped
        guard volumeSender == nil else { return }
        volumeSender = Task {
            while let next = pendingVolume {
                pendingVolume = nil
                do {
                    try await connectedClient().setVolume(next)
                } catch {
                    report(error, context: "Volume")
                    break
                }
                try? await Task.sleep(for: .milliseconds(70))
            }
            volumeSender = nil
        }
    }

    func toggleScreen() async {
        if power == .screenOff { await screenOn() } else { await screenOff() }
        power = (try? await client?.powerState()) ?? power
    }

    var isShowingMacInput: Bool {
        guard let appId = macInput?.appId ?? Self.defaultAppId(forInput: macInputId) else { return false }
        return foregroundAppId == appId
    }

    /// Human label for what the TV is showing: an input name, or a tidied app id.
    var currentSourceLabel: String? {
        guard let appId = foregroundAppId, !appId.isEmpty else { return nil }
        if let input = inputs.first(where: { $0.appId == appId }) { return input.label }
        let known = [
            "netflix": "Netflix", "youtube.leanback.v4": "YouTube", "com.disney.disneyplus-prod": "Disney+",
            "com.apple.appletv": "Apple TV", "amazon": "Prime Video", "com.webos.app.livetv": "Live TV",
            "com.webos.app.home": "Home", "com.webos.app.browser": "Browser", "spotify-beehive": "Spotify",
        ]
        if let name = known[appId] { return name }
        let tail = appId.split(separator: ".").last.map(String.init) ?? appId
        return tail.prefix(1).uppercased() + tail.dropFirst()
    }

    func toggleTVMouse() async {
        if tvMouse.isActive { return tvMouse.stop() }
        await run("TV Mouse") {
            let c = try await self.connectedClient()
            let path: String?
            do {
                path = try await c.pointerSocketPath()
            } catch WebOSError.tv(let msg) where msg.contains("401") {
                throw WebOSError.tv("This pairing doesn't include mouse control yet. Use Settings → Re-pair, then try again.")
            }
            guard let url = PointerSocket.validatedURL(path, tvHost: self.host) else {
                throw WebOSError.tv("The TV returned an unexpected pointer socket address.")
            }
            self.tvMouse.start(socketURL: url, pinnedFingerprint: self.certificateFingerprint)
            self.note("TV Mouse on")
        }
    }

    func switchInput(_ id: String) async {
        await run("Switch input") {
            try await self.connectedClient().switchInput(id)
            self.foregroundAppId = self.inputs.first { $0.id == id }?.appId
        }
    }

    // MARK: Core operations

    private func wakeTV(switchToMac: Bool) async throws {
        // Screen-off (TV still running) just needs the screen back on.
        let probe = try? await connectedClient(connectTimeout: .seconds(2.5))
        if let c = probe, let state = try? await c.powerState(), state.isOn {
            if state == .screenOff { try await c.screenOn() }
        } else {
            guard let mac = MACAddress(macAddress) else {
                throw WebOSError.tv("No MAC address for Wake-on-LAN yet. Connect once while the TV is on.")
            }
            try WakeOnLAN.send(to: mac, tvHost: host)
            note("Sent Wake-on-LAN")
            try await waitForTV(sending: mac)
        }
        weTurnedItOff = false
        let c = try await connectedClient()
        if switchToMac, !macInputId.isEmpty {
            try await c.switchInput(macInputId)
            note("Switched TV to \(macInput?.label ?? macInputId)")
        }
        power = (try? await c.powerState()) ?? .on
    }

    /// Retries the connection for ~25 s while the TV boots, re-sending the magic packet.
    private func waitForTV(sending mac: MACAddress) async throws {
        for attempt in 1...12 {
            try await Task.sleep(for: .seconds(2))
            if let c = try? await connectedClient(connectTimeout: .seconds(3)), let state = try? await c.powerState(), state == .on || state == .screenOff {
                return
            }
            if attempt % 3 == 0 { try? WakeOnLAN.send(to: mac, tvHost: host) }
        }
        throw WebOSError.timeout("TV to wake up. Is “Turn on via Wi-Fi” enabled on the TV?")
    }

    private func powerOffTV() async throws {
        let c = try await connectedClient()
        // getPowerState guards against system/turnOff toggling a TV in standby back on.
        guard try await c.powerState().isOn else { return }
        try await c.powerOff()
        weTurnedItOff = true
        power = .standby
        note("Turned TV off")
    }

    private func isShowingMac(_ c: WebOSClient) async -> Bool {
        guard let appId = macInput?.appId ?? Self.defaultAppId(forInput: macInputId) else { return false }
        return (try? await c.foregroundAppId()) == appId
    }

    /// "HDMI_2" → "com.webos.app.hdmi2" (used if the input list hasn't loaded yet).
    nonisolated static func defaultAppId(forInput id: String) -> String? {
        guard id.hasPrefix("HDMI_"), let n = Int(id.dropFirst(5)) else { return nil }
        return "com.webos.app.hdmi\(n)"
    }

    // MARK: Automations

    private func handle(_ event: SystemEvent) async {
        guard automationsEnabled, isPaired, !automationInFlight else { return }
        automationInFlight = true
        defer { automationInFlight = false }
        log.info("System event: \(event.rawValue, privacy: .public)")
        switch event {
        case .displayWake, .screenUnlocked:
            guard turnOnWhenMacWakes, !onlyWakeIfWeTurnedItOff || weTurnedItOff else { return }
            await run("Auto: Mac woke") { try await self.wakeTV(switchToMac: self.switchInputOnWake) }

        case .displaySleep, .screenLocked:
            guard displaySleepAction != .nothing else { return }
            await automatedOff(screenOnly: displaySleepAction == .screenOff, reason: "display slept")

        case .systemWillSleep, .shutdown:
            guard turnOffOnSystemSleep else { return }
            await automatedOff(screenOnly: false, reason: event == .shutdown ? "Mac shutting down" : "Mac sleeping")
        }
    }

    private func automatedOff(screenOnly: Bool, reason: String) async {
        await run("Auto: \(reason)") {
            guard let c = try? await self.connectedClient(),
                  let state = try? await c.powerState(), state == .on
            else { return }
            if self.onlyTurnOffWhenShowingMac, !(await self.isShowingMac(c)) {
                self.note("Skipped (\(reason)): TV isn't showing the Mac")
                return
            }
            if screenOnly {
                try await c.screenOff()
                self.weTurnedItOff = true
                self.note("Turned screen off (\(reason))")
            } else {
                try await self.powerOffTV()
            }
        }
    }

    #if DEBUG
    /// Fake state for UI snapshots; never persisted.
    func applyPreview(power: TVPower, paired: Bool = true, volume: Int? = 23, muted: Bool = false, mouse: Bool = false) {
        loading = true
        defer { loading = false }
        isPaired = paired
        self.power = power
        inputs = [
            TVInput(id: "HDMI_1", label: "Apple TV", appId: "com.webos.app.hdmi1", connected: true),
            TVInput(id: "HDMI_2", label: "HDMI 2", appId: "com.webos.app.hdmi2", connected: true),
            TVInput(id: "HDMI_3", label: "PlayStation", appId: "com.webos.app.hdmi3", connected: false),
        ]
        macInputId = "HDMI_2"
        tvModel = "OLED65C5"
        foregroundAppId = power == .on ? "com.webos.app.hdmi2" : nil
        self.volume = volume
        isMuted = muted
        lastError = nil
    }
    #endif

    // MARK: Helpers

    private func run(_ label: String, _ work: @escaping @MainActor () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await work()
            lastError = nil
            localNetworkBlocked = false
        } catch is CancellationError {
        } catch {
            report(error, context: label)
        }
    }

    func openLocalNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
    }

    private func report(_ error: Error, context: String? = nil) {
        let text = [context, error.localizedDescription].compactMap { $0 }.joined(separator: ": ")
        lastError = text
        localNetworkBlocked = (WebOSClient.map(error) as? WebOSError) == .localNetworkBlocked
        note("⚠︎ " + text)
    }

    private func note(_ text: String) {
        let stamp = Date().formatted(date: .omitted, time: .shortened)
        activity.insert("\(stamp)  \(text)", at: 0)
        if activity.count > 30 { activity.removeLast(activity.count - 30) }
    }

    private func save(_ key: String, _ value: Any?) {
        guard !loading else { return }
        defaults.set(value, forKey: key)
    }

    private func load() {
        host = defaults.string(forKey: "host") ?? ""
        macAddress = defaults.string(forKey: "macAddress") ?? ""
        macInputId = defaults.string(forKey: "macInputId") ?? ""
        tvModel = defaults.string(forKey: "tvModel") ?? ""
        certificateFingerprint = defaults.string(forKey: "certFingerprint")
        func bool(_ k: String, _ d: Bool) -> Bool { defaults.object(forKey: k) as? Bool ?? d }
        automationsEnabled = bool("automationsEnabled", true)
        turnOnWhenMacWakes = bool("turnOnWhenMacWakes", true)
        switchInputOnWake = bool("switchInputOnWake", true)
        onlyWakeIfWeTurnedItOff = bool("onlyWakeIfWeTurnedItOff", true)
        turnOffOnSystemSleep = bool("turnOffOnSystemSleep", true)
        onlyTurnOffWhenShowingMac = bool("onlyTurnOffWhenShowingMac", true)
        weTurnedItOff = bool("weTurnedItOff", false)
        pointerSensitivity = defaults.object(forKey: "pointerSensitivity") as? Double ?? 1.5
        invertScroll = bool("invertScroll", false)
        displaySleepAction = DisplaySleepAction(rawValue: defaults.string(forKey: "displaySleepAction") ?? "") ?? .powerOff
    }
}
