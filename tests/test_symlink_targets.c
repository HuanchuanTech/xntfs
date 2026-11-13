/* SPDX-License-Identifier: GPL-2.0-or-later */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>
#include <ntfs-3g/volume.h>
#include <ntfs-3g/inode.h>
#include <ntfs-3g/attrib.h>
#include <ntfs-3g/unistr.h>
#include <ntfs-3g/dir.h>
#include <ntfs-3g/reparse.h>
#include "ntfs_fskit.h"

typedef struct { int fd; int64_t size; } test_device;
typedef struct { char input[4096], output[4096]; ntfschar units[1025]; int length; } target_case;
static int checks, failures, reads, writes, syncs;
static int malloc_countdown, malloc_hits, conversion_error, conversion_hits, partial_frees;
static int open_error, open_armed, open_hits, patch_mode, patch_hits, close_countdown, close_hits;
static int backend_mode, backend_armed, backend_hits, delete_error, delete_hits;
static int live_attributes;
static int watch_output, watched_allocations, watched_frees;
static void *watched_output;
static void *partial;
#define CHECK(ok, message) do { checks++; if (!(ok)) { failures++; \
    fprintf(stderr, "FAIL TARGET: %s\n", message); } } while (0)
static void require(int ok, const char *message) {
    if (!ok) { fprintf(stderr, "Target fixture: %s errno=%d\n", message, errno); exit(2); }
}

int64_t nfsk_block_pread(void *p, void *buf, int64_t off, int64_t count) {
    reads++; return pread(((test_device *)p)->fd, buf, count, off);
}
int64_t nfsk_block_pwrite(void *p, const void *buf, int64_t off, int64_t count) {
    writes++;
    if (backend_armed) {
        backend_hits++;
        if (backend_mode == 2) { errno = 0; return 0; }
        errno = ENXIO; return -1;
    }
    return pwrite(((test_device *)p)->fd, buf, count, off);
}
int nfsk_block_sync(void *p) { syncs++; return fsync(((test_device *)p)->fd) ? -errno : 0; }
uint64_t nfsk_block_total_bytes(void *p) { return ((test_device *)p)->size; }
uint32_t nfsk_block_sector_size(void *p) { (void)p; return 512; }
int nfsk_block_is_writable(void *p) { (void)p; return 1; }

void *nfsk_test_malloc(size_t size) {
    if (malloc_countdown && --malloc_countdown == 0) { malloc_hits++; errno = ENOMEM; return NULL; }
    void *result = malloc(size);
    if (watch_output && result) { watched_allocations++; watched_output = result; }
    return result;
}
void nfsk_test_free(void *p) {
    if (p && p == partial) { partial = NULL; partial_frees++; }
    if (p && p == watched_output) { watched_output = NULL; watched_frees++; }
    free(p);
}
int nfsk_test_ucstombs(const ntfschar *name, int length, char **output, int capacity) {
    if (conversion_error) {
        *output = malloc(16); require(*output != NULL, "partial output"); partial = *output;
        conversion_hits++; errno = conversion_error; return -1;
    }
    return ntfs_ucstombs(name, length, output, capacity);
}
ntfs_attr *nfsk_test_attr_open(ntfs_inode *ni, ATTR_TYPES type, ntfschar *name, u32 length) {
    if (open_armed && type == AT_REPARSE_POINT) {
        open_armed = 0; open_hits++; errno = open_error; return NULL;
    }
    ntfs_attr *attr = ntfs_attr_open(ni, type, name, length);
    if (attr) live_attributes++;
    return attr;
}
void nfsk_test_attr_close(ntfs_attr *attr) {
    if (attr) live_attributes--;
    ntfs_attr_close(attr);
}
s64 nfsk_test_attr_pwrite(ntfs_attr *attr, s64 offset, s64 count, const void *buffer) {
    if (attr->type == AT_REPARSE_POINT && offset == sizeof(REPARSE_POINT) + sizeof(le32) && count == 3) {
        patch_hits++;
        if (patch_mode == 1) { errno = ENOSPC; return -1; }
        if (patch_mode == 2) { errno = 0; return 0; }
        if (patch_mode == 3) { errno = 0; return 2; }
        if (patch_mode == 4) {
            int before_writes = writes;
            s64 done = ntfs_attr_pwrite(attr, offset, 2, buffer);
            printf("TARGET SHORT: nonresident=%d writes=%d done=%lld errno=%d\n",
                   !!NAttrNonResident(attr), writes - before_writes, done, errno);
            require(done == 2, "short correction changes two bytes"); errno = 0; return done;
        }
        if (backend_mode) backend_armed = 1;
    }
    return ntfs_attr_pwrite(attr, offset, count, buffer);
}
static int fail_close(void) {
    if (close_countdown && --close_countdown == 0) { close_hits++; errno = EIO; return 1; }
    return 0;
}
int nfsk_test_inode_close(ntfs_inode *ni) { return fail_close() ? -1 : ntfs_inode_close(ni); }
int nfsk_test_inode_real_close(ntfs_inode *ni) { return fail_close() ? -1 : ntfs_inode_real_close(ni); }
int nfsk_test_delete(ntfs_volume *vol, const char *path, ntfs_inode *ni, ntfs_inode *dir,
                     const ntfschar *name, u8 length) {
    int result = ntfs_delete(vol, path, ni, dir, name, length);
    if (delete_error) { delete_hits++; errno = delete_error; return -1; }
    return result;
}

static void append(target_case *c, const char *input, const char *output, u16 unit) {
    strcat(c->input, input); strcat(c->output, output); c->units[c->length++] = cpu_to_le16(unit);
}
static target_case make_case(int index) {
    target_case c = {0};
    int boms = index == 1 || index == 3 ? 2 : index == 10 ? 3 : index == 11 ? 341 :
               index == 14 ? 342 : index != 7 && index != 8 && index != 12;
    for (int i = 0; i < boms; i++) append(&c, "\xef\xbb\xbf", "\xef\xbb\xbf", 0xfeff);
    if (index == 2 || index == 3 || index == 10 || index == 12) {
        for (const char *p = "Alpha"; *p; p++) { char text[] = {*p, 0}; append(&c, text, text, *p); }
    } else if (index == 4) append(&c, "e\xcc\x81", "e\xcc\x81", 0xe9);
    else if (index == 5) {
        for (int i = 0; i < 340; i++) append(&c, "\xea\xb0\x81", "\xe1\x84\x80\xe1\x85\xa1\xe1\x86\xa8", 0xac01);
    } else if (index == 6 || index == 7 || index == 13) {
        int n = index == 6 ? 1020 : index == 7 ? 1023 : 1021;
        for (int i = 0; i < n; i++) append(&c, "a", "a", 'a');
    } else if (index == 8) {
        append(&c, ".", ".", '.'); append(&c, "/", "/", '/');
        append(&c, "\xef\xbb\xbf", "\xef\xbb\xbf", 0xfeff); append(&c, "A", "A", 'A');
    } else if (index == 9) {
        strcat(c.input, "\xf0\x9f\x98\x80"); strcat(c.output, "\xf0\x9f\x98\x80");
        c.units[c.length++] = const_cpu_to_le16(0xd83d); c.units[c.length++] = const_cpu_to_le16(0xde00);
    }
    return c;
}

static void native_interix(const char *path) {
    ntfs_volume *vol = ntfs_mount(path, 0); require(vol != NULL, "native mount");
    vol->special_files = NTFS_FILES_INTERIX;
    ntfs_inode *dir = ntfs_inode_open(vol, FILE_root); require(dir != NULL, "native root");
    for (int index = 0; index < 15; index++) {
        target_case c = make_case(index); char name[32]; snprintf(name, sizeof name, "LiteralInterix%d", index);
        ntfschar *units = NULL; int length = ntfs_mbstoucs(name, &units);
        ntfs_inode *ni = ntfs_create_symlink(dir, 0, units, length, c.units, c.length); free(units);
        require(ni && ntfs_inode_close_in_dir(ni, dir) == 0, "literal Interix creation");
    }
    require(ntfs_inode_close(dir) == 0 && ntfs_umount(vol, FALSE) == 0, "native close");
}

static void check_read(ntfs_fskit_volume *v, uint64_t ino, const target_case *c) {
    char buffer[4096], *first = NULL, *second = NULL;
    size_t bytes = strlen(c->output);
    CHECK(nfsk_readlink(v, ino, buffer, bytes + 1) == 0 && !strcmp(buffer, c->output),
          "readlink retains exact target bytes at the exact caller capacity");
    CHECK(nfsk_readlink_alloc(v, ino, &first, 4096) == 0 && first && !strcmp(first, c->output),
          "owned readlink retains complete literal target");
    CHECK(nfsk_readlink_alloc(v, ino, &second, 4096) == 0 && second && first && second != first &&
          !strcmp(second, c->output) && !strcmp(first, c->output), "independent target outputs have separate ownership");
    nfsk_attr_t attr;
    CHECK(nfsk_getattr(v, ino, &attr) == 0 && attr.type == NFSK_TYPE_SYMLINK && attr.size == bytes,
          "symlink attributes report the complete target byte length");
    memset(buffer, '!', sizeof buffer);
    CHECK(nfsk_readlink(v, ino, buffer, bytes) == -ENAMETOOLONG && buffer[0] == '!',
          "too-small caller buffer is rejected without publishing a truncated target");
    nfsk_test_free(first); nfsk_test_free(second);
}

static void normal_tests(test_device *device, const char *path) {
    native_interix(path);
    int error = 0;
    ntfs_fskit_volume *v = nfsk_mount(device, false, &error); require(v != NULL, "bridge mount");
    uint64_t inodes[13] = {0};
    for (int index = 0; index < 15; index++) {
        target_case c = make_case(index); char name[32]; snprintf(name, sizeof name, "LiteralWSL%d", index);
        error = 0; int before = patch_hits;
        uint64_t ino = nfsk_symlink(v, NFSK_ROOT_INO, name, c.input, &error);
        printf("TARGET CASE: index=%d input=%zu output=%zu inode=%llu error=%d\n",
               index, strlen(c.input), strlen(c.output), ino, error);
        if (index < 13) {
            inodes[index] = ino;
            CHECK(ino && !error, "valid target accepted without losing content or narrowing native limits");
            if (ino) check_read(v, ino, &c);
            if (index == 7 || index == 8 || index == 12)
                CHECK(patch_hits == before, "ordinary and middle-BOM targets keep the direct native creation path");
        } else {
            CHECK(!ino && error == ENAMETOOLONG, "raw UTF8 conversion boundary is not widened by preserving BOM");
            CHECK(!nfsk_lookup(v, NFSK_ROOT_INO, name, &error) && error == ENOENT,
                  "rejected oversized target leaves no created directory entry");
        }
        snprintf(name, sizeof name, "LiteralInterix%d", index);
        ino = nfsk_lookup(v, NFSK_ROOT_INO, name, &error); require(ino != 0, "Interix lookup");
        if (index < 13) check_read(v, ino, &c);
        else {
            char *output = NULL;
            CHECK(nfsk_readlink_alloc(v, ino, &output, 4096) == -ENAMETOOLONG && !output,
                  "Interix retains native raw UTF8 bound and publishes no oversized target");
            nfsk_test_free(output);
        }
    }
    CHECK(nfsk_sync(v) == 0 && nfsk_umount(v) == 0, "created literal targets synchronize and retire");
    ntfs_volume *native = ntfs_mount(path, NTFS_MNT_RDONLY | NTFS_MNT_FORENSIC);
    require(native != NULL, "raw WSL observer");
    for (int index = 0; index < 13; index++) {
        if (!inodes[index]) continue;
        target_case c = make_case(index);
        ntfs_inode *ni = ntfs_inode_open(native, inodes[index]); require(ni != NULL, "raw WSL inode");
        REPARSE_POINT *point = ntfs_get_reparse_point(ni);
        le32 type = 0; if (point) memcpy(&type, point->reparse_data, sizeof type);
        CHECK(point && point->reparse_tag == IO_REPARSE_TAG_LX_SYMLINK && type == const_cpu_to_le32(2) &&
              le16_to_cpu(point->reparse_data_length) == sizeof(le32) + strlen(c.output) &&
              !memcmp(point->reparse_data + sizeof(le32), c.output, strlen(c.output)),
              "independent raw reparse observer sees literal WSL payload without stored NUL");
        CHECK((ni->flags & (FILE_ATTR_REPARSE_POINT | FILE_ATTR_ARCHIVE | FILE_ATTR_SYSTEM | FILE_ATTR_COMPRESSED)) ==
              (FILE_ATTR_REPARSE_POINT | FILE_ATTR_ARCHIVE), "creation retains native WSL type and flags");
        free(point); require(ntfs_inode_close(ni) == 0, "raw observer inode close");
    }
    require(ntfs_umount(native, FALSE) == 0, "raw observer close");
    v = nfsk_mount(device, true, &error); require(v != NULL, "read-only target reopen");
    reads = writes = syncs = 0;
    char *retained = NULL; target_case last = make_case(2);
    for (int index = 0; index < 13; index++) {
        if (!inodes[index]) continue;
        target_case c = make_case(index); check_read(v, inodes[index], &c);
    }
    CHECK(nfsk_readlink_alloc(v, inodes[2], &retained, 4096) == 0 && retained && !strcmp(retained, last.output),
          "prepare independent target result for post-unmount lifetime");
    CHECK(!nfsk_symlink(v, NFSK_ROOT_INO, "ReadonlyTarget", last.input, &error) && error == EROFS,
          "literal target path preserves read-only rejection");
    CHECK(nfsk_umount(v) == 0 && writes == 0 && retained && !strcmp(retained, last.output),
          "owned target outlives read-only teardown without backend writes");
    nfsk_test_free(retained);
}

static void fault_tests(test_device *device, const char *path) {
    native_interix(path); int error = 0;
    ntfs_fskit_volume *v = nfsk_mount(device, false, &error); require(v != NULL, "fault mount");
    uint64_t sentinel = nfsk_create(v, NFSK_ROOT_INO, "TargetSentinel", NFSK_TYPE_FILE, &error);
    const char payload[] = "preserve this unrelated file";
    require(sentinel && nfsk_write(v, sentinel, 0, payload, sizeof payload, &error) == sizeof payload &&
            nfsk_sync(v) == 0, "sentinel payload");
    target_case c = make_case(2);
    malloc_countdown = 1;
    CHECK(!nfsk_symlink(v, NFSK_ROOT_INO, "TargetMalloc", c.input, &error) && error == ENOMEM && malloc_hits == 1,
          "literal target input allocation fails before namespace mutation");
    malloc_countdown = 0;
    for (int mode = 0; mode < 6; mode++) {
        char name[32]; snprintf(name, sizeof name, "TargetFailure%d", mode);
        if (mode < 3) { open_armed = 1; open_error = mode == 0 ? ENOMEM : mode == 1 ? ENXIO : 0; }
        else patch_mode = mode - 2;
        int expected = mode == 0 ? ENOMEM : mode == 1 ? ENXIO : mode == 3 ? ENOSPC : EIO;
        int reached = mode < 3 ? open_hits : patch_hits;
        CHECK(!nfsk_symlink(v, NFSK_ROOT_INO, name, c.input, &error) && error == expected &&
              (mode < 3 ? open_hits : patch_hits) == reached + 1,
              "target correction failure reaches its injection and preserves primary errno");
        open_armed = patch_mode = 0;
        uint64_t remaining = nfsk_lookup(v, NFSK_ROOT_INO, name, &error);
        int sync_result = nfsk_sync(v);
        printf("TARGET FAULT: mode=%d remaining=%llu lookup_error=%d sync=%d open_hits=%d patch_hits=%d\n",
               mode, remaining, error, sync_result, open_hits, patch_hits);
        CHECK(!remaining && error == ENOENT && sync_result == 0,
              "pre-I/O correction failure removes only the new entry and leaves a usable volume");
        char bytes[sizeof payload];
        CHECK(nfsk_read(v, sentinel, 0, bytes, sizeof bytes, &error) == sizeof bytes && !memcmp(bytes, payload, sizeof bytes),
              "failed correction and cleanup preserve independent sibling contents");
    }
    uint64_t interix = nfsk_lookup(v, NFSK_ROOT_INO, "LiteralInterix2", &error); require(interix != 0, "fault Interix");
    for (int i = 0; i < 2; i++) {
        conversion_error = i ? EILSEQ : ENOMEM; char *output = NULL;
        int released = partial_frees, hit = conversion_hits;
        CHECK(nfsk_readlink_alloc(v, interix, &output, 4096) == -conversion_error && !output &&
              conversion_hits == hit + 1 && partial_frees == released + 1 && !partial,
              "failed literal Interix conversion frees partial output once and publishes nothing");
        conversion_error = 0; nfsk_test_free(output); check_read(v, interix, &c);
    }
    for (int which = 1; which <= 2; which++) {
        char name[32]; snprintf(name, sizeof name, "TargetClose%d", which); close_countdown = which;
        int hits = close_hits;
        CHECK(!nfsk_symlink(v, NFSK_ROOT_INO, name, c.input, &error) && error == EIO && close_hits == hits + 1,
              "corrected creation still reports parent and child final-close failures");
        close_countdown = 0;
        CHECK(nfsk_sync(v) == -EIO && nfsk_sync(v) == 0, "corrected dirty target retains retry ownership after close failure");
        uint64_t ino = nfsk_lookup(v, NFSK_ROOT_INO, name, &error); CHECK(ino != 0, "close retry preserves created link");
        if (ino) check_read(v, ino, &c);
    }
    CHECK(nfsk_umount(v) == 0, "nonfatal target faults retire without leaked owned inodes");
}

static void fatal_test(test_device *device, const char *mode) {
    int error = 0; ntfs_fskit_volume *v = nfsk_mount(device, false, &error); require(v != NULL, "fatal mount");
    target_case c = make_case(!strcmp(mode, "backend-resident") ? 2 : 5);
    if (!strcmp(mode, "cleanup")) { patch_mode = 1; delete_error = EIO; }
    else if (!strcmp(mode, "short-write")) patch_mode = 4;
    else backend_mode = !strcmp(mode, "backend-zero") ? 2 : 1;
    uint64_t ino = nfsk_symlink(v, NFSK_ROOT_INO, "FatalTarget", c.input, &error);
    int expected = delete_error ? ENOSPC : patch_mode == 4 || backend_mode == 2 ? EIO : ENXIO;
    printf("TARGET FATAL: mode=%s inode=%llu error=%d patch=%d backend=%d cleanup=%d\n",
           mode, ino, error, patch_hits, backend_hits, delete_hits);
    CHECK(!ino && error == expected && patch_hits == 1 &&
          (delete_error ? delete_hits == 1 : patch_mode == 4 ? writes > 0 : backend_hits > 0),
          "actual backend or cleanup failure prevents successful creation and preserves primary errno");
    backend_armed = backend_mode = patch_mode = delete_error = 0;
    reads = writes = syncs = 0;
    int latched = !strcmp(mode, "cleanup") || !strcmp(mode, "backend-zero") || !strcmp(mode, "short-write") ? EIO : ENXIO;
    CHECK(nfsk_sync(v) == -latched && nfsk_sync(v) == -latched,
          "partially written or failed-cleanup target cannot acknowledge successful retry");
    CHECK(!nfsk_lookup(v, NFSK_ROOT_INO, "FatalTarget", &error) && error == latched,
          "fatal correction error blocks subsequent inode admission");
    CHECK(nfsk_umount(v) == -latched && reads == 0 && writes == 0 && syncs == 0,
          "fatal correction teardown frees retained ownership without backend I/O");
}

typedef struct {
    const char *input, *output;
    int full, junction, padding;
    uint64_t ino;
    void *raw;
    size_t raw_size;
} windows_case;

static int literal_units(const char *text, ntfschar **output) {
    int prefix = 0;
    while (!strncmp(text, "\xef\xbb\xbf", 3)) { prefix++; text += 3; }
    /* External Windows reparse paths can exceed the native convenience
     * converter's PATH_MAX. Build their literal UTF16 without that input cap. */
    CFStringRef decoded = CFStringCreateWithBytes(kCFAllocatorDefault, (const UInt8 *)text,
        strlen(text), kCFStringEncodingUTF8, false);
    require(decoded != NULL, "Windows suffix decoding");
    CFMutableStringRef normalized = CFStringCreateMutableCopy(kCFAllocatorDefault, 0, decoded);
    CFRelease(decoded); require(normalized != NULL, "Windows fixture normalization");
    CFStringNormalize(normalized, kCFStringNormalizationFormC);
    int length = (int)CFStringGetLength(normalized);
    *output = calloc((size_t)prefix + length + 1, sizeof(ntfschar)); require(*output != NULL, "Windows literal units");
    for (int i = 0; i < prefix; i++) (*output)[i] = const_cpu_to_le16(0xfeff);
    for (int i = 0; i < length; i++) (*output)[prefix + i] = cpu_to_le16(CFStringGetCharacterAtIndex(normalized, i));
    CFRelease(normalized); return prefix + length;
}
static ntfs_inode *windows_entry(ntfs_inode *dir, const char *name, mode_t kind) {
    ntfschar *units = NULL; int length = literal_units(name, &units);
    ntfs_inode *ni = ntfs_create(dir, 0, units, length, kind); free(units);
    require(ni != NULL, "Windows entry"); return ni;
}
static uint64_t windows_file(ntfs_inode *dir, const char *name) {
    ntfs_inode *ni = windows_entry(dir, name, S_IFREG); uint64_t ino = ni->mft_no;
    require(ntfs_inode_close_in_dir(ni, dir) == 0, "Windows file close"); return ino;
}
static void windows_link(ntfs_inode *dir, const char *name, windows_case *c) {
    ntfs_inode *ni = windows_entry(dir, name, c->junction ? S_IFDIR : S_IFREG);
    ntfschar *units = NULL; int length = literal_units(c->input, &units);
    size_t header = c->junction ? 8 : 12;
    size_t payload = header + c->padding + (length + 1) * sizeof(ntfschar);
    c->raw_size = sizeof(REPARSE_POINT) + payload;
    REPARSE_POINT *point = calloc(1, c->raw_size); require(point != NULL, "Windows reparse allocation");
    point->reparse_tag = c->junction ? IO_REPARSE_TAG_MOUNT_POINT : IO_REPARSE_TAG_SYMLINK;
    point->reparse_data_length = cpu_to_le16(payload);
    le16 offset = cpu_to_le16(c->padding), bytes = cpu_to_le16(length * sizeof(ntfschar));
    le32 flags = cpu_to_le32(!c->full);
    memcpy(point->reparse_data, &offset, 2); memcpy(point->reparse_data + 2, &bytes, 2);
    if (!c->junction) memcpy(point->reparse_data + 8, &flags, 4);
    memcpy(point->reparse_data + header + c->padding, units, length * sizeof(ntfschar)); free(units);
    require(ntfs_set_ntfs_reparse_data(ni, (char *)point, c->raw_size, 0) == 0, "Windows native raw setter");
    c->ino = ni->mft_no; c->raw = point;
    require(ntfs_inode_close_in_dir(ni, dir) == 0, "Windows link close");
}

static void windows_tests(test_device *device, const char *path) {
    windows_case cases[] = {
        { "\xef\xbb\xbf" "mIxEd", "\xef\xbb\xbf" "mixed" },
        { "\xef\xbb\xbf\xef\xbb\xbf" "mIxEd", "\xef\xbb\xbf\xef\xbb\xbf" "mixed" },
        { "\xef\xbb\xbf", "\xef\xbb\xbf" }, { "\xef\xbb\xbf\xef\xbb\xbf", "\xef\xbb\xbf\xef\xbb\xbf" },
        { "\\\xef\xbb\xbf" "mIxEd", "//\xef\xbb\xbf" "mixed" },
        { "C:\\\xef\xbb\xbf" "mIxEd", "//\xef\xbb\xbf" "mixed" },
        { "\\??\\C:\\\xef\xbb\xbf" "mIxEd", "//\xef\xbb\xbf" "mixed", .full = 1 },
        { "C:\\\xef\xbb\xbf" "missing", "//.NTFS-3G/C:/\xef\xbb\xbf" "missing" },
        { "Z:\\\xef\xbb\xbf" "mIxEd", "//.NTFS-3G/Z:/\xef\xbb\xbf" "mIxEd" },
        { "\\??\\Z:\\\xef\xbb\xbf" "mIxEd", "//.NTFS-3G/Z:/\xef\xbb\xbf" "mIxEd", .full = 1 },
        { "\xef\xbb\xbf" "Dir\\\xef\xbb\xbf" "LeAf", "\xef\xbb\xbf" "dir/\xef\xbb\xbf" "leaf" },
        { "C:\\\xef\xbb\xbf" ".NTFS-3G\\C:\\\xef\xbb\xbf" "LeAf", "//\xef\xbb\xbf" ".ntfs-3g/c:/\xef\xbb\xbf" "leaf" },
        { "\\??\\C:\\\xef\xbb\xbf" ".NTFS-3G\\C:\\\xef\xbb\xbf" "LeAf", "//\xef\xbb\xbf" ".ntfs-3g/c:/\xef\xbb\xbf" "leaf", .full = 1 },
        { "\\??\\C:\\\xef\xbb\xbf" "Dir", "//\xef\xbb\xbf" "dir", .full = 1, .junction = 1 },
        { ".\\\xef\xbb\xbf" "mIxEd", "./\xef\xbb\xbf" "mixed" },
        { "C:\\MiXeD", "//mixed" }, { "\\??\\C:\\MiXeD", "//mixed", .full = 1 },
        { "\xef\xbb\xbf" "missing", NULL },
        { "\xef\xbb\xbf" "e\xcc\x81", "\xef\xbb\xbf" "e\xcc\x81", .padding = 4 },
        { "\\\xef\xbb\xbf\xef\xbb\xbf" "mIxEd", "//\xef\xbb\xbf\xef\xbb\xbf" "mixed" },
        { "\\\xef\xbb\xbf", "//\xef\xbb\xbf" },
        { NULL, NULL }, { NULL, NULL, .full = 1 }, { NULL, NULL },
    };
    size_t count = sizeof cases / sizeof cases[0];
    require(ntfs_set_char_encoding("UTF-8") == 0, "Windows encoding");
    ntfs_volume *native = ntfs_mount(path, 0); require(native != NULL, "Windows native mount");
    ntfs_inode *root = ntfs_inode_open(native, FILE_root); require(root != NULL, "Windows root");
    uint64_t literal_target = windows_file(root, "\xef\xbb\xbf" "MiXeD");
    windows_file(root, "\xef\xbb\xbf\xef\xbb\xbf" "MiXeD"); windows_file(root, "\xef\xbb\xbf");
    windows_file(root, "\xef\xbb\xbf\xef\xbb\xbf"); windows_file(root, "MiXeD");
    windows_file(root, "\xef\xbb\xbf" "e\xcc\x81");
    ntfs_inode *dir = windows_entry(root, "\xef\xbb\xbf" "Dir", S_IFDIR);
    windows_file(dir, "\xef\xbb\xbf" "LeAf"); require(ntfs_inode_close_in_dir(dir, root) == 0, "Windows dir close");
    dir = windows_entry(root, ".NTFS-3G", S_IFDIR); windows_file(dir, "Z:");
    require(ntfs_inode_close_in_dir(dir, root) == 0, "Windows mapping close");
    dir = windows_entry(root, "\xef\xbb\xbf" ".NTFS-3G", S_IFDIR);
    ntfs_inode *sub = windows_entry(dir, "C:", S_IFDIR); windows_file(sub, "\xef\xbb\xbf" "LeAf");
    require(ntfs_inode_close_in_dir(sub, dir) == 0 && ntfs_inode_close_in_dir(dir, root) == 0, "lookalike mapping close");
    char boundary[1100] = "", expected[1100] = "", full[1110], full_expected[1110], over[1100];
    ntfs_inode *parents[5] = {root};
    for (int component = 0; component < 4; component++) {
        char name[260] = "";
        if (!component) strcpy(name, "\xef\xbb\xbf");
        size_t start = strlen(name); memset(name + start, 'a' + component, component ? 250 : 249);
        name[start + (component ? 250 : 249)] = 0;
        strcat(boundary, name); strcat(boundary, "\\"); strcat(expected, name); strcat(expected, "/");
        parents[component + 1] = windows_entry(parents[component], name, S_IFDIR);
    }
    const char *leaf = "eeeeeeeeeeeeeeeee";
    windows_file(parents[4], leaf); windows_file(parents[4], "eeeeeeeeeeeeeeeeee");
    strcat(boundary, leaf); strcat(expected, leaf); require(strlen(boundary) == 1023, "Windows raw boundary");
    for (int component = 4; component; component--)
        require(ntfs_inode_close_in_dir(parents[component], parents[component-1]) == 0, "boundary directory close");
    snprintf(full, sizeof full, "\\??\\C:\\%s", boundary); snprintf(full_expected, sizeof full_expected, "//%s", expected);
    snprintf(over, sizeof over, "%se", boundary);
    cases[21].input = boundary; cases[21].output = expected;
    cases[22].input = full; cases[22].output = full_expected; cases[23].input = over;
    for (size_t i = 0; i < count; i++) {
        char name[32]; snprintf(name, sizeof name, "WindowsTarget%zu", i); windows_link(root, name, &cases[i]);
    }
    require(ntfs_inode_close(root) == 0 && ntfs_umount(native, FALSE) == 0, "Windows fixtures close");
    int error = 0; ntfs_fskit_volume *v = nfsk_mount(device, true, &error); require(v != NULL, "Windows bridge mount");
    reads = writes = syncs = 0;
    for (size_t i = 0; i < count; i++) {
        windows_case *c = &cases[i]; char bytes[4096], *owned = NULL; nfsk_attr_t attr;
        int result = nfsk_readlink(v, c->ino, bytes, sizeof bytes);
        printf("WINDOWS TARGET: index=%zu result=%d expected_bytes=%zu actual_bytes=%zu\n",
               i, result, c->output ? strlen(c->output) : 0, result ? 0 : strlen(bytes));
        if (!c->output) {
            CHECK(result == -EOPNOTSUPP, "unresolved or over-limit Windows path retains native failure");
            CHECK(nfsk_getattr(v, c->ino, &attr) == 0 && attr.type == NFSK_TYPE_FILE,
                  "unresolved Windows reparse keeps its existing opaque type policy");
            continue;
        }
        size_t length = strlen(c->output);
        CHECK(result == 0 && !strcmp(bytes, c->output), "native Windows resolution retains complete literal target bytes");
        CHECK(nfsk_readlink_alloc(v, c->ino, &owned, 4096) == 0 && owned && !strcmp(owned, c->output),
              "owned Windows target matches exact expected local or mapped spelling");
        CHECK(nfsk_getattr(v, c->ino, &attr) == 0 &&
              attr.type == (c->junction ? NFSK_TYPE_DIR : NFSK_TYPE_SYMLINK) && (c->junction || attr.size == length),
              "target byte size is complete and existing directory-junction type policy is unchanged");
        memset(bytes, '!', sizeof bytes);
        CHECK(nfsk_readlink(v, c->ino, bytes, length) == -ENAMETOOLONG && bytes[0] == '!',
              "Windows capacity rejection does not truncate or publish target bytes");
        CHECK(nfsk_readlink(v, c->ino, bytes, length + 1) == 0 && !strcmp(bytes, c->output),
              "Windows exact-capacity read includes the restored BOM");
        nfsk_test_free(owned);
    }
    char target[4096];
    CHECK(nfsk_readlink(v, cases[0].ino, target, sizeof target) == 0 &&
          nfsk_lookup(v, NFSK_ROOT_INO, target, &error) == literal_target,
          "literal Windows target resolves to its actual inode rather than the plain-name neighbor");
    for (int operation = 0; operation < 2; operation++) {
        malloc_countdown = 1; int hits = malloc_hits; char *output = NULL; nfsk_attr_t attr;
        int result = operation ? nfsk_getattr(v, cases[0].ino, &attr) : nfsk_readlink_alloc(v, cases[0].ino, &output, 4096);
        CHECK(result == -ENOMEM && !output && malloc_hits == hits + 1,
              "restored Windows output allocation failure is visible without publishing a target or attributes");
        malloc_countdown = 0; nfsk_test_free(output);
    }
    const int unchanged[] = {2, 7, 8, 9, 14, 15, 16, 20};
    for (size_t i = 0; i < sizeof unchanged / sizeof unchanged[0]; i++) {
        malloc_countdown = 1; int hits = malloc_hits; windows_case *c = &cases[unchanged[i]];
        CHECK(nfsk_readlink(v, c->ino, target, sizeof target) == 0 && !strcmp(target, c->output) &&
              malloc_countdown == 1 && malloc_hits == hits,
              "already-literal, mapped and ordinary Windows targets need no restoration allocation");
        malloc_countdown = 0;
    }
    watch_output = 1; close_countdown = 1; char *output = NULL;
    CHECK(nfsk_readlink_alloc(v, cases[0].ino, &output, 4096) == -EIO && !output &&
          watched_allocations == 1 && watched_frees == 1 && !watched_output,
          "final-close failure frees restored Windows output before publication");
    watch_output = close_countdown = 0; nfsk_test_free(output);
    CHECK(nfsk_umount(v) == -EIO && writes == 0 && syncs == 0,
          "read-only Windows failures release retained inode ownership without writing");
    v = nfsk_mount(device, true, &error); require(v != NULL, "Windows retry mount");
    CHECK(nfsk_readlink_alloc(v, cases[0].ino, &output, 4096) == 0 && output && !strcmp(output, cases[0].output),
          "fresh read-only mount returns the complete target after faults");
    CHECK(nfsk_umount(v) == 0 && output && !strcmp(output, cases[0].output), "owned restored target outlives volume teardown");
    nfsk_test_free(output);
    native = ntfs_mount(path, NTFS_MNT_RDONLY | NTFS_MNT_FORENSIC); require(native != NULL, "Windows raw observer");
    for (size_t i = 0; i < count; i++) {
        ntfs_inode *ni = ntfs_inode_open(native, cases[i].ino); require(ni != NULL, "Windows raw inode");
        s64 size = 0; void *raw = ntfs_attr_readall(ni, AT_REPARSE_POINT, AT_UNNAMED, 0, &size);
        CHECK(raw && size == (s64)cases[i].raw_size && !memcmp(raw, cases[i].raw, (size_t)size),
              "independent native reopen finds byte-identical Windows reparse data after reads and faults");
        free(raw); free(cases[i].raw); require(ntfs_inode_close(ni) == 0, "Windows raw inode close");
    }
    require(ntfs_umount(native, FALSE) == 0, "Windows raw observer close");
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    test_device device = { .fd = open(argv[1], O_RDWR) }; struct stat st;
    require(device.fd >= 0 && fstat(device.fd, &st) == 0 && S_ISREG(st.st_mode), "regular image backend");
    device.size = st.st_size;
    const char *mode = getenv("NFSK_SYMLINK_TEST_MODE"); if (!mode) mode = "normal";
    if (!strcmp(mode, "normal")) normal_tests(&device, argv[1]);
    else if (!strcmp(mode, "windows")) windows_tests(&device, argv[1]);
    else if (!strcmp(mode, "faults")) fault_tests(&device, argv[1]);
    else if (!strcmp(mode, "backend-error") || !strcmp(mode, "backend-zero") ||
             !strcmp(mode, "backend-resident") || !strcmp(mode, "short-write") || !strcmp(mode, "cleanup")) fatal_test(&device, mode);
    else return 2;
    close(device.fd);
    CHECK(live_attributes == 0, "every bridge-owned attribute is released after success or failure");
    printf("SYMLINK TARGET SUMMARY: mode=%s %d checks, %d failures\n", mode, checks, failures);
    return failures ? 1 : 0;
}
