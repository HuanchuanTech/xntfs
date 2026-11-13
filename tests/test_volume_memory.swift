import Foundation
import FSKit
import Darwin

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
}

@available(macOS 15.4, *)
@main
struct VolumeMemoryTests {
    static func wait(_ semaphore: DispatchSemaphore) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                precondition(semaphore.wait(timeout: .now() + 10) == .success, "queue progress deadline")
                continuation.resume()
            }
        }
    }

    static func batch(label: String, count: Int, round: Int, observe: Bool,
                      submit: (@escaping () -> Void) -> Void) async {
        nfsk_memory_reset()
        let entered = DispatchSemaphore(value: 0), start = DispatchSemaphore(value: 0)
        let sampled = DispatchSemaphore(value: 0), finish = DispatchSemaphore(value: 0)
        let result = LockedBox(nfsk_memory_stats())
        submit {
            entered.signal()
            precondition(start.wait(timeout: .now() + 10) == .success)
        }
        await wait(entered)
        for _ in 0..<count { submit { nfsk_memory_emit(32768) } }
        // Holding the sentinel prevents an idle-queue drain from hiding how
        // many preceding callbacks' temporaries survive their own completion.
        submit {
            result.value = nfsk_memory_sample()
            sampled.signal()
            precondition(finish.wait(timeout: .now() + 10) == .success)
        }
        start.signal()
        await wait(sampled)
        let sample = result.value
        precondition(sample.created == count)
        if !observe {
            precondition(sample.live == 0 && sample.destroyed == count && sample.peak == 32768,
                         "temporary objects must end with each completed callback")
        }
        if round == 1 || round == 20 || round == 100 {
            print("QUEUE_MEMORY label=\(label) round=\(round) created=\(sample.created) destroyed=\(sample.destroyed) live=\(sample.live) peak=\(sample.peak)")
        }
        finish.signal()
        let drained = DispatchSemaphore(value: 0)
        submit { drained.signal() }
        await wait(drained)
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while nfsk_memory_sample().live != 0 {
            precondition(DispatchTime.now().uptimeNanoseconds < deadline, "queue temporaries eventually release")
            try! await Task.sleep(nanoseconds: 1_000_000)
        }
        precondition(nfsk_memory_sample().destroyed == count)
    }

    static func main() async throws {
        setbuf(stdout, nil)
        DispatchQueue.global().asyncAfter(deadline: .now() + 120) { _exit(124) }
        let image = CommandLine.arguments[1]
        let observe = CommandLine.arguments.contains("observe")
        var error: Int32 = 0
        let raw = image.withCString { nfsk_backend_from_file($0, 1, &error) }
        precondition(raw != nil && error == 0)
        let cleaned = LockedBox(0)
        let backend = NTFSBackend(backend: raw!, retain: nil, cleanup: { cleaned.value += 1 }, writable: true)
        let volume = try ntfs3gVolume(backend: backend, activationBackend: { _, _ in nil }, onContainerStatusChange: { _ in })
        let root = ntfs3gItem(ino: NFSK_ROOT_INO, parentIno: NFSK_PARENT_OF_ROOT, name: FSFileName(string: "/"))
        let (file, _) = try await (volume as any FSVolume.Operations).createItem(named: FSFileName(string: "MemoryLifetime.bin"),
            type: .file, inDirectory: root, attributes: FSItem.SetAttributesRequest())
        let returned = LockedBox<(FSItem, FSFileName)?>(nil)
        for round in 1...(observe ? 1 : 100) {
            await batch(label: "volume", count: 128, round: round, observe: observe) { completion in
                volume.lookupItem(named: FSFileName(string: "MemoryLifetime.bin"), inDirectory: root) { item, name, error in
                    precondition(error == nil && item === file && name?.string == "MemoryLifetime.bin")
                    returned.value = (item!, name!)
                    completion()
                }
            }
        }
        let closed = await volume.teardown()
        precondition(closed == 0 && cleaned.value == 1)
        precondition(returned.value?.0 === file && returned.value?.1.string == "MemoryLifetime.bin",
                     "strongly owned reply values outlive queue pools and backend teardown")
        if #available(macOS 26.0, *) {
            let fs = ntfs3gFileSystem()
            let resource = FSPathURLResource(url: URL(fileURLWithPath: image), writable: false)
            for round in 1...(observe ? 1 : 100) {
                await batch(label: "resource", count: 32, round: round, observe: observe) { completion in
                    fs.probeResource(resource: resource) { result, error in
                        precondition(result != nil && error == nil)
                        completion()
                    }
                }
            }
        }
        print("PASS: queue temporary lifetimes, retained reply values and single backend release; synthetic bytes only")
    }
}
