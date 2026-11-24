import Foundation
import os

/// Commands understood by the TV's pointer input socket (Magic Remote channel).
enum PointerCommand: Sendable, Equatable {
    case move(dx: Int, dy: Int, down: Bool)
    case click
    case scroll(dx: Int, dy: Int)
    case button(String)

    var frame: String {
        switch self {
        case let .move(dx, dy, down): "type:move\ndx:\(dx)\ndy:\(dy)\ndown:\(down ? 1 : 0)\n\n"
        case .click: "type:click\n\n"
        case let .scroll(dx, dy): "type:scroll\ndx:\(dx)\ndy:\(dy)\n\n"
        case .button(let name): "type:button\nname:\(name)\n\n"
        }
    }
}

/// Second WebSocket to the TV for pointer/button input. Commands are queued through
/// an AsyncStream so they reach the TV in the order they were produced.
final class PointerSocket: @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let continuation: AsyncStream<PointerCommand>.Continuation
    private let sender: Task<Void, Never>
    private let log = Logger(subsystem: "com.buraksakalli.tvcompanion", category: "pointer")

    /// The TV hands us `socketPath`; treat it as untrusted and only accept wss on the TV's own host.
    static func validatedURL(_ socketPath: String?, tvHost: String) -> URL? {
        guard let socketPath, let url = URL(string: socketPath),
              url.scheme == "wss", url.host == tvHost, url.user == nil
        else { return nil }
        return url
    }

    init(url: URL, pinnedFingerprint: String?, onClose: @escaping @Sendable () -> Void) {
        let delegate = CertificatePinningDelegate(pinnedFingerprint: pinnedFingerprint)
        session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = 8 * 1024
        task.resume()

        let (stream, continuation) = AsyncStream<PointerCommand>.makeStream(bufferingPolicy: .bufferingNewest(256))
        self.continuation = continuation
        let task = self.task
        let log = self.log
        sender = Task.detached {
            for await command in stream {
                do { try await task.send(.string(command.frame)) } catch {
                    log.info("Pointer socket send failed: \(error.localizedDescription, privacy: .public)")
                    onClose()
                    return
                }
            }
        }
        // Drain anything the TV sends so we notice when it closes the socket.
        Task.detached {
            while true {
                do { _ = try await task.receive() } catch { onClose(); return }
            }
        }
    }

    func send(_ command: PointerCommand) { continuation.yield(command) }

    func close() {
        continuation.finish()
        sender.cancel()
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

/// Accumulates fractional trackpad deltas and emits whole-pixel moves at a fixed rate,
/// so a 120 Hz trackpad doesn't flood the TV and slow movements aren't lost to rounding.
struct DeltaAccumulator: Equatable {
    private(set) var x: Double = 0
    private(set) var y: Double = 0

    mutating func add(dx: Double, dy: Double) { x += dx; y += dy }

    /// Returns the whole part (if any) and keeps the remainder.
    mutating func drain() -> (dx: Int, dy: Int)? {
        let ix = Int(x.rounded(.towardZero)), iy = Int(y.rounded(.towardZero))
        guard ix != 0 || iy != 0 else { return nil }
        x -= Double(ix); y -= Double(iy)
        return (ix, iy)
    }
}
