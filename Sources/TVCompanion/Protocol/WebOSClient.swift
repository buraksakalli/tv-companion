import Foundation
import os

enum WebOSError: LocalizedError, Equatable {
    case invalidHost
    case notConnected
    case timeout(String)
    case pairingRejected(String)
    case certificateChanged
    case tv(String)
    case localNetworkBlocked

    var errorDescription: String? {
        switch self {
        case .invalidHost: "Invalid TV address."
        case .notConnected: "Not connected to the TV."
        case .timeout(let what): "Timed out waiting for the TV (\(what))."
        case .pairingRejected(let why): "Pairing failed: \(why)"
        case .certificateChanged:
            "The TV presented a different certificate than the one pinned at pairing. "
                + "If you reset or replaced the TV, use “Forget TV” and pair again."
        case .tv(let msg): "TV error: \(msg)"
        case .localNetworkBlocked:
            "macOS is blocking TV Companion from the local network. "
                + "Turn it on in System Settings → Privacy & Security → Local Network."
        }
    }
}

/// A single WebSocket session with an LG webOS TV.
actor WebOSClient {
    struct Registration: Sendable {
        let clientKey: String
        let certificateFingerprint: String?
    }

    nonisolated let host: String
    private let pinnedFingerprint: String?
    private let log = Logger(subsystem: "com.buraksakalli.tvcompanion", category: "webos")

    private var session: URLSession?
    private var pinning: CertificatePinningDelegate?
    private var socket: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var registerTimeout: Task<Void, Never>?
    private var registerContinuation: CheckedContinuation<String, Error>?
    private var pending: [String: CheckedContinuation<SSAPMessage, Error>] = [:]
    private var counter = 0
    private var onPairingPrompt: (@Sendable () -> Void)?
    private var onDisconnect: (@Sendable () -> Void)?

    private(set) var isConnected = false

    init(host: String, pinnedFingerprint: String?) {
        self.host = host
        self.pinnedFingerprint = pinnedFingerprint
    }

    // MARK: Connection

    /// Opens the socket and registers. With no `clientKey`, the TV shows an
    /// "allow this device" prompt and the user has `pairingTimeout` to accept.
    func connect(
        clientKey: String?,
        connectTimeout: Duration = .seconds(6),
        pairingTimeout: Duration = .seconds(60),
        onPairingPrompt: (@Sendable () -> Void)? = nil,
        onDisconnect: (@Sendable () -> Void)? = nil
    ) async throws -> Registration {
        guard Self.isValidHost(host), let url = URL(string: "wss://\(host):\(SSAP.port)/") else {
            throw WebOSError.invalidHost
        }
        disconnect()
        self.onPairingPrompt = onPairingPrompt
        self.onDisconnect = onDisconnect

        let delegate = CertificatePinningDelegate(pinnedFingerprint: pinnedFingerprint)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let socket = session.webSocketTask(with: url)
        self.session = session
        self.pinning = delegate
        self.socket = socket
        socket.resume()
        startReceiving(socket)

        let key: String = try await withCheckedThrowingContinuation { cont in
            registerContinuation = cont
            armRegisterTimeout(connectTimeout, pairingTimeout: pairingTimeout)
            let frame = SSAP.registerMessage(clientKey: clientKey)
            Task { await self.sendFrame(frame, failing: nil) }
        }
        isConnected = true
        log.info("Registered with TV at \(self.host, privacy: .public)")
        return Registration(clientKey: key, certificateFingerprint: delegate.observedFingerprint)
    }

    func disconnect() {
        registerTimeout?.cancel()
        receiveLoop?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        socket = nil
        session = nil
        receiveLoop = nil
        isConnected = false
        failAll(WebOSError.notConnected)
    }

    // MARK: Requests

    /// Sends an SSAP request and waits for its response payload.
    @discardableResult
    func request(_ uri: String, payload: JSONValue = [:], timeout: Duration = .seconds(6)) async throws -> JSONValue {
        guard isConnected else { throw WebOSError.notConnected }
        counter += 1
        let id = "req_\(counter)"
        let frame: JSONValue = [
            "type": "request", "id": .string(id), "uri": .string("ssap://" + uri), "payload": payload,
        ]
        let message: SSAPMessage = try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            Task { await self.sendFrame(frame, failing: id) }
            Task {
                try? await Task.sleep(for: timeout)
                self.resolve(id, with: .failure(WebOSError.timeout(uri)))
            }
        }
        if message.type == "error" {
            throw WebOSError.tv(message.error ?? "unknown error")
        }
        let payload = message.payload ?? .null
        if payload["returnValue"]?.bool == false {
            throw WebOSError.tv(payload["errorText"]?.string ?? payload["errorCode"]?.string ?? "request failed")
        }
        return payload
    }

    /// Sends a request without waiting (used for power-off, whose reply is unreliable).
    func send(_ uri: String, payload: JSONValue = [:]) async throws {
        guard isConnected else { throw WebOSError.notConnected }
        counter += 1
        let frame: JSONValue = [
            "type": "request", "id": .string("req_\(counter)"), "uri": .string("ssap://" + uri), "payload": payload,
        ]
        try await socket?.send(.string(Self.encode(frame)))
    }

    // MARK: Internals

    private func sendFrame(_ frame: JSONValue, failing id: String?) async {
        do {
            try await socket?.send(.string(Self.encode(frame)))
        } catch {
            if let id { resolve(id, with: .failure(error)) } else { failRegister(error) }
        }
    }

    private func startReceiving(_ socket: URLSessionWebSocketTask) {
        receiveLoop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let frame = try await socket.receive()
                    await self?.handle(frame)
                } catch {
                    await self?.connectionLost(error)
                    return
                }
            }
        }
    }

    private func handle(_ frame: URLSessionWebSocketTask.Message) {
        let data: Data
        switch frame {
        case .string(let s): data = Data(s.utf8)
        case .data(let d): data = d
        @unknown default: return
        }
        guard let message = try? JSONDecoder().decode(SSAPMessage.self, from: data) else { return }

        if message.id == "register_0" {
            switch message.type {
            case "registered":
                if let key = message.payload?["client-key"]?.string {
                    registerTimeout?.cancel()
                    registerContinuation?.resume(returning: key)
                    registerContinuation = nil
                } else {
                    failRegister(WebOSError.pairingRejected("TV did not return a client key"))
                }
            case "response" where message.payload?["pairingType"]?.string == "PROMPT":
                // TV is showing the "allow" prompt; give the user time to accept.
                armRegisterTimeout(nil, pairingTimeout: .seconds(60))
                onPairingPrompt?()
            case "error":
                failRegister(WebOSError.pairingRejected(message.error ?? "rejected on TV"))
            default:
                break
            }
            return
        }
        if let id = message.id { resolve(id, with: .success(message)) }
    }

    private func armRegisterTimeout(_ connectTimeout: Duration?, pairingTimeout: Duration) {
        registerTimeout?.cancel()
        let wait = connectTimeout ?? pairingTimeout
        registerTimeout = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            await self?.failRegister(WebOSError.timeout(connectTimeout == nil ? "pairing approval" : "connect"))
        }
    }

    private func connectionLost(_ error: Error) {
        let wasConnected = isConnected
        let mapped: Error
        if let pinnedFingerprint, let seen = pinning?.observedFingerprint, seen != pinnedFingerprint {
            mapped = WebOSError.certificateChanged
        } else {
            mapped = Self.map(error)
        }
        log.info("Socket closed: \(mapped.localizedDescription, privacy: .public)")
        isConnected = false
        failRegister(mapped)
        failAll(mapped)
        session?.invalidateAndCancel()
        session = nil
        socket = nil
        if wasConnected { onDisconnect?() }
    }

    private func failRegister(_ error: Error) {
        registerTimeout?.cancel()
        registerContinuation?.resume(throwing: error)
        registerContinuation = nil
        if !isConnected { socket?.cancel(with: .goingAway, reason: nil) }
    }

    private func resolve(_ id: String, with result: Result<SSAPMessage, Error>) {
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func failAll(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        waiting.values.forEach { $0.resume(throwing: error) }
    }

    /// macOS reports a Local Network privacy denial as "not connected to internet" (-1009).
    nonisolated static func map(_ error: Error) -> Error {
        if let e = error as? URLError, e.code == .notConnectedToInternet { return WebOSError.localNetworkBlocked }
        return error
    }

    private static func encode(_ value: JSONValue) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    /// Accepts IPv4/IPv6 literals and plain hostnames; rejects schemes, paths, ports.
    nonisolated static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        return host.unicodeScalars.allSatisfy { allowed.contains($0) }
            && !host.hasPrefix("-") && !host.hasPrefix(".")
    }
}

// MARK: - High-level commands

extension WebOSClient {
    func powerState() async throws -> TVPower {
        TVPower(state: try await request(SSAP.powerState)["state"]?.string)
    }

    func inputs() async throws -> [TVInput] {
        let devices = try await request(SSAP.inputs)["devices"]?.array ?? []
        return devices.compactMap { d in
            guard let id = d["id"]?.string else { return nil }
            return TVInput(
                id: id,
                label: d["label"]?.string ?? id,
                appId: d["appId"]?.string,
                connected: d["connected"]?.bool ?? false
            )
        }
    }

    func foregroundAppId() async throws -> String? {
        try await request(SSAP.foregroundApp)["appId"]?.string
    }

    func switchInput(_ inputId: String) async throws {
        try await request(SSAP.switchInput, payload: ["inputId": .string(inputId)])
    }

    func powerOff() async throws { try await send(SSAP.powerOff) }
    func screenOff() async throws { try await request(SSAP.screenOff) }
    func screenOn() async throws { try await request(SSAP.screenOn) }
    func volumeUp() async throws { try await request(SSAP.volumeUp) }
    func volumeDown() async throws { try await request(SSAP.volumeDown) }

    func audioStatus() async throws -> AudioStatus {
        let status = AudioStatus(payload: try await request(SSAP.audioStatus))
        if status.volume != nil { return status }
        let v = AudioStatus(payload: try await request(SSAP.getVolume))
        return AudioStatus(volume: v.volume, muted: status.muted || v.muted)
    }

    func setVolume(_ volume: Int) async throws {
        try await request(SSAP.setVolume, payload: ["volume": .number(Double(min(max(volume, 0), 100)))])
    }

    func setMute(_ muted: Bool) async throws {
        try await request(SSAP.setMute, payload: ["mute": .bool(muted)])
    }

    func pointerSocketPath() async throws -> String? {
        try await request(SSAP.pointerSocket)["socketPath"]?.string
    }

    func toast(_ message: String) async throws {
        try await request(SSAP.toast, payload: ["message": .string(message)])
    }

    /// The TV's MAC address (for Wake-on-LAN), if the firmware exposes it.
    func macAddress() async throws -> String? {
        let info = try await request(SSAP.connectionInfo)
        return Self.macAddress(fromConnectionInfo: info)
    }

    nonisolated static func macAddress(fromConnectionInfo info: JSONValue) -> String? {
        let candidates = ["wiredInfo", "wifiInfo"].compactMap { info[$0] }
        let connected = candidates.first { $0["state"]?.string == "connected" }
        for iface in [connected].compactMap({ $0 }) + candidates {
            if let mac = iface["macAddress"]?.string, MACAddress(mac) != nil { return mac }
        }
        return nil
    }
}
