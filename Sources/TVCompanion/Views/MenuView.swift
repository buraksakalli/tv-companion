import SwiftUI

struct MenuView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var osdVisible = false
    @State private var osdToken = 0

    private var look: TVIllustration<AnyView>.Look {
        switch model.power {
        case .on: .on
        case .screenOff: .screenOff
        default: .off
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            TVIllustration(look: look, width: 320) { AnyView(screenOverlay) }
                .padding(.top, 14)
            statusLine
                .padding(.top, 10)

            if model.isPaired {
                controls.padding(.top, 16)
                inputChips.padding(.top, 16)
            } else {
                setupCard.padding(.top, 18)
            }

            if let error = model.lastError { errorBanner(error).padding(.top, 14) }
            footer.padding(.top, 16)
        }
        .padding(20)
        .frame(width: 380)
        .background(background)
        .environment(\.colorScheme, .dark)
        .animation(Theme.spring, value: model.power)
        .animation(Theme.spring, value: model.lastError)
        .onChange(of: model.volume) { old, new in
            guard old != nil, new != nil, old != new else { return }
            showOSD()
        }
        .onChange(of: model.isMuted) { _, _ in showOSD() }
        .task {
            // Live polling only while the popover is open.
            await model.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                await model.refresh(live: true)
            }
        }
    }

    private var background: some View {
        ZStack {
            Theme.background
            RadialGradient(colors: [Theme.violet.opacity(model.power == .on ? 0.16 : 0.05), .clear],
                           center: .init(x: 0.5, y: 0.2), startRadius: 0, endRadius: 280)
        }
        .ignoresSafeArea()
    }

    // MARK: Header + mini-TV

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.power.isOn ? Theme.live : Color.white.opacity(0.2))
                .frame(width: 7, height: 7)
                .shadow(color: model.power.isOn ? Theme.live : .clear, radius: 4)
            Text("LG").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.primary)
            Text(model.tvModelLabel).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
                .lineLimit(1)
            Spacer()
            if model.isBusy {
                ProgressView().controlSize(.small).tint(Theme.secondary).padding(.trailing, 4)
            }
            CircleIconButton(
                systemImage: "power",
                tint: model.power.isOn ? Theme.primary : Theme.secondary,
                glow: model.power.isOn ? Theme.pink : nil
            ) {
                Task {
                    if model.power.isOn { await model.turnOff() } else { await model.turnOn(switchToMac: true) }
                }
            }
            .disabled(!model.isPaired)
            .help(model.power.isOn ? "Turn TV off" : "Turn TV on and switch to the Mac")
        }
    }

    /// Things drawn *on* the mini-TV screen: the current source, and a volume OSD that
    /// mirrors what the real TV shows.
    @ViewBuilder
    private var screenOverlay: some View {
        if model.power == .on {
            ZStack {
                if let source = model.currentSourceLabel {
                    HStack(spacing: 4) {
                        if model.isShowingMacInput { Image(systemName: "laptopcomputer") }
                        Text(model.isShowingMacInput ? "Mac · \(source)" : source)
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 7).frame(height: 18)
                    .background(Capsule().fill(.black.opacity(0.45)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(8)
                }
                if osdVisible {
                    volumeOSD
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(10)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
        }
    }

    private var volumeOSD: some View {
        HStack(spacing: 6) {
            Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 9, weight: .bold))
            HStack(spacing: 1.5) {
                ForEach(0..<20) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Double(i) < Double(model.volume ?? 0) / 5 && !model.isMuted ? Color.white : Color.white.opacity(0.22))
                        .frame(width: 3, height: 8)
                }
            }
            Text("\(model.volume ?? 0)")
                .font(.system(size: 10, weight: .bold, design: .rounded)).monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8).frame(height: 20)
        .background(Capsule().fill(.black.opacity(0.55)))
    }

    private func showOSD() {
        guard model.power == .on else { return }
        withAnimation(.spring(duration: 0.3)) { osdVisible = true }
        osdToken += 1
        let token = osdToken
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard token == osdToken else { return }
            withAnimation(.easeOut(duration: 0.4)) { osdVisible = false }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        Group {
            if model.awaitingPairingApproval {
                Text("Accept the prompt on your TV…").foregroundStyle(.orange)
            } else if !model.isPaired {
                Text("Not set up").foregroundStyle(Theme.secondary)
            } else if model.power != .on {
                Text(model.power.label).foregroundStyle(Theme.secondary)
            } else {
                Text("Scroll the dial · tap to mute").foregroundStyle(Theme.tertiary)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .contentTransition(.opacity)
        .frame(height: 16)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(alignment: .center, spacing: 14) {
            VolumeDial(
                value: model.volume,
                muted: model.isMuted,
                enabled: model.power.isOn,
                onChange: { model.setVolume($0) },
                onToggleMute: { Task { await model.toggleMute() } }
            )
            VStack(spacing: 8) {
                ActionRow(systemImage: "cursorarrow.motionlines", title: "TV Mouse",
                          trailing: nil, active: model.tvMouse.isActive) {
                    Task { await model.toggleTVMouse() }
                }
                .help("Use the trackpad as a TV mouse (⌃⌥M)")
                ActionRow(systemImage: "laptopcomputer", title: "Mac",
                          trailing: model.macInput?.label, active: model.isShowingMacInput) {
                    guard !model.macInputId.isEmpty else { return showSettings() }
                    Task { await model.switchInput(model.macInputId) }
                }
                ActionRow(systemImage: model.power == .screenOff ? "moon.zzz.fill" : "moon.zzz",
                          title: model.power == .screenOff ? "Screen on" : "Screen off",
                          trailing: nil, active: model.power == .screenOff) {
                    Task { await model.toggleScreen() }
                }
            }
            .disabled(!model.power.isOn)
            .opacity(model.power.isOn ? 1 : 0.5)
        }
    }

    @ViewBuilder
    private var inputChips: some View {
        if !model.inputs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("INPUTS")
                    .font(.system(size: 10, weight: .bold)).tracking(1.2)
                    .foregroundStyle(Theme.tertiary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.inputs) { input in
                            InputChip(
                                label: input.label,
                                selected: model.power == .on && model.foregroundAppId == input.appId,
                                isMac: input.id == model.macInputId,
                                connected: input.connected
                            ) {
                                Task { await model.switchInput(input.id) }
                            }
                        }
                    }
                }
            }
            .disabled(!model.power.isOn)
            .opacity(model.power.isOn ? 1 : 0.5)
        }
    }

    // MARK: Setup, errors, footer

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect your TV").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.primary)
            Text("Find your LG on the network and pair once. You'll accept a prompt on the TV.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button { showSettings() } label: {
                Text("Set up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.85))
                    .padding(.horizontal, 18).frame(height: 32)
                    .background(Capsule().fill(Theme.accent))
            }
            .buttonStyle(PressableStyle())
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
            VStack(alignment: .leading, spacing: 6) {
                Text(text).foregroundStyle(Theme.primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                if model.localNetworkBlocked {
                    Button("Open Local Network Settings") { model.openLocalNetworkSettings() }
                        .buttonStyle(.link)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5))
        .padding(10)
        .background(Theme.warn.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.warn.opacity(0.25)))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var footer: some View {
        @Bindable var model = model
        let connected = model.isPaired && model.power != .unreachable && model.power != .unknown("")
        return HStack(spacing: 8) {
            Image(systemName: connected ? "wifi" : "wifi.slash")
                .foregroundStyle(connected ? Theme.secondary : Theme.tertiary)
            Text(connected ? "Connected" : (model.isPaired ? "Offline" : "Not paired"))
                .foregroundStyle(Theme.secondary)
            Spacer()
            Button {
                model.automationsEnabled.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "wand.and.stars").font(.system(size: 10, weight: .semibold))
                    Text(model.automationsEnabled ? "Auto on" : "Auto off")
                }
                .foregroundStyle(model.automationsEnabled ? Theme.primary : Theme.tertiary)
                .padding(.horizontal, 9).frame(height: 24)
                .card(radius: 12, highlighted: model.automationsEnabled)
            }
            .buttonStyle(PressableStyle())
            .help("Turn the TV on/off with the Mac's sleep, wake and lock")
            Menu {
                Button("Settings…") { showSettings() }
                Button("Refresh") { Task { await model.refresh() } }
                Divider()
                Button("Quit TV Companion") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(PressableStyle())
            .menuIndicator(.hidden)
        }
        .font(.system(size: 12, weight: .medium))
    }

    private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }
}
