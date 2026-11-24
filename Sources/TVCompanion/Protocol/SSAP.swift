import Foundation

/// LG webOS "second screen" (SSAP) endpoints used by the app.
/// Mirrors the public endpoint list used by Home Assistant's aiowebostv.
enum SSAP {
    static let port = 3001  // wss; plain ws://3000 is intentionally not used.

    static let powerOff = "system/turnOff"
    static let powerState = "com.webos.service.tvpower/power/getPowerState"
    static let screenOff = "com.webos.service.tvpower/power/turnOffScreen"
    static let screenOn = "com.webos.service.tvpower/power/turnOnScreen"
    static let inputs = "tv/getExternalInputList"
    static let switchInput = "tv/switchInput"
    static let foregroundApp = "com.webos.applicationManager/getForegroundAppInfo"
    static let toast = "system.notifications/createToast"
    static let volumeUp = "audio/volumeUp"
    static let volumeDown = "audio/volumeDown"
    static let setMute = "audio/setMute"
    static let audioStatus = "audio/getStatus"
    static let getVolume = "audio/getVolume"
    static let setVolume = "audio/setVolume"
    static let connectionInfo = "com.webos.service.connectionmanager/getinfo"
    static let pointerSocket = "com.webos.service.networkinput/getPointerInputSocket"

    /// Only the permissions this app actually uses (least privilege).
    static let permissions: [JSONValue] = [
        "CONTROL_AUDIO",
        "CONTROL_POWER",
        "CONTROL_TV_SCREEN",
        "CONTROL_INPUT_TV",
        "READ_POWER_STATE",
        "READ_INPUT_DEVICE_LIST",
        "READ_RUNNING_APPS",
        "READ_APP_STATUS",
        "READ_NETWORK_STATE",
        "WRITE_NOTIFICATION_TOAST",
        "CONTROL_MOUSE_AND_KEYBOARD",
        "CONTROL_INPUT_JOYSTICK",
        "CONTROL_INPUT_MEDIA_PLAYBACK",
    ]

    static func registerMessage(clientKey: String?) -> JSONValue {
        var payload: [String: JSONValue] = [
            "forcePairing": false,
            "pairingType": "PROMPT",
            "manifest": [
                "appVersion": "1.0",
                "manifestVersion": .number(1),
                "permissions": .array(permissions),
            ],
        ]
        if let clientKey { payload["client-key"] = .string(clientKey) }
        return ["type": "register", "id": "register_0", "payload": .object(payload)]
    }
}

/// Power states reported by `getPowerState`.
enum TVPower: Equatable, Sendable {
    case on, screenOff, standby, unreachable, unknown(String)

    init(state: String?) {
        switch state {
        case "Active": self = .on
        case "Screen Off": self = .screenOff
        case "Power Off", "Suspend", "Active Standby": self = .standby
        case nil: self = .unknown("")
        case let s?: self = .unknown(s)
        }
    }

    var isOn: Bool { self == .on || self == .screenOff }

    var label: String {
        switch self {
        case .on: "On"
        case .screenOff: "Screen off"
        case .standby: "Standby"
        case .unreachable: "Off / unreachable"
        case .unknown(let s): s.isEmpty ? "Unknown" : s
        }
    }
}

/// Volume/mute as reported by the TV. Firmware differs in shape: older returns
/// {volume, mute}; newer nests it under "volumeStatus" with "muteStatus".
struct AudioStatus: Equatable, Sendable {
    let volume: Int?
    let muted: Bool

    init(volume: Int?, muted: Bool) { self.volume = volume; self.muted = muted }

    init(payload: JSONValue) {
        let nested = payload["volumeStatus"]
        let v = payload["volume"]?.double ?? nested?["volume"]?.double
        volume = v.map { Int($0) }.flatMap { $0 >= 0 ? $0 : nil }  // -1 = external speaker
        muted = payload["mute"]?.bool ?? payload["muted"]?.bool ?? nested?["muteStatus"]?.bool ?? false
    }
}

struct TVInput: Identifiable, Hashable, Sendable {
    let id: String      // e.g. "HDMI_2"
    let label: String   // e.g. "HDMI 2" or the user's rename
    let appId: String?  // e.g. "com.webos.app.hdmi2"
    let connected: Bool
}
