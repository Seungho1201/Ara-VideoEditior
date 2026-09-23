import Foundation

/// Integer media clock. All supported frame rates divide this scale exactly.
public struct MediaTime: Codable, Hashable, Sendable, Comparable, AdditiveArithmetic {
    public static let scale: Int64 = 600_000
    public var ticks: Int64
    public init(ticks: Int64) { self.ticks = ticks }
    public init(seconds: Double) { ticks = seconds.isFinite ? Int64((seconds * Double(Self.scale)).rounded()) : 0 }
    public var seconds: Double { Double(ticks) / Double(Self.scale) }
    public static let zero = Self(ticks: 0)
    public static func < (a: Self, b: Self) -> Bool { a.ticks < b.ticks }
    public static func + (a: Self, b: Self) -> Self { .init(ticks: a.ticks + b.ticks) }
    public static func - (a: Self, b: Self) -> Self { .init(ticks: a.ticks - b.ticks) }
    /// Multiply by a finite factor, saturating rather than trapping: retime factors reach
    /// this from decoded documents, which must never crash the app on malformed input.
    public func scaled(by factor: Double) -> Self {
        guard factor.isFinite else { return .zero }
        let value = (Double(ticks) * factor).rounded()
        guard value.isFinite else { return .zero }
        guard value.magnitude < 9.0e18 else { return .init(ticks: value < 0 ? .min : .max) }
        return .init(ticks: Int64(value))
    }
}

public struct FrameRate: Codable, Hashable, Sendable, Identifiable {
    public let numerator: Int
    public let denominator: Int
    public init(_ numerator: Int, _ denominator: Int = 1) { self.numerator = numerator; self.denominator = denominator }
    public var id: String { "\(numerator)/\(denominator)" }
    public var value: Double { Double(numerator) / Double(denominator) }
    public var label: String { denominator == 1 ? "\(numerator)" : String(format: "%.3f", value) }
    public var frame: MediaTime { .init(ticks: MediaTime.scale * Int64(denominator) / Int64(numerator)) }
    public func quantize(_ time: MediaTime) -> MediaTime {
        .init(ticks: Int64((Double(time.ticks) / Double(frame.ticks)).rounded()) * frame.ticks)
    }
    public func floor(_ time: MediaTime) -> MediaTime { .init(ticks: time.ticks / frame.ticks * frame.ticks) }
    public func timecode(_ time: MediaTime) -> String {
        // Non-drop-frame display; fractional rates are explicitly labelled NDF in UI.
        let frames = max(0, time.ticks / frame.ticks)
        let nominal = Int64(value.rounded())
        return String(format: "%02lld:%02lld:%02lld:%02lld", frames / (nominal * 3600), frames / (nominal * 60) % 60, frames / nominal % 60, frames % nominal)
    }
    public static let supported: [Self] = [.init(24), .init(25), .init(30), .init(50), .init(60), .init(24000,1001), .init(30000,1001), .init(60000,1001)]
}
