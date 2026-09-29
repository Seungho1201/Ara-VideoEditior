import Foundation

/// Pictures (and outline coverage) kept between composition builds and live edits, found again
/// by key. The most recently used are kept alive up to `budget` bytes. Past that a value is found
/// only while something else still holds it: the preview's current composition holds its held
/// frames and titles, so a rebuild after an edit finds all it showed, while pictures nothing
/// shows any more (a finished 4K export's) are not kept beyond the budget. Safe from any thread.
final class RecentCache<Key: Hashable, Value: AnyObject>: @unchecked Sendable {
    private struct Entry { weak var value: Value?; var kept: Value?; let bytes: Int; var used: UInt64 }
    private var entries: [Key:Entry] = [:]
    private var clock: UInt64 = 0, kept = 0, found = 0, missed = 0
    private let budget: Int
    private let lock = NSLock()
    init(budget: Int) { self.budget = budget }
    /// How often a value was found, and not found.
    var lookups: (found: Int, missed: Int) { lock.withLock { (found,missed) } }

    func value(for key: Key) -> Value? {
        lock.withLock {
            guard var entry = entries[key], let value = entry.value else { entries[key] = nil; missed += 1; return nil }
            clock += 1; entry.used = clock; found += 1
            if entry.kept == nil { entry.kept = value; kept += entry.bytes }
            entries[key] = entry; trim()
            return value
        }
    }
    func insert(_ value: Value, bytes: Int, for key: Key) {
        lock.withLock {
            if let old = entries[key], old.kept != nil { kept -= old.bytes }
            clock += 1; entries[key] = Entry(value:value,kept:value,bytes:bytes,used:clock); kept += bytes
            trim()
        }
    }
    func removeAll() { lock.withLock { entries.removeAll(); kept = 0 } }
    /// Lets go of the least recently used values past the budget, then forgets what nothing holds.
    private func trim() {
        guard kept > budget else { return }
        for (key,entry) in entries.filter({ $0.value.kept != nil }).sorted(by:{ $0.value.used < $1.value.used }) {
            guard kept > budget else { break }
            entries[key]?.kept = nil; kept -= entry.bytes
        }
        entries = entries.filter { $0.value.value != nil }
    }
}
