#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <ntfs-3g/attrib.h>
#include <ntfs-3g/inode.h>
#include <ntfs-3g/volume.h>
#include <ntfs-3g/unistr.h>
#include "ntfs_fskit.h"

typedef struct { int fd; int64_t size; } test_device;
static int checks, failures, write_fault, read_fault, close_fault, backend_writes;
#define CHECK(condition, message) do { checks++; if (!(condition)) { \
    failures++; fprintf(stderr, "FAIL: %s\n", message); \
} else { printf("PASS: %s\n", message); } } while (0)

/* Track only allocations made by the bridge while an owned read is active.
 * Upstream allocations and the existing calloc-owned inode records are separate. */
static int tracking, allocation_calls, fail_allocation;
static void *allocations[16];
static int allocation_slot(void *pointer) {
    for (int i = 0; i < 16; i++) if (allocations[i] == pointer) return i;
    abort();
}
static int live_allocations(void) {
    int live = 0;
    for (int i = 0; i < 16; i++) live += allocations[i] != NULL;
    return live;
}
static int allocation_fails(void) {
    if (!tracking) return 0;
    if (++allocation_calls != fail_allocation) return 0;
    errno = ENOMEM;
    return 1;
}
void *nfsk_test_malloc(size_t size) {
    if (allocation_fails()) return NULL;
    void *result = malloc(size);
    if (tracking && result) allocations[allocation_slot(NULL)] = result;
    return result;
}
void *nfsk_test_realloc(void *pointer, size_t size) {
    if (allocation_fails()) return NULL;
    int slot = tracking ? allocation_slot(pointer) : 0;
    void *result = realloc(pointer, size);
    if (tracking && result) allocations[slot] = result;
    return result;
}
void nfsk_test_free(void *pointer) {
    if (pointer) for (int i = 0; i < 16; i++) if (allocations[i] == pointer) allocations[i] = NULL;
    free(pointer);
}
static void begin_allocations(int fail_at) {
    if (live_allocations()) abort();
    tracking = 1; allocation_calls = 0; fail_allocation = fail_at;
}
static void end_allocations(void) {
    CHECK(live_allocations() == 0, "owned xattr read releases all tracked buffers");
    tracking = 0;
}
int nfsk_test_inode_close(ntfs_inode *inode) {
    if (close_fault) { close_fault = 0; errno = EIO; return -1; }
    return ntfs_inode_close(inode);
}
int nfsk_test_inode_real_close(ntfs_inode *inode) {
    if (close_fault) { close_fault = 0; errno = EIO; return -1; }
    return ntfs_inode_real_close(inode);
}

int64_t nfsk_block_pread(void *device, void *buf, int64_t offset, int64_t count) {
    return pread(((test_device *)device)->fd, buf, count, offset);
}
int64_t nfsk_block_pwrite(void *device, const void *buf, int64_t offset, int64_t count) {
    backend_writes++;
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
        if (fault == 3) return ntfs_attr_pread(attr, offset, count < 7 ? count : 7, value);
        if (fault == 4) return count + 1;
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
    void *owned = (void *)1;
    int64_t length = nfsk_getxattr_alloc(v, ino, name, &owned);
    ok = ok && length == (int64_t)size && (size ? owned && !memcmp(owned, value, size) : owned == NULL);
    free(owned);
    return ok;
}

static int listed(ntfs_fskit_volume *v, uint64_t ino, const char *name) {
    char buffer[8192];
    int64_t count = nfsk_listxattr(v, ino, buffer, sizeof buffer);
    for (int64_t offset = 0; offset < count; offset += strlen(buffer + offset) + 1)
        if (!strcmp(buffer + offset, name)) return 1;
    return 0;
}

static int same_list(ntfs_fskit_volume *v, uint64_t ino) {
    char buffer[8192], *owned = (char *)1;
    int64_t size = nfsk_listxattr(v, ino, buffer, sizeof buffer);
    int64_t count = nfsk_listxattr_alloc(v, ino, &owned);
    int ok = size >= 0 && count == size && (size ? owned && !memcmp(buffer, owned, (size_t)size) : owned == NULL);
    free(owned);
    return ok;
}

static void owned_errors(ntfs_fskit_volume *v, uint64_t file, const char *key,
                         const void *original, size_t size) {
    for (int i = 0; i < 8; i++) {
        char name[128];
        snprintf(name, sizeof name, "owned.list.%d.%080d", i, i);
        CHECK(nfsk_setxattr(v, file, name, NULL, 0, NFSK_XATTR_CREATE) == 0,
              "prepare enough distinct names to exercise list growth");
    }
    void *value = (void *)1;
    char *names = (char *)1;
    CHECK(nfsk_getxattr_alloc(v, file, key, NULL) == -EINVAL &&
          nfsk_listxattr_alloc(v, file, NULL) == -EINVAL, "owned APIs require an output pointer");
    CHECK(nfsk_getxattr_alloc(NULL, file, key, &value) == -EINVAL && value == NULL &&
          nfsk_listxattr_alloc(NULL, file, &names) == -EINVAL && names == NULL,
          "invalid volumes clear owned outputs");
    value = (void *)1; names = (char *)1;
    CHECK(nfsk_getxattr_alloc(v, 0, key, &value) == -EPERM && value == NULL &&
          nfsk_listxattr_alloc(v, 0, &names) == -EPERM && names == NULL,
          "reserved inode errors clear owned outputs");
    value = (void *)1;
    CHECK(nfsk_getxattr_alloc(v, file, "missing", &value) == -ENOATTR && value == NULL,
          "missing value transfers no buffer");
    for (int fault = 1; fault <= 4; fault++) {
        begin_allocations(0);
        read_fault = fault; value = (void *)1;
        int64_t count = nfsk_getxattr_alloc(v, file, key, &value);
        CHECK(read_fault == 0, "injected xattr read fault was exercised");
        CHECK(fault == 3 ? count == (int64_t)size && value && !memcmp(value, original, size) : count == -EIO && !value,
              "owned reads handle failures, EOF, partial progress and oversized completions");
        nfsk_test_free(value);
        end_allocations();
    }
    begin_allocations(1);
    value = (void *)1;
    CHECK(nfsk_getxattr_alloc(v, file, key, &value) == -ENOMEM && value == NULL && allocation_calls == 1,
          "value allocation failure returns ENOMEM without ownership transfer");
    end_allocations();

    begin_allocations(0);
    names = NULL;
    CHECK(nfsk_listxattr_alloc(v, file, &names) > 256 && names && allocation_calls > 1,
          "list grows across its initial allocation and returns one owned buffer");
    int grows = allocation_calls;
    nfsk_test_free(names);
    end_allocations();
    for (int fail = 1; fail <= grows; fail++) {
        begin_allocations(fail); names = (char *)1;
        CHECK(nfsk_listxattr_alloc(v, file, &names) == -ENOMEM && names == NULL && allocation_calls == fail,
              "every list allocation/growth failure frees the partial list");
        end_allocations();
    }
    for (int list = 0; list < 2; list++) {
        begin_allocations(0); close_fault = 1;
        value = (void *)1; names = (char *)1;
        int64_t count = list ? nfsk_listxattr_alloc(v, file, &names) : nfsk_getxattr_alloc(v, file, key, &value);
        CHECK(count == -EIO && (list ? names == NULL : value == NULL) && close_fault == 0,
              "failed inode close frees completed data before returning an error");
        end_allocations();
        CHECK(nfsk_sync(v) == -EIO && nfsk_sync(v) == 0,
              "failed xattr close retains sync/retry ownership and reports its saved error once");
    }
    CHECK(equals(v, file, key, original, size) && same_list(v, file),
          "successful reads after faults match both legacy API results");
}

/* Seed/read Windows' private backing ADS independently of the xattr bridge. */
static int backing_stream(const char *path, uint64_t ino, const char *name, int create) {
    const char payload[] = "private compressed backing bytes";
    ntfs_volume *vol = ntfs_mount(path, create ? NTFS_MNT_NONE : NTFS_MNT_RDONLY);
    if (!vol) return -1;
    ntfs_inode *ni = ntfs_inode_open(vol, ino);
    ntfschar *unicode = NULL;
    int length = ntfs_mbstoucs(name, &unicode), result = -1;
    if (ni && length > 0) {
        if (create) {
            result = ntfs_attr_add(ni, AT_DATA, unicode, length, (const u8 *)payload, sizeof payload);
        } else {
            ntfs_attr *attr = ntfs_attr_open(ni, AT_DATA, unicode, length);
            char bytes[sizeof payload];
            if (attr) {
                result = attr->data_size == sizeof payload &&
                         ntfs_attr_pread(attr, 0, sizeof bytes, bytes) == sizeof bytes &&
                         !memcmp(bytes, payload, sizeof bytes) ? 0 : -1;
                ntfs_attr_close(attr);
            }
        }
    }
    free(unicode);
    if (ni && ntfs_inode_close(ni)) result = -1;
    if (ntfs_umount(vol, FALSE)) result = -1;
    return result;
}

static char bom_limit[NFSK_MAX_XATTR_NAME + 1];
static const char *bom_names[] = {
    "\xef\xbb\xbf", "\xef\xbb\xbf\xef\xbb\xbf",
    "\xef\xbb\xbf" "alpha", "\xef\xbb\xbf\xef\xbb\xbf" "alpha",
    "\xef\xbb\xbf" "$private", "\xef\xbb\xbf" "WofCompressedData",
    "\xef\xbb\xbf" "ntfs-3g.acl", bom_limit,
};
static uint64_t bom_files[sizeof bom_names / sizeof bom_names[0]];
static const char bom_body[] = "ordinary body stays separate", bom_neighbor[] = "neighbor";
static const char bom_first[] = "bom-first", bom_final[] = "bom-final";

static void bom_name_tests(ntfs_fskit_volume *v) {
    memcpy(bom_limit, "\xef\xbb\xbf", 3);
    memset(bom_limit + 3, 'a', NFSK_MAX_XATTR_NAME - 3);
    bom_limit[NFSK_MAX_XATTR_NAME] = 0;
    for (size_t i = 0; i < sizeof bom_names / sizeof bom_names[0]; i++) {
        char file_name[32], bytes[128]; int error = 0;
        snprintf(file_name, sizeof file_name, "XattrBOM%zu", i);
        uint64_t file = nfsk_create(v, NFSK_ROOT_INO, file_name, NFSK_TYPE_FILE, &error);
        if (!file || nfsk_write(v, file, 0, bom_body, sizeof bom_body, &error) != sizeof bom_body ||
            nfsk_setxattr(v, file, "alpha", bom_neighbor, sizeof bom_neighbor, NFSK_XATTR_CREATE)) exit(2);
        bom_files[i] = file;
        const char *name = bom_names[i];
        int writes = backend_writes;
        void *owned = (void *)1;
        int64_t missing = nfsk_getxattr_alloc(v, file, name, &owned);
        CHECK(missing == -ENOATTR && owned == NULL, "absent BOM name never reads unnamed DATA or its neighbor");
        nfsk_test_free(owned);
        int removed = nfsk_setxattr(v, file, name, NULL, 0, NFSK_XATTR_DELETE);
        CHECK(removed == -ENOATTR && backend_writes == writes,
              "absent BOM deletion cannot remove ordinary contents or another attribute");
        printf("BOM_C_MISSING case=%zu get=%lld delete=%d writes=%d\n",
               i, (long long)missing, removed, backend_writes - writes);
        CHECK(nfsk_setxattr(v, file, name, bom_first, sizeof bom_first, NFSK_XATTR_CREATE) == 0,
              "literal BOM name can be created independently");
        CHECK(equals(v, file, name, bom_first, sizeof bom_first), "literal BOM value round-trips through both read APIs");
        CHECK(nfsk_setxattr(v, file, name, bom_final, sizeof bom_final, NFSK_XATTR_CREATE) == -EEXIST,
              "create-only still rejects the exact existing BOM name");
        CHECK(nfsk_setxattr(v, file, name, bom_final, sizeof bom_final, NFSK_XATTR_REPLACE) == 0 &&
              equals(v, file, name, bom_final, sizeof bom_final), "replace-only selects the exact BOM name");
        CHECK(listed(v, file, name) && same_list(v, file), "both lists retain every leading BOM byte");
        CHECK(nfsk_setxattr(v, file, name, NULL, 0, NFSK_XATTR_DELETE) == 0 &&
              nfsk_getxattr(v, file, name, NULL, 0) == -ENOATTR && !listed(v, file, name),
              "deleting a BOM name removes only that exact named DATA");
        CHECK(nfsk_setxattr(v, file, name, bom_final, sizeof bom_final, NFSK_XATTR_SET) == 0,
              "always-set recreates the literal BOM name for native observation");
        int64_t body_size = nfsk_read(v, file, 0, bytes, sizeof bytes, &error);
        int body_ok = body_size == sizeof bom_body && !memcmp(bytes, bom_body, sizeof bom_body);
        int neighbor_ok = equals(v, file, "alpha", bom_neighbor, sizeof bom_neighbor);
        CHECK(body_ok && neighbor_ok, "all BOM policies preserve ordinary file bytes and an unprefixed neighbor");
        printf("BOM_C_CONTENT case=%zu body=%d neighbor=%d\n", i, body_ok, neighbor_ok);
    }
    char oversized[NFSK_MAX_XATTR_NAME + 2];
    memcpy(oversized, bom_limit, NFSK_MAX_XATTR_NAME); oversized[NFSK_MAX_XATTR_NAME] = 'a';
    oversized[NFSK_MAX_XATTR_NAME + 1] = 0;
    int writes = backend_writes;
    CHECK(nfsk_setxattr(v, bom_files[0], oversized, bom_first, sizeof bom_first, NFSK_XATTR_SET) == -ENAMETOOLONG &&
          backend_writes == writes, "BOM bytes count toward the unchanged127-byte name limit");
}

static int native_value(ntfs_inode *ni, ntfschar *name, int length, const char *value, size_t size) {
    ntfs_attr *attr = ntfs_attr_open(ni, AT_DATA, name, length);
    char bytes[128];
    int result = attr && attr->data_size == (s64)size && size <= sizeof bytes &&
                 ntfs_attr_pread(attr, 0, size, bytes) == (s64)size && !memcmp(bytes, value, size);
    if (attr) ntfs_attr_close(attr);
    return result;
}

static void bom_native_observation(const char *path) {
    ntfs_volume *vol = ntfs_mount(path, NTFS_MNT_RDONLY | NTFS_MNT_FORENSIC);
    if (!vol) exit(2);
    for (size_t i = 0; i < sizeof bom_names / sizeof bom_names[0]; i++) {
        ntfs_inode *ni = ntfs_inode_open(vol, bom_files[i]);
        if (!ni) exit(2);
        /* Build literal UTF16 units independently of all UTF8/CF decoders. */
        ntfschar unicode[NFSK_MAX_XATTR_NAME]; int length = 0;
        const unsigned char *p = (const unsigned char *)bom_names[i];
        while (!strncmp((const char *)p, "\xef\xbb\xbf", 3)) {
            unicode[length++] = const_cpu_to_le16(0xfeff); p += 3;
        }
        while (*p) unicode[length++] = cpu_to_le16(*p++);
        CHECK(native_value(ni, unicode, length, bom_final, sizeof bom_final),
              "native read-only observer finds the exact literal BOM stream after remount");
        CHECK(native_value(ni, AT_UNNAMED, 0, bom_body, sizeof bom_body),
              "native ordinary DATA survives all BOM operations");
        ntfschar alpha[] = {const_cpu_to_le16('a'), const_cpu_to_le16('l'), const_cpu_to_le16('p'),
                            const_cpu_to_le16('h'), const_cpu_to_le16('a')};
        CHECK(native_value(ni, alpha, 5, bom_neighbor, sizeof bom_neighbor),
              "native unprefixed neighbor survives all BOM operations");
        if (i >= 4 && i <= 6) {
            memmove(unicode, unicode + 1, (size_t)(length - 1) * sizeof *unicode);
            errno = 0;
            ntfs_attr *private_attr = ntfs_attr_open(ni, AT_DATA, unicode, length - 1);
            CHECK(!private_attr && errno == ENOENT, "BOM lookalike never creates an actual private stream");
            if (private_attr) ntfs_attr_close(private_attr);
        }
        CHECK(ntfs_inode_close(ni) == 0, "native BOM observer releases its clean inode");
    }
    CHECK(ntfs_umount(vol, TRUE) == 0, "native BOM observer releases its read-only volume");
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
    const char *private_names[] = {"WofCompressedData", "wofcompresseddata"};
    uint64_t private_files[2];
    private_files[0] = nfsk_create(v, NFSK_ROOT_INO, "PrivateWof", NFSK_TYPE_FILE, &error);
    private_files[1] = nfsk_create(v, NFSK_ROOT_INO, "PrivateWofLower", NFSK_TYPE_FILE, &error);
    if (!private_files[0] || !private_files[1]) return 2;
    nfsk_umount(v);
    for (int i = 0; i < 2; i++)
        if (backing_stream(argv[1], private_files[i], private_names[i], 1)) return 2;
    v = nfsk_mount(&device, false, &error);
    if (!v) return 2;
    for (int i = 0; i < 2; i++) {
        CHECK(!listed(v, private_files[i], private_names[i]), "WOF backing ADS is not enumerated as a user xattr");
        CHECK(nfsk_getxattr(v, private_files[i], private_names[i], NULL, 0) == -EPERM,
              "WOF backing ADS cannot be read through xattrs");
        void *value = (void *)1;
        CHECK(nfsk_getxattr_alloc(v, private_files[i], private_names[i], &value) == -EPERM &&
              value == NULL && same_list(v, private_files[i]), "owned APIs preserve private ADS filtering");
        CHECK(nfsk_setxattr(v, private_files[i], private_names[i], "replace", 7, NFSK_XATTR_SET) == -EPERM,
              "WOF backing ADS cannot be replaced through xattrs");
        CHECK(nfsk_setxattr(v, private_files[i], private_names[i], NULL, 0, NFSK_XATTR_DELETE) == -EPERM,
              "WOF backing ADS cannot be deleted through xattrs");
    }
    const char *key = "com.apple.metadata:_kMDItemUserTags";
    char original[65536], replacement[65536], output[32];
    memset(original, 0x31, sizeof original);
    memset(replacement, 0x72, sizeof replacement);
    CHECK(nfsk_write(v, file, 0, "file data", 9, &error) == 9, "prepare unnamed file data");
    CHECK(nfsk_getxattr(v, file, "missing", NULL, 0) == -ENOATTR, "missing xattr returns ENOATTR");
    CHECK(nfsk_listxattr(v, file, NULL, 0) == 0 && same_list(v, file), "unnamed file data is never listed as an xattr");
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
    owned_errors(v, file, key, original, sizeof original);
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
    bom_name_tests(v);
    CHECK(nfsk_sync(v) == 0, "xattr changes synchronize successfully");
    nfsk_umount(v);
    v = nfsk_mount(&device, true, &error);
    if (!v) return 2;
    CHECK(equals(v, file, key, original, sizeof original) &&
          equals(v, file, "com.apple.ResourceFork", original, sizeof original) && listed(v, file, key) && same_list(v, file),
          "native metadata survives a read-only remount");
    CHECK(nfsk_setxattr(v, file, key, replacement, 1, NFSK_XATTR_SET) == -EROFS &&
          nfsk_setxattr(v, file, key, NULL, 0, NFSK_XATTR_DELETE) == -EROFS,
          "read-only mounts reject xattr writes and deletes");
    nfsk_umount(v);
    close(device.fd);
    bom_native_observation(argv[1]);
    for (int i = 0; i < 2; i++)
        CHECK(backing_stream(argv[1], private_files[i], private_names[i], 0) == 0,
              "private backing bytes survive rejected xattr operations and remount");
    printf("%d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
