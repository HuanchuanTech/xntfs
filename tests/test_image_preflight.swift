import Foundation
import Darwin

// Simulate scope grants without modifying app entitlements or creating mounts.
nonisolated private final class AccessRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0, stops = 0, bookmarks = 0, mainCalls = 0
    private var modes: [Bool] = []
    let grant: Bool
    let failBookmark: Bool
    let pauseBookmark: Bool
    let resumeBookmark = DispatchSemaphore(value: 0)
    init(grant: Bool = true, failBookmark: Bool = false, pauseBookmark: Bool = false) {
        self.grant = grant; self.failBookmark = failBookmark; self.pauseBookmark = pauseBookmark
    }
    var counts: (starts: Int, stops: Int, bookmarks: Int, mainCalls: Int, modes: [Bool]) {
        lock.lock(); defer { lock.unlock() }
        return (starts, stops, bookmarks, mainCalls, modes)
    }
    var access: ImageMountFileAccess {
        ImageMountFileAccess(start: { [self] _ in
            lock.lock(); starts += 1; mainCalls += Thread.isMainThread ? 1 : 0; lock.unlock()
            return grant
        }, stop: { [self] _ in
            lock.lock(); stops += 1; precondition(stops <= starts); lock.unlock()
        }, scopedURL: { [self] source, readOnly in
            lock.lock(); bookmarks += 1; modes.append(readOnly); mainCalls += Thread.isMainThread ? 1 : 0; lock.unlock()
            if pauseBookmark { resumeBookmark.wait() }
            if failBookmark { throw POSIXError(.EACCES) }
            return source
        })
    }
}

@available(macOS 27.0, *)
@MainActor
private final class ClientRecord {
    var images: [MountedImage] = []
    var enabled = true, publish = true, pauseEnabled = false, pauseSubmit = false
    var enableError: POSIXErrorCode?, submitError: POSIXErrorCode?
    var imageErrorAt: Int?
    var imageCalls = 0, enabledCalls = 0, submitCalls = 0
    var enabledReply: CheckedContinuation<Void, Never>?, submitReply: CheckedContinuation<Void, Never>?
    let point = URL(fileURLWithPath: "/Volumes/Unused-Preflight-Test", isDirectory: true)
    var client: ImageMountClient {
        ImageMountClient(images: {
            self.imageCalls += 1
            if self.imageCalls == self.imageErrorAt { throw POSIXError(.ENOMEM) }
            return self.images
        }, enabled: {
            self.enabledCalls += 1
            if self.pauseEnabled { await withCheckedContinuation { self.enabledReply = $0 } }
            if let error = self.enableError { throw POSIXError(error) }
            return self.enabled
        }, submit: { source, readOnly in
            self.submitCalls += 1
            if self.pauseSubmit { await withCheckedContinuation { self.submitReply = $0 } }
            if let error = self.submitError { throw POSIXError(error) }
            if self.publish { self.images = [self.image(source, readOnly: readOnly)] }
            return self.point
        })
    }
    func image(_ source: URL, readOnly: Bool = true) -> MountedImage {
        MountedImage(mountPoint: point, source: source, readOnly: readOnly, sizeBytes: 512, fileSystemID: [99, 1])
    }
}

@main
@MainActor
struct ImagePreflightTests {
    private static func wait(_ predicate: () -> Bool) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while !predicate() {
            precondition(DispatchTime.now().uptimeNanoseconds < deadline, "Asynchronous phase never started")
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    @available(macOS 27.0, *)
    private static func attempt(_ url: URL, _ client: ClientRecord, _ access: AccessRecord, readOnly: Bool = true) async -> Result<URL, Error> {
        do { return .success(try await ImageMountService.mount(url, readOnly: readOnly, client: client.client, fileAccess: access.access)) }
        catch { return .failure(error) }
    }
    private static func failure(_ result: Result<URL, Error>) -> Error {
        if case .failure(let error) = result { return error }
        preconditionFailure("Unexpected success")
    }
    private static func check(_ result: Result<URL, Error>, errno: POSIXErrorCode) {
        var error = failure(result) as NSError
        // FileHandle preserves EIO in NSUnderlyingErrorKey of a Cocoa error.
        while error.domain != NSPOSIXErrorDomain, let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            error = underlying
        }
        precondition(error.domain == NSPOSIXErrorDomain && error.code == Int(errno.rawValue), "Wrong error: \(error)")
    }
    private static func balanced(_ record: AccessRecord, starts: Int) {
        let c = record.counts
        precondition(c.starts == starts && c.stops == (record.grant ? starts : 0) && c.mainCalls == 0,
                     "Unbalanced scopes or preflight permission work on MainActor: \(c)")
    }
    private static func arm(_ source: URL, hold: Bool = false, fail: Bool = false) {
        precondition(source.path.withCString { image_gate_arm($0, hold ? 1 : 0, 0, fail ? 1 : 0) } == 0)
    }
    private static func closedRead() {
        precondition(image_gate_reads() == 1 && image_gate_requested_bytes() == 512 && image_gate_closes() == 1,
                     "Header read or close count changed")
        precondition(image_gate_main_reads() == 0, "Image read ran on the main thread")
        image_gate_clear()
    }

    @available(macOS 27.0, *)
    private static func cancellation(_ source: URL) async throws {
        let client = ClientRecord(), record = AccessRecord()
        arm(source, hold: true)
        var finished = false
        let task = Task { let result = await attempt(source, client, record); finished = true; return result }
        try await wait { image_gate_entered() != 0 }
        for _ in 0..<32 { check(await attempt(source, ClientRecord(), AccessRecord()), errno: .EBUSY) }
        precondition(record.counts.starts == 1 && record.counts.stops == 0 && image_gate_closes() == 0)
        task.cancel()
        try await Task.sleep(nanoseconds: 10_000_000)
        precondition(!finished && record.counts.stops == 0 && client.enabledCalls == 0)
        image_gate_release()
        let readResult = await task.value
        precondition(failure(readResult) is CancellationError)
        balanced(record, starts: 1); closedRead()
        precondition(client.submitCalls == 0)

        let availability = ClientRecord(), sourceAccess = AccessRecord()
        availability.pauseEnabled = true
        let checking = Task { await attempt(source, availability, sourceAccess) }
        try await wait { availability.enabledReply != nil }
        precondition(sourceAccess.counts.starts == 1 && sourceAccess.counts.stops == 0)
        checking.cancel(); availability.enabledReply!.resume()
        let availabilityResult = await checking.value
        precondition(failure(availabilityResult) is CancellationError)
        balanced(sourceAccess, starts: 1); precondition(sourceAccess.counts.bookmarks == 0)

        let bookmarking = AccessRecord(pauseBookmark: true), bookmarkClient = ClientRecord()
        let pending = Task { await attempt(source, bookmarkClient, bookmarking) }
        try await wait { bookmarking.counts.bookmarks == 1 }
        pending.cancel()
        precondition(bookmarking.counts.starts == 1 && bookmarking.counts.stops == 0)
        bookmarking.resumeBookmark.signal()
        let bookmarkResult = await pending.value
        precondition(failure(bookmarkResult) is CancellationError)
        balanced(bookmarking, starts: 2); precondition(bookmarkClient.submitCalls == 0)

        let submitted = ClientRecord(), submittedAccess = AccessRecord()
        submitted.pauseSubmit = true
        let mounting = Task { await attempt(source, submitted, submittedAccess, readOnly: false) }
        try await wait { submitted.submitReply != nil }
        precondition(submittedAccess.counts.starts == 2 && submittedAccess.counts.stops == 0)
        mounting.cancel()
        check(await attempt(source, ClientRecord(), AccessRecord()), errno: .EBUSY)
        submitted.submitReply!.resume()
        let mounted = try await mounting.value.get()
        precondition(mounted == submitted.point && submitted.images[0].readOnly == false)
        balanced(submittedAccess, starts: 2); precondition(submittedAccess.counts.modes == [false])

        let cancelledAccess = AccessRecord(), cancelledClient = ClientRecord()
        let cancelled = Task { await attempt(source, cancelledClient, cancelledAccess) }
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        precondition(failure(cancelledResult) is CancellationError)
        balanced(cancelledAccess, starts: 0)
        print("PASS: paused reads keep MainActor responsive; 32 duplicates rejected; cancellation preserves scopes through read, availability, bookmark and submitted reply")
    }

    @available(macOS 27.0, *)
    private static func failures(_ source: URL, alias: URL, other: URL) async throws {
        arm(source, fail: true)
        let reading = AccessRecord(), readClient = ClientRecord()
        check(await attempt(source, readClient, reading), errno: .EIO)
        balanced(reading, starts: 1); closedRead(); precondition(readClient.enabledCalls == 0)
        for available in [false, true] {
            let client = ClientRecord(), record = AccessRecord()
            client.enabled = available
            if available { client.enableError = .EACCES }
            let error = failure(await attempt(source, client, record))
            if available { precondition((error as NSError).code == Int(EACCES)) }
            else { guard case ImageMountError.extensionUnavailable = error else { preconditionFailure("Availability error changed") } }
            balanced(record, starts: 1); precondition(record.counts.bookmarks == 0 && client.submitCalls == 0)
        }
        let bookmark = AccessRecord(failBookmark: true), bookmarkClient = ClientRecord()
        check(await attempt(source, bookmarkClient, bookmark), errno: .EACCES)
        balanced(bookmark, starts: 1); precondition(bookmarkClient.submitCalls == 0)

        let submit = AccessRecord(), submitClient = ClientRecord()
        submitClient.submitError = .EBUSY
        check(await attempt(source, submitClient, submit), errno: .EBUSY)
        balanced(submit, starts: 2)
        submitClient.submitError = nil
        _ = try await attempt(source, submitClient, AccessRecord()).get()
        precondition(submitClient.submitCalls == 2, "A failed mount retained admission")

        let missing = ClientRecord(), missingAccess = AccessRecord()
        missing.publish = false
        guard case ImageMountError.unexpectedMount = failure(await attempt(source, missing, missingAccess)) else {
            preconditionFailure("Missing mount validation was lost")
        }
        balanced(missingAccess, starts: 2)
        let occupied = ClientRecord(), occupiedAccess = AccessRecord()
        occupied.images = [occupied.image(other)]
        guard case ImageMountError.alreadyMounted = failure(await attempt(source, occupied, occupiedAccess)) else {
            preconditionFailure("Reused mountpoint was accepted")
        }
        balanced(occupiedAccess, starts: 2)

        let duplicate = ClientRecord(), duplicateAccess = AccessRecord()
        duplicate.images = [duplicate.image(source)]
        guard case ImageMountError.alreadyMounted = failure(await attempt(alias, duplicate, duplicateAccess)) else {
            preconditionFailure("Symlink alias bypassed duplicate check")
        }
        balanced(duplicateAccess, starts: 1); precondition(duplicate.enabledCalls == 0)

        arm(source, hold: true)
        let refreshed = ClientRecord(), refreshedAccess = AccessRecord()
        let checking = Task { await attempt(source, refreshed, refreshedAccess) }
        try await wait { image_gate_entered() != 0 }
        refreshed.images = [refreshed.image(source)]
        image_gate_release()
        guard case ImageMountError.alreadyMounted = failure(await checking.value) else {
            preconditionFailure("Mount snapshot predates the slow read")
        }
        balanced(refreshedAccess, starts: 1); closedRead()

        for grant in [false, true] {
            let access = AccessRecord(grant: grant), client = ClientRecord()
            arm(source)
            _ = try await attempt(source, client, access).get()
            balanced(access, starts: 2); closedRead()
            precondition(access.counts.modes == [true])
        }
        print("PASS: read/availability/bookmark/submission failures, retry, late mount snapshots, aliases and mount-result checks; each successful scope start has one stop")
    }

    @available(macOS 27.0, *)
    private static func observationFailures(_ source: URL) async throws {
        for phase in [1, 2] {
            let client = ClientRecord(), access = AccessRecord()
            client.imageErrorAt = phase
            arm(source)
            check(await attempt(source, client, access), errno: .ENOMEM)
            balanced(access, starts: phase == 1 ? 1 : 2); closedRead()
            precondition(client.imageCalls == phase)
            precondition(client.enabledCalls == (phase == 1 ? 0 : 1))
            precondition(client.submitCalls == (phase == 1 ? 0 : 1))
            precondition(access.counts.bookmarks == (phase == 1 ? 0 : 1))
            client.imageErrorAt = nil
            let retriedAccess = AccessRecord()
            if phase == 1 {
                _ = try await attempt(source, client, retriedAccess).get()
                balanced(retriedAccess, starts: 2)
            } else {
                // A failed observation after submission does not undo the created mount.
                precondition(client.images.count == 1)
                guard case ImageMountError.alreadyMounted = failure(await attempt(source, client, retriedAccess)) else {
                    preconditionFailure("Verification failure lost the created mount or retained admission")
                }
                balanced(retriedAccess, starts: 1)
            }
            precondition(client.submitCalls == 1)
        }
        let client = ClientRecord(), access = AccessRecord()
        client.pauseSubmit = true; client.imageErrorAt = 2
        let task = Task { await attempt(source, client, access) }
        try await wait { client.submitReply != nil }
        task.cancel()
        precondition(access.counts.stops == 0)
        check(await attempt(source, ClientRecord(), AccessRecord()), errno: .EBUSY)
        client.submitReply!.resume()
        check(await task.value, errno: .ENOMEM)
        balanced(access, starts: 2)
        precondition(client.submitCalls == 1 && client.images.count == 1)
        print("PASS: image observation failures prevent unchecked submission, preserve post-submit state/error, retire scopes/admission and respect submitted cancellation")
    }

    static func main() async throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + 25) { _exit(124) }
        guard #available(macOS 27.0, *) else { preconditionFailure("Requires macOS 27 for stub mounting tests") }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).appendingPathComponent("fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { image_gate_clear(); try? FileManager.default.removeItem(at: folder) }
        var boot = Data(repeating: 0, count: 512)
        boot.replaceSubrange(3..<11, with: Data("NTFS    ".utf8)); boot[510] = 0x55; boot[511] = 0xaa
        let source = folder.appendingPathComponent("valid.ntfs", isDirectory: false)
        let other = folder.appendingPathComponent("other.ntfs", isDirectory: false)
        let alias = folder.appendingPathComponent("alias.ntfs", isDirectory: false)
        try boot.write(to: source); try boot.write(to: other)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        try ImageMountService.validateImage(alias)
        for (index, data) in [Data(), boot.prefix(511), Data(repeating: 0, count: 512)].enumerated() {
            let invalid = folder.appendingPathComponent("bad-\(index).ntfs", isDirectory: false)
            try data.write(to: invalid)
            let access = AccessRecord(), client = ClientRecord()
            guard case ImageMountError.unsupportedImage = failure(await attempt(invalid, client, access)) else {
                preconditionFailure("Invalid boot sector was accepted")
            }
            balanced(access, starts: 1); precondition(client.enabledCalls == 0)
        }
        for invalid in [folder, URL(string: "https://example.invalid/test.ntfs")!] {
            do { try ImageMountService.validateImage(invalid); preconditionFailure("Invalid URL accepted") }
            catch ImageMountError.unsupportedImage {}
        }
        try await cancellation(source)
        try await failures(source, alias: alias, other: other)
        try await observationFailures(source)
        print("PASS: real 512-byte header validation and file closure; synthetic clients only, no FSKit mount or device operation")
    }
}
