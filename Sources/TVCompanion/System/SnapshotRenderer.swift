#if DEBUG
import AppKit
import SwiftUI

/// Debug-only: `--snapshot <dir>` renders the popover in several states to PNGs and quits.
@MainActor
enum SnapshotRenderer {
    static var requested: Bool { CommandLine.arguments.contains("--snapshot") }

    static func run(model: AppModel) async {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return NSApp.terminate(nil) }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let states: [(String, () -> Void)] = [
            ("on", { model.applyPreview(power: .on) }),
            ("muted", { model.applyPreview(power: .on, volume: 12, muted: true, mouse: false) }),
            ("screenoff", { model.applyPreview(power: .screenOff) }),
            ("off", { model.applyPreview(power: .standby, volume: nil) }),
            ("setup", { model.applyPreview(power: .unknown(""), paired: false, volume: nil) }),
        ]
        for (name, apply) in states {
            apply()
            let host = NSHostingView(rootView: MenuView().environment(model))
            let size = host.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -4000, y: -4000), size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            window.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(900))  // let transitions settle
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "\(name).png"))
            }
            window.orderOut(nil)
        }
        NSApp.terminate(nil)
    }
}
#endif
