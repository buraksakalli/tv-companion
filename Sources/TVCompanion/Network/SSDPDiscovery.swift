import Darwin
import Foundation

struct DiscoveredTV: Identifiable, Hashable, Sendable {
    var id: String { host }
    let host: String
    let name: String

    /// "[LG] webOS TV OLED65C5" → "OLED65C5".
    static func model(fromName name: String) -> String {
        var n = name
        for prefix in ["[LG]", "webOS TV"] {
            n = n.trimmingCharacters(in: .whitespaces)
            if n.hasPrefix(prefix) { n.removeFirst(prefix.count) }
        }
        return n.trimmingCharacters(in: .whitespaces)
    }
}

/// Finds LG webOS TVs on the LAN via SSDP (UPnP M-SEARCH).
enum SSDPDiscovery {
    static let searchTarget = "urn:lge-com:service:webos-second-screen:1"

    static func discover(timeout: TimeInterval = 3) async -> [DiscoveredTV] {
        await Task.detached(priority: .userInitiated) { search(timeout: timeout) }.value
    }

    private static func search(timeout: TimeInterval) -> [DiscoveredTV] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var ttl: UInt8 = 2
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        let request = [
            "M-SEARCH * HTTP/1.1",
            "HOST: 239.255.255.250:1900",
            "MAN: \"ssdp:discover\"",
            "MX: 2",
            "ST: \(searchTarget)",
            "", "",
        ].joined(separator: "\r\n")

        var dest = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = UInt16(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &dest.sin_addr)
        let bytes = Array(request.utf8)
        for _ in 0..<2 {
            _ = withUnsafePointer(to: &dest) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var found: [String: DiscoveredTV] = [:]
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 2048)
        while Date() < deadline {
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &len)
                }
            }
            guard n > 0 else { continue }
            var addrBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &from.sin_addr, &addrBuf, socklen_t(INET_ADDRSTRLEN))
            let host = String(decoding: addrBuf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if let tv = parse(response: String(decoding: buffer[0..<n], as: UTF8.self), from: host) {
                found[tv.host] = tv
            }
        }
        return found.values.sorted { $0.host < $1.host }
    }

    /// Accepts only responses for the webOS second-screen service.
    static func parse(response: String, from host: String) -> DiscoveredTV? {
        var headers: [String: String] = [:]
        for line in response.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["st"] == searchTarget || headers["usn"]?.contains(searchTarget) == true,
              WebOSClient.isValidHost(host)
        else { return nil }
        // LG adds a URL-encoded friendly name header; treat it as display text only.
        let rawName = headers["dlnadevicename.lge.com"]?.removingPercentEncoding
        let name = rawName.map { String($0.prefix(64)) }.flatMap { $0.isEmpty ? nil : $0 } ?? "LG TV"
        return DiscoveredTV(host: host, name: name)
    }
}
