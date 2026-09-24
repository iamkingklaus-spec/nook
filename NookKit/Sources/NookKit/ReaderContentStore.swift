import Foundation

/// Manages the reader-mode content CRDT: this device's shard plus a merged view
/// of every device's shard. Each device writes only its own file, so macOS and
/// iOS never conflict; comparable extractions use last-writer-wins, while a full
/// cached body outranks a failed/summary result regardless of its timestamp.
///
/// An `actor` so all file I/O and merging run off the main actor and are
/// serialized (no torn reads between `record` and `reload`).
public actor ReaderContentStore {
    /// Caps this device's shard so the synced file stays bounded; reader content
    /// is regenerable, so an evicted (oldest) entry just re-extracts on reopen.
    private static let maxOwnEntries = 500

    private let storage: ReaderStorage
    private let deviceID: String
    /// This device's own shard — only our writes, the single file we persist.
    private var own: ReaderContentShardDocument
    /// Merged registers across all devices, for lookups.
    private var merged: [Article.ID: LWWRegister<ReaderContentValue>] = [:]

    public init(storage: ReaderStorage, deviceID: String) {
        self.storage = storage
        self.deviceID = deviceID
        own = ReaderContentShardDocument(deviceID: deviceID)
    }

    /// Reloads this device's shard and folds in every peer's shard (LWW). Called
    /// on setup and when pulling peer changes, so an article another device
    /// extracted appears here without re-fetching.
    public func reload() {
        var doc = storage.loadOwnReaderShard(deviceID: deviceID) ?? ReaderContentShardDocument(deviceID: deviceID)
        var mergedRegisters = doc.entries
        var clock = doc.clock
        for shard in storage.loadReaderShards() where shard.deviceID != deviceID {
            clock = clock.witnessed(shard.clock)
            for (id, register) in shard.entries {
                mergedRegisters[id] = mergedRegisters[id].map { Self.preservingBody($0, register) } ?? register
            }
        }
        // Absorb peers' clocks so our next write outranks their latest edit.
        doc.clock = clock
        own = doc
        merged = mergedRegisters
    }

    /// The merged value for an article, or `nil` on a miss.
    public func value(for articleID: Article.ID) -> ReaderContentValue? {
        merged[articleID]?.value
    }

    /// Records this device's extraction result for an article, stamping it with a
    /// fresh clock that beats any peer, and persists our shard.
    public func record(_ value: ReaderContentValue, for articleID: Article.ID) {
        // A failed refresh or a peer's summary must not discard our only full copy.
        if merged[articleID]?.value.protectsBody == true && !value.protectsBody { return }
        let hlc = HLC.next(after: own.clock, node: deviceID)
        own.clock = hlc
        let register = LWWRegister(value: value, hlc: hlc)
        own.entries[articleID] = register
        merged[articleID] = merged[articleID].map { Self.preservingBody($0, register) } ?? register
        evictOwnIfNeeded()
        try? storage.saveReaderShard(own)
    }

    /// Order by full-body availability, then HLC. Symmetric and associative so
    /// peer enumeration order cannot affect convergence. Legacy successes retain
    /// their existing protection until they can be assessed by a reader.
    private static func preservingBody(
        _ lhs: LWWRegister<ReaderContentValue>, _ rhs: LWWRegister<ReaderContentValue>
    ) -> LWWRegister<ReaderContentValue> {
        if lhs.value.protectsBody != rhs.value.protectsBody {
            return lhs.value.protectsBody ? lhs : rhs
        }
        return lhs.merged(with: rhs)
    }

    /// Drops the oldest entries (by clock) from this device's shard when it grows
    /// past the cap. Merged peer entries are untouched.
    private func evictOwnIfNeeded() {
        guard own.entries.count > Self.maxOwnEntries else { return }
        let oldest = own.entries
            .sorted { $0.value.hlc < $1.value.hlc }
            .prefix(own.entries.count - Self.maxOwnEntries)
        for (id, _) in oldest { own.entries.removeValue(forKey: id) }
    }
}
