import Foundation
import Network

/// Launch with `--probe` to test reachability from inside the app process (which is
/// what macOS Local Network privacy judges). Writes ~/Library/Logs/TVCompanion/probe.log.
/// Sends only a webOS "hello" — no pairing prompt, no client key involved.
enum ConnectionProbe {
    static var requested: Bool { CommandLine.arguments.contains("--probe") }

    static func run(host: String) async {
        var lines = ["TV Companion probe \(Date().ISO8601Format())", "host: \(host)"]
        guard WebOSClient.isValidHost(host) else {
            lines.append("invalid or empty host")
            return write(lines)
        }

        // 1. Path status as seen by this process.
        let monitor = NWPathMonitor()
        let path: NWPath = await withCheckedContinuation { cont in
            let once = OnceFlag()
            monitor.pathUpdateHandler = { p in if once.fire() { cont.resume(returning: p) } }
            monitor.start(queue: .global())
        }
        monitor.cancel()
        lines.append("path: \(path.status) interfaces=\(path.availableInterfaces.map(\.name)) unsatisfiedReason=\(path.unsatisfiedReason)")

        // 2. Raw TCP to 3001.
        lines.append("tcp 3001: " + (await tcp(host: host, port: 3001)))

        // 3. WebSocket over TLS + hello.
        lines.append("wss hello: " + (await wssHello(host: host)))
        write(lines)
    }

    private static func tcp(host: String, port: UInt16) async -> String {
        let conn = NWConnection(host: .init(host), port: .init(rawValue: port)!, using: .tcp)
        return await withCheckedContinuation { cont in
            let once = OnceFlag()
            conn.stateUpdateHandler = { state in
                let result: String? = switch state {
                case .ready: "ready"
                case .failed(let e): "failed \(e)"
                case .waiting(let e): "waiting \(e)"
                default: nil
                }
                if let result, once.fire() { conn.cancel(); cont.resume(returning: result) }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if once.fire() { conn.cancel(); cont.resume(returning: "timeout") }
            }
        }
    }

    private static func wssHello(host: String) async -> String {
        let delegate = CertificatePinningDelegate(pinnedFingerprint: nil)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.webSocketTask(with: URL(string: "wss://\(host):\(SSAP.port)/")!)
        task.resume()
        do {
            try await task.send(.string(#"{"type":"hello","id":"hello","payload":{}}"#))
            let reply = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { g in
                g.addTask { try await task.receive() }
                g.addTask { try await Task.sleep(for: .seconds(6)); throw URLError(.timedOut) }
                let first = try await g.next()!
                g.cancelAll()
                return first
            }
            let text: String = switch reply {
            case .string(let s): s
            case .data(let d): String(decoding: d, as: UTF8.self)
            @unknown default: "?"
            }
            let type = (try? JSONDecoder().decode(SSAPMessage.self, from: Data(text.utf8)))?.type ?? "unparsed"
            return "ok (reply type: \(type)) cert=\(delegate.observedFingerprint?.prefix(11) ?? "none")"
        } catch let e as URLError {
            let underlying = (e.userInfo[NSUnderlyingErrorKey] as? NSError).map { " underlying=\($0.domain)#\($0.code)" } ?? ""
            return "URLError \(e.code.rawValue) \(e.localizedDescription)\(underlying) cert=\(delegate.observedFingerprint?.prefix(11) ?? "none")"
        } catch {
            return "error \(error)"
        }
    }

    private static func write(_ lines: [String]) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/TVCompanion")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: dir.appending(path: "probe.log"), atomically: true, encoding: .utf8)
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool { lock.withLock { defer { fired = true }; return !fired } }
}
