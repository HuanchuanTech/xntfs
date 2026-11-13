#include <errno.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>
#include "host_query_guard.h"

// Test executable only: no query of a /Volumes path reaches a real filesystem.
// Count even Foundation's implicit directory-type and path-resolution queries.
static atomic_bool enabled;
static atomic_uint queries;
void xntfs_test_begin_query_guard(void) { atomic_store(&queries, 0); atomic_store(&enabled, true); }
uint32_t xntfs_test_query_count(void) { return atomic_load(&queries); }
void xntfs_test_end_query_guard(void) { atomic_store(&enabled, false); }
static bool reject(const char *path) {
    if (!atomic_load(&enabled) || !path || strncmp(path, "/Volumes/", 9)) return false;
    atomic_fetch_add(&queries, 1);
    errno = EIO;
    return true;
}
static int guarded_stat(const char *path, struct stat *out) { return reject(path) ? -1 : stat(path, out); }
static int guarded_lstat(const char *path, struct stat *out) { return reject(path) ? -1 : lstat(path, out); }
static int guarded_statfs(const char *path, struct statfs *out) { return reject(path) ? -1 : statfs(path, out); }
static int guarded_fstatat(int fd, const char *path, struct stat *out, int flags) {
    return reject(path) ? -1 : fstatat(fd, path, out, flags);
}
static int guarded_getattrlist(const char *path, struct attrlist *attributes, void *buffer, size_t size, unsigned long options) {
    return reject(path) ? -1 : getattrlist(path, attributes, buffer, size, options);
}
#define INTERPOSE(replacement, original) \
    __attribute__((used, section("__DATA,__interpose"))) \
    static const struct { const void *replace; const void *original; } interpose_##replacement = \
        { (const void *)(replacement), (const void *)(original) }
INTERPOSE(guarded_stat, stat);
INTERPOSE(guarded_lstat, lstat);
INTERPOSE(guarded_statfs, statfs);
INTERPOSE(guarded_fstatat, fstatat);
INTERPOSE(guarded_getattrlist, getattrlist);
