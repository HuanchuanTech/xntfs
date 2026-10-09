#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <ntfs-3g/inode.h>
#include "ntfs_fskit.h"

typedef struct { int fd; int64_t size; } test_device;
static int failures, checks, fail_close_writes, inside_close;
#define CHECK(condition, message) do { checks++; if (!(condition)) { \
    failures++; fprintf(stderr, "FAIL: %s\n", message); \
} else { printf("PASS: %s\n", message); } } while (0)

int64_t nfsk_block_pread(void *opaque, void *buf, int64_t off, int64_t count) {
    return pread(((test_device *)opaque)->fd, buf, count, off);
}
int64_t nfsk_block_pwrite(void *opaque, const void *buf, int64_t off, int64_t count) {
    if (fail_close_writes && inside_close) { errno = EIO; return -1; }
    return pwrite(((test_device *)opaque)->fd, buf, count, off);
}
int nfsk_block_sync(void *opaque) { return fsync(((test_device *)opaque)->fd) ? -errno : 0; }
uint64_t nfsk_block_total_bytes(void *opaque) { return ((test_device *)opaque)->size; }
uint32_t nfsk_block_sector_size(void *opaque) { (void)opaque; return 512; }
int nfsk_block_is_writable(void *opaque) { (void)opaque; return 1; }

/* Only the bridge translation unit redirects close calls to these wrappers. */
int nfsk_test_inode_close(ntfs_inode *ni) {
    inside_close++;
    int result = ntfs_inode_close(ni), saved = errno;
    inside_close--;
    errno = saved;
    return result;
}
int nfsk_test_inode_real_close(ntfs_inode *ni) {
    inside_close++;
    int result = ntfs_inode_real_close(ni), saved = errno;
    inside_close--;
    errno = saved;
    return result;
}
int nfsk_test_inode_sync(ntfs_inode *ni) {
    inside_close++;
    int result = ntfs_inode_sync(ni), saved = errno;
    inside_close--;
    errno = saved;
    return result;
}

static uint64_t lookup(ntfs_fskit_volume *v, const char *name) {
    int error = 0;
    return nfsk_lookup(v, NFSK_ROOT_INO, name, &error);
}

typedef struct { ntfs_fskit_volume *volume; uint64_t inode; int found, valid, stop; } case_listing;
static int check_case_listing(void *opaque, const char *name, uint64_t inode, uint32_t type, int64_t cookie) {
    (void)type; (void)cookie;
    case_listing *check = opaque;
    if (inode != check->inode) return 0;
    check->found++;
    check->valid = !strcmp(name, "MiXeDCaSe.txt") && lookup(check->volume, "mixedcase.txt") == inode;
    return check->stop;
}

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "Usage: %s <disposable-NTFS-image>\n", argv[0]); return 2; }
    test_device device = { .fd = open(argv[1], O_RDWR) };
    struct stat sb;
    if (device.fd < 0 || fstat(device.fd, &sb) || !S_ISREG(sb.st_mode)) return 2;
    device.size = sb.st_size;
    int error = 0;
    ntfs_fskit_volume *v = nfsk_mount(&device, false, &error);
    if (!v) { fprintf(stderr, "mount: %d\n", error); return 2; }
    nfsk_statfs_t initial, allocated, removed, remounted;
    CHECK(nfsk_statfs(v, &initial) == 0 && initial.free_clusters > initial.total_clusters / 2,
          "a mostly empty fixture reports real free clusters");
    CHECK(initial.free_files > 0 && initial.free_files <= initial.total_files,
          "free inode counts are initialized and bounded");
    uint64_t ino = nfsk_create(v, NFSK_ROOT_INO, "IssueSpace.bin", NFSK_TYPE_FILE, &error);
    char data[65536]; memset(data, 'a', sizeof data);
    CHECK(ino && nfsk_write(v, ino, 0, data, sizeof data, &error) == sizeof data, "allocate 64 KiB");
    CHECK(nfsk_statfs(v, &allocated) == 0 && allocated.free_clusters < initial.free_clusters,
          "allocation reduces free clusters");
    CHECK(nfsk_remove(v, NFSK_ROOT_INO, "IssueSpace.bin") == 0, "remove allocated file");
    CHECK(nfsk_statfs(v, &removed) == 0 && removed.free_clusters > allocated.free_clusters,
          "deletion releases free clusters");

    ino = nfsk_create(v, NFSK_ROOT_INO, "MiXeDCaSe.txt", NFSK_TYPE_FILE, &error);
    CHECK(ino != 0, "create mixed-case name");
    nfsk_umount(v);
    v = nfsk_mount(&device, false, &error);
    if (!v) return 2;
    CHECK(nfsk_statfs(v, &remounted) == 0 && remounted.free_clusters == removed.free_clusters,
          "free space agrees after remount");
    CHECK(lookup(v, "mixedcase.txt") == ino, "lowercase lookup after remount");
    CHECK(lookup(v, "MIXEDCASE.TXT") == ino, "uppercase lookup after remount");
    char canonical[1024];
    CHECK(nfsk_lookup_name(v, NFSK_ROOT_INO, "mixedcase.txt", canonical, sizeof canonical, &error) == ino &&
          !strcmp(canonical, "MiXeDCaSe.txt"), "lookup returns the stored filename spelling");
    CHECK(nfsk_link(v, ino, NFSK_ROOT_INO, "MIXEDCASE.TXT", &error) == -1 && error == EEXIST,
          "case-folded duplicate hard link is rejected");
    error = 0;
    uint64_t duplicate = nfsk_create(v, NFSK_ROOT_INO, "MIXEDCASE.TXT", NFSK_TYPE_FILE, &error);
    CHECK(!duplicate && error == EEXIST, "case-folded duplicate create is rejected");
    if (duplicate) nfsk_remove(v, NFSK_ROOT_INO, "MIXEDCASE.TXT");
    CHECK(nfsk_rename(v, NFSK_ROOT_INO, "MiXeDCaSe.txt", NFSK_ROOT_INO, "mixedcase.txt") == 0,
          "case-only rename retains a valid name");
    CHECK(nfsk_lookup_name(v, NFSK_ROOT_INO, "mixedcase.txt", canonical, sizeof canonical, &error) == ino &&
          !strcmp(canonical, "MiXeDCaSe.txt"), "case-only no-op reports its actual stored spelling");

    case_listing listing = { .volume = v, .inode = ino };
    CHECK(nfsk_readdir(v, NFSK_ROOT_INO, 0, &listing, check_case_listing) == 0 &&
          listing.found == 1 && listing.valid && lookup(v, "mixedcase.txt") == ino,
          "enumeration preserves spelling and case-insensitive lookup inside and after callbacks");
    listing.found = 0; listing.valid = 0; listing.stop = 1;
    CHECK(nfsk_readdir(v, NFSK_ROOT_INO, 0, &listing, check_case_listing) == 0 &&
          listing.found == 1 && listing.valid && lookup(v, "MIXEDCASE.TXT") == ino,
          "early enumeration stop preserves the normal lookup mode");

    uint64_t unicode = nfsk_create(v, NFSK_ROOT_INO, "\xc3\x89" "cole.txt", NFSK_TYPE_FILE, &error);
    CHECK(unicode && lookup(v, "\xc3\xa9" "cole.txt") == unicode,
          "non-ASCII case variants resolve to the same inode");
    CHECK(!nfsk_create(v, NFSK_ROOT_INO, "\xc3\xa9" "cole.txt", NFSK_TYPE_FILE, &error) && error == EEXIST,
          "non-ASCII duplicate creation uses the NTFS case table");
    CHECK(!nfsk_create(v, NFSK_ROOT_INO, "mixedcase.txt", NFSK_TYPE_DIR, &error) && error == EEXIST,
          "a directory cannot duplicate an existing file's case-folded name");
    uint64_t subdir = nfsk_create(v, NFSK_ROOT_INO, "CaseDirectory", NFSK_TYPE_DIR, &error);
    CHECK(subdir && lookup(v, "casedirectory") == subdir &&
          nfsk_create(v, subdir, "mixedcase.txt", NFSK_TYPE_FILE, &error),
          "directory lookup ignores case; name uniqueness is per directory");

    uint64_t write_ino = nfsk_create(v, NFSK_ROOT_INO, "IssueWriteback.bin", NFSK_TYPE_FILE, &error);
    CHECK(write_ino && nfsk_write(v, write_ino, 0, data, sizeof data, &error) == sizeof data,
          "prepare nonresident file for writeback fault");
    CHECK(nfsk_set_times(v, write_ino, 1000000000, 0, INT64_MIN, 0) == 0 && nfsk_sync(v) == 0,
          "persist an old mtime before injection");
    fail_close_writes = 1;
    error = 0;
    int64_t written = nfsk_write(v, write_ino, 0, "new payload", 11, &error);
    int sync_result = nfsk_sync(v);
    CHECK((written < 0 && error == EIO) || sync_result == -EIO,
          "inode-close EIO is observable through write or sync");
    CHECK(sync_result == -EIO, "sync cannot report success while writeback fails");
    nfsk_attr_t blocked;
    CHECK(nfsk_getattr(v, write_ino, &blocked) == -EIO, "dirty inode cannot be reopened as a stale duplicate");
    fail_close_writes = 0;
    (void)nfsk_sync(v); /* A saved writeback error may be reported once after retry. */
    CHECK(nfsk_sync(v) == 0, "sync recovers after the fault is removed");
    nfsk_umount(v);
    v = nfsk_mount(&device, false, &error);
    if (!v) return 2;
    nfsk_attr_t attributes;
    CHECK(nfsk_getattr(v, write_ino, &attributes) == 0 && attributes.mtime_sec != 1000000000,
          "retry persists the dirty inode's mtime across remount");
    char payload[12] = {0};
    CHECK(nfsk_read(v, write_ino, 0, payload, 11, &error) == 11 && !strcmp(payload, "new payload"),
          "payload remains intact across writeback recovery");

    fail_close_writes = 1;
    error = 0;
    uint64_t created = nfsk_create(v, NFSK_ROOT_INO, "IssueCreateWriteback.txt", NFSK_TYPE_FILE, &error);
    CHECK(!created && error == EIO && nfsk_sync(v) == -EIO, "create surfaces inode and parent writeback failures");
    fail_close_writes = 0;
    (void)nfsk_sync(v);
    CHECK(nfsk_sync(v) == 0 && lookup(v, "IssueCreateWriteback.txt") != 0,
          "partially applied create retains and flushes both dirty inodes");

    uint64_t rename_source = nfsk_create(v, NFSK_ROOT_INO, "IssueRenameSource.txt", NFSK_TYPE_FILE, &error);
    uint64_t rename_target = nfsk_create(v, NFSK_ROOT_INO, "IssueRenameTarget.txt", NFSK_TYPE_FILE, &error);
    CHECK(rename_source && rename_target &&
          nfsk_write(v, rename_source, 0, "source", 6, &error) == 6 &&
          nfsk_write(v, rename_target, 0, "target", 6, &error) == 6 && nfsk_sync(v) == 0,
          "prepare recoverable overwrite with two distinct payloads");
    fail_close_writes = 1;
    CHECK(nfsk_rename(v, NFSK_ROOT_INO, "IssueRenameSource.txt", NFSK_ROOT_INO, "IssueRenameTarget.txt") == -EIO &&
          nfsk_sync(v) == -EIO, "rename aborts safely when its backup writeback fails");
    fail_close_writes = 0;
    (void)nfsk_sync(v);
    CHECK(nfsk_sync(v) == 0 && lookup(v, "IssueRenameSource.txt") == rename_source &&
          lookup(v, "IssueRenameTarget.txt") == rename_target,
          "failed overwrite preserves both original names after recovery");
    memset(payload, 0, sizeof payload);
    CHECK(nfsk_read(v, rename_target, 0, payload, 6, &error) == 6 && !strcmp(payload, "target"),
          "failed overwrite preserves the destination payload");

    uint64_t hibernation = nfsk_create(v, NFSK_ROOT_INO, "hiberfil.sys", NFSK_TYPE_FILE, &error);
    memset(data, 0, 4096); memcpy(data, "hibr", 4);
    CHECK(hibernation && nfsk_write(v, hibernation, 0, data, 4096, &error) == 4096,
          "create synthetic hibernation fixture in disposable image");
    nfsk_umount(v);
    v = nfsk_mount(&device, false, &error);
    CHECK(v && nfsk_statfs(v, &remounted) == 0 && remounted.read_only,
          "C statistics expose the effective read-only fallback");
    if (v) nfsk_umount(v);
    close(device.fd);
    printf("%d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
