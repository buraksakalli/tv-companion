import Darwin
import Foundation

struct MACAddress: Equatable, Sendable, CustomStringConvertible {
    let bytes: [UInt8]

    /// Accepts "aa:bb:cc:dd:ee:ff", "aa-bb-…", and arp's short form "a:b:c:d:e:f".
    init?(_ string: String) {
        let parts = string.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6 else { return nil }
        var bytes: [UInt8] = []
        for p in parts {
            guard (1...2).contains(p.count), let b = UInt8(p, radix: 16) else { return nil }
            bytes.append(b)
        }
        guard bytes != [0, 0, 0, 0, 0, 0], bytes != [255, 255, 255, 255, 255, 255] else { return nil }
        self.bytes = bytes
    }

    var description: String { bytes.map { String(format: "%02X", $0) }.joined(separator: ":") }
}

enum WakeOnLAN {
    /// 6 × 0xFF followed by the MAC repeated 16 times.
    static func magicPacket(for mac: MACAddress) -> [UInt8] {
        [UInt8](repeating: 0xFF, count: 6) + (0..<16).flatMap { _ in mac.bytes }
    }

    /// Sends the magic packet to the TV subnet's directed broadcast (when we can work
    /// it out from local interfaces) and to 255.255.255.255, on UDP 9 and 7.
    static func send(to mac: MACAddress, tvHost: String) throws {
        var targets = ["255.255.255.255"]
        if let directed = LocalInterfaces.directedBroadcast(forIPv4: tvHost) { targets.insert(directed, at: 0) }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))

        let packet = magicPacket(for: mac)
        var sentAny = false
        for target in targets {
            for port: UInt16 in [9, 7] {
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = port.bigEndian
                guard inet_pton(AF_INET, target, &addr.sin_addr) == 1 else { continue }
                let n = packet.withUnsafeBytes { buf in
                    withUnsafePointer(to: &addr) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                if n == packet.count { sentAny = true }
            }
        }
        if !sentAny { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
}

enum LocalInterfaces {
    /// For a TV at 192.168.1.40 on a /24 interface, returns "192.168.1.255".
    static func directedBroadcast(forIPv4 host: String) -> String? {
        var target = in_addr()
        guard inet_pton(AF_INET, host, &target) == 1 else { return nil }
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
        defer { freeifaddrs(ifap) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, let mask = ifa.ifa_netmask,
                  addr.pointee.sa_family == sa_family_t(AF_INET),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0,
                  ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0
            else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let nm = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            if let b = broadcast(ip: ip, netmask: nm, target: target.s_addr) { return b }
        }
        return nil
    }

    /// Pure helper (network byte order in, dotted string out); nil if target isn't on that subnet.
    static func broadcast(ip: in_addr_t, netmask: in_addr_t, target: in_addr_t) -> String? {
        guard ip & netmask == target & netmask, netmask != 0 else { return nil }
        var b = in_addr(s_addr: (ip & netmask) | ~netmask)
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &b, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Looks up a host's MAC in the system ARP cache (populated after we've talked to it).
    static func arpMAC(for host: String) -> MACAddress? {
        guard WebOSClient.isValidHost(host) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        p.arguments = ["-n", host]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return parseARP(text)
    }

    /// Parses "? (192.168.1.40) at a4:36:c7:1:2:3 on en0 ifscope [ethernet]".
    static func parseARP(_ text: String) -> MACAddress? {
        let tokens = text.split(separator: " ")
        guard let i = tokens.firstIndex(of: "at"), i + 1 < tokens.count else { return nil }
        return MACAddress(String(tokens[i + 1]))
    }
}
