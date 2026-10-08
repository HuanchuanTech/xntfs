#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <ntfs-3g/attrib.h>
#include <ntfs-3g/inode.h>
#include "ntfs_fskit.h"

typedef struct { int fd; int64_t size; } test_device;
static int checks, failures, write_fault, read_fault;
#define CHECK(condition, message) do { checks++; if (!(condition)) { \
    failures++; fprintf(stderr, "FAIL: %s\n", message); \
} else { printf("PASS: %s\n", message); } } while (0)

int64_t nfsk_block_pread(void *device, void *buf, int64_t offset, int64_t count) {
    return pread(((test_device *)device)->fd, buf, count, offset);
}
int64_t nfsk_block_pwrite(void *device, const void *buf, int64_t offset, int64_t count) {
    return pwrite(((test_device *)device)->fd, buf, count, offset);
}
int nfsk_block_sync(void *device) { return fsync(((test_device *)device)->fd) ? -errno : 0; }
uint64_t nfsk_block_total_bytes(void *device) { return ((test_device *)device)->size; }
uint32_t nfsk_block_sector_size(void *device) { (void)device; return 512; }
int nfsk_block_is_writable(void *device) { (void)device; return 1; }

s64 nfsk_test_attr_pwrite(ntfs_attr *attr, s64 offset, s64 count, const void *value) {
    if (attr->name_len && write_fault) {
        if (write_fault == 1) {
            write_fault = 2;
            return ntfs_attr_pwrite(attr, offset, count < 16 ? count : 16, value);
        }
        write_fault = 0;
        errno = ENOSPC;
        return -1;
    }
    return ntfs_attr_pwrite(attr, offset, count, value);
}

s64 nfsk_test_attr_pread(ntfs_attr *attr, s64 offset, s64 count, void *value) {
    if (attr->name_len && read_fault) {
        int fault = read_fault;
        read_fault = 0;
        errno = fault == 1 ? EIO : ENOENT;
        return fault == 1 ? -1 : 0;
    }
    return ntfs_attr_pread(attr, offset, count, value);
}

static int equals(ntfs_fskit_volume *v, uint64_t ino, const char *name, const void *value, size_t size) {
    unsigned char *buffer = malloc(size ? size : 1);
    if (!buffer) return 0;
    int ok = nfsk_getxattr(v, ino, name, NULL, 0) == (int64_t)size &&
             nfsk_getxattr(v, ino, name, buffer, size) == (int64_t)size &&
             (!size || !memcmp(buffer, value, size));
    free(buffer);
    return ok;
}

static int listed(ntfs_fskit_volume *v, uint64_t ino, const char *name) {
    char buffer[8192];
    int64_t count = nfsk_listxattr(v, ino, buffer, sizeof buffer);
    for (int64_t offset = 0; offset < count; offset += strlen(buffer + offset) + 1)
        if (!strcmp(buffer + offset, name)) return 1;
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    test_device device = {.fd = open(argv[1], O_RDWR)};
    struct stat info;
    if (device.fd < 0 || fstat(device.fd, &info) || !S_ISREG(info.st_mode)) return 2;
    device.size = info.st_size;
    int error = 0;
    ntfs_fskit_volume *v = nfsk_mount(&device, false, &error);
    if (!v) return 2;
    uint64_t file = nfsk_create(v, NFSK_ROOT_INO, "XattrFile", NFSK_TYPE_FILE, &error);
    uint64_t dir = nfsk_create(v, NFSK_ROOT_INO, "XattrDirectory", NFSK_TYPE_DIR, &error);
    if (!file || !dir) return 2;
    const char *key = "com.apple.metadata:_kMDItemUserTags";
    char original[65536], replacement[65536], output[32];
    memset(original, 0x31, sizeof original);
    memset(replacement, 0x72, sizeof replacement);
    CHECK(nfsk_write(v, file, 0, "file data", 9, &error) == 9, "prepare unnamed file data");
    CHECK(nfsk_getxattr(v, file, "missing", NULL, 0) == -ENOATTR, "missing xattr returns ENOATTR");
    CHECK(nfsk_listxattr(v, file, NULL, 0) == 0, "unnamed file data is never listed as an xattr");
    CHECK(nfsk_setxattr(v, file, key, original, sizeof original, NFSK_XATTR_CREATE) == 0,
          "create a nonresident Finder tags ADS");
    CHECK(equals(v, file, key, original, sizeof original), "read tags ADS byte for byte");
    CHECK(nfsk_getxattr(v, file, key, output, sizeof output) == -ERANGE, "short xattr buffer returns ERANGE");
    read_fault = 1;
    CHECK(nfsk_getxattr(v, file, key, replacement, sizeof replacement) == -EIO,
          "read failure is not reported as missing metadata");
    read_fault = 2;
    CHECK(nfsk_getxattr(v, file, key, replacement, sizeof replacement) == -EIO,
          "premature EOF reports EIO even with stale errno");
    CHECK(listed(v, file, key), "list includes the exact xattr name");
    CHECK(nfsk_listxattr(v, file, output, 1) == -ERANGE, "short list buffer returns ERANGE");
    CHECK(nfsk_setxattr(v, file, key, replacement, 10, NFSK_XATTR_CREATE) == -EEXIST &&
          equals(v, file, key, original, sizeof original), "create-only preserves an existing value");
    CHECK(nfsk_setxattr(v, file, "missing", original, 1, NFSK_XATTR_REPLACE) == -ENOATTR,
          "replace-only requires an existing ADS");
    CHECK(nfsk_setxattr(v, file, key, replacement, 10, NFSK_XATTR_REPLACE) == 0 &&
          equals(v, file, key, replacement, 10), "shorter replacement truncates the old tail");
    CHECK(nfsk_setxattr(v, file, key, original, sizeof original, NFSK_XATTR_SET) == 0,
          "grow an existing ADS");
    write_fault = 1;
    CHECK(nfsk_setxattr(v, file, key, replacement, sizeof replacement, NFSK_XATTR_SET) == -ENOSPC &&
          equals(v, file, key, original, sizeof original), "partial replacement failure restores the original metadata");
    write_fault = 1;
    CHECK(nfsk_setxattr(v, file, "new-fails", replacement, sizeof replacement, NFSK_XATTR_CREATE) == -ENOSPC &&
          nfsk_getxattr(v, file, "new-fails", NULL, 0) == -ENOATTR,
          "failed new xattr does not leave a partial stream");
    CHECK(nfsk_setxattr(v, file, "empty", NULL, 0, NFSK_XATTR_SET) == 0 &&
          equals(v, file, "empty", NULL, 0) && listed(v, file, "empty"), "empty values exist and enumerate");
    CHECK(nfsk_setxattr(v, file, "com.apple.ResourceFork", original, sizeof original, NFSK_XATTR_SET) == 0 &&
          equals(v, file, "com.apple.ResourceFork", original, sizeof original), "resource fork is a separate named stream");
    CHECK(nfsk_setxattr(v, dir, "com.apple.FinderInfo", original, 32, NFSK_XATTR_SET) == 0 &&
          equals(v, dir, "com.apple.FinderInfo", original, 32), "directory xattrs are supported");
    CHECK(nfsk_setxattr(v, NFSK_ROOT_INO, "root-test", original, 1, NFSK_XATTR_SET) == 0,
          "root directory xattrs are supported");
    CHECK(nfsk_setxattr(v, file, "user.\xc3\xa9", original, 2, NFSK_XATTR_SET) == 0 &&
          listed(v, file, "user.\xc3\xa9"), "Unicode names survive enumeration");
    CHECK(nfsk_setxattr(v, file, "user.e\xcc\x81", replacement, 2, NFSK_XATTR_CREATE) == 0 &&
          equals(v, file, "user.\xc3\xa9", original, 2) && equals(v, file, "user.e\xcc\x81", replacement, 2) &&
          listed(v, file, "user.e\xcc\x81"), "composed and decomposed xattr names remain distinct");
    CHECK(nfsk_setxattr(v, file, "Case", original, 1, NFSK_XATTR_SET) == 0 &&
          nfsk_setxattr(v, file, "case", replacement, 1, NFSK_XATTR_CREATE) == 0 &&
          equals(v, file, "Case", original, 1) && equals(v, file, "case", replacement, 1),
          "xattr names remain case-sensitive on a case-insensitive volume");
    CHECK(nfsk_setxattr(v, file, "", original, 1, NFSK_XATTR_SET) == -EINVAL &&
          nfsk_getxattr(v, file, "", NULL, 0) == -EINVAL, "empty name cannot access unnamed file contents");
    CHECK(nfsk_setxattr(v, file, "bad.\xff", original, 1, NFSK_XATTR_SET) == -EILSEQ,
          "invalid UTF-8 names are rejected");
    CHECK(nfsk_setxattr(v, file, "invalid", NULL, 1, NFSK_XATTR_SET) == -EINVAL &&
          nfsk_setxattr(v, file, "invalid", original, 1, 99) == -EINVAL,
          "invalid buffers and policies are rejected");
    CHECK(nfsk_setxattr(v, file, "$TXF_DATA", original, 1, NFSK_XATTR_SET) == -EPERM &&
          nfsk_setxattr(v, file, "ntfs-3g.acl", original, 1, NFSK_XATTR_SET) == -EPERM,
          "private NTFS streams cannot be changed through xattrs");
    CHECK(nfsk_setxattr(v, 0, "test", original, 1, NFSK_XATTR_SET) == -EPERM &&
          nfsk_getxattr(v, 0, "test", NULL, 0) == -EPERM && nfsk_listxattr(v, 0, NULL, 0) == -EPERM,
          "reserved metadata inodes are protected");
    CHECK(nfsk_setxattr(v, file, key, original, (size_t)NFSK_MAX_XATTR_SIZE + 1, NFSK_XATTR_SET) == -E2BIG &&
          equals(v, file, key, original, sizeof original), "oversized values are rejected before changing data");
    char long_name[NFSK_MAX_XATTR_NAME + 2]; memset(long_name, 'a', sizeof long_name); long_name[sizeof long_name - 1] = 0;
    CHECK(nfsk_setxattr(v, file, long_name, original, 1, NFSK_XATTR_SET) == -ENAMETOOLONG,
          "overlong attribute names are rejected");
    long_name[NFSK_MAX_XATTR_NAME] = 0;
    CHECK(nfsk_setxattr(v, file, long_name, original, 1, NFSK_XATTR_SET) == 0 &&
          equals(v, file, long_name, original, 1) && listed(v, file, long_name),
          "maximum-length attribute names round-trip");
    unsigned char *maximum = malloc(NFSK_MAX_XATTR_SIZE);
    if (!maximum) return 2;
    memset(maximum, 0x5a, NFSK_MAX_XATTR_SIZE);
    CHECK(nfsk_setxattr(v, file, "maximum", maximum, NFSK_MAX_XATTR_SIZE, NFSK_XATTR_SET) == 0 &&
          equals(v, file, "maximum", maximum, NFSK_MAX_XATTR_SIZE),
          "a value at the 128 KiB limit round-trips");
    free(maximum);
    CHECK(nfsk_setxattr(v, file, "maximum", NULL, 0, NFSK_XATTR_DELETE) == 0,
          "large xattr deletion succeeds");
    CHECK(nfsk_setxattr(v, file, "empty", NULL, 0, NFSK_XATTR_DELETE) == 0 &&
          nfsk_getxattr(v, file, "empty", NULL, 0) == -ENOATTR && !listed(v, file, "empty"),
          "deleting an xattr removes it from enumeration");
    CHECK(nfsk_setxattr(v, file, "empty", NULL, 0, NFSK_XATTR_DELETE) == -ENOATTR,
          "deleting a missing xattr returns ENOATTR");
    CHECK(nfsk_read(v, file, 0, output, 9, &error) == 9 && !memcmp(output, "file data", 9),
          "ADS operations leave ordinary file contents intact");
    CHECK(nfsk_rename(v, NFSK_ROOT_INO, "XattrFile", dir, "Renamed") == 0 &&
          equals(v, file, key, original, sizeof original) &&
          equals(v, file, "com.apple.ResourceFork", original, sizeof original),
          "cross-directory rename preserves tags and resource fork");
    CHECK(nfsk_sync(v) == 0, "xattr changes synchronize successfully");
    nfsk_umount(v);
    v = nfsk_mount(&device, true, &error);
    if (!v) return 2;
    CHECK(equals(v, file, key, original, sizeof original) &&
          equals(v, file, "com.apple.ResourceFork", original, sizeof original) && listed(v, file, key),
          "native metadata survives a read-only remount");
    CHECK(nfsk_setxattr(v, file, key, replacement, 1, NFSK_XATTR_SET) == -EROFS &&
          nfsk_setxattr(v, file, key, NULL, 0, NFSK_XATTR_DELETE) == -EROFS,
          "read-only mounts reject xattr writes and deletes");
    nfsk_umount(v);
    close(device.fd);
    printf("%d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
