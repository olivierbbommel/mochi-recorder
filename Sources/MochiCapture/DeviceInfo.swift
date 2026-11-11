import Foundation

/// Core Audio four-character codes as text ("blue", "hdpn"), and the transport names the engine
/// reads from `mochi-tap devices --json` (src/mochi/devices.py decides what is a headset).
public enum DeviceInfo {
    /// "blue" for 0x626C7565. Unprintable codes become "" (no code).
    public static func fourCC(_ code: UInt32) -> String {
        guard code != 0 else { return "" }
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return "" }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// kAudioDevicePropertyTransportType as a stable name.
    public static func transport(_ code: UInt32) -> String {
        switch fourCC(code) {
        case "bltn": return "builtin"
        case "grup", "fgrp": return "aggregate"
        case "virt": return "virtual"
        case "usb ": return "usb"
        case "blue": return "bluetooth"
        case "blea": return "bluetooth_le"
        case "hdmi": return "hdmi"
        case "dprt": return "displayport"
        case "airp": return "airplay"
        case "thun": return "thunderbolt"
        case "pci ": return "pci"
        case "1394": return "firewire"
        case "eavb": return "avb"
        case "ccap", "ccwd", "ccwl": return "continuity"
        default: return "unknown"
        }
    }

    /// kAudioStreamPropertyTerminalType as a stable name. Core Audio uses USB Audio terminal codes
    /// (0x0301 speaker, 0x0302 headphones, 0x0402 headset ...) and its own four-character codes.
    public static func terminal(_ code: UInt32) -> String {
        switch code {
        case 0: return "unknown"
        case 0x0201, 0x0202, 0x0204, 0x0205, 0x0206: return "microphone"
        case 0x0203: return "personal_microphone"
        case 0x0301, 0x0304, 0x0305, 0x0306, 0x0307: return "speaker"
        case 0x0302: return "headphones"
        case 0x0303: return "head_mounted"
        case 0x0401: return "handset"
        case 0x0402: return "headset"
        case 0x0403, 0x0404, 0x0405: return "speakerphone"
        default: break
        }
        switch fourCC(code) {
        case "spkr", "lfes": return "speaker"
        case "hdph": return "headphones"
        case "rspk": return "receiver"
        case "micr": return "microphone"
        case "hmic": return "headset_microphone"
        case "rmic": return "receiver_microphone"
        case "line": return "line"
        case "spdf": return "digital"
        case "hdmi": return "hdmi"
        case "dprt": return "displayport"
        case "tty_": return "tty"
        default: return "other"
        }
    }
}

/// One audio device, as `mochi-tap devices --json` prints it.
public struct DeviceRecord: Codable, Equatable {
    /// The Core Audio AudioObjectID: the engine checks an opened stream really is this device.
    public var id: UInt32 = 0
    public var name: String
    public var uid: String
    public var inputs: Int
    public var outputs: Int
    public var transport: String
    public var defaultInput: Bool
    public var defaultOutput: Bool
    public var inputRate: Double
    public var outputSource: String
    public var inputTerminal: String
    public var outputTerminal: String

    public init(name: String, uid: String, inputs: Int, outputs: Int, transport: String,
                defaultInput: Bool, defaultOutput: Bool, inputRate: Double, outputSource: String,
                inputTerminal: String = "", outputTerminal: String = "") {
        self.name = name; self.uid = uid; self.inputs = inputs; self.outputs = outputs
        self.transport = transport; self.defaultInput = defaultInput; self.defaultOutput = defaultOutput
        self.inputRate = inputRate; self.outputSource = outputSource
        self.inputTerminal = inputTerminal; self.outputTerminal = outputTerminal
    }

    enum CodingKeys: String, CodingKey {
        case id, name, uid, inputs, outputs, transport
        case defaultInput = "default_input", defaultOutput = "default_output"
        case inputRate = "input_rate", outputSource = "output_source"
        case inputTerminal = "input_terminal", outputTerminal = "output_terminal"
    }

    /// The JSON array the engine reads, keys sorted so the output is stable.
    public static func json(_ records: [DeviceRecord]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(records) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}
