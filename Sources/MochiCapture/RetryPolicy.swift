import Foundation

/// When to (re)try tapping a set of processes after Core Audio refused it.
///
/// The tap re-scans every second. Without this, a set that cannot be tapped (a format change, a
/// process that refuses taps) would be rebuilt every second forever. A refused set waits 1, 2, 4 ...
/// up to `maximum` seconds; a different set is tried at once; a success forgets the refusal.
public struct RetryPolicy: Equatable {
    public private(set) var rejected: Set<UInt32> = []
    public private(set) var failures = 0
    public private(set) var notBefore: Date = .distantPast
    public let maximum: TimeInterval

    public init(maximum: TimeInterval = 30) {
        self.maximum = maximum
    }

    public func shouldTry(_ wanted: Set<UInt32>, now: Date = Date()) -> Bool {
        wanted != rejected || now >= notBefore
    }

    public mutating func failed(_ wanted: Set<UInt32>, now: Date = Date()) {
        failures = wanted == rejected ? failures + 1 : 1
        rejected = wanted
        notBefore = now.addingTimeInterval(min(maximum, pow(2, Double(failures - 1))))
    }

    public mutating func succeeded() {
        rejected = []
        failures = 0
        notBefore = .distantPast
    }
}
