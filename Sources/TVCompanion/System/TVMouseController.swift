import AppKit
import Observation
import SwiftUI

/// "Pointer lock" mode: freezes and hides the Mac cursor, and forwards trackpad/keyboard
/// input to the TV. Input is only captured through a local event monitor on our own
/// key panel, so no Accessibility/Input Monitoring permission is needed.
@MainActor
@Observable
final class TVMouseController {
    private(set) var isActive = false
    var sensitivity: Double = 1.5
    var invertScroll = false
    var onEnded: ((_ error: String?) -> Void)?

    @ObservationIgnored private var socket: PointerSocket?
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var flushTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var move = DeltaAccumulator()
    @ObservationIgnored private var scroll = DeltaAccumulator()
    @ObservationIgnored private var playing = true
    @ObservationIgnored private var savedCursor: CGPoint?

    func start(socketURL: URL, pinnedFingerprint: String?) {
        guard !isActive else { return }
        socket = PointerSocket(url: socketURL, pinnedFingerprint: pinnedFingerprint) { [weak self] in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                self.stop(error: "The TV closed the pointer connection.")
            }
        }
        isActive = true
        showPanel()
        lockCursor()
        installMonitor()

        flushTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
        RunLoop.main.add(flushTimer!, forMode: .common)

        let nc = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification, NSApplication.willTerminateNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            })
        }
    }

    func stop(error: String? = nil) {
        guard isActive else { return }
        isActive = false
        flushTimer?.invalidate()
        flushTimer = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        unlockCursor()
        panel?.orderOut(nil)
        panel = nil
        socket?.close()
        socket = nil
        move = DeltaAccumulator()
        scroll = DeltaAccumulator()
        onEnded?(error)
    }

    // MARK: Input

    private func installMonitor() {
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
            .scrollWheel, .keyDown, .keyUp, .magnify, .swipe,
        ]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self, self.isActive else { return event }
            self.handle(event)
            return nil  // swallow: the Mac shouldn't react while in TV Mouse mode
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .mouseMoved, .leftMouseDragged:
            move.add(dx: event.deltaX * sensitivity, dy: event.deltaY * sensitivity)
        case .leftMouseDown:
            socket?.send(.click)
        case .rightMouseDown:
            socket?.send(.button("BACK"))
        case .scrollWheel:
            let sign: Double = invertScroll ? -1 : 1
            let factor = event.hasPreciseScrollingDeltas ? 0.5 : 4
            scroll.add(dx: event.scrollingDeltaX * factor * sign, dy: event.scrollingDeltaY * factor * sign)
        case .keyDown:
            handleKey(event)
        default:
            break
        }
    }

    private func handleKey(_ event: NSEvent) {
        if let button = Self.button(forKeyCode: event.keyCode) {
            socket?.send(.button(button))
            return
        }
        switch event.keyCode {
        case 53: stop()  // Esc
        case 49 where !event.isARepeat:  // Space
            playing.toggle()
            socket?.send(.button(playing ? "PLAY" : "PAUSE"))
        default: break
        }
    }

    /// Keyboard → TV remote buttons (arrow keys, OK, Back, Home, volume).
    nonisolated static func button(forKeyCode code: UInt16) -> String? {
        switch code {
        case 123: "LEFT"
        case 124: "RIGHT"
        case 125: "DOWN"
        case 126: "UP"
        case 36, 76: "ENTER"   // Return, keypad Enter
        case 51: "BACK"        // Delete
        case 4: "HOME"         // H
        case 24: "VOLUMEUP"    // =/+
        case 27: "VOLUMEDOWN"  // -
        case 46: "MUTE"        // M
        default: nil
        }
    }

    private func flush() {
        if let d = move.drain() { socket?.send(.move(dx: d.dx, dy: d.dy, down: false)) }
        if let s = scroll.drain() { socket?.send(.scroll(dx: s.dx, dy: s.dy)) }
    }

    // MARK: Cursor + panel

    private func lockCursor() {
        savedCursor = CGEvent(source: nil)?.location
        if let panel {
            // Park the (hidden) cursor over our panel so all mouse events are routed to it.
            let f = panel.frame
            let primaryHeight = NSScreen.screens.first?.frame.height ?? f.maxY
            CGWarpMouseCursorPosition(CGPoint(x: f.midX, y: primaryHeight - f.midY))
        }
        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()
    }

    private func unlockCursor() {
        CGAssociateMouseAndMouseCursorPosition(1)
        if let savedCursor { CGWarpMouseCursorPosition(savedCursor) }
        savedCursor = nil
        NSCursor.unhide()
    }

    private func showPanel() {
        let size = NSSize(width: 380, height: 150)
        let panel = KeyPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: TVMouseHUD())
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let vf = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.maxY - size.height - 40))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }
}

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct TVMouseHUD: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("TV Mouse", systemImage: "cursorarrow.motionlines")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow { Text("Move / click"); Text("trackpad").foregroundStyle(.secondary) }
                GridRow { Text("Back"); Text("right-click or ⌫").foregroundStyle(.secondary) }
                GridRow { Text("Navigate / OK"); Text("arrows, Return").foregroundStyle(.secondary) }
                GridRow { Text("Play/pause · Home"); Text("Space · H").foregroundStyle(.secondary) }
            }
            .font(.callout)
            Text("Esc or ⌃⌥M to give the trackpad back to the Mac")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
