#include <errno.h>
#include <fcntl.h>
#include <execinfo.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <ntfs-3g/volume.h>
#include <ntfs-3g/inode.h>
#include <ntfs-3g/attrib.h>
#include <ntfs-3g/dir.h>
#include <ntfs-3g/unistr.h>
#include "ntfs_fskit.h"

typedef struct { int fd, writes, syncs, fail_reads, fail_write_at, faulted; int64_t size; } device;
static int checks, failures;
#define CHECK(ok, message) do { checks++; if (!(ok)) { failures++; \
    fprintf(stderr, "FAIL: %s (errno=%d)\n", message, errno); } else printf("PASS: %s\n", message); } while (0)
static void require(int ok, const char *message) {
    if (!ok) { fprintf(stderr, "Fixture failure: %s (errno=%d)\n", message, errno); exit(2); }
}
int64_t nfsk_block_pread(void *p, void *buf, int64_t off, int64_t len) {
    device *d = p;
    if (d->fail_reads) { errno = EIO; return -1; }
    return pread(d->fd, buf, (size_t)len, off);
}
int64_t nfsk_block_pwrite(void *p, const void *buf, int64_t off, int64_t len) {
    device *d = p; d->writes++;
    if (d->fail_write_at && d->writes == d->fail_write_at) {
        if (getenv("NFSK_TRACE_FAULT")) {
            void *frames[24];
            backtrace_symbols_fd(frames, backtrace(frames, 24), STDERR_FILENO);
        }
        d->faulted++; errno = EIO; return -1;
    }
    return pwrite(d->fd, buf, (size_t)len, off);
}
int nfsk_block_sync(void *p) { device *d = p; d->syncs++; return fsync(d->fd) ? -errno : 0; }
uint64_t nfsk_block_total_bytes(void *p) { return ((device *)p)->size; }
uint32_t nfsk_block_sector_size(void *p) { (void)p; return 512; }
int nfsk_block_is_writable(void *p) { (void)p; return 1; }

static uint64_t create(ntfs_fskit_volume *v, uint64_t parent, const char *name, uint32_t type) {
    int error = 0;
    uint64_t ino = nfsk_create(v, parent, name, type, &error);
    require(ino != 0, name);
    return ino;
}
static uint64_t lookup(ntfs_fskit_volume *v, uint64_t parent, const char *name) {
    int error = 0;
    return nfsk_lookup(v, parent, name, &error);
}
static int has_payload(ntfs_fskit_volume *v, uint64_t ino, const char *text) {
    char bytes[64] = {0}; int error = 0;
    return nfsk_read(v, ino, 0, bytes, sizeof bytes, &error) == (int64_t)strlen(text) && !strcmp(bytes, text);
}
static int retained_names(void *p, const char *name, uint64_t ino, uint32_t type, int64_t cookie) {
    (void)ino; (void)type; (void)cookie;
    if (!strncmp(name, ".xntfs-open-", 12)) (*(int *)p)++;
    return 0;
}
static void prepare_native(const char *path) {
    ntfs_volume *volume = ntfs_mount(path, NTFS_MNT_NONE);
    require(volume != NULL && ntfs_volume_get_free_space(volume) == 0, "native fixture mount");
    ntfs_inode *root = ntfs_inode_open(volume, FILE_root);
    ntfschar *name = NULL, *target = NULL;
    int length = ntfs_mbstoucs("LongOpenName.txt", &name);
    ntfs_inode *file = ntfs_create(root, const_cpu_to_le32(0), name, length, S_IFREG);
    free(name); name = NULL;
    require(file && ntfs_set_ntfs_dos_name(file, root, "LONGOP~1.TXT", 12, 0) == 0, "long and DOS names (consumes both inodes)");
    root = ntfs_inode_open(volume, FILE_root);
    volume->special_files = NTFS_FILES_INTERIX;
    length = ntfs_mbstoucs("InterixLink", &name);
    int target_length = ntfs_mbstoucs("Metadata", &target);
    file = ntfs_create_symlink(root, const_cpu_to_le32(0), name, length, target, target_length);
    free(name); free(target);
    require(file && ntfs_inode_close_in_dir(file, root) == 0, "Interix symlink fixture");
    require(ntfs_inode_close(root) == 0 && ntfs_umount(volume, FALSE) == 0, "close native fixtures");
}
static int find_retention(void *p, const ntfschar *name, int length, int name_type,
                          s64 position, MFT_REF ref, unsigned type) {
    (void)name_type; (void)position; (void)ref; (void)type;
    char *text = NULL;
    require(ntfs_ucstombs(name, length, &text, 0) >= 0, "native directory name");
    if (!strncmp(text, ".xntfs-open-", 12)) snprintf(p, 96, "%s", text);
    free(text);
    return 0;
}
static void read_retention_name(const char *path, char name[96]) {
    /* The bridge is idle and synchronized while this independent, read-only
     * view inspects the actual on-disk name, bypassing bridge filtering. */
    ntfs_volume *volume = ntfs_mount(path, NTFS_MNT_RDONLY | NTFS_MNT_FORENSIC);
    require(volume != NULL, "read-only observer");
    ntfs_inode *root = ntfs_inode_open(volume, FILE_root);
    s64 position = 0;
    name[0] = 0;
    require(root && ntfs_readdir(root, &position, name, find_retention) == 0 && *name, "find on-disk retention link");
    require(ntfs_inode_close(root) == 0 && ntfs_umount(volume, FALSE) == 0, "close read-only observer");
}
static uint64_t checksum(device *d) {
    unsigned char bytes[65536]; uint64_t sum = 14695981039346656037ULL;
    for (int64_t off = 0; off < d->size;) {
        ssize_t got = pread(d->fd, bytes, sizeof bytes, off);
        require(got > 0, "read checksum");
        for (ssize_t i = 0; i < got; i++) sum = (sum ^ bytes[i]) * 1099511628211ULL;
        off += got;
    }
    return sum;
}
static void check_read_only(device *d, int expected, const char *message) {
    uint64_t before = checksum(d);
    int reason = -1;
    d->writes = d->syncs = 0;
    int rc = nfsk_quick_check(d, &reason);
    CHECK((expected == NFSK_CHECK_CLEAN ? rc == 0 : rc < 0) && reason == expected, message);
    CHECK(d->writes == 0 && d->syncs == 0 && checksum(d) == before, "check neither writes, syncs nor changes image bytes");
}

static void check_cases(device *d, const char *path) {
    check_read_only(d, NFSK_CHECK_CLEAN, "clean volume passes real read-only preflight");
    d->fail_reads = 1;
    check_read_only(d, NFSK_CHECK_METADATA, "backend read failure does not pass preflight");
    d->fail_reads = 0;
    unsigned char boot[512], damaged[512] = {0};
    require(pread(d->fd, boot, sizeof boot, 0) == sizeof boot, "save boot sector");
    require(pwrite(d->fd, damaged, sizeof damaged, 0) == sizeof damaged, "damage boot copy");
    check_read_only(d, NFSK_CHECK_METADATA, "invalid boot sector fails preflight");
    require(pwrite(d->fd, boot, sizeof boot, 0) == sizeof boot, "restore boot copy");

    ntfs_volume *volume = ntfs_mount(path, NTFS_MNT_NONE);
    require(volume != NULL, "prepare volume flags");
    le16 original_flags = volume->flags;
    require(ntfs_volume_write_flags(volume, original_flags | VOLUME_IS_DIRTY) == 0, "mark disposable volume dirty");
    require(ntfs_umount(volume, FALSE) == 0, "persist dirty flag");
    check_read_only(d, NFSK_CHECK_DIRTY, "dirty volume is not falsely declared clean");
    volume = ntfs_mount(path, NTFS_MNT_NONE);
    require(volume && ntfs_volume_write_flags(volume, original_flags) == 0, "restore disposable flags");
    ntfs_inode *log = ntfs_inode_open(volume, FILE_LogFile);
    require(log != NULL, "open fixture journal");
    ntfs_attr *data = ntfs_attr_open(log, AT_DATA, AT_UNNAMED, 0);
    require(data != NULL, "open journal data");
    LCN lcn = ntfs_attr_vcn_to_lcn(data, 0);
    require(lcn >= 0, "find fixture journal sector");
    off_t journal = lcn << volume->cluster_size_bits;
    ntfs_attr_close(data);
    require(ntfs_inode_close(log) == 0 && ntfs_umount(volume, FALSE) == 0, "close journal fixture");
    unsigned char old_log[512];
    require(pread(d->fd, old_log, sizeof old_log, journal) == sizeof old_log, "save journal sector");
    require(pwrite(d->fd, damaged, sizeof damaged, journal) == sizeof damaged, "damage journal copy");
    check_read_only(d, NFSK_CHECK_JOURNAL, "invalid journal is not silently reset or accepted");
    require(pwrite(d->fd, old_log, sizeof old_log, journal) == sizeof old_log, "restore journal copy");

    int error = 0;
    ntfs_fskit_volume *v = nfsk_mount(d, false, &error);
    require(v != NULL, "prepare hibernation fixture");
    uint64_t hiber = create(v, NFSK_ROOT_INO, "hiberfil.sys", NFSK_TYPE_FILE);
    char header[4096] = "hibr";
    require(nfsk_write(v, hiber, 0, header, sizeof header, &error) == sizeof header, "write hibernation marker");
    nfsk_umount(v);
    check_read_only(d, NFSK_CHECK_HIBERNATED, "hibernated Windows volume fails writable preflight");
}

static int allocation_fault(device *d, int nth, int nonresident) {
    int error = 0;
    ntfs_fskit_volume *v = nfsk_mount(d, false, &error);
    require(v != NULL, "mount allocation fault fixture");
    uint64_t ino = create(v, NFSK_ROOT_INO, "AllocationFault", NFSK_TYPE_FILE);
    size_t length = nonresident ? 8192 : 7;
    char payload[8192], actual[8192];
    memset(payload, 0x5a, sizeof payload);
    require(nfsk_write(v, ino, 0, payload, length, &error) == (int64_t)length && nfsk_sync(v) == 0, "persist original payload");
    d->writes = 0; d->fail_write_at = nth;
    int64_t rc = nfsk_preallocate(v, ino, 0, 1024 * 1024, true);
    d->fail_write_at = 0;
    printf("Fault case: %s write %d, injected=%d, result=%lld\n", nonresident ? "nonresident" : "resident", nth, d->faulted, rc);
    CHECK(!d->faulted || rc < 0, "allocation write failure is reported");
    (void)nfsk_sync(v);
    (void)nfsk_sync(v);
    nfsk_umount(v);
    v = nfsk_mount(d, true, &error);
    require(v != NULL, "read-only reopen after allocation failure");
    nfsk_attr_t attributes;
    CHECK(nfsk_getattr(v, ino, &attributes) == 0 && attributes.size == length,
          "allocation failure never exposes extended logical EOF after remount");
    CHECK(nfsk_read(v, ino, 0, actual, sizeof actual, &error) == (int64_t)length && !memcmp(payload, actual, length),
          "allocation failure preserves original payload after remount");
    nfsk_umount(v);
    return failures ? 1 : 0;
}

int main(int argc, char **argv) {
    if (argc != 2 && argc != 4) return 2;
    device d = { .fd = open(argv[1], O_RDWR) };
    struct stat st;
    require(d.fd >= 0 && fstat(d.fd, &st) == 0 && S_ISREG(st.st_mode), "disposable regular image");
    d.size = st.st_size;
    require(ntfs_set_char_encoding("UTF-8") == 0, "UTF-8");
    if (argc == 4) {
        int result = allocation_fault(&d, atoi(argv[2]), atoi(argv[3]));
        close(d.fd);
        return result;
    }
    prepare_native(argv[1]);
    int error = 0;
    ntfs_fskit_volume *v = nfsk_mount(&d, false, &error);
    require(v != NULL, "mount feature fixture");
    nfsk_attr_t a;

    uint64_t parent = create(v, NFSK_ROOT_INO, "LifetimeParent", NFSK_TYPE_DIR);
    uint64_t old = create(v, parent, "Old", NFSK_TYPE_FILE);
    CHECK(nfsk_write(v, old, 0, "old data", 8, &error) == 8 && nfsk_open_item(v, old) == 0 &&
          nfsk_open_item(v, old) == 0, "open notification is idempotent, not a descriptor count");
    CHECK(nfsk_remove(v, parent, "Old") == 0 && lookup(v, parent, "Old") == 0, "open unlink removes the visible name");
    CHECK(nfsk_getattr(v, old, &a) == 0 && a.nlink == 0 && has_payload(v, old, "old data"), "unlinked open item retains data and reports zero links");
    CHECK(nfsk_remove(v, NFSK_ROOT_INO, "LifetimeParent") == 0, "retention does not prevent removing original parent");
    CHECK(nfsk_write(v, old, 0, "new data", 8, &error) == 8 && has_payload(v, old, "new data"), "unlinked open item remains writable");
    int anchors = 0;
    CHECK(nfsk_readdir(v, NFSK_ROOT_INO, 0, &anchors, retained_names) == 0 && anchors == 0, "retention links are absent from enumeration");
    require(nfsk_sync(v) == 0, "synchronize retention link for observer");
    char anchor[96];
    read_retention_name(argv[1], anchor);
    CHECK(lookup(v, NFSK_ROOT_INO, anchor) == 0 && nfsk_remove(v, NFSK_ROOT_INO, anchor) == -ENOENT &&
          nfsk_rename(v, NFSK_ROOT_INO, anchor, NFSK_ROOT_INO, "Stolen") == -ENOENT &&
          nfsk_rename(v, NFSK_ROOT_INO, "LongOpenName.txt", NFSK_ROOT_INO, anchor) == -ENOENT,
          "even a known retention name cannot be looked up, removed or renamed");
    CHECK(nfsk_close_item(v, old) == 0 && nfsk_getattr(v, old, &a) == -ENOENT, "final close reclaims the unlinked item");
    CHECK(nfsk_close_item(v, old) == 0, "repeated final close is harmless");
    uint64_t dos = lookup(v, NFSK_ROOT_INO, "LongOpenName.txt");
    CHECK(dos && nfsk_open_item(v, dos) == 0 && nfsk_remove(v, NFSK_ROOT_INO, "LongOpenName.txt") == 0 &&
          nfsk_getattr(v, dos, &a) == 0 && a.nlink == 0 && nfsk_close_item(v, dos) == 0 && nfsk_getattr(v, dos, &a) == -ENOENT,
          "deleting a WIN32/DOS name pair retains its open inode until final close");

    old = create(v, NFSK_ROOT_INO, "OpenDestination", NFSK_TYPE_FILE);
    uint64_t source = create(v, NFSK_ROOT_INO, "RenameSource", NFSK_TYPE_FILE);
    require(nfsk_write(v, old, 0, "old", 3, &error) == 3 && nfsk_write(v, source, 0, "source", 6, &error) == 6, "rename payloads");
    CHECK(nfsk_open_item(v, old) == 0 && nfsk_rename(v, NFSK_ROOT_INO, "RenameSource", NFSK_ROOT_INO, "OpenDestination") == 0,
          "overwrite rename retains an open destination");
    CHECK(lookup(v, NFSK_ROOT_INO, "OpenDestination") == source && has_payload(v, source, "source") && has_payload(v, old, "old"),
          "new pathname and old open handle expose their distinct payloads");
    CHECK(nfsk_close_item(v, old) == 0 && nfsk_getattr(v, old, &a) == -ENOENT, "overwritten destination is reclaimed at final close");

    uint64_t hard = create(v, NFSK_ROOT_INO, "OpenHardLink", NFSK_TYPE_FILE);
    CHECK(nfsk_link(v, hard, NFSK_ROOT_INO, "OtherHardLink", &error) == 0 && nfsk_open_item(v, hard) == 0 &&
          nfsk_remove(v, NFSK_ROOT_INO, "OpenHardLink") == 0 && nfsk_getattr(v, hard, &a) == 0 && a.nlink == 1,
          "removing a nonfinal hard link does not add a retention link");
    CHECK(nfsk_remove(v, NFSK_ROOT_INO, "OtherHardLink") == 0 && nfsk_getattr(v, hard, &a) == 0 && a.nlink == 0 &&
          nfsk_close_item(v, hard) == 0, "last hard link is retained until final close");
    uint64_t empty = create(v, NFSK_ROOT_INO, "OpenEmptyDirectory", NFSK_TYPE_DIR);
    CHECK(nfsk_open_item(v, empty) == 0 && nfsk_remove(v, NFSK_ROOT_INO, "OpenEmptyDirectory") == 0 &&
          nfsk_getattr(v, empty, &a) == 0 && a.type == NFSK_TYPE_DIR && a.nlink == 0,
          "an open empty directory retains its inode until close");
    CHECK(!nfsk_create(v, empty, "Child", NFSK_TYPE_FILE, &error) && error == ENOENT &&
          !nfsk_symlink(v, empty, "Link", "target", &error) && error == ENOENT &&
          nfsk_link(v, source, empty, "Link", &error) == -1 && error == ENOENT &&
          nfsk_close_item(v, empty) == 0, "unlinked directories cannot receive new children");

    uint64_t retry = create(v, NFSK_ROOT_INO, "RetryCleanup", NFSK_TYPE_FILE);
    require(nfsk_open_item(v, retry) == 0 && nfsk_remove(v, NFSK_ROOT_INO, "RetryCleanup") == 0, "cleanup retry fixture");
    d.fail_reads = 1;
    CHECK(nfsk_close_item(v, retry) == -EIO, "failed final close reports its I/O error");
    d.fail_reads = 0;
    CHECK(nfsk_sync(v) == 0 && nfsk_getattr(v, retry, &a) == -ENOENT, "synchronize retries pending retention cleanup");

    uint64_t meta = create(v, NFSK_ROOT_INO, "Metadata", NFSK_TYPE_FILE);
    nfsk_metadata_t metadata = { .valid = NFSK_SET_BTIME | NFSK_SET_MTIME | NFSK_SET_ATIME | NFSK_SET_FLAGS,
        .btime_sec = 946684800, .btime_nsec = 123456700, .mtime_sec = 946684801,
        .atime_sec = 946684802, .flags = UF_HIDDEN };
    CHECK(nfsk_set_metadata(v, meta, &metadata) == 0 && nfsk_getattr(v, meta, &a) == 0 &&
          a.btime_sec == 946684800 && a.btime_nsec == 123456700 && a.mtime_sec == 946684801 &&
          a.atime_sec == 946684802 && a.flags == UF_HIDDEN, "native creation/access/modify times and hidden flag round-trip");
    metadata.btime_nsec = 1000000000;
    CHECK(nfsk_set_metadata(v, meta, &metadata) == -EINVAL, "invalid nanoseconds are rejected");
    metadata.btime_nsec = 0; metadata.btime_sec = INT64_MAX;
    CHECK(nfsk_set_metadata(v, meta, &metadata) == -EINVAL, "NTFS timestamp overflow is rejected");
    metadata.btime_sec = 946684800; metadata.flags = UF_IMMUTABLE;
    CHECK(nfsk_set_metadata(v, meta, &metadata) == -ENOTSUP && nfsk_getattr(v, meta, &a) == 0 && a.flags == UF_HIDDEN,
          "unsupported BSD flags fail without changing existing metadata");
    CHECK(nfsk_write(v, meta, 0, "x", 1, &error) == 1 && nfsk_getattr(v, meta, &a) == 0 && a.btime_sec == 946684800,
          "ordinary writes do not replace creation time with ctime");
    metadata.valid = NFSK_SET_FLAGS; metadata.flags = 0;
    CHECK(nfsk_set_metadata(v, meta, &metadata) == 0 && nfsk_getattr(v, meta, &a) == 0 && a.flags == 0, "hidden flag can be cleared");

    char target[4096];
    uint64_t interix = lookup(v, NFSK_ROOT_INO, "InterixLink");
    CHECK(interix && nfsk_getattr(v, interix, &a) == 0 && a.type == NFSK_TYPE_SYMLINK &&
          nfsk_readlink(v, interix, target, sizeof target) == 0 && !strcmp(target, "Metadata"), "existing Interix symlinks have consistent type and target");
    uint64_t relative = nfsk_symlink(v, NFSK_ROOT_INO, "RelativeLink", "Metadata", &error);
    uint64_t absolute = nfsk_symlink(v, NFSK_ROOT_INO, "AbsoluteLink", "/some/absolute/path", &error);
    CHECK(relative && nfsk_getattr(v, relative, &a) == 0 && a.type == NFSK_TYPE_SYMLINK &&
          nfsk_readlink(v, relative, target, sizeof target) == 0 && !strcmp(target, "Metadata"), "relative symlink creation and readback agree");
    CHECK(absolute && nfsk_readlink(v, absolute, target, sizeof target) == 0 && !strcmp(target, "/some/absolute/path"), "absolute POSIX symlink target is preserved");
    uint64_t link_parent = create(v, NFSK_ROOT_INO, "SmallLinkDirectory", NFSK_TYPE_DIR);
    uint64_t nested = nfsk_symlink(v, link_parent, "Link", "../Metadata", &error);
    CHECK(nested && nfsk_readlink(v, nested, target, sizeof target) == 0 && !strcmp(target, "../Metadata"),
          "symlinks can be created in a resident directory index");
    CHECK(!nfsk_symlink(v, NFSK_ROOT_INO, "relativelink", "other", &error) && error == EEXIST, "symlink creation rejects case-folded duplicates");
    char oversized_target[4097]; memset(oversized_target, 'x', sizeof oversized_target - 1); oversized_target[4096] = 0;
    CHECK(!nfsk_symlink(v, NFSK_ROOT_INO, "TooLongLink", oversized_target, &error) && error == ENAMETOOLONG &&
          !lookup(v, NFSK_ROOT_INO, "TooLongLink"), "oversized symlink target is rejected before namespace mutation");
    CHECK(!nfsk_create(v, NFSK_ROOT_INO, "NotAFifo", NFSK_TYPE_FIFO, &error) && error == ENOTSUP,
          "unsupported special-file creation is not converted into an ordinary file");

    uint64_t allocation = create(v, NFSK_ROOT_INO, "Allocation", NFSK_TYPE_FILE);
    require(nfsk_write(v, allocation, 0, "payload", 7, &error) == 7, "allocation payload");
    CHECK(nfsk_preallocate(v, allocation, 777, 65536, true) >= 65536 && nfsk_getattr(v, allocation, &a) == 0 &&
          a.size == 7 && a.alloc_size >= 65536 && has_payload(v, allocation, "payload"), "preallocation reserves space without changing EOF or payload");
    CHECK(nfsk_preallocate(v, allocation, 0, 32768, false) == 0, "already reserved range needs no new allocation");
    uint64_t before_allocation = a.alloc_size;
    CHECK(nfsk_preallocate(v, allocation, 0, 1LL << 40, true) == -ENOSPC && nfsk_getattr(v, allocation, &a) == 0 &&
          a.size == 7 && a.alloc_size == before_allocation, "ENOSPC leaves original allocation and EOF intact");
    CHECK(nfsk_preallocate(v, allocation, 0, INT64_MAX, true) == -EFBIG, "allocation range overflow is rejected");
    uint64_t keep = create(v, NFSK_ROOT_INO, "KeepEOF", NFSK_TYPE_FILE);
    require(nfsk_write(v, keep, 0, "payload", 7, &error) == 7 && nfsk_preallocate(v, keep, 0, 65536, true) >= 65536,
            "reservation with unchanged EOF fixture");
    CHECK(nfsk_truncate(v, allocation, 65536) == 0, "logical EOF can grow into reserved storage");
    char zeroes[512]; memset(zeroes, 1, sizeof zeroes);
    CHECK(nfsk_read(v, allocation, 4096, zeroes, sizeof zeroes, &error) == sizeof zeroes &&
          !memcmp(zeroes, (char[512]){0}, sizeof zeroes), "reserved uninitialized storage reads as zero, never old disk contents");

    uint64_t sparse = create(v, NFSK_ROOT_INO, "Sparse", NFSK_TYPE_FILE);
    require(nfsk_truncate(v, sparse, 3 * 1024 * 1024) == 0 && nfsk_write(v, sparse, 1024 * 1024, "data", 4, &error) == 4, "sparse fixture");
    int64_t offset = -1;
    CHECK(nfsk_seek_region(v, sparse, 0, true, &offset) == 0 && offset == 1024 * 1024, "SEEK_DATA skips the leading sparse hole");
    CHECK(nfsk_seek_region(v, sparse, 0, false, &offset) == 0 && offset == 0, "SEEK_HOLE returns the current hole offset");
    CHECK(nfsk_seek_region(v, sparse, 1024 * 1024 + 1, true, &offset) == 0 && offset == 1024 * 1024 + 1, "SEEK_DATA preserves an offset already in data");
    CHECK(nfsk_seek_region(v, sparse, 1024 * 1024, false, &offset) == 0 && offset == 1024 * 1024 + 4096, "SEEK_HOLE finds the next actual runlist hole");
    CHECK(nfsk_seek_region(v, sparse, 2 * 1024 * 1024, true, &offset) == -ENXIO &&
          nfsk_seek_region(v, sparse, 3 * 1024 * 1024, false, &offset) == -ENXIO, "missing data and EOF return ENXIO");
    CHECK(nfsk_seek_region(v, sparse, -1, true, &offset) == -EINVAL, "negative seek is rejected");
    CHECK(nfsk_getattr(v, sparse, &a) == 0 && a.alloc_size < a.size, "sparse allocation reports physical rather than logical storage");
    CHECK(nfsk_preallocate(v, sparse, 0, 4096, true) == -ENOTSUP, "unsupported sparse preallocation is rejected");

    nfsk_statfs_t before, after;
    require(nfsk_statfs(v, &before) == 0, "original volume identity");
    CHECK(nfsk_rename_volume(v, "Renamed NTFS") == 0 && nfsk_statfs(v, &after) == 0 &&
          !strcmp(after.volume_name, "Renamed NTFS") && before.volume_serial == after.volume_serial, "volume rename preserves persistent identity");
    char unicode_label[382];
    for (int i = 0; i < 127; i++) memcpy(unicode_label + i * 3, "\xe6\xb5\x8b", 3);
    unicode_label[381] = 0;
    CHECK(nfsk_rename_volume(v, unicode_label) == 0 && nfsk_statfs(v, &after) == 0 && !strcmp(after.volume_name, unicode_label),
          "maximum-length Unicode volume label is not truncated in statistics");
    require(nfsk_rename_volume(v, "Renamed NTFS") == 0, "restore test label");
    CHECK(nfsk_rename_volume(v, "bad/name") == -EINVAL && nfsk_rename_volume(v, "") == -EINVAL, "invalid volume labels are rejected");
    char long_name[130]; memset(long_name, 'x', 128); long_name[128] = 0;
    CHECK(nfsk_rename_volume(v, long_name) == -ENAMETOOLONG, "oversized volume label is rejected");
    CHECK(nfsk_set_metadata(v, 3, &metadata) == -EPERM && nfsk_preallocate(v, 3, 0, 1, false) == -EPERM &&
          nfsk_seek_region(v, 3, 0, true, &offset) == -EPERM && nfsk_open_item(v, 3) == -EPERM, "new bridge operations protect reserved metadata");
    nfsk_umount(v);
    v = nfsk_mount(&d, true, &error);
    require(v != NULL, "read-only remount");
    CHECK(nfsk_statfs(v, &after) == 0 && !strcmp(after.volume_name, "Renamed NTFS"), "volume label survives remount");
    CHECK(nfsk_getattr(v, meta, &a) == 0 && a.btime_sec == 946684800 && a.flags == 0, "creation time and flags survive remount");
    CHECK(nfsk_getattr(v, allocation, &a) == 0 && a.size == 65536 && a.alloc_size >= 65536, "preallocation survives close and remount");
    CHECK(nfsk_getattr(v, keep, &a) == 0 && a.size == 7 && a.alloc_size >= 65536 && has_payload(v, keep, "payload"),
          "reservation and unchanged small EOF both survive remount");
    CHECK(nfsk_readlink(v, absolute, target, sizeof target) == 0 && !strcmp(target, "/some/absolute/path"), "symlink survives read-only remount");
    CHECK(nfsk_rename_volume(v, "No") == -EROFS && nfsk_set_metadata(v, meta, &metadata) == -EROFS &&
          nfsk_preallocate(v, allocation, 0, 1, true) == -EROFS &&
          !nfsk_symlink(v, NFSK_ROOT_INO, "NoLink", "target", &error) && error == EROFS, "all new mutations respect read-only mode");
    anchors = 0;
    CHECK(nfsk_readdir(v, NFSK_ROOT_INO, 0, &anchors, retained_names) == 0 && anchors == 0, "normal close/unmount leaves no retention links on disk");
    nfsk_umount(v);
    check_cases(&d, argv[1]);
    close(d.fd);
    printf("%d feature checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
