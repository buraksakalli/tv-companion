import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ConnectionSettings().tabItem { Label("TV", systemImage: "tv") }
            AutomationSettings().tabItem { Label("Automations", systemImage: "wand.and.stars") }
            ActivityLog().tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }
        }
        .frame(width: 500, height: 440)
    }
}

private struct ConnectionSettings: View {
    @Environment(AppModel.self) private var model
    @State private var hostDraft = ""

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Find your TV") {
                HStack {
                    TextField("IP address", text: $hostDraft, prompt: Text("192.168.1.40"))
                        .onSubmit { Task { await model.selectHost(hostDraft) } }
                    Button("Use") { Task { await model.selectHost(hostDraft) } }
                        .disabled(hostDraft.trimmingCharacters(in: .whitespaces) == model.host)
                    Button {
                        Task { await model.discover() }
                    } label: {
                        if model.isDiscovering { ProgressView().controlSize(.small) } else { Text("Search") }
                    }
                }
                ForEach(model.discovered) { tv in
                    HStack {
                        Text(tv.name)
                        Text(tv.host).foregroundStyle(.secondary).monospacedDigit()
                        Spacer()
                        Button(tv.host == model.host ? "Selected" : "Select") {
                            hostDraft = tv.host
                            Task { await model.selectHost(tv.host, name: tv.name) }
                        }
                        .disabled(tv.host == model.host)
                    }
                }
                Text("Tip: give the TV a fixed IP (DHCP reservation) in your router so this doesn't change.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Pairing") {
                if model.localNetworkBlocked {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("macOS is blocking local network access for TV Companion.")
                            .foregroundStyle(.red)
                        Button("Open Local Network Settings") { model.openLocalNetworkSettings() }
                    }
                } else if let error = model.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                LabeledContent("Status") {
                    if model.awaitingPairingApproval {
                        Text("Accept the prompt on your TV…").foregroundStyle(.orange)
                    } else {
                        Text(model.isPaired ? "Paired" : "Not paired")
                            .foregroundStyle(model.isPaired ? .green : .secondary)
                    }
                }
                HStack {
                    Button(model.isPaired ? "Re-pair" : "Pair with TV") { Task { await model.pair() } }
                        .disabled(!model.isConfigured || model.isBusy)
                    Button("Forget TV", role: .destructive) { Task { await model.forgetTV() } }
                        .disabled(!model.isPaired)
                }
                if let fp = model.certificateFingerprint {
                    LabeledContent("Pinned certificate") {
                        Text(fp.prefix(23) + "…").font(.caption.monospaced()).textSelection(.enabled)
                            .help(fp)
                    }
                }
            }

            Section("Mac connection") {
                Picker("Mac is on input", selection: $model.macInputId) {
                    Text("Choose…").tag("")
                    ForEach(model.inputs) { Text($0.label).tag($0.id) }
                }
                .disabled(model.inputs.isEmpty)
                TextField("TV MAC address (Wake-on-LAN)", text: $model.macAddress, prompt: Text("Learned automatically"))
                if !model.macAddress.isEmpty && MACAddress(model.macAddress) == nil {
                    Text("Not a valid MAC address.").font(.caption).foregroundStyle(.red)
                }
                Text("On the TV, enable Settings → General → TV On With Mobile → “Turn on via Wi-Fi” so the Mac can wake it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { hostDraft = model.host }
    }
}

private struct AutomationSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Enable automations", isOn: $model.automationsEnabled)
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
            }
            Section("When the Mac wakes or unlocks") {
                Toggle("Turn the TV on", isOn: $model.turnOnWhenMacWakes)
                Toggle("Switch to the Mac's input", isOn: $model.switchInputOnWake)
                    .disabled(!model.turnOnWhenMacWakes)
                Toggle("Only if TV Companion turned it off", isOn: $model.onlyWakeIfWeTurnedItOff)
                    .disabled(!model.turnOnWhenMacWakes)
            }
            Section("When the display sleeps or the Mac locks") {
                Picker("Action", selection: $model.displaySleepAction) {
                    ForEach(DisplaySleepAction.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("TV Mouse (⌃⌥M)") {
                LabeledContent("Pointer speed") {
                    Slider(value: $model.pointerSensitivity, in: 0.5...4, step: 0.25)
                        .frame(width: 200)
                }
                Toggle("Invert scrolling", isOn: $model.invertScroll)
            }
            Section("When the Mac sleeps or shuts down") {
                Toggle("Turn the TV off", isOn: $model.turnOffOnSystemSleep)
            }
            Section {
                Toggle("Only turn off when the TV is showing the Mac", isOn: $model.onlyTurnOffWhenShowingMac)
            } footer: {
                Text("Keeps the Mac from switching off the TV while someone is watching something else.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ActivityLog: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(Array(model.activity.enumerated()), id: \.offset) { Text($0.element).font(.callout.monospaced()) }
            .overlay {
                if model.activity.isEmpty {
                    ContentUnavailableView("No activity yet", systemImage: "clock")
                }
            }
    }
}
