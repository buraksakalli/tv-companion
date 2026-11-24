import Darwin
import Foundation
import Testing
@testable import TVCompanion

@Suite struct MACAddressTests {
    @Test func parsesCommonFormats() {
        #expect(MACAddress("a4:36:c7:01:02:0f")?.description == "A4:36:C7:01:02:0F")
        #expect(MACAddress("A4-36-C7-01-02-0F")?.description == "A4:36:C7:01:02:0F")
        #expect(MACAddress("a4:36:c7:1:2:f")?.description == "A4:36:C7:01:02:0F")  // arp short form
    }

    @Test func rejectsInvalid() {
        #expect(MACAddress("") == nil)
        #expect(MACAddress("a4:36:c7:01:02") == nil)
        #expect(MACAddress("zz:36:c7:01:02:0f") == nil)
        #expect(MACAddress("00:00:00:00:00:00") == nil)
        #expect(MACAddress("ff:ff:ff:ff:ff:ff") == nil)
        #expect(MACAddress("(incomplete)") == nil)
    }
}

@Suite struct WakeOnLANTests {
    @Test func magicPacketLayout() throws {
        let mac = try #require(MACAddress("01:02:03:04:05:06"))
        let packet = WakeOnLAN.magicPacket(for: mac)
        #expect(packet.count == 102)
        #expect(packet.prefix(6).allSatisfy { $0 == 0xFF })
        for i in 0..<16 {
            #expect(Array(packet[(6 + i * 6)..<(12 + i * 6)]) == [1, 2, 3, 4, 5, 6])
        }
    }

    @Test func directedBroadcast() {
        func addr(_ s: String) -> in_addr_t { var a = in_addr(); inet_pton(AF_INET, s, &a); return a.s_addr }
        #expect(LocalInterfaces.broadcast(ip: addr("192.168.1.10"), netmask: addr("255.255.255.0"),
                                          target: addr("192.168.1.40")) == "192.168.1.255")
        #expect(LocalInterfaces.broadcast(ip: addr("10.0.4.2"), netmask: addr("255.255.252.0"),
                                          target: addr("10.0.5.9")) == "10.0.7.255")
        #expect(LocalInterfaces.broadcast(ip: addr("192.168.1.10"), netmask: addr("255.255.255.0"),
                                          target: addr("192.168.2.40")) == nil)
    }

    @Test func parsesARPOutput() {
        let line = "? (192.168.1.40) at a4:36:c7:1:2:3 on en0 ifscope [ethernet]\n"
        #expect(LocalInterfaces.parseARP(line)?.description == "A4:36:C7:01:02:03")
        #expect(LocalInterfaces.parseARP("? (192.168.1.40) at (incomplete) on en0 ifscope [ethernet]") == nil)
        #expect(LocalInterfaces.parseARP("192.168.1.40 (192.168.1.40) -- no entry") == nil)
    }
}

@Suite struct ProtocolTests {
    @Test func decodesMessagesWithStringOrNumericIds() throws {
        let a = try JSONDecoder().decode(SSAPMessage.self, from: Data(#"{"type":"response","id":"req_3","payload":{"returnValue":true,"state":"Active"}}"#.utf8))
        #expect(a.id == "req_3")
        #expect(a.payload?["state"]?.string == "Active")
        let b = try JSONDecoder().decode(SSAPMessage.self, from: Data(#"{"type":"error","id":7,"error":"401 insufficient permissions"}"#.utf8))
        #expect(b.id == "7")
        #expect(b.error == "401 insufficient permissions")
    }

    @Test func registerMessageIncludesKeyOnlyWhenPresent() throws {
        let withKey = SSAP.registerMessage(clientKey: "k")
        #expect(withKey["type"]?.string == "register")
        #expect(withKey["payload"]?["client-key"]?.string == "k")
        #expect(withKey["payload"]?["pairingType"]?.string == "PROMPT")
        #expect(SSAP.registerMessage(clientKey: nil)["payload"]?["client-key"] == nil)
        // Round-trips through JSON.
        let data = try JSONEncoder().encode(withKey)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == withKey)
    }

    @Test func powerStates() {
        #expect(TVPower(state: "Active") == .on)
        #expect(TVPower(state: "Screen Off") == .screenOff)
        #expect(TVPower(state: "Active Standby") == .standby)
        #expect(TVPower(state: "Suspend").isOn == false)
        #expect(TVPower(state: "Screen Off").isOn)
    }

    @Test func macFromConnectionInfoPrefersConnectedInterface() {
        let info: JSONValue = [
            "wiredInfo": ["state": "disconnected", "macAddress": "11:22:33:44:55:66"],
            "wifiInfo": ["state": "connected", "macAddress": "aa:bb:cc:dd:ee:ff"],
        ]
        #expect(WebOSClient.macAddress(fromConnectionInfo: info) == "aa:bb:cc:dd:ee:ff")
        #expect(WebOSClient.macAddress(fromConnectionInfo: ["wiredInfo": ["macAddress": "11:22:33:44:55:66"]]) == "11:22:33:44:55:66")
        #expect(WebOSClient.macAddress(fromConnectionInfo: [:]) == nil)
    }

    @Test func hostValidation() {
        #expect(WebOSClient.isValidHost("192.168.1.40"))
        #expect(WebOSClient.isValidHost("lg-tv.local"))
        #expect(!WebOSClient.isValidHost(""))
        #expect(!WebOSClient.isValidHost("wss://192.168.1.40"))
        #expect(!WebOSClient.isValidHost("192.168.1.40:3001"))
        #expect(!WebOSClient.isValidHost("192.168.1.40/evil"))
        #expect(!WebOSClient.isValidHost("-rf"))
    }

    @Test func mapsLocalNetworkDenial() {
        #expect(WebOSClient.map(URLError(.notConnectedToInternet)) as? WebOSError == .localNetworkBlocked)
        #expect(WebOSClient.map(URLError(.timedOut)) as? WebOSError == nil)
    }

    @Test func defaultInputAppIds() {
        #expect(AppModel.defaultAppId(forInput: "HDMI_2") == "com.webos.app.hdmi2")
        #expect(AppModel.defaultAppId(forInput: "AV_1") == nil)
    }

    @Test func certificateFingerprintFormat() {
        let fp = CertificatePinningDelegate.fingerprint(of: Data("abc".utf8))
        #expect(fp == "BA:78:16:BF:8F:01:CF:EA:41:41:40:DE:5D:AE:22:23:B0:03:61:A3:96:17:7A:9C:B4:10:FF:61:F2:00:15:AD")
    }
}

@Suite struct SSDPTests {
    @Test func acceptsWebOSResponse() {
        let response = [
            "HTTP/1.1 200 OK",
            "CACHE-CONTROL: max-age=1800",
            "ST: urn:lge-com:service:webos-second-screen:1",
            "USN: uuid:abc::urn:lge-com:service:webos-second-screen:1",
            "DLNADeviceName.lge.com: %5BLG%5D%20webOS%20TV%20OLED65C5",
            "", "",
        ].joined(separator: "\r\n")
        let tv = SSDPDiscovery.parse(response: response, from: "192.168.1.40")
        #expect(tv == DiscoveredTV(host: "192.168.1.40", name: "[LG] webOS TV OLED65C5"))
        #expect(DiscoveredTV.model(fromName: "[LG] webOS TV OLED65C5") == "OLED65C5")
        #expect(DiscoveredTV.model(fromName: "Living Room") == "Living Room")
    }

    @Test func ignoresOtherDevices() {
        let response = "HTTP/1.1 200 OK\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n"
        #expect(SSDPDiscovery.parse(response: response, from: "192.168.1.50") == nil)
    }
}

@Suite struct PointerTests {
    @Test func frames() {
        #expect(PointerCommand.move(dx: 3, dy: -2, down: false).frame == "type:move\ndx:3\ndy:-2\ndown:0\n\n")
        #expect(PointerCommand.click.frame == "type:click\n\n")
        #expect(PointerCommand.scroll(dx: 0, dy: 5).frame == "type:scroll\ndx:0\ndy:5\n\n")
        #expect(PointerCommand.button("BACK").frame == "type:button\nname:BACK\n\n")
    }

    @Test func accumulatorKeepsRemainders() {
        var acc = DeltaAccumulator()
        acc.add(dx: 0.4, dy: -0.4)
        #expect(acc.drain() == nil)
        acc.add(dx: 0.7, dy: -0.7)
        let d = acc.drain()
        #expect(d?.dx == 1 && d?.dy == -1)
        #expect(abs(acc.x - 0.1) < 1e-9 && abs(acc.y + 0.1) < 1e-9)
    }

    @Test func socketPathValidation() {
        let host = "192.168.1.40"
        #expect(PointerSocket.validatedURL("wss://192.168.1.40:3001/resources/abc/netinput.pointer.sock", tvHost: host) != nil)
        #expect(PointerSocket.validatedURL("ws://192.168.1.40:3000/resources/abc/netinput.pointer.sock", tvHost: host) == nil)
        #expect(PointerSocket.validatedURL("wss://evil.example:3001/x", tvHost: host) == nil)
        #expect(PointerSocket.validatedURL("wss://u@192.168.1.40:3001/x", tvHost: host) == nil)
        #expect(PointerSocket.validatedURL(nil, tvHost: host) == nil)
    }

    @Test func keyMapping() {
        #expect(TVMouseController.button(forKeyCode: 126) == "UP")
        #expect(TVMouseController.button(forKeyCode: 36) == "ENTER")
        #expect(TVMouseController.button(forKeyCode: 51) == "BACK")
        #expect(TVMouseController.button(forKeyCode: 53) == nil)  // Esc exits instead
    }
}

@Suite struct AudioTests {
    @Test func parsesFlatAndNestedShapes() {
        #expect(AudioStatus(payload: ["volume": .number(23), "mute": false]) == AudioStatus(volume: 23, muted: false))
        #expect(AudioStatus(payload: ["volumeStatus": ["volume": .number(40), "muteStatus": true]]) == AudioStatus(volume: 40, muted: true))
        #expect(AudioStatus(payload: ["volume": .number(-1)]).volume == nil)  // external speaker
    }
}
