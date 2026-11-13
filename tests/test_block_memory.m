/* Byte/lifetime accounting for the production block adapter. The resource
 * generates deterministic bytes; no device, mount or full-size backing cache. */
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <errno.h>
#include <inttypes.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "ntfs_fskit.h"

static void require(BOOL ok, const char *why) {
    if (!ok) { fprintf(stderr, "FAIL: %s errno=%d\n", why, errno); abort(); }
}
static int checks;
#define CHECK(ok, why) do { require((ok), (why)); checks++; } while (0)
enum { LIMIT = 256 * 1024, GUARD = 16 };
typedef struct { void *pointer; size_t size; } Allocation;
typedef struct { size_t live, peak, maximum, count, attempts; } Metrics;
static pthread_mutex_t allocationLock = PTHREAD_MUTEX_INITIALIZER;
static Allocation owned[128];
static Metrics metrics;
static BOOL allocationFailure;

static int slot(void *pointer) {
    for (int i = 0; i < 128; i++) if (owned[i].pointer == pointer) return i;
    require(NO, "allocation accounting entry exists"); return -1;
}
static void add_allocation(void *p, size_t size) {
    int i = slot(NULL); owned[i] = (Allocation){p, size};
    metrics.live += size; metrics.count++;
    metrics.peak = MAX(metrics.peak, metrics.live);
}
static void remove_allocation(void *p) {
    int i = slot(p); metrics.live -= owned[i].size; metrics.count--;
    owned[i] = (Allocation){0};
}
void *nfsk_test_malloc(size_t size) {
    pthread_mutex_lock(&allocationLock);
    metrics.attempts++; metrics.maximum = MAX(metrics.maximum, size);
    void *p = allocationFailure ? NULL : malloc(size);
    if (p) add_allocation(p, size);
    pthread_mutex_unlock(&allocationLock);
    return p;
}
void nfsk_test_free(void *p);
void *nfsk_test_realloc(void *old, size_t size) {
    pthread_mutex_lock(&allocationLock);
    metrics.attempts++; metrics.maximum = MAX(metrics.maximum, size);
    // Force relocation so peak includes both allocations, as realloc may do.
    void *p = allocationFailure ? NULL : malloc(size);
    size_t previous = old ? owned[slot(old)].size : 0;
    if (p) add_allocation(p, size);
    pthread_mutex_unlock(&allocationLock);
    // Allow different backends' old/new lifetimes to overlap during the copy;
    // the accounting mutex must not artificially serialize whole relocations.
    if (p && old) { memcpy(p, old, MIN(size, previous)); nfsk_test_free(old); }
    return p;
}
void nfsk_test_free(void *p) {
    pthread_mutex_lock(&allocationLock);
    if (p) { remove_allocation(p); free(p); }
    pthread_mutex_unlock(&allocationLock);
}
static Metrics sample(void) {
    pthread_mutex_lock(&allocationLock); Metrics result = metrics;
    pthread_mutex_unlock(&allocationLock); return result;
}
static void reset_counters(BOOL fail) {
    pthread_mutex_lock(&allocationLock);
    metrics.peak = metrics.live; metrics.maximum = metrics.attempts = 0;
    allocationFailure = fail;
    pthread_mutex_unlock(&allocationLock);
}

typedef struct {
    pthread_mutex_t lock;
    pthread_cond_t condition;
    unsigned entered;
    BOOL released;
    int error;
} ReadGate;

@interface GeneratedBlock : NSObject
@property uint64_t blockSize, physicalBlockSize, blockCount, reads, writes;
@property(getter=isWritable) BOOL writable;
@property uint64_t failRead, malformedAt, failWrite, malformedWriteAt;
@property int failureCode, malformed;
@property size_t shortLimit;
@property ReadGate *gate;
@property BOOL gateWrites;
@property int64_t expectedOffset, expectedCount, nextWrite;
@property const unsigned char *input;
@end
@implementation GeneratedBlock
- (size_t)readInto:(void *)buffer startingAt:(off_t)offset length:(size_t)length error:(NSError **)error {
    uint64_t capacity = _blockSize * _blockCount;
    require(offset >= 0 && (uint64_t)offset <= capacity && length <= capacity - offset, "resource range");
    require(offset % _blockSize == 0 && length % _blockSize == 0, "resource logical alignment");
    _reads++;
    int failure = _reads == _failRead ? _failureCode : 0;
    if (_gate && !_gateWrites && _reads == 1) {
        pthread_mutex_lock(&_gate->lock);
        _gate->entered++; pthread_cond_broadcast(&_gate->condition);
        while (!_gate->released) pthread_cond_wait(&_gate->condition, &_gate->lock);
        failure = _gate->error;
        pthread_mutex_unlock(&_gate->lock);
    }
    if (failure) {
        memset(buffer, 0xfe, MIN(length, (size_t)512));
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:failure userInfo:nil];
        return MIN(length, (size_t)512); // Partial completion plus error.
    }
    if (_reads == _malformedAt) {
        if (_malformed == 1) return 0;
        if (_malformed == 2) return length + 1;
        return 1;
    }
    size_t got = _shortLimit ? MIN(length, _shortLimit) : length;
    for (size_t i = 0; i < got; i++) ((unsigned char *)buffer)[i] = (unsigned char)((offset + i) % 251);
    return got;
}
- (size_t)writeFrom:(void *)buffer startingAt:(off_t)offset length:(size_t)length error:(NSError **)error {
    require(_writable && _input, "read-only tests never write");
    uint64_t capacity = _blockSize * _blockCount;
    require(offset >= 0 && (uint64_t)offset <= capacity && length <= capacity - offset &&
            offset % _blockSize == 0 && length % _blockSize == 0, "write resource bounds/alignment");
    require(offset == _nextWrite, "large writes visit contiguous disk ranges in order");
    _writes++;
    for (size_t i = 0; i < length; i++) {
        int64_t pos = offset + i;
        unsigned char expected = pos >= _expectedOffset && pos < _expectedOffset + _expectedCount ?
                                 _input[pos - _expectedOffset] : pos % 251;
        require(((const unsigned char *)buffer)[i] == expected, "write payload and preserved neighboring bytes");
    }
    int failure = _writes == _failWrite ? _failureCode : 0;
    if (_gate && _gateWrites && _writes == 1) {
        pthread_mutex_lock(&_gate->lock);
        _gate->entered++; pthread_cond_broadcast(&_gate->condition);
        while (!_gate->released) pthread_cond_wait(&_gate->condition, &_gate->lock);
        failure = _gate->error;
        pthread_mutex_unlock(&_gate->lock);
    }
    if (failure) {
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:failure userInfo:nil];
        return MIN(length, (size_t)512);
    }
    if (_writes == _malformedWriteAt) return _malformed == 1 ? 0 : _malformed == 2 ? length + 1 : 1;
    size_t put = _shortLimit ? MIN(length, _shortLimit) : length;
    _nextWrite += put;
    return put;
}
@end

static GeneratedBlock *resource(uint64_t sector) {
    GeneratedBlock *r = [GeneratedBlock new];
    r.blockSize = 512; r.physicalBlockSize = sector;
    r.blockCount = (32 * 1024 * 1024 - 512) / 512; r.failureCode = EIO;
    return r;
}
static unsigned char *buffer(size_t count) {
    unsigned char *p = malloc(count + 2 * GUARD);
    require(p != NULL, "caller buffer"); memset(p, 0xcd, count + 2 * GUARD); return p;
}
static BOOL guards(const unsigned char *p, size_t count) {
    for (int i = 0; i < GUARD; i++) if (p[i] != 0xcd || p[GUARD + count + i] != 0xcd) return NO;
    return YES;
}
static BOOL payload(const unsigned char *p, int64_t offset, size_t count) {
    for (size_t i = 0; i < count; i++) if (p[i] != (offset + i) % 251) return NO;
    return YES;
}

static void expect_write(GeneratedBlock *r, const unsigned char *input, int64_t offset, int64_t count) {
    r.writable = YES; r.input = input; r.expectedOffset = offset; r.expectedCount = count;
    r.nextWrite = offset - offset % r.physicalBlockSize; r.reads = r.writes = 0;
}

static void write_ranges(BOOL observe) {
    const uint64_t sectors[] = {512, 4096, 3072, 65536, LIMIT};
    const size_t lengths[] = {LIMIT - 1, LIMIT, LIMIT + 1, 1024 * 1024, 8 * 1024 * 1024, 16 * 1024 * 1024};
    for (unsigned s = 0; s < sizeof sectors / sizeof *sectors; s++) {
        for (unsigned n = 0; n < sizeof lengths / sizeof *lengths; n++) @autoreleasepool {
            GeneratedBlock *r = resource(sectors[s]); r.writable = YES;
            void *b = nfsk_backend_from_block((__bridge void *)r, 1);
            size_t count = lengths[n]; unsigned char *p = buffer(count);
            expect_write(r, p + GUARD, 1, count); reset_counters(NO);
            CHECK(nfsk_block_pwrite(b, p + GUARD, 1, count) == count && guards(p, count), "large write input and boundary bytes");
            Metrics used = sample();
            if (!observe) CHECK(used.maximum <= 2 * LIMIT && used.live <= LIMIT && used.peak <= 2 * LIMIT,
                                "cold write allocation has a request-independent bound");
            if (observe) printf("WRITE_MEMORY sector=%" PRIu64 " count=%zu live=%zu peak=%zu maximum=%zu reads=%" PRIu64 " writes=%" PRIu64 "\n",
                                sectors[s], count, used.live, used.peak, used.maximum, r.reads, r.writes);
            int64_t total = r.blockSize * r.blockCount;
            expect_write(r, p + GUARD, total - count, count);
            CHECK(nfsk_block_pwrite(b, p + GUARD, total - count, INT64_MAX) == count && guards(p, count),
                  "clipped large write ends at the logical capacity with intact neighbors");
            nfsk_backend_free(b); free(p);
            CHECK(sample().live == 0 && sample().count == 0, "large-write workspace released");
        }
    }
}

static void write_failures(void) {
    const size_t count = 1024 * 1024;
    unsigned char *p = buffer(count);
    GeneratedBlock *r = resource(4096); r.writable = YES;
    void *b = nfsk_backend_from_block((__bridge void *)r, 1);
    for (int stage = 1; stage <= 3; stage++) {
        expect_write(r, p + GUARD, 1, count); r.failWrite = stage; r.failureCode = ENXIO;
        CHECK(nfsk_block_pwrite(b, p + GUARD, 1, count) == -1 && errno == ENXIO && r.writes == stage && guards(p, count),
              "large write stops at each failed stage and keeps the caller alive");
    }
    r.failWrite = 0;
    for (int mode = 1; mode <= 3; mode++) {
        expect_write(r, p + GUARD, 1, count); r.malformedWriteAt = 2; r.malformed = mode;
        CHECK(nfsk_block_pwrite(b, p + GUARD, 1, count) == -1 && errno == EIO && r.writes == 2,
              "malformed middle write cannot issue the tail");
    }
    r.malformedWriteAt = 0; r.shortLimit = 4096; expect_write(r, p + GUARD, 1, count);
    CHECK(nfsk_block_pwrite(b, p + GUARD, 1, count) == count && guards(p, count), "large write aligned short transfers");
    r.shortLimit = 0; nfsk_backend_free(b);
    r = resource(LIMIT); r.writable = YES; b = nfsk_backend_from_block((__bridge void *)r, 1);
    expect_write(r, p + GUARD, 1, 100);
    CHECK(nfsk_block_pwrite(b, p + GUARD, 1, 100) == 100 && sample().live == LIMIT, "prewarm largest retained workspace");
    expect_write(r, p + GUARD, 1, count); reset_counters(YES);
    CHECK(nfsk_block_pwrite(b, p + GUARD, 1, count) == -1 && errno == ENOMEM && r.reads == 0 && r.writes == 0 && sample().live == LIMIT,
          "two giant edges fail allocation before I/O and preserve the old scratch");
    reset_counters(NO); expect_write(r, p + GUARD, 1, count);
    CHECK(nfsk_block_pwrite(b, p + GUARD, 1, count) == count && sample().peak == 3 * LIMIT && sample().live == LIMIT,
          "giant edge temporary plus retained workspace has a fixed peak and releases after return");
    nfsk_backend_free(b);
    r = resource(2 * LIMIT); r.writable = YES; b = nfsk_backend_from_block((__bridge void *)r, 1);
    expect_write(r, p + GUARD, 1, count); reset_counters(NO);
    CHECK(nfsk_block_pwrite(b, p + GUARD, 1, count) == -1 && errno == ENOTSUP && r.reads == 0 && r.writes == 0 && sample().attempts == 0,
          "oversized unaligned write geometry fails before allocation or I/O");
    expect_write(r, p + GUARD, 0, count);
    CHECK(nfsk_block_pwrite(b, p + GUARD, 0, count) == count && sample().attempts == 0, "oversized aligned write geometry still needs no scratch");
    nfsk_backend_free(b); free(p);
    CHECK(sample().live == 0 && sample().count == 0, "write failure workspace ownership returns to zero");
}

static void ranges(BOOL observe) {
    const uint64_t sectors[] = {512, 4096, 3072, 65536, LIMIT};
    const size_t lengths[] = {LIMIT - 1, LIMIT, LIMIT + 1, 1024 * 1024, 8 * 1024 * 1024, 16 * 1024 * 1024};
    for (unsigned s = 0; s < sizeof sectors/sizeof *sectors; s++) {
        for (unsigned n = 0; n < sizeof lengths/sizeof *lengths; n++) @autoreleasepool {
            GeneratedBlock *r = resource(sectors[s]);
            void *b = nfsk_backend_from_block((__bridge void *)r, 0);
            size_t count = lengths[n]; unsigned char *p = buffer(count);
            reset_counters(NO);
            CHECK(nfsk_block_pread(b, p + GUARD, 1, count) == count && payload(p + GUARD, 1, count) && guards(p, count),
                  "large read payload and caller guards");
            Metrics used = sample();
            if (!observe) CHECK(used.maximum <= LIMIT && used.live <= LIMIT && used.peak <= LIMIT,
                                "cold read allocation and retained workspace are bounded");
            if (observe) printf("MEMORY sector=%" PRIu64 " count=%zu live=%zu peak=%zu maximum=%zu reads=%" PRIu64 "\n",
                                sectors[s], count, used.live, used.peak, used.maximum, r.reads);
            int64_t total = r.blockSize * r.blockCount, offset = total - count;
            memset(p, 0xcd, count + 2 * GUARD);
            CHECK(nfsk_block_pread(b, p + GUARD, offset, INT64_MAX) == count && payload(p + GUARD, offset, count) && guards(p, count),
                  "large clipped read preserves exact capacity and output boundary");
            nfsk_backend_free(b); free(p);
            CHECK(sample().live == 0 && sample().count == 0, "cold-read workspace released");
        }
    }
}

static void failures(void) {
    const size_t count = 1024 * 1024;
    unsigned char *p = buffer(count);
    GeneratedBlock *r = resource(4096);
    void *b = nfsk_backend_from_block((__bridge void *)r, 0);
    for (int stage = 1; stage <= 3; stage++) {
        r.reads = 0; r.failRead = stage; r.failureCode = stage == 2 ? ENXIO : EIO;
        CHECK(nfsk_block_pread(b, p + GUARD, 1, count) == -1 && errno == r.failureCode && r.reads == stage &&
              r.writes == 0 && guards(p, count), "head/middle/tail failure stops immediately with original errno");
    }
    r.failRead = 0;
    for (int mode = 1; mode <= 3; mode++) {
        r.reads = 0; r.malformedAt = 2; r.malformed = mode;
        CHECK(nfsk_block_pread(b, p + GUARD, 1, count) == -1 && errno == EIO && r.reads == 2,
              "malformed middle completion cannot issue a tail request");
    }
    r.malformedAt = 0; r.shortLimit = 4096; r.reads = 0;
    CHECK(nfsk_block_pread(b, p + GUARD, 1, count) == count && payload(p + GUARD, 1, count) && guards(p, count),
          "aligned short completions recover exact large-read payload");
    r.shortLimit = 0;
    reset_counters(YES);
    uint64_t before = r.reads;
    CHECK(nfsk_block_pread(b, p + GUARD, 1, 200000) == -1 && errno == ENOMEM && r.reads == before && sample().live == 4096,
          "failed growth preserves old scratch and makes no resource request");
    CHECK(nfsk_block_pread(b, p + GUARD, 1, count) == count && payload(p + GUARD, 1, count),
          "large reads reuse old edge workspace even when new allocations fail");
    nfsk_backend_free(b);
    b = nfsk_backend_from_block((__bridge void *)r, 0); before = r.reads;
    CHECK(nfsk_block_pread(b, p + GUARD, 1, count) == -1 && errno == ENOMEM && r.reads == before && sample().live == 0,
          "cold allocation failure has no I/O or leaked buffer");
    reset_counters(NO); nfsk_backend_free(b);
    r = resource(2 * LIMIT); b = nfsk_backend_from_block((__bridge void *)r, 0);
    CHECK(nfsk_block_pread(b, p + GUARD, 1, count) == -1 && errno == ENOTSUP && r.reads == 0 && sample().attempts == 0,
          "oversized edge-sector workspace is rejected before allocation or I/O");
    CHECK(nfsk_block_pread(b, p + GUARD, 0, count) == count && payload(p + GUARD, 0, count) && sample().attempts == 0,
          "large-sector aligned reads still use direct I/O without scratch");
    nfsk_backend_free(b); free(p);
    CHECK(sample().live == 0, "failure-path ownership converges to zero");
}

static void paused(int resumedError, BOOL observe, BOOL writing) {
    ReadGate gate = {PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER, 0, NO, 0};
    ReadGate *shared = &gate;
    dispatch_group_t group = dispatch_group_create();
    reset_counters(NO);
    for (int i = 0; i < 8; i++) dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __weak GeneratedBlock *weak;
        @autoreleasepool {
            GeneratedBlock *r = resource(4096); r.gate = shared; r.gateWrites = writing; r.writable = writing;
            weak = r;
            void *b = nfsk_backend_from_block((__bridge void *)r, writing);
            size_t count = 1024 * 1024; unsigned char *p = buffer(count);
            if (writing) expect_write(r, p + GUARD, 1, count);
            r = nil;
            require(weak != nil, "backend owns resource while caller releases its reference");
            int64_t result = writing ? nfsk_block_pwrite(b, p + GUARD, 1, count) : nfsk_block_pread(b, p + GUARD, 1, count);
            require(resumedError ? result == -1 && errno == resumedError :
                    result == count && (writing || payload(p + GUARD, 1, count)), "paused transfer result and error");
            require(guards(p, count), "paused read caller guards");
            nfsk_backend_free(b); free(p);
        }
        require(weak == nil, "paused backend releases its resource after completion");
    });
    pthread_mutex_lock(&gate.lock);
    struct timespec deadline; clock_gettime(CLOCK_REALTIME, &deadline); deadline.tv_sec += 10;
    while (gate.entered < 8) require(pthread_cond_timedwait(&gate.condition, &gate.lock, &deadline) == 0,
                                   "all backends progress independently into paused I/O");
    Metrics used = sample();
    if (observe) printf("PAUSED mode=%s instances=8 error=%d live=%zu peak=%zu count=%zu\n",
                        writing ? "write" : "read", resumedError, used.live, used.peak, used.count);
    else CHECK(used.live == 8 * (writing ? 8192 : 4096) && used.count == 8 && used.peak == used.live,
               "eight paused operations retain exactly their live edge workspaces");
    gate.error = resumedError; gate.released = YES; pthread_cond_broadcast(&gate.condition);
    pthread_mutex_unlock(&gate.lock);
    require(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0, "paused readers complete");
    CHECK(sample().live == 0 && sample().count == 0, "success or surprise-removal error releases all backend buffers after I/O");
    pthread_cond_destroy(&gate.condition); pthread_mutex_destroy(&gate.lock);
}

static void cycles(unsigned instances, BOOL writing) {
    reset_counters(NO);
    size_t maximumPeak = 0;
    for (int cycle = 0; cycle < 100; cycle++) {
        dispatch_apply(instances, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t worker) {
            __weak GeneratedBlock *weak;
            @autoreleasepool {
                GeneratedBlock *r = resource(worker % 2 ? 512 : 4096); r.writable = writing;
                weak = r;
                void *b = nfsk_backend_from_block((__bridge void *)r, writing);
                size_t count = 512 * 1024 + 1; unsigned char *p = buffer(count);
                const size_t sizes[] = {100, 65537, 200000, count};
                for (unsigned j = 0; j < sizeof sizes/sizeof *sizes; j++) {
                    if (writing) expect_write(r, p + GUARD, 1, sizes[j]);
                    int64_t done = writing ? nfsk_block_pwrite(b, p + GUARD, 1, sizes[j]) : nfsk_block_pread(b, p + GUARD, 1, sizes[j]);
                    require(done == sizes[j] && (writing || payload(p + GUARD, 1, sizes[j])), "growth and transfer lifecycle payload");
                }
                require(guards(p, count), "cycle caller guards");
                nfsk_backend_free(b); free(p);
            }
            require(weak == nil, "each cycle releases every backend resource");
        });
        Metrics used = sample(); maximumPeak = MAX(maximumPeak, used.peak);
        require(used.live == 0 && used.count == 0 && used.maximum <= LIMIT && used.peak <= instances * (LIMIT + LIMIT / 2),
                "each cycle releases all workspaces; peak accounts for old/new realloc overlap");
        if (cycle == 0 || cycle == 19 || cycle == 99) {
            struct task_vm_info info; mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
            require(task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &n) == KERN_SUCCESS, "memory sample");
            printf("CYCLE mode=%s instances=%u cycle=%d live=%zu peak=%zu resident=%llu footprint=%llu\n",
                   writing ? "write" : "read", instances, cycle + 1, used.live, used.peak, info.resident_size, info.phys_footprint);
        }
    }
    CHECK(sample().live == 0, "100 allocation/growth/read/release cycles settle to zero");
    printf("LIFETIME mode=%s instances=%u cycles=100 peak_requested=%zu\n", writing ? "write" : "read", instances, maximumPeak);
}

/* Saturate retained storage independently of in-flight workspace. Additional
 * backends must still work, without permanently expanding the process cache. */
static void retained_budget(BOOL observe) {
    for (unsigned cycle = 0; cycle < (observe ? 1 : 100); cycle++) {
        void *backends[16];
        __weak GeneratedBlock *resources[16];
        unsigned char *p = buffer(1024 * 1024);
        reset_counters(NO);
        for (unsigned i = 0; i < 16; i++) @autoreleasepool {
            GeneratedBlock *r = resource(4096); resources[i] = r;
            backends[i] = nfsk_backend_from_block((__bridge void *)r, 0);
            require(nfsk_block_pread(backends[i], p + GUARD, 1, 200000) == 200000 &&
                    payload(p + GUARD, 1, 200000), "all sixteen backends work at retained capacity");
        }
        Metrics used = sample();
        if (observe) printf("RETAINED instances=16 live=%zu peak=%zu count=%zu\n", used.live, used.peak, used.count);
        else require(used.live == 2 * 1024 * 1024 && used.count == 8 && used.peak <= 2 * 1024 * 1024 + LIMIT,
                     "retained cap with temporary fallback for additional backends");
        if (!observe) {
            GeneratedBlock *r = resources[15]; uint64_t before = r.reads;
            reset_counters(YES);
            require(nfsk_block_pread(backends[15], p + GUARD, 1, 200000) == -1 && errno == ENOMEM &&
                    r.reads == before && sample().live == used.live, "fallback malloc failure precedes I/O and preserves retained storage");
            reset_counters(NO);
            require(nfsk_block_pread(backends[15], p + GUARD, 1, 200000) == 200000 &&
                    sample().live == used.live, "fallback admission released after allocation failure and success");
            if (cycle == 0) {
                require(nfsk_block_pread(backends[15], p + GUARD, 1, 1024 * 1024) == 1024 * 1024 &&
                        payload(p + GUARD, 1, 1024 * 1024) && sample().live == used.live,
                        "large read releases temporary edge storage when retention is full");
                for (unsigned stage = 1; stage <= 3; stage++) {
                    r.failRead = r.reads + stage;
                    require(nfsk_block_pread(backends[15], p + GUARD, 1, 1024 * 1024) == -1 &&
                            errno == EIO && sample().live == used.live && guards(p, 1024 * 1024),
                            "large read failure returns temporary edge budget at every stage");
                    r.failRead = 0;
                }
            }
        }
        for (unsigned i = 0; i < 16; i++) nfsk_backend_free(backends[i]);
        for (unsigned i = 0; i < 16; i++) require(resources[i] == nil, "all saturated-budget resources released");
        free(p);
        require(sample().live == 0 && sample().count == 0, "saturated retained storage returns to zero each cycle");
    }
    CHECK(sample().live == 0, "retained budget and fallback lifecycle");
}

/* Twelve worst-case temporary workspaces plus eight full retained buffers use
 * exactly the 8 MiB process budget. Independent direct I/O must stay available,
 * and a denied partial request must be retryable after active work completes. */
static void active_budget(int resumedError, BOOL observe, unsigned heldCount) {
    void *held[8]; unsigned char *p = buffer(1024 * 1024);
    unsigned activeCount = 16 - heldCount / 2;
    size_t retainedBytes = heldCount * LIMIT;
    reset_counters(NO);
    for (unsigned i = 0; i < heldCount; i++) @autoreleasepool {
        GeneratedBlock *r = resource(4096);
        held[i] = nfsk_backend_from_block((__bridge void *)r, 0);
        require(nfsk_block_pread(held[i], p + GUARD, 1, 200000) == 200000, "warm maximum retained workspace");
    }
    ReadGate gate = {PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER, 0, NO, 0};
    ReadGate *shared = &gate;
    dispatch_group_t group = dispatch_group_create();
    for (unsigned i = 0; i < activeCount; i++) dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __weak GeneratedBlock *weak;
        @autoreleasepool {
            GeneratedBlock *r = resource(LIMIT); weak = r; r.gate = shared; r.gateWrites = YES;
            expect_write(r, p + GUARD, 1, 1024 * 1024);
            void *b = nfsk_backend_from_block((__bridge void *)r, 1); r = nil;
            int64_t done = nfsk_block_pwrite(b, p + GUARD, 1, 1024 * 1024);
            require(resumedError ? done == -1 && errno == resumedError : done == 1024 * 1024,
                    "paused global-budget writes preserve error and completion");
            nfsk_backend_free(b);
        }
        require(weak == nil, "global-budget resource lifetime ends after I/O");
    });
    pthread_mutex_lock(&gate.lock);
    struct timespec deadline; clock_gettime(CLOCK_REALTIME, &deadline); deadline.tv_sec += 10;
    while (gate.entered < activeCount) require(pthread_cond_timedwait(&gate.condition, &gate.lock, &deadline) == 0,
                                    "independent backends fill active budget without cross-volume waits");
    pthread_mutex_unlock(&gate.lock);
    Metrics full = sample();
    if (observe) printf("ACTIVE_BUDGET paused=%u retained=%u error=%d live=%zu peak=%zu\n", activeCount, heldCount, resumedError, full.live, full.peak);
    else CHECK(full.live == 8 * 1024 * 1024 && full.peak == full.live, "aggregate bound includes retained and active workspaces");
    @autoreleasepool {
        unsigned char *probe = buffer(1024 * 1024);
        GeneratedBlock *r = resource(4096); r.writable = YES;
        void *b = nfsk_backend_from_block((__bridge void *)r, 1);
        if (!observe) {
            expect_write(r, probe + GUARD, 1, 1024 * 1024);
            CHECK(nfsk_block_pwrite(b, probe + GUARD, 1, 1024 * 1024) == -1 && errno == ENOMEM &&
                  r.reads == 0 && r.writes == 0 && sample().attempts == full.attempts,
                  "over-budget write fails before allocation or resource I/O");
            CHECK(nfsk_block_pread(b, probe + GUARD, 1, 200000) == -1 && errno == ENOMEM &&
                  r.reads == 0 && sample().attempts == full.attempts,
                  "over-budget read does not leak a retained reservation");
            CHECK(nfsk_block_pread(b, probe + GUARD, 0, 4096) == 4096 && payload(probe + GUARD, 0, 4096),
                  "aligned read progresses with no workspace while budget is full");
            expect_write(r, probe + GUARD, 0, 4096);
            CHECK(nfsk_block_pwrite(b, probe + GUARD, 0, 4096) == 4096 && sample().live == full.live,
                  "aligned write progresses while budget is full");
        }
        pthread_mutex_lock(&gate.lock); gate.error = resumedError; gate.released = YES;
        pthread_cond_broadcast(&gate.condition); pthread_mutex_unlock(&gate.lock);
        require(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0,
                "full-budget transfers complete after release");
        CHECK(sample().live == retainedBytes && sample().count == heldCount, "active allocations released even after disconnect");
        expect_write(r, probe + GUARD, 1, 1024 * 1024);
        CHECK(nfsk_block_pwrite(b, probe + GUARD, 1, 1024 * 1024) == 1024 * 1024 &&
              (observe || sample().live == retainedBytes + (heldCount == 8 ? 0 : 8192)), "denied backend can retry after budget is released");
        nfsk_backend_free(b); free(probe);
    }
    for (unsigned i = 0; i < heldCount; i++) nfsk_backend_free(held[i]);
    free(p);
    CHECK(sample().live == 0 && sample().count == 0, "entire process workspace released");
    pthread_cond_destroy(&gate.condition); pthread_mutex_destroy(&gate.lock);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ _Exit(124); });
        BOOL observe = argc > 1 && !strcmp(argv[1], "observe");
        if (argc > 1 && (!strcmp(argv[1], "budget") || !strcmp(argv[1], "observe-budget"))) {
            observe = !strcmp(argv[1], "observe-budget");
            retained_budget(observe);
            active_budget(0, observe, 8); active_budget(ENXIO, observe, 8);
            active_budget(0, observe, 0); active_budget(ENXIO, observe, 0);
            retained_budget(observe);
            printf("%d process-budget checks passed; %s\n", checks, observe ? "baseline observation only" : "including 100 retained/fallback cycles");
            return 0;
        }
        ranges(observe); write_ranges(observe);
        if (!observe) {
            failures(); write_failures();
            for (unsigned n = 1; n <= 8; n *= n == 1 ? 2 : 4) { cycles(n, NO); cycles(n, YES); }
        }
        paused(0, observe, NO); paused(ENXIO, observe, NO);
        paused(0, observe, YES); paused(ENXIO, observe, YES);
        printf("%d block memory checks passed; requested-byte accounting excludes caller/Foundation buffers; no device used\n", checks);
    }
    return 0;
}
