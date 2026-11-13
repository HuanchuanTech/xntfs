import Foundation
import Darwin

// Test/diagnostic copies only; clean timing builds do not call these from the recorder.
nonisolated enum DiagnosticProbe {
    private final class State: @unchecked Sendable {
        let condition = NSCondition()
        var stores = 0, writes = 0, bytes = 0, maximumPending = 0, snapshots = 0
        var blockedStore = 0, entered = false, released = false
        var writeError: Int32 = 0
        var currentSnapshots = 0, maximumSnapshots = 0, maximumReadBytes = 0
        var blockRead = false, readEntered = false, readReleased = false
    }
    private static let state = State()
    struct Counts: Codable {
        let stores: Int
        let writes: Int
        let bytes: Int
        let maximumPending: Int
        let snapshots: Int
        let currentSnapshots: Int
        let maximumSnapshots: Int
        let maximumReadBytes: Int
    }
    static func reset(blockStore: Int = 0, blockRead: Bool = false) {
        state.condition.lock(); defer { state.condition.unlock() }
        state.stores = 0; state.writes = 0; state.bytes = 0; state.maximumPending = 0; state.snapshots = 0
        state.blockedStore = blockStore; state.entered = false; state.released = false; state.writeError = 0
        state.currentSnapshots = 0; state.maximumSnapshots = 0; state.maximumReadBytes = 0
        state.blockRead = blockRead; state.readEntered = false; state.readReleased = false
    }
    static func store() {
        state.condition.lock(); defer { state.condition.unlock() }
        state.stores += 1
        if state.stores == state.blockedStore {
            state.entered = true
            while !state.released { state.condition.wait() }
        }
    }
    static var entered: Bool {
        state.condition.lock(); defer { state.condition.unlock() }; return state.entered
    }
    static func release() {
        state.condition.lock(); state.released = true; state.readReleased = true
        state.condition.broadcast(); state.condition.unlock()
    }
    static func failWrites(_ code: Int32) {
        state.condition.lock(); state.writeError = code; state.condition.unlock()
    }
    static func write(_ count: Int) throws {
        state.condition.lock()
        state.writes += 1; state.bytes += count
        let error = state.writeError
        state.condition.unlock()
        if error != 0 { throw POSIXError(POSIXErrorCode(rawValue: error)!) }
    }
    static func pending(_ count: Int) {
        state.condition.lock(); state.maximumPending = max(state.maximumPending, count); state.condition.unlock()
    }
    static func snapshotEnqueued() {
        state.condition.lock(); state.snapshots += 1; state.condition.unlock()
    }
    static func snapshotPending(_ count: Int) {
        state.condition.lock(); defer { state.condition.unlock() }
        state.currentSnapshots = count; state.maximumSnapshots = max(state.maximumSnapshots, count)
    }
    static func readReady() {
        state.condition.lock(); defer { state.condition.unlock() }
        state.readEntered = true
        while state.blockRead && !state.readReleased { state.condition.wait() }
    }
    static var hasEnteredRead: Bool {
        state.condition.lock(); defer { state.condition.unlock() }; return state.readEntered
    }
    static func readBytes(_ count: Int) {
        state.condition.lock(); state.maximumReadBytes = max(state.maximumReadBytes, count); state.condition.unlock()
    }
    static var counts: Counts {
        state.condition.lock(); defer { state.condition.unlock() }
        return Counts(stores: state.stores, writes: state.writes, bytes: state.bytes,
                      maximumPending: state.maximumPending, snapshots: state.snapshots,
                      currentSnapshots: state.currentSnapshots, maximumSnapshots: state.maximumSnapshots,
                      maximumReadBytes: state.maximumReadBytes)
    }
}
