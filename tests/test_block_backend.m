/* Production ObjC backend against memory and a tiny temporary regular file.
 * No FSKit device is constructed and no image is OS-mounted. */
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include "ntfs_fskit.h"

static _Thread_local uint64_t allocations, frees, live_allocations, maximum_allocation;
static _Thread_local int fail_allocation;
void *nfsk_test_malloc(size_t size) {
    allocations++;
    if (size > maximum_allocation) maximum_allocation = size;
    if (fail_allocation) return NULL;
    void *p = malloc(size);
    if (p) live_allocations++;
    return p;
}
void *nfsk_test_realloc(void *old, size_t size) {
    allocations++;
    if (size > maximum_allocation) maximum_allocation = size;
    if (fail_allocation) return NULL;
    void *p = realloc(old, size);
    if (p && !old) live_allocations++;
    return p;
}
void nfsk_test_free(void *p) {
    if (p) { frees++; live_allocations--; }
    free(p);
}
static int checks;
static void require(BOOL ok, const char *message) {
    if (!ok) { fprintf(stderr, "FAIL: %s errno=%d\n", message, errno); abort(); }
}
#define CHECK(ok, message) do { require((ok), (message)); checks++; } while (0)

@interface MemoryBlock : NSObject
@property uint64_t blockSize, physicalBlockSize, blockCount;
@property(getter=isWritable) BOOL writable;
@property(strong) NSMutableData *bytes;
@property uint64_t reads, readBytes, writes, writeBytes;
@property uint64_t failRead, failWrite;
@property size_t shortLimit, partialFailure;
@property int malformedTransfer; /* 1=zero, 2=oversized, 3=unaligned short */
@property BOOL failFlush, flushWithoutError;
@property NSInteger errorCode;
@end
@implementation MemoryBlock
- (size_t)transferLength:(size_t)size {
    if (_malformedTransfer == 1) return 0;
    if (_malformedTransfer == 2) return size + 1;
    if (_malformedTransfer == 3) return 1;
    return _shortLimit ? MIN(_shortLimit, size) : size;
}
- (void)validate:(off_t)offset length:(size_t)size {
    require(offset >= 0 && (uint64_t)offset <= _bytes.length && size <= _bytes.length - offset,
            "request within resource");
    require(offset % _blockSize == 0 && size % _blockSize == 0, "logical block alignment");
}
- (size_t)readInto:(void *)buffer startingAt:(off_t)offset length:(size_t)size error:(NSError **)error {
    [self validate:offset length:size];
    _reads++;
    if (_reads == _failRead) { *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:_errorCode userInfo:nil]; return 0; }
    size_t n = [self transferLength:size];
    if (n <= size) memcpy(buffer, (const char *)_bytes.bytes + offset, n);
    _readBytes += MIN(n, size);
    return n;
}
- (size_t)writeFrom:(void *)buffer startingAt:(off_t)offset length:(size_t)size error:(NSError **)error {
    [self validate:offset length:size];
    _writes++;
    if (_writes == _failWrite) {
        size_t n = MIN(_partialFailure, size);
        memcpy((char *)_bytes.mutableBytes + offset, buffer, n);
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:_errorCode userInfo:nil];
        return n;
    }
    size_t n = [self transferLength:size];
    if (n <= size) memcpy((char *)_bytes.mutableBytes + offset, buffer, n);
    _writeBytes += MIN(n, size);
    return n;
}
- (BOOL)metadataFlushWithError:(NSError **)error {
    if (_failFlush && !_flushWithoutError) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:_errorCode userInfo:nil];
    return !_failFlush;
}
@end

static MemoryBlock *resource(uint64_t sector, size_t size) {
    MemoryBlock *r = [MemoryBlock new];
    r.blockSize = 512; r.physicalBlockSize = sector;
    r.blockCount = size / r.blockSize; r.writable = YES;
    r.errorCode = EIO;
    r.bytes = [NSMutableData dataWithLength:size];
    return r;
}
static void verify_ranges(void) {
    const size_t total = 2 * 1024 * 1024;
    unsigned char *payload = malloc(total), *expected = malloc(total), *readback = malloc(total);
    require(payload && expected && readback, "test buffers");
    memset(payload, 0xa7, total);
    for (int geometry = 0; geometry < 3; geometry++) {
        uint64_t sector = geometry ? 4096 : 512;
        size_t bytes = geometry == 2 ? total - 512 : total;
        MemoryBlock *r = resource(sector, bytes);
        void *b = nfsk_backend_from_block((__bridge void *)r, 1);
        const int64_t offsets[] = {0, 1, (int64_t)sector-1, (int64_t)sector, (int64_t)sector+1, (int64_t)bytes-511, (int64_t)bytes-1};
        const int64_t lengths[] = {0, 1, (int64_t)sector-1, (int64_t)sector, (int64_t)sector*2+1, 65536, INT64_MAX};
        for (unsigned i = 0; i < sizeof offsets/sizeof *offsets; i++) {
            for (unsigned j = 0; j < sizeof lengths/sizeof *lengths; j++) {
                int64_t off = offsets[i], size = lengths[j], count = MIN(size, (int64_t)bytes-off);
                memset(r.bytes.mutableBytes, 0x35, bytes); memset(expected, 0x35, bytes);
                memcpy(expected + off, payload, count);
                CHECK(nfsk_block_pwrite(b, payload, off, size) == count, "bounded write result");
                CHECK(!memcmp(expected, r.bytes.bytes, bytes), "write preserves both neighboring regions");
                memset(readback, 0xcd, total);
                CHECK(nfsk_block_pread(b, readback, off, size) == count && !memcmp(readback, expected + off, count), "bounded read payload");
                CHECK(count == total || readback[count] == 0xcd, "read does not overrun output");
            }
        }
        CHECK(nfsk_block_pread(b, readback, bytes, 1) == 0, "EOF read");
        CHECK(nfsk_block_pwrite(b, payload, bytes, 1) == -1 && errno == ENOSPC, "EOF write");
        CHECK(nfsk_block_pread(b, readback, -1, 1) == -1 && errno == EINVAL, "negative offset");
        CHECK(nfsk_block_pwrite(b, payload, 0, -1) == -1 && errno == EINVAL, "negative length");
        nfsk_backend_free(b);
        CHECK(live_allocations == 0, "scratch and ephemeral buffers released");
    }
    free(payload); free(expected); free(readback);
}

static void verify_failures(void) {
    MemoryBlock *r = resource(4096, 2 * 1024 * 1024);
    unsigned char *payload = malloc(r.bytes.length), *out = malloc(r.bytes.length);
    require(payload && out, "fault buffers");
    memset(payload, 0xa7, r.bytes.length);
    void *b = nfsk_backend_from_block((__bridge void *)r, 1);
    for (int stage = 1; stage <= 2; stage++) {
        r.reads = r.writes = 0; r.failRead = stage;
        memset(r.bytes.mutableBytes, 0x35, r.bytes.length);
        CHECK(nfsk_block_pwrite(b, payload, 1, 65536) == -1 && errno == EIO && r.writes == 0,
              "edge read failure does not begin a write");
        CHECK(((unsigned char *)r.bytes.bytes)[1] == 0x35, "failed pre-read leaves contents intact");
    }
    r.failRead = 0; r.writes = 0; r.failWrite = 1; r.partialFailure = 4096;
    CHECK(nfsk_block_pwrite(b, payload, 1, 65536) == -1 && errno == EIO && r.writes == 1,
          "partial write plus error does not report full success or retry");
    CHECK(((unsigned char *)r.bytes.bytes)[0] == 0x35 && ((unsigned char *)r.bytes.bytes)[65537] == 0x35,
          "failed write preserves bytes outside the request");
    r.failWrite = 0; r.shortLimit = 4096;
    CHECK(nfsk_block_pwrite(b, payload, 1, 65536) == 65536 && nfsk_block_pread(b, out, 1, 65536) == 65536 &&
          !memcmp(out, payload, 65536), "aligned short I/O completes correctly");
    r.shortLimit = 0;
    for (int mode = 1; mode <= 3; mode++) {
        r.malformedTransfer = mode;
        uint64_t before = r.reads;
        CHECK(nfsk_block_pread(b, out, 0, 65536) == -1 && errno == EIO && r.reads == before + 1,
              "zero/oversized/unaligned short read fails before another request");
        before = r.writes;
        CHECK(nfsk_block_pwrite(b, payload, 0, 65536) == -1 && errno == EIO && r.writes == before + 1,
              "zero/oversized/unaligned short write fails before another request");
    }
    r.malformedTransfer = 0;
    uint64_t before = allocations;
    CHECK(nfsk_block_pread(b, out, 1, 65536) == 65536 && allocations == before,
          "same-size unaligned reads reuse bounded scratch");
    fail_allocation = 1;
    CHECK(nfsk_block_pread(b, out, 1, 200000) == -1 && errno == ENOMEM, "scratch growth allocation failure");
    CHECK(nfsk_block_pread(b, out, 1, 65536) == 65536, "failed growth retains the existing buffer");
    before = allocations;
    CHECK(nfsk_block_pwrite(b, payload, 1, 400000) == 400000 && allocations == before,
          "large write reuses existing edge scratch when allocations fail");
    void *cold = nfsk_backend_from_block((__bridge void *)r, 1);
    uint64_t oldReads = r.reads, oldWrites = r.writes;
    CHECK(nfsk_block_pwrite(cold, payload, 1, 400000) == -1 && errno == ENOMEM && r.reads == oldReads && r.writes == oldWrites,
          "cold edge allocation failure does not perform I/O");
    nfsk_backend_free(cold);
    fail_allocation = 0;
    CHECK(nfsk_block_pwrite(b, payload, 1, 400000) == 400000 && live_allocations == 1,
          "large write retains only reusable bounded scratch");
    r.failFlush = YES;
    CHECK(nfsk_block_sync(b) == -EIO, "flush error remains visible");
    r.flushWithoutError = YES;
    CHECK(nfsk_block_sync(b) == -EIO, "false flush with no NSError remains EIO");
    r.failFlush = NO;
    CHECK(nfsk_block_sync(b) == 0, "flush recovery");
    r.writable = NO;
    CHECK(nfsk_block_pwrite(b, payload, 1, 16) == -1 && errno == EROFS, "resource write protection");
    r.writable = YES;
    void *readonly = nfsk_backend_from_block((__bridge void *)r, 0);
    CHECK(nfsk_block_pwrite(readonly, payload, 1, 16) == -1 && errno == EROFS, "caller read-only intent");
    nfsk_backend_free(readonly);
    nfsk_backend_free(b);
    CHECK(live_allocations == 0, "fault-path buffer ownership");
    r.blockCount = UINT64_MAX;
    b = nfsk_backend_from_block((__bridge void *)r, 1);
    CHECK(nfsk_block_pread(b, out, 0, 1) == -1 && errno == EOVERFLOW, "geometry overflow at resource creation");
    nfsk_backend_free(b);
    free(payload); free(out);
}

static void verify_large_write_failures(void) {
    const size_t count = 1024 * 1024, total = 2 * count;
    unsigned char *input = malloc(count), *expected = malloc(total);
    require(input && expected, "large fault buffers"); memset(input, 0xa7, count);
    MemoryBlock *r = resource(4096, total);
    void *b = nfsk_backend_from_block((__bridge void *)r, 1);
    for (int stage = 1; stage <= 2; stage++) {
        r.reads = r.writes = 0; r.failRead = stage;
        memset(r.bytes.mutableBytes, 0x35, total); memset(expected, 0x35, total);
        CHECK(nfsk_block_pwrite(b, input, 1, count) == -1 && errno == EIO && r.reads == stage && r.writes == 0 &&
              !memcmp(expected, r.bytes.bytes, total), "both large-write edges are read before any mutation");
    }
    r.failRead = 0; r.partialFailure = 512;
    for (int stage = 1; stage <= 3; stage++) {
        r.reads = r.writes = 0; r.failWrite = stage; r.errorCode = stage == 2 ? ENXIO : EIO;
        memset(r.bytes.mutableBytes, 0x35, total); memset(expected, 0x35, total);
        size_t acceptedEnd = stage == 1 ? 512 : stage == 2 ? 4096 + 512 : count + 512;
        memcpy(expected + 1, input, MIN(count, acceptedEnd - 1));
        CHECK(nfsk_block_pwrite(b, input, 1, count) == -1 && errno == r.errorCode && r.writes == stage,
              "partial failure in head/middle/tail stops without full-success reply");
        CHECK(!memcmp(expected, r.bytes.bytes, total), "failed split write has exact accepted prefix and intact neighbors");
    }
    r.failWrite = 0; r.shortLimit = 4096;
    memset(r.bytes.mutableBytes, 0x35, total); memset(expected, 0x35, total); memcpy(expected + 1, input, count);
    CHECK(nfsk_block_pwrite(b, input, 1, count) == count && !memcmp(expected, r.bytes.bytes, total),
          "large write handles repeated aligned short completions");
    nfsk_backend_free(b); free(input); free(expected);
    CHECK(live_allocations == 0, "large-write fault workspace ownership");
}

static uint64_t now(void) {
    struct timespec t;
    require(clock_gettime(CLOCK_MONOTONIC_RAW, &t) == 0, "clock");
    return (uint64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}
static uint64_t cpu_now(void) {
    struct timespec t;
    require(clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t) == 0, "thread CPU clock");
    return (uint64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}

static void verify_file_bounds(void) {
    char path[] = "/tmp/xntfs-backend-XXXXXX";
    int fd = mkstemp(path);
    require(fd >= 0, "temporary ordinary file");
    unsigned char data[32], out[32]; memset(data, 0x41, sizeof data);
    require(write(fd, data, sizeof data) == sizeof data && close(fd) == 0, "prepare tiny file");
    int error = 0;
    void *b = nfsk_backend_from_file(path, 1, &error);
    require(b != NULL, "file backend");
    memset(out, 0xcd, sizeof out);
    CHECK(nfsk_block_pread(b, out, 31, INT64_MAX) == 1 && out[0] == 0x41 && out[1] == 0xcd,
          "file read length clamps without signed overflow");
    out[0] = 0x57;
    CHECK(nfsk_block_pwrite(b, out, 31, INT64_MAX) == 1 && nfsk_block_sync(b) == 0,
          "file write length clamps without extending the image");
    nfsk_backend_free(b);
    b = nfsk_backend_from_file(path, 0, &error);
    require(b != NULL, "reopen tiny file read only");
    data[31] = 0x57;
    CHECK(nfsk_block_total_bytes(b) == 32 && nfsk_block_pread(b, out, 0, sizeof out) == sizeof out &&
          !memcmp(data, out, sizeof out), "file boundary write survives reopen with neighbors intact");
    CHECK(nfsk_block_pwrite(b, out, 0, 1) == -1 && errno == EROFS, "file backend honors read-only");
    nfsk_backend_free(b);
    require(unlink(path) == 0, "remove temporary file");
}
static void verify_error_codes(BOOL observe) {
    MemoryBlock *r = resource(4096, 8192);
    void *b = nfsk_backend_from_block((__bridge void *)r, 1);
    unsigned char data[4096] = {0};
    const NSInteger codes[] = {0, -1, INT64_MIN, INT64_C(1) << 32};
    for (unsigned i = 0; i < sizeof codes/sizeof *codes; i++) {
        r.errorCode = codes[i]; r.reads = r.writes = 0;
        r.failRead = 1; r.failWrite = 0; errno = 0;
        int64_t read = nfsk_block_pread(b, data, 0, sizeof data); int readError = errno;
        r.failRead = 0; r.failWrite = 1; errno = 0;
        int64_t write = nfsk_block_pwrite(b, data, 0, sizeof data); int writeError = errno;
        r.failFlush = YES;
        int sync = nfsk_block_sync(b);
        if (observe) printf("ERROR code=%lld read=%lld read_errno=%d write=%lld write_errno=%d sync=%d\n",
                            (long long)codes[i], (long long)read, readError, (long long)write, writeError, sync);
        else {
            CHECK(read == -1 && readError == EIO, "NSError with non-errno code cannot become read success");
            CHECK(write == -1 && writeError == EIO, "NSError with non-errno code cannot become write success");
            CHECK(sync == -EIO, "NSError with non-errno code remains a negative sync failure");
        }
    }
    nfsk_backend_free(b);
}
static void benchmark(void) {
    const int sizes[] = {4096, 512, 65536, 1048576, 65536, 4096, 1048576, 8 * 1048576, 8 * 1048576};
    const int offsets[] = {0, 1, 1, 1, 1, 0, 1, 1, 1};
    const int repetitions[] = {500000, 500000, 10000, 2000, 10000, 500000, 2000, 200, 200};
    const char *names[] = {"aligned_write4k", "partial_write512", "partial_write64k", "partial_write1m", "partial_read64k", "aligned_read4k", "partial_read1m", "partial_read8m", "partial_write8m"};
    puts("sector,workload,operations,wall_ns,reads,read_bytes,writes,write_bytes,allocations,cpu_ns");
    for (int geometry = 0; geometry < 2; geometry++) for (int mode = 0; mode < 9; mode++) {
        @autoreleasepool {
            const int iterations = repetitions[mode];
            uint64_t sector = geometry ? 4096 : 512;
            MemoryBlock *r = resource(sector, MAX(2 * 1024 * 1024, sizes[mode] * 2));
            void *b = nfsk_backend_from_block((__bridge void *)r, 1);
            void *buffer = malloc(sizes[mode]); require(buffer != NULL, "benchmark buffer");
            memset(buffer, 0xa7, sizes[mode]);
            uint64_t until = now() + 50000000;
            volatile uint64_t warmup = 1;
            do {
                for (int i = 0; i < 1000; i++) warmup = warmup * 6364136223846793005ULL + 1;
            } while (now() < until);
            allocations = 0;
            uint64_t cpu_start = cpu_now();
            uint64_t start = now();
            for (int i = 0; i < iterations; i++) {
                int64_t result = mode >= 4 && mode < 8 ? nfsk_block_pread(b, buffer, offsets[mode], sizes[mode]) :
                    nfsk_block_pwrite(b, buffer, offsets[mode], sizes[mode]);
                require(result == sizes[mode], "benchmark transfer");
            }
            uint64_t elapsed = now() - start;
            uint64_t cpu_elapsed = cpu_now() - cpu_start;
            require(!memcmp(buffer, (const char *)r.bytes.bytes + offsets[mode], sizes[mode]), "benchmark final payload");
            printf("%" PRIu64 ",%s,%d,%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 "\n",
                   sector, names[mode], iterations, elapsed, r.reads, r.readBytes, r.writes, r.writeBytes, allocations, cpu_elapsed);
            nfsk_backend_free(b); free(buffer);
            require(live_allocations == 0, "benchmark buffer release");
        }
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        require(pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0) == 0, "QoS");
        if (argc == 2 && !strcmp(argv[1], "benchmark")) { benchmark(); return 0; }
        if (argc == 2 && !strcmp(argv[1], "errorprobe")) { verify_error_codes(YES); return 0; }
        verify_ranges(); verify_failures(); verify_large_write_failures(); verify_file_bounds(); verify_error_codes(NO);
        dispatch_apply(2, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t worker) {
            @autoreleasepool {
                MemoryBlock *r = resource(worker ? 4096 : 512, 65536);
                void *b = nfsk_backend_from_block((__bridge void *)r, 1);
                unsigned char input[8192], output[8192]; memset(input, 0x41 + worker, sizeof input);
                for (int i = 0; i < 100; i++) {
                    require(nfsk_block_pwrite(b, input, 3, sizeof input) == sizeof input &&
                            nfsk_block_pread(b, output, 3, sizeof output) == sizeof output &&
                            !memcmp(input, output, sizeof input), "independent concurrent scratch buffers");
                }
                nfsk_backend_free(b);
                require(live_allocations == 0, "concurrent scratch release");
            }
        });
        printf("%d block checks and two concurrent backends passed\n", checks);
    }
    return 0;
}
