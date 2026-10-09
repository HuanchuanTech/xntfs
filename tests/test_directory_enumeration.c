#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <ntfs-3g/volume.h>
#include <ntfs-3g/inode.h>
#include <ntfs-3g/dir.h>
#include <ntfs-3g/index.h>
#include <ntfs-3g/unistr.h>
#include "ntfs_fskit.h"

typedef struct { int fd; int64_t size; } test_device;
static int checks, failures, fail_reads, fail_lookup, corrupt_key, fail_next_after = -1;
static int fail_read_after;
static int index_calls, wrong_case_mode, allocation_entries;
#define CHECK(ok, message) do { checks++; if (!(ok)) { failures++; \
    fprintf(stderr, "FAIL: %s\n", message); } else printf("PASS: %s\n", message); } while (0)

static void require(int ok, const char *message) {
    if (!ok) { fprintf(stderr, "Fixture failure: %s (errno=%d)\n", message, errno); exit(2); }
}

int64_t nfsk_block_pread(void *opaque, void *buf, int64_t off, int64_t count) {
    if (fail_reads) { errno = EIO; return -1; }
    return pread(((test_device *)opaque)->fd, buf, count, off);
}
int64_t nfsk_block_pwrite(void *opaque, const void *buf, int64_t off, int64_t count) {
    return pwrite(((test_device *)opaque)->fd, buf, count, off);
}
int nfsk_block_sync(void *opaque) { return fsync(((test_device *)opaque)->fd) ? -errno : 0; }
uint64_t nfsk_block_total_bytes(void *opaque) { return ((test_device *)opaque)->size; }
uint32_t nfsk_block_sector_size(void *opaque) { (void)opaque; return 512; }
int nfsk_block_is_writable(void *opaque) { (void)opaque; return 1; }

/* Redirect only the bridge's index calls; keep the upstream library unchanged. */
int nfsk_test_index_lookup(const void *key, int length, ntfs_index_context *index) {
    index_calls++;
    wrong_case_mode += !!NVolCaseSensitive(index->ni->vol);
    if (fail_lookup) { errno = EIO; return -1; }
    int rc = ntfs_index_lookup(key, length, index);
    if (corrupt_key && (!rc || errno == ENOENT) && index->entry &&
        !(index->entry->ie_flags & INDEX_ENTRY_END)) index->entry->key_length = const_cpu_to_le16(1);
    return rc;
}
INDEX_ENTRY *nfsk_test_index_next(INDEX_ENTRY *entry, ntfs_index_context *index) {
    index_calls++;
    wrong_case_mode += !!NVolCaseSensitive(index->ni->vol);
    if (fail_next_after == 0) { errno = EIO; return NULL; }
    if (fail_next_after > 0) fail_next_after--;
    INDEX_ENTRY *next = ntfs_index_next(entry, index);
    if (next && !index->is_in_root) allocation_entries++;
    return next;
}

static ntfs_inode *create(ntfs_inode *parent, const char *name, mode_t mode) {
    ntfschar *wide = NULL;
    int length = ntfs_mbstoucs(name, &wide);
    require(length > 0, "convert create name");
    ntfs_inode *item = ntfs_create(parent, const_cpu_to_le32(0), wide, length, mode);
    free(wide);
    require(item != NULL, "create item");
    return item;
}
static void close_inode(ntfs_inode *item) { require(ntfs_inode_close(item) == 0, "close fixture inode"); }

static void prepare(const char *path) {
    ntfs_volume *volume = ntfs_mount(path, NTFS_MNT_NONE);
    require(volume && !NVolReadOnly(volume), "open writable fixture copy");
    require(ntfs_volume_get_free_space(volume) == 0, "initialize free space");
    ntfs_inode *root = ntfs_inode_open(volume, FILE_root);
    require(root != NULL, "open root");
    ntfs_inode *small = create(root, "EnumSmall", S_IFDIR);
    ntfs_inode *file = create(small, "MiXeD.txt", S_IFREG);
    ntfschar *wide = NULL;
    int length = ntfs_mbstoucs("OtherLink.TXT", &wide);
    require(length > 0 && ntfs_link(file, small, wide, length) == 0, "create hard link");
    free(wide);
    close_inode(file);
    close_inode(create(small, "\xc3\x89" "cole.txt", S_IFREG));
    close_inode(create(small, "SubDirectory", S_IFDIR));
    close_inode(create(small, ".DotFile", S_IFREG));
    file = create(small, "Hidden.txt", S_IFREG);
    file->flags |= FILE_ATTR_HIDDEN;
    NInoSetDirty(file);
    NInoFileNameSetDirty(file);
    require(ntfs_inode_close_in_dir(file, small) == 0, "close hidden file in parent");
    volume->special_files = NTFS_FILES_INTERIX;
    close_inode(create(small, "Fifo", S_IFIFO));
    close_inode(create(small, "Socket", S_IFSOCK));
    volume->special_files = NTFS_FILES_WSL;
    ntfschar *target = NULL;
    int target_length = ntfs_mbstoucs("MiXeD.txt", &target);
    wide = NULL;
    length = ntfs_mbstoucs("Link", &wide);
    require(length > 0 && target_length > 0, "convert symlink");
    file = ntfs_create_symlink(small, const_cpu_to_le32(0), wide, length, target, target_length);
    free(wide);
    free(target);
    require(file != NULL, "create reparse symlink");
    require(ntfs_inode_close_in_dir(file, small) == 0, "close symlink in parent");
    file = create(small, "OpaqueReparse", S_IFIFO);
    require(ntfs_inode_close_in_dir(file, small) == 0, "close opaque reparse in parent");
    file = create(small, "LongDisplayName.txt", S_IFREG);
    /* This upstream API consumes both inodes. */
    require(ntfs_set_ntfs_dos_name(file, small, "LONGDI~1.TXT", 12, 0) == 0, "add DOS alias");

    ntfs_inode *large = create(root, "EnumLarge", S_IFDIR);
    for (int i = 0; i < 320; i++) {
        char name[64];
        snprintf(name, sizeof name, "Entry-%04d-MiXeD.txt", i);
        close_inode(create(large, name, S_IFREG));
    }
    close_inode(large);
    close_inode(create(root, "EnumEmpty", S_IFDIR));
    close_inode(root);
    require(ntfs_umount(volume, FALSE) == 0, "unmount prepared fixture");
}

typedef struct { char name[1024]; uint64_t ino; uint32_t type; int64_t cookie; } record;
typedef struct {
    ntfs_fskit_volume *volume;
    uint64_t directory, nested_directory;
    int count, limit, invalid;
    int64_t cookie;
    record entries[512];
} listing;

static int count_entry(void *opaque, const char *name, uint64_t ino, uint32_t type, int64_t cookie) {
    (void)name; (void)ino; (void)type; (void)cookie;
    (*(int *)opaque)++;
    if (fail_read_after && *(int *)opaque == fail_read_after) fail_reads = 1;
    return 0;
}
static int collect(void *opaque, const char *name, uint64_t ino, uint32_t type, int64_t cookie) {
    listing *out = opaque;
    if (out->count >= out->limit) return 1; /* Rejected entry must be retried on resume. */
    if (out->count >= 512 || strlen(name) >= sizeof out->entries[0].name) { out->invalid++; return 1; }
    if (cookie != out->cookie + 1 || ino < FILE_first_user || !strcmp(name, ".") || !strcmp(name, "..")) out->invalid++;
    record *item = &out->entries[out->count++];
    strcpy(item->name, name);
    item->ino = ino;
    item->type = type;
    nfsk_attr_t attributes;
    if (nfsk_getattr(out->volume, ino, &attributes) || attributes.type != type) out->invalid++;
    item->cookie = out->cookie = cookie;
    char folded[1024];
    strcpy(folded, name);
    for (char *p = folded; *p; p++) if ((unsigned char)*p < 128) *p = (char)tolower((unsigned char)*p);
    int error = 0;
    if (nfsk_lookup(out->volume, out->directory, folded, &error) != ino) out->invalid++;
    if (out->nested_directory && out->count == 1) {
        int nested_count = 0;
        if (nfsk_readdir(out->volume, out->nested_directory, 0, &nested_count, count_entry) || nested_count) out->invalid++;
    }
    errno = ENOENT; /* Must not leak into the iterator's end-of-directory result. */
    return 0;
}
static listing *new_listing(ntfs_fskit_volume *volume, uint64_t directory) {
    listing *result = calloc(1, sizeof(*result));
    require(result != NULL, "allocate listing");
    result->volume = volume;
    result->directory = directory;
    result->limit = 512;
    return result;
}
static record *named(listing *list, const char *name) {
    for (int i = 0; i < list->count; i++) if (!strcmp(list->entries[i].name, name)) return &list->entries[i];
    return NULL;
}
static int has_type(listing *list, const char *name, uint32_t type) {
    record *item = named(list, name);
    return item && item->type == type;
}
static uint64_t lookup(ntfs_fskit_volume *v, uint64_t dir, const char *name) {
    int error = 0;
    uint64_t ino = nfsk_lookup(v, dir, name, &error);
    require(ino != 0, "lookup fixture item");
    return ino;
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    struct stat st;
    require(stat(argv[1], &st) == 0 && S_ISREG(st.st_mode), "regular disposable image required");
    require(ntfs_set_char_encoding("UTF-8") == 0, "set encoding");
    prepare(argv[1]);
    test_device device = { .fd = open(argv[1], O_RDWR), .size = st.st_size };
    require(device.fd >= 0, "open test backend");
    int error = 0;
    ntfs_fskit_volume *v = nfsk_mount(&device, false, &error);
    require(v != NULL, "bridge mount");
    uint64_t small = lookup(v, NFSK_ROOT_INO, "enumsmall");
    uint64_t large = lookup(v, NFSK_ROOT_INO, "enumlarge");
    uint64_t empty = lookup(v, NFSK_ROOT_INO, "enumempty");
    listing *list = new_listing(v, small);
    list->nested_directory = empty;
    CHECK(nfsk_readdir(v, small, 0, list, collect) == 0 && list->count == 11 && !list->invalid,
          "small-directory enumeration supports reentrant lookup and nested enumeration");
    record *mixed = named(list, "MiXeD.txt"), *link = named(list, "OtherLink.TXT");
    CHECK(mixed && link && mixed->ino == link->ino, "hard links retain their distinct original names");
    CHECK(named(list, "E\xcc\x81" "cole.txt") != NULL, "Unicode uppercase survives macOS NFD conversion");
    CHECK(has_type(list, "SubDirectory", NFSK_TYPE_DIR) && has_type(list, "MiXeD.txt", NFSK_TYPE_FILE),
          "ordinary file and directory types are preserved");
    CHECK(named(list, "Hidden.txt") && named(list, ".DotFile"), "hidden and dot files retain existing visibility");
    CHECK(named(list, "LongDisplayName.txt") && !named(list, "LONGDI~1.TXT"), "DOS aliases are excluded");
    CHECK(has_type(list, "Fifo", NFSK_TYPE_FIFO) && has_type(list, "Socket", NFSK_TYPE_SOCKET),
          "Interix special-file types are preserved");
    CHECK(has_type(list, "Link", NFSK_TYPE_SYMLINK) && has_type(list, "OpaqueReparse", NFSK_TYPE_FILE),
          "readable reparse symlinks and opaque reparse points keep their types");
    char target[128];
    CHECK(nfsk_readlink(v, lookup(v, small, "link"), target, sizeof target) == 0 && !strcmp(target, "MiXeD.txt"),
          "enumerated symlink has a readable target");
    int count = 0;
    CHECK(nfsk_readdir(v, empty, 0, &count, count_entry) == 0 && count == 0, "empty directory returns clean EOF");
    CHECK(nfsk_readdir(v, lookup(v, small, "mixed.txt"), 0, &count, count_entry) == -ENOTDIR,
          "enumerating a regular file returns ENOTDIR");
    listing *root = new_listing(v, NFSK_ROOT_INO);
    CHECK(nfsk_readdir(v, NFSK_ROOT_INO, 0, root, collect) == 0 && root->count > 0 && !root->invalid,
          "root enumeration excludes metadata and synthetic dot entries");
    free(root);
    free(list);

    list = new_listing(v, large);
    CHECK(nfsk_readdir(v, large, 0, list, collect) == 0 && list->count == 320 && !list->invalid && allocation_entries > 0,
          "large-directory traversal covers index allocation blocks");
    int correct_names = 1;
    for (int i = 0; i < 320; i++) {
        char name[64];
        snprintf(name, sizeof name, "Entry-%04d-MiXeD.txt", i);
        if (!has_type(list, name, NFSK_TYPE_FILE)) correct_names = 0;
    }
    CHECK(correct_names, "all large-directory names preserve stored spelling without omissions");
    listing *pages = new_listing(v, large);
    int rc = 0;
    for (int page = 0; page < 50; page++) {
        int before = pages->count;
        pages->limit = before + 7;
        rc = nfsk_readdir(v, large, pages->cookie, pages, collect);
        if (rc || pages->count == before) break;
    }
    CHECK(rc == 0 && pages->count == list->count && !pages->invalid &&
          !memcmp(pages->entries, list->entries, list->count * sizeof(record)),
          "seven-entry pages retry rejected entries with no duplicates, gaps, or cookie changes");
    count = 0;
    CHECK(nfsk_readdir(v, large, INT64_MAX, &count, count_entry) == 0 && count == 0,
          "cookie beyond EOF returns an empty listing");
    free(pages);
    free(list);

    count = 0;
    fail_lookup = 1;
    CHECK(nfsk_readdir(v, large, 0, &count, count_entry) == -EIO && count == 0, "initial index failure is not EOF");
    fail_lookup = 0;
    fail_next_after = 3;
    CHECK(nfsk_readdir(v, large, 0, &count, count_entry) == -EIO && count > 0 && count < 320,
          "mid-enumeration index failure propagates after partial results");
    fail_next_after = -1;
    corrupt_key = 1;
    count = 0;
    CHECK(nfsk_readdir(v, small, 0, &count, count_entry) == -EIO && count == 0,
          "truncated filename key is rejected before reading its fields");
    corrupt_key = 0;
    fail_reads = 1;
    CHECK(nfsk_readdir(v, large, 0, &count, count_entry) == -EIO, "backend read errors propagate");
    fail_reads = 0;
    count = 0;
    fail_read_after = 1;
    CHECK(nfsk_readdir(v, large, 0, &count, count_entry) == -EIO && count > 0 && count < 320,
          "later index-block I/O failure is not mistaken for end of directory");
    fail_reads = fail_read_after = 0;
    count = 0;
    CHECK(nfsk_readdir(v, large, 0, &count, count_entry) == 0 && count == 320,
          "enumeration can retry successfully after injected failures");
    CHECK(index_calls > 0 && wrong_case_mode == 0, "all index operations keep the volume case-insensitive");
    nfsk_umount(v);
    v = nfsk_mount(&device, true, &error);
    require(v != NULL, "read-only remount");
    list = new_listing(v, large);
    CHECK(nfsk_readdir(v, large, 0, list, collect) == 0 && list->count == 320 && !list->invalid &&
          named(list, "Entry-0319-MiXeD.txt"), "stored spelling and case-insensitive access survive read-only remount");
    free(list);
    nfsk_umount(v);
    close(device.fd);
    printf("%d directory checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
