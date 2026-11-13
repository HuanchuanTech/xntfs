/*
 * ntfs_device_fskit.m - Block I/O backend for the NTFS bridge.
 *
 * A backend wraps one of two sources behind a single C interface (nfsk_block_*):
 *   - NFSKModeBlock: an FSKit FSBlockDeviceResource (a real disk/partition).
 *     FSBlockDeviceResource requires sector-aligned offsets/lengths, so partial
 *     accesses are handled with read-modify-write.
 *   - NFSKModeFile:  an opened image file (FSPathURLResource). A regular file
 *     descriptor supports arbitrary pread/pwrite, so no alignment is needed.
 *
 * No libntfs headers here on purpose: libntfs's `enum BOOL` collides with ObjC's BOOL.
 */

#import <Foundation/Foundation.h>
#import <FSKit/FSKit.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include "ntfs_fskit.h"

typedef NS_ENUM(int, NFSKMode) { NFSKModeBlock = 0, NFSKModeFile = 1 };

/* Requested workspace bytes, not total RSS. These counters are shared across
 * backends, but never protect I/O or objects. Admission never waits for another
 * volume; existing scratch reuse and direct aligned I/O do not touch them. */
enum {
    NFSK_SCRATCH_LIMIT = 256 * 1024,
    NFSK_RETAINED_LIMIT = 2 * 1024 * 1024,
    NFSK_WORKSPACE_LIMIT = 8 * 1024 * 1024,
};
static _Atomic size_t retainedWorkspace;
static _Atomic size_t liveWorkspace;

static BOOL reserve_workspace(_Atomic size_t *used, size_t size, size_t limit) {
    size_t current = atomic_load_explicit(used, memory_order_relaxed);
    do {
        if (size > limit - current) return NO;
    } while (!atomic_compare_exchange_weak_explicit(used, &current, current + size,
                                                    memory_order_relaxed, memory_order_relaxed));
    return YES;
}

static void release_workspace(void *buffer, size_t size) {
    free(buffer);
    atomic_fetch_sub_explicit(&liveWorkspace, size, memory_order_relaxed);
}

@interface NFSKBackend : NSObject {
@public
    NFSKMode               mode;
    FSBlockDeviceResource *block;     /* NFSKModeBlock (strong) */
    int                    fd;        /* NFSKModeFile */
    uint64_t               totalBytes;
    uint32_t               sectorSize;
    int                    geometryError;
    BOOL                   writable;
    void                  *scratch;   /* serial backend workspace, never cached data */
    size_t                 scratchCapacity;
}
@end
@implementation NFSKBackend
- (void)dealloc {
    release_workspace(scratch, scratchCapacity);
    atomic_fetch_sub_explicit(&retainedWorkspace, scratchCapacity, memory_order_relaxed);
}
@end

static inline NFSKBackend *BK(void *backend) { return (__bridge NFSKBackend *)backend; }
static uint32_t sector_of(FSBlockDeviceResource *res);
static int64_t total_of(FSBlockDeviceResource *res);

/* ------------------------------------------------------------------ */
/* Backend lifecycle.                                                  */
/* ------------------------------------------------------------------ */
void *nfsk_backend_from_block(void *block_resource, int allow_write) {
    NFSKBackend *b = [NFSKBackend new];
    b->mode = NFSKModeBlock;
    b->block = (__bridge FSBlockDeviceResource *)block_resource;   /* strong ivar retains */
    b->fd = -1;
    /* Snapshot geometry for this mount, as libntfs does for its volume geometry.
     * A replacement resource/remount gets a new backend and snapshot. */
    b->sectorSize = sector_of(b->block);
    int64_t total = total_of(b->block);
    b->geometryError = total < 0 ? errno : (b->sectorSize ? 0 : EINVAL);
    b->totalBytes = total < 0 ? 0 : (uint64_t)total;
    /* Honor the caller's read-only intent at the backend: writes are gated unless the
       operation allows writing AND the media is writable. */
    b->writable = (allow_write && b->block.isWritable) ? YES : NO;
    return (void *)CFBridgingRetain(b);
}

void *nfsk_backend_from_file(const char *path, int writable, int *out_err) {
    int fd = open(path, writable ? O_RDWR : O_RDONLY);
    if (fd < 0) { if (out_err) *out_err = errno; return NULL; }
    struct stat st;
    if (fstat(fd, &st) != 0) { if (out_err) *out_err = errno; close(fd); return NULL; }
    NFSKBackend *b = [NFSKBackend new];
    b->mode = NFSKModeFile;
    b->fd = fd;
    b->totalBytes = (uint64_t)st.st_size;
    b->sectorSize = 512;
    b->writable = writable ? YES : NO;
    return (void *)CFBridgingRetain(b);
}

void nfsk_backend_free(void *backend) {
    if (!backend) return;
    NFSKBackend *b = (NFSKBackend *)CFBridgingRelease(backend);
    if (b->mode == NFSKModeFile && b->fd >= 0) { close(b->fd); b->fd = -1; }
    b->block = nil;
}

/* ------------------------------------------------------------------ */
/* Block-device (FSBlockDeviceResource) helpers — sector aligned.      */
/* ------------------------------------------------------------------ */
static uint32_t sector_of(FSBlockDeviceResource *res) {
    uint64_t s = res.physicalBlockSize;
    if (s == 0) s = res.blockSize;
    if (s == 0) s = 512;
    return s <= UINT32_MAX ? (uint32_t)s : 0;
}

static int64_t total_of(FSBlockDeviceResource *res) {
    uint64_t size = res.blockSize, count = res.blockCount;
    if (size && count > INT64_MAX / size) { errno = EOVERFLOW; return -1; }
    return (int64_t)(size * count);
}

/* All uses, including final release, run in the owner's serial I/O context.
 * Retained capacity is optional: once its process budget is full, borrow a
 * temporary allocation from the total workspace budget and return it after I/O.
 * Account for both buffers during realloc, including allocator-induced moves. */
static void *borrow_scratch(NFSKBackend *b, size_t size, BOOL *temporary) {
    *temporary = NO;
    if (size <= b->scratchCapacity) return b->scratch;
    if (size <= NFSK_SCRATCH_LIMIT) {
        size_t capacity = 512;
        while (capacity < size) capacity *= 2;
        size_t delta = capacity - b->scratchCapacity;
        if (reserve_workspace(&retainedWorkspace, delta, NFSK_RETAINED_LIMIT)) {
            if (reserve_workspace(&liveWorkspace, capacity, NFSK_WORKSPACE_LIMIT)) {
                void *newBuffer = realloc(b->scratch, capacity);
                if (newBuffer) {
                    atomic_fetch_sub_explicit(&liveWorkspace, b->scratchCapacity, memory_order_relaxed);
                    b->scratch = newBuffer;
                    b->scratchCapacity = capacity;
                    return newBuffer;
                }
                atomic_fetch_sub_explicit(&liveWorkspace, capacity, memory_order_relaxed);
                atomic_fetch_sub_explicit(&retainedWorkspace, delta, memory_order_relaxed);
                return NULL;
            }
            atomic_fetch_sub_explicit(&retainedWorkspace, delta, memory_order_relaxed);
        }
    }
    *temporary = YES;
    if (!reserve_workspace(&liveWorkspace, size, NFSK_WORKSPACE_LIMIT)) return NULL;
    void *buffer = malloc(size);
    if (!buffer) atomic_fetch_sub_explicit(&liveWorkspace, size, memory_order_relaxed);
    return buffer;
}

static int block_range(NFSKBackend *b, int64_t offset, int64_t *count,
                       int64_t *start, int64_t *span, uint32_t *sector) {
    if (b->geometryError) return -b->geometryError;
    int64_t total = (int64_t)b->totalBytes;
    *sector = b->sectorSize;
    if (offset >= total) { *count = 0; return 0; }
    if (*count > total - offset) *count = total - offset;
    *start = offset - offset % *sector;
    int64_t end = offset + *count;
    int64_t remainder = end % *sector;
    int64_t padding = remainder ? *sector - remainder : 0;
    int64_t aligned_end = padding > total - end ? total : end + padding;
    *span = aligned_end - *start;
    return 0;
}

/* Keep the synchronous fast path inline so ARC can fold the caller's and
 * helper's backend/resource lifetimes instead of retaining them twice. */
static inline int resource_error(NSError *error) {
    NSInteger code = error.code;
    // NSError codes are signed and wider than errno. An invalid conversion
    // must never turn an explicit resource failure into zero/positive success.
    return code > 0 && code <= INT_MAX ? -(int)code : -EIO;
}

static inline __attribute__((always_inline))
int aligned_read(FSBlockDeviceResource *res, uint32_t sector, void *buf, int64_t offset, int64_t span) {
    int64_t done = 0;
    while (done < span) {
        NSError *err = nil;
        size_t got = [res readInto:(char *)buf + done startingAt:offset + done
                           length:(size_t)(span - done) error:&err];
        if (err != nil) return resource_error(err);
        if (got == 0 || got > (uint64_t)(span - done)) return -EIO;
        if (got < (uint64_t)(span - done) && got % sector) return -EIO;
        done += (int64_t)got;
    }
    return 0;
}

static inline __attribute__((always_inline))
int aligned_write(FSBlockDeviceResource *res, uint32_t sector, const void *buf, int64_t offset, int64_t span) {
    int64_t done = 0;
    while (done < span) {
        NSError *err = nil;
        size_t put = [res writeFrom:(void *)((const char *)buf + done) startingAt:offset + done
                            length:(size_t)(span - done) error:&err];
        if (err != nil) return resource_error(err);
        if (put == 0 || put > (uint64_t)(span - done)) return -EIO;
        if (put < (uint64_t)(span - done) && put % sector) return -EIO;
        done += (int64_t)put;
    }
    return 0;
}

/* Keep bounce-buffer allocation and assembly off the direct I/O path. Inlining
 * the entire slow path adds register/ARC overhead even to small aligned I/O. */
static __attribute__((noinline))
int64_t block_pread(NFSKBackend *b, void *buf, int64_t offset, int64_t count) {
    uint32_t sector;
    int64_t aligned_start, span;
    int rc = block_range(b, offset, &count, &aligned_start, &span, &sector);
    if (rc) { errno = -rc; return -1; }
    if (!count) return 0;
    if (aligned_start == offset && span == count) {
        rc = aligned_read(b->block, sector, buf, offset, count);
        if (rc < 0) { errno = -rc; return -1; }
        return count;
    }
    if (span > NFSK_SCRATCH_LIMIT) {
        /* Keep large reads independent of request-sized bounce allocations.
         * Only the edge sectors need scratch; the middle can fill the caller's
         * buffer directly. A later error invalidates the result, not necessarily
         * the bytes already copied, just like the aligned-read path. */
        if (sector > NFSK_SCRATCH_LIMIT) { errno = ENOTSUP; return -1; }
        BOOL temporary;
        void *edge = borrow_scratch(b, sector, &temporary);
        if (!edge) { errno = ENOMEM; return -1; }
        int64_t done = 0;
        if (offset != aligned_start) {
            rc = aligned_read(b->block, sector, edge, aligned_start, sector);
            if (!rc) {
                done = MIN(count, sector - (offset - aligned_start));
                memcpy(buf, (char *)edge + (offset - aligned_start), (size_t)done);
            }
        }
        int64_t middle = (count - done) / sector * sector;
        if (!rc && middle) {
            rc = aligned_read(b->block, sector, (char *)buf + done, offset + done, middle);
            if (!rc) done += middle;
        }
        if (!rc && done < count) {
            int64_t tail = offset + done;
            rc = aligned_read(b->block, sector, edge, tail, aligned_start + span - tail);
            if (!rc) memcpy((char *)buf + done, edge, (size_t)(count - done));
        }
        if (temporary) release_workspace(edge, sector);
        if (rc < 0) { errno = -rc; return -1; }
        return count;
    }
    BOOL temporary;
    void *tmp = borrow_scratch(b, (size_t)span, &temporary);
    if (!tmp) { errno = ENOMEM; return -1; }
    rc = aligned_read(b->block, sector, tmp, aligned_start, span);
    if (!rc) memcpy(buf, (char *)tmp + (offset - aligned_start), (size_t)count);
    if (temporary) release_workspace(tmp, (size_t)span);
    if (rc < 0) { errno = -rc; return -1; }
    return count;
}

static __attribute__((noinline))
int64_t block_pwrite(NFSKBackend *b, const void *buf, int64_t offset, int64_t count) {
    FSBlockDeviceResource *res = b->block;
    if (!res.isWritable) { errno = EROFS; return -1; }
    uint32_t sector;
    int64_t aligned_start, span;
    int rc = block_range(b, offset, &count, &aligned_start, &span, &sector);
    if (rc) { errno = -rc; return -1; }
    if (!count) { errno = ENOSPC; return -1; }
    if (aligned_start == offset && span == count) {
        rc = aligned_write(res, sector, buf, offset, count);
        if (rc < 0) { errno = -rc; return -1; }
        return count;
    }
    if (span > NFSK_SCRATCH_LIMIT) {
        /* Prepare both edges before any write: a failed tail pre-read must
         * not leave a newly written head. The middle uses the caller's live
         * buffer directly, in the same serial synchronous operation. */
        if (sector > NFSK_SCRATCH_LIMIT) { errno = ENOTSUP; return -1; }
        BOOL head = aligned_start < offset;
        int64_t end = offset + count, aligned_end = aligned_start + span;
        BOOL tail = end < aligned_end;
        int64_t tail_start = end - end % sector;
        BOOL temporary;
        size_t workspace = ((size_t)head + (size_t)tail) * sector;
        void *edges = borrow_scratch(b, workspace, &temporary);
        if (!edges) { errno = ENOMEM; return -1; }
        void *last = (char *)edges + (head ? sector : 0);
        if (head && tail && span <= 2 * (int64_t)sector) {
            rc = aligned_read(res, sector, edges, aligned_start, span);
        } else {
            if (head) rc = aligned_read(res, sector, edges, aligned_start, sector);
            if (!rc && tail) rc = aligned_read(res, sector, last, tail_start, aligned_end - tail_start);
        }
        int64_t head_bytes = head ? sector - (offset - aligned_start) : 0;
        int64_t tail_bytes = tail ? end - tail_start : 0;
        int64_t middle = count - head_bytes - tail_bytes;
        if (!rc) {
            if (head) memcpy((char *)edges + (offset - aligned_start), buf, (size_t)head_bytes);
            if (tail) memcpy(last, (const char *)buf + count - tail_bytes, (size_t)tail_bytes);
            if (head) rc = aligned_write(res, sector, edges, aligned_start, sector);
            if (!rc && middle) rc = aligned_write(res, sector, (const char *)buf + head_bytes,
                                                  offset + head_bytes, middle);
            if (!rc && tail) rc = aligned_write(res, sector, last, tail_start, aligned_end - tail_start);
        }
        if (temporary) release_workspace(edges, workspace);
        if (rc < 0) { errno = -rc; return -1; }
        return count;
    }
    BOOL temporary;
    void *tmp = borrow_scratch(b, (size_t)span, &temporary);
    if (!tmp) { errno = ENOMEM; return -1; }
    BOOL head = aligned_start < offset;
    int64_t end = offset + count, aligned_end = aligned_start + span;
    BOOL tail = end < aligned_end;
    int64_t tail_start = end - end % sector;
    if (head && tail && span <= 2 * (int64_t)sector) {
        rc = aligned_read(res, sector, tmp, aligned_start, span);
    } else {
        if (head) rc = aligned_read(res, sector, tmp, aligned_start, MIN(span, (int64_t)sector));
        if (!rc && tail) rc = aligned_read(res, sector, (char *)tmp + (tail_start - aligned_start),
                                         tail_start, aligned_end - tail_start);
    }
    if (!rc) {
        memcpy((char *)tmp + (offset - aligned_start), buf, (size_t)count);
        rc = aligned_write(res, sector, tmp, aligned_start, span);
    }
    if (temporary) release_workspace(tmp, (size_t)span);
    if (rc < 0) { errno = -rc; return -1; }
    return count;
}

/* ------------------------------------------------------------------ */
/* Public I/O interface — dispatches on backend mode.                  */
/* ------------------------------------------------------------------ */
uint32_t nfsk_block_sector_size(void *backend) {
    return BK(backend)->sectorSize;
}

uint64_t nfsk_block_total_bytes(void *backend) {
    return BK(backend)->totalBytes;
}

int nfsk_block_is_writable(void *backend) { return BK(backend)->writable ? 1 : 0; }

static inline BOOL direct_block_request(uint64_t total, uint32_t sector, int error,
                                       int64_t offset, int64_t count) {
    return !error && (uint64_t)offset < total &&
        (uint64_t)count <= total - offset && offset % sector == 0 && count % sector == 0;
}

int64_t nfsk_block_pread(void *backend, void *buf, int64_t offset, int64_t count) {
    if (offset < 0 || count < 0) { errno = EINVAL; return -1; }
    if (count == 0) return 0;
    NFSKBackend *b = BK(backend);
    if (b->mode == NFSKModeFile) {
        int64_t total = (int64_t)b->totalBytes;
        if (offset >= total) return 0;
        if (count > total - offset) count = total - offset;
        ssize_t n = pread(b->fd, buf, (size_t)count, (off_t)offset);
        if (n < 0) return -1;
        return n;
    }
    if (direct_block_request(b->totalBytes, b->sectorSize, b->geometryError, offset, count)) {
        int rc = aligned_read(b->block, b->sectorSize, buf, offset, count);
        if (rc < 0) { errno = -rc; return -1; }
        return count;
    }
    return block_pread(b, buf, offset, count);
}

int64_t nfsk_block_pwrite(void *backend, const void *buf, int64_t offset, int64_t count) {
    if (offset < 0 || count < 0) { errno = EINVAL; return -1; }
    if (count == 0) return 0;
    NFSKBackend *b = BK(backend);
    if (!b->writable) { errno = EROFS; return -1; }
    if (b->mode == NFSKModeFile) {
        int64_t total = (int64_t)b->totalBytes;
        if (offset >= total) { errno = ENOSPC; return -1; }
        if (count > total - offset) count = total - offset;
        ssize_t n = pwrite(b->fd, buf, (size_t)count, (off_t)offset);
        if (n < 0) return -1;
        return n;
    }
    if (direct_block_request(b->totalBytes, b->sectorSize, b->geometryError, offset, count)) {
        if (!b->block.isWritable) { errno = EROFS; return -1; }
        int rc = aligned_write(b->block, b->sectorSize, buf, offset, count);
        if (rc < 0) { errno = -rc; return -1; }
        return count;
    }
    return block_pwrite(b, buf, offset, count);
}

int nfsk_block_sync(void *backend) {
    NFSKBackend *b = BK(backend);
    if (b->mode == NFSKModeFile) {
        return fsync(b->fd) == 0 ? 0 : -errno;
    }
    NSError *err = nil;
    if (![b->block metadataFlushWithError:&err]) {
        return resource_error(err);
    }
    return 0;
}
