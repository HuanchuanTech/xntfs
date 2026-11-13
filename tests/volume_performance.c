/* Counters are only redirected into diagnostic builds. Timed A/B binaries link
 * the original bridge/backend without redirects or observer calls. */
#ifdef HAVE_CONFIG_H
#include "config.h"
#endif
#include <errno.h>
#include <stdatomic.h>
#include <time.h>
#include <unistd.h>
#include "volume_performance.h"

enum { READS, BYTES, READ_NS, INODES, ATTRS, STATS, STAT_NS, SYMLINKS,
       INODE_OPEN_NS, INODE_CLOSES, INODE_CLOSE_NS, ATTR_OPEN_NS, ATTR_CLOSES, ATTR_CLOSE_NS,
       MBSTOUCS_CALLS, MBSTOUCS_NS, REPARSE_VALIDATIONS, REPARSE_VALIDATION_NS, COUNTERS };
static _Atomic uint64_t values[COUNTERS];
void nfsk_perf_reset(void) {
    for (int i = 0; i < COUNTERS; i++) atomic_store_explicit(&values[i], 0, memory_order_relaxed);
}
nfsk_perf_counters nfsk_perf_snapshot(void) {
    nfsk_perf_counters r = {
        atomic_load_explicit(&values[READS], memory_order_relaxed),
        atomic_load_explicit(&values[BYTES], memory_order_relaxed),
        atomic_load_explicit(&values[READ_NS], memory_order_relaxed),
        atomic_load_explicit(&values[INODES], memory_order_relaxed),
        atomic_load_explicit(&values[ATTRS], memory_order_relaxed),
        atomic_load_explicit(&values[STATS], memory_order_relaxed),
        atomic_load_explicit(&values[STAT_NS], memory_order_relaxed),
        atomic_load_explicit(&values[SYMLINKS], memory_order_relaxed),
        atomic_load_explicit(&values[INODE_OPEN_NS], memory_order_relaxed),
        atomic_load_explicit(&values[INODE_CLOSES], memory_order_relaxed),
        atomic_load_explicit(&values[INODE_CLOSE_NS], memory_order_relaxed),
        atomic_load_explicit(&values[ATTR_OPEN_NS], memory_order_relaxed),
        atomic_load_explicit(&values[ATTR_CLOSES], memory_order_relaxed),
        atomic_load_explicit(&values[ATTR_CLOSE_NS], memory_order_relaxed),
        atomic_load_explicit(&values[MBSTOUCS_CALLS], memory_order_relaxed),
        atomic_load_explicit(&values[MBSTOUCS_NS], memory_order_relaxed),
        atomic_load_explicit(&values[REPARSE_VALIDATIONS], memory_order_relaxed),
        atomic_load_explicit(&values[REPARSE_VALIDATION_NS], memory_order_relaxed)
    };
    return r;
}

#ifdef NFSK_PERF_TRACE
#include <ntfs-3g/volume.h>
#include <ntfs-3g/inode.h>
#include <ntfs-3g/attrib.h>
#include <ntfs-3g/reparse.h>
#include <ntfs-3g/unistr.h>
static uint64_t now(void) {
    int saved = errno;
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC_RAW, &t);
    errno = saved;
    return (uint64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}
#define ADD(i, n) atomic_fetch_add_explicit(&values[i], (n), memory_order_relaxed)
int nfsk_perf_mbstoucs(const char *name, ntfschar **output) {
    uint64_t start = now();
    int result = ntfs_mbstoucs(name, output), saved = errno;
    ADD(MBSTOUCS_CALLS, 1); ADD(MBSTOUCS_NS, now() - start);
    errno = saved;
    return result;
}
ssize_t nfsk_perf_pread(int fd, void *buf, size_t size, off_t offset) {
    uint64_t start = now();
    ssize_t result = pread(fd, buf, size, offset);
    int saved = errno;
    ADD(READ_NS, now() - start); ADD(READS, 1);
    if (result > 0) ADD(BYTES, (uint64_t)result);
    errno = saved;
    return result;
}
ntfs_inode *nfsk_perf_inode_open(ntfs_volume *volume, MFT_REF ref) {
    uint64_t start = now();
    ntfs_inode *result = ntfs_inode_open(volume, ref);
    int saved = errno;
    ADD(INODES, 1);
    ADD(INODE_OPEN_NS, now() - start);
    errno = saved;
    return result;
}
int nfsk_perf_inode_close(ntfs_inode *inode) {
    uint64_t start = now();
    int result = ntfs_inode_close(inode), saved = errno;
    ADD(INODE_CLOSES, 1); ADD(INODE_CLOSE_NS, now() - start);
    errno = saved;
    return result;
}
#if CACHE_NIDATA_SIZE
int nfsk_perf_inode_real_close(ntfs_inode *inode) {
    uint64_t start = now();
    int result = ntfs_inode_real_close(inode), saved = errno;
    ADD(INODE_CLOSES, 1); ADD(INODE_CLOSE_NS, now() - start);
    errno = saved;
    return result;
}
#endif
ntfs_attr *nfsk_perf_attr_open(ntfs_inode *inode, ATTR_TYPES type, ntfschar *name, u32 length) {
    uint64_t start = now();
    ntfs_attr *result = ntfs_attr_open(inode, type, name, length);
    int saved = errno;
    ADD(ATTRS, 1);
    ADD(ATTR_OPEN_NS, now() - start);
    errno = saved;
    return result;
}
void nfsk_perf_attr_close(ntfs_attr *attr) {
    uint64_t start = now();
    ntfs_attr_close(attr);
    int saved = errno;
    ADD(ATTR_CLOSES, 1); ADD(ATTR_CLOSE_NS, now() - start);
    errno = saved;
}
char *nfsk_perf_make_symlink(ntfs_inode *inode, const char *mountpoint) {
    char *result = ntfs_make_symlink(inode, mountpoint);
    int saved = errno;
    ADD(SYMLINKS, 1);
    errno = saved;
    return result;
}
REPARSE_POINT *nfsk_perf_get_reparse_point(ntfs_inode *inode) {
    uint64_t start = now();
    REPARSE_POINT *result = ntfs_get_reparse_point(inode);
    int saved = errno;
    ADD(REPARSE_VALIDATIONS, 1); ADD(REPARSE_VALIDATION_NS, now() - start);
    errno = saved;
    return result;
}
int nfsk_perf_original_statfs(ntfs_fskit_volume *, nfsk_statfs_t *);
int nfsk_statfs(ntfs_fskit_volume *v, nfsk_statfs_t *out) {
    int incoming = errno;
    uint64_t start = now();
    errno = incoming;
    int result = nfsk_perf_original_statfs(v, out);
    int saved = errno;
    ADD(STAT_NS, now() - start); ADD(STATS, 1);
    errno = saved;
    return result;
}
#ifdef NFSK_PERF_STATFS_COUNTERS
int nfsk_perf_original_statfs_counters(ntfs_fskit_volume *, nfsk_statfs_counters_t *);
int nfsk_statfs_counters(ntfs_fskit_volume *v, nfsk_statfs_counters_t *out) {
    int incoming = errno;
    uint64_t start = now();
    errno = incoming;
    int result = nfsk_perf_original_statfs_counters(v, out);
    int saved = errno;
    ADD(STAT_NS, now() - start); ADD(STATS, 1);
    errno = saved;
    return result;
}
#endif
#endif
