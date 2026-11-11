import AVFoundation
import AudioToolbox
import CoreAudio
import Darwin
import Foundation

// MARK: Core Audio helpers

struct CAError: Error, CustomStringConvertible {
    let what: String
    let status: OSStatus
    var description: String { "\(what) failed (OSStatus \(status))" }
}

func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw CAError(what: what, status: status) }
}

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func readValue<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) throws -> T {
    var addr = address(selector)
    var size = UInt32(MemoryLayout<T>.size)
    var value = initial
    try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value), "read property \(selector)")
    return value
}

/// The rate a device's IO runs at (an aggregate: its main sub-device's), nil when unreadable.
func aggregateRate(_ device: AudioObjectID) -> Double? {
    guard let rate = try? readValue(device, kAudioDevicePropertyNominalSampleRate, Float64(0)), rate > 0 else { return nil }
    return rate
}

func readArray(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
    var addr = address(selector)
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size), "size of property \(selector)")
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids), "read property \(selector)")
    return ids
}

func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: Unmanaged<CFString>?
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr,
          let str = value?.takeRetainedValue() else { return nil }
    return str as String
}

// MARK: Logging

/// Where capture log lines go. The app points it at the call's capture.log.
public enum CaptureLog {
    nonisolated(unsafe) public static var handler: (String) -> Void = { print($0) }
    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

/// One timestamped line to stdout (the engine sends it to the call's tap.log).
func log(_ message: String) {
    CaptureLog.handler("[\(CaptureLog.clock.string(from: Date()))] \(message)")
}

func dbfs(_ value: Float) -> Double {
    value > 0 ? max(-100, (20 * log10(Double(value)) * 10).rounded() / 10) : -100
}

// MARK: Process discovery

struct AudioProcess: Hashable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let name: String
    let playing: Bool

    var label: String { "pid \(pid) \(bundleID.isEmpty ? "-" : bundleID) \(name)" }
    var short: String { "\(pid) \(name)" }
}

func processName(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "?" }
    return URL(fileURLWithPath: String(cString: buf)).lastPathComponent
}

func audioProcesses() throws -> [AudioProcess] {
    try readArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).map { id in
        let pid = (try? readValue(id, kAudioProcessPropertyPID, pid_t(-1))) ?? -1
        let running = (try? readValue(id, kAudioProcessPropertyIsRunningOutput, UInt32(0))) ?? 0
        return AudioProcess(objectID: id, pid: pid,
                            bundleID: readString(id, kAudioProcessPropertyBundleID) ?? "",
                            name: processName(pid), playing: running != 0)
    }
}

func channelCount(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
    var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func scoped<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope,
               _ initial: T) -> T? {
    var addr = address(selector, scope)
    var size = UInt32(MemoryLayout<T>.size)
    var value = initial
    return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : nil
}

/// kAudioStreamPropertyTerminalType of the device's first stream in `scope` (0 when there is none).
func terminalType(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> UInt32 {
    var addr = address(kAudioDevicePropertyStreams, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    var streams = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &streams) == noErr, let first = streams.first else { return 0 }
    return (try? readValue(first, kAudioStreamPropertyTerminalType, UInt32(0))) ?? 0
}

