import Foundation

/// Labels must also accept finite numbers decoded from projects, outside Int's range.
nonisolated enum NumericLabel {
    static func whole(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if let integer = Int(exactly: value.rounded()) { return String(integer) }
        return String(format: "%.6g", value)
    }
    static func transform(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return abs(value - value.rounded()) < 0.005 ? whole(value) : String(format: "%.2f", value)
    }
}
