/// The rate the tap's IO buffers really come at, measured from their timestamps.
///
/// A Bluetooth headset that enters call mode switches the aggregate device from 48 to 24 kHz (and
/// back) before Core Audio's nominal-rate notice arrives: on 22 Oct 2026 the notice came about
/// 0.6 s late, so half a second was written at the wrong speed at each switch. Each buffer's host
/// time is exact, so frames over the time between two buffers gives the rate within a few buffers.
public struct RateTracker: Sendable {
    public static let knownRates: [Double] = [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 88_200, 96_000]
    /// How far a measurement may be from a known rate. Neighbours differ by at least 8 percent.
    public static let tolerance = 0.03

    private var lastNanos: UInt64 = 0
    private var lastFrames: UInt32 = 0
    private var pending: Double?

    public init() {}

    /// Forget the last buffer (a new device: its clock starts afresh).
    public mutating func reset() {
        lastNanos = 0
        lastFrames = 0
        pending = nil
    }

    /// The known rate `measured` is, if any.
    public static func knownRate(_ measured: Double) -> Double? {
        knownRates.first { abs($0 - measured) / $0 < tolerance }
    }

    /// Feed every buffer: its host time in nanoseconds and its frame count. Returns the new rate
    /// once two measurements in a row agree on a known rate other than `current`. A stall (the
    /// device paused while it changed profile) measures no known rate and is ignored.
    public mutating func observe(nanos: UInt64, frames: UInt32, current: Double) -> Double? {
        defer { lastNanos = nanos; lastFrames = frames }
        guard lastNanos != 0, lastFrames > 0, nanos > lastNanos else { return nil }
        let seconds = Double(nanos - lastNanos) / 1e9
        guard let rate = Self.knownRate(Double(lastFrames) / seconds), rate != current else {
            pending = nil
            return nil
        }
        if pending == rate {
            pending = nil
            return rate
        }
        pending = rate
        return nil
    }
}
