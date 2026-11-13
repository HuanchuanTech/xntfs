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
static int checks, failures, fail_reads, fail_writes, fail_lookup, miss_checkpoint, corrupt_key, fail_next_after = -1;
static int fail_read_after;
static int index_calls, wrong_case_mode, allocation_entries;
static uint64_t fail_open_mft = UINT64_MAX, fail_close_mft = UINT64_MAX, fail_attr_mft = UINT64_MAX;
static int injected_faults;
static int conversion_error, conversion_faults, conversion_calls;
static void *conversion_partial;
static int conversion_partial_frees;
static int track_conversion_result, conversion_result_frees;
static void *conversion_result;
static uint64_t fail_search_mft = UINT64_MAX;
static int fail_search_after = -1;
static int search_error = EIO, context_error = ENOMEM, search_contexts;
static uint64_t fail_context_mft = UINT64_MAX;
static char encoding_names[5][2300], encoding_expected[5][2300];
#define CHECK(ok, message) do { checks++; if (!(ok)) { failures++; \
    fprintf(stderr, "FAIL: %s\n", message); } else printf("PASS: %s\n", message); } while (0)

static void require(int ok, const char *message) {
    if (!ok) { fprintf(stderr, "Fixture failure: %s (errno=%d)\n", message, errno); exit(2); }
}

int nfsk_test_ucstombs(const ntfschar *input, int length, char **output, int capacity) {
    conversion_calls++;
    if (conversion_error) {
        conversion_faults++;
        // Upstream can fail after allocating a partial output; the caller owns it.
        if (!*output) *output = malloc(8);
        require(*output != NULL, "allocate partial conversion witness");
        conversion_partial = *output;
        errno = conversion_error;
        return -1;
    }
    int result = ntfs_ucstombs(input, length, output, capacity);
    if (track_conversion_result && result >= 0) {
        require(!conversion_result && *output, "one owned conversion result at a time");
        conversion_result = *output;
    }
    return result;
}

void nfsk_test_free(void *pointer) {
    if (pointer && pointer == conversion_partial) {
        conversion_partial = NULL;
        conversion_partial_frees++;
    }
    if (pointer && pointer == conversion_result) {
        conversion_result = NULL;
        conversion_result_frees++;
    }
    free(pointer);
}

int nfsk_test_attr_lookup(const ATTR_TYPES type, const ntfschar *name,
        const u32 length, const IGNORE_CASE_BOOL ic, const VCN lowest_vcn,
        const u8 *value, const u32 value_length, ntfs_attr_search_ctx *ctx) {
    if (type == AT_FILE_NAME && ctx->ntfs_ino->mft_no == fail_search_mft &&
        fail_search_after >= 0 && fail_search_after-- == 0) {
        injected_faults++; errno = search_error; return -1;
    }
    return ntfs_attr_lookup(type, name, length, ic, lowest_vcn, value, value_length, ctx);
}

ntfs_attr_search_ctx *nfsk_test_attr_get_search_ctx(ntfs_inode *ni, MFT_RECORD *mrec) {
    if (ni && ni->mft_no == fail_context_mft) {
        fail_context_mft = UINT64_MAX;
        injected_faults++; errno = context_error; return NULL;
    }
    ntfs_attr_search_ctx *ctx = ntfs_attr_get_search_ctx(ni, mrec);
    if (ctx) search_contexts++;
    return ctx;
}

void nfsk_test_attr_put_search_ctx(ntfs_attr_search_ctx *ctx) {
    if (ctx) search_contexts--;
    ntfs_attr_put_search_ctx(ctx);
}

static void encoding_fixture_names(void) {
    memset(encoding_names[0], 'Z', 255);
    strcpy(encoding_expected[0], encoding_names[0]);
    strcpy(encoding_names[1], "A-ReadMe mixed Case.txt");
    strcpy(encoding_expected[1], encoding_names[1]);
    strcpy(encoding_names[2], "B-Caf\xc3\xa9");
    strcpy(encoding_expected[2], "B-Cafe\xcc\x81");
    strcpy(encoding_names[3], "C-\xf0\x9f\xa7\xa0.txt");
    strcpy(encoding_expected[3], encoding_names[3]);
    // 255 UTF-16 units are valid NTFS names. NFD is 2295 UTF-8 bytes here;
    // replacing the Unicode path with a fixed 256/1024-byte buffer truncates it.
    for (int i = 0; i < 255; i++) {
        memcpy(encoding_names[4] + i * 3, "\xea\xb0\x81", 3);
        memcpy(encoding_expected[4] + i * 9, "\xe1\x84\x80\xe1\x85\xa1\xe1\x86\xa8", 9);
    }
}

ntfs_inode *nfsk_test_inode_open(ntfs_volume *vol, MFT_REF ref) {
    if (MREF(ref) == fail_open_mft) { injected_faults++; fail_open_mft = UINT64_MAX; errno = EIO; return NULL; }
    return ntfs_inode_open(vol, ref);
}
ntfs_attr *nfsk_test_attr_open(ntfs_inode *ni, ATTR_TYPES type, ntfschar *name, u32 length) {
    if (ni->mft_no == fail_attr_mft) { injected_faults++; fail_attr_mft = UINT64_MAX; errno = EIO; return NULL; }
    return ntfs_attr_open(ni, type, name, length);
}
static int close_fails(ntfs_inode *ni) {
    if (ni->mft_no != fail_close_mft) return 0;
    injected_faults++; fail_close_mft = UINT64_MAX; errno = EIO; return 1;
}
int nfsk_test_inode_close(ntfs_inode *ni) { return close_fails(ni) ? -1 : ntfs_inode_close(ni); }
int nfsk_test_inode_real_close(ntfs_inode *ni) { return close_fails(ni) ? -1 : ntfs_inode_real_close(ni); }

int64_t nfsk_block_pread(void *opaque, void *buf, int64_t off, int64_t count) {
    if (fail_reads) { errno = EIO; return -1; }
    return pread(((test_device *)opaque)->fd, buf, count, off);
}
int64_t nfsk_block_pwrite(void *opaque, const void *buf, int64_t off, int64_t count) {
    if (fail_writes) { errno = EIO; return -1; }
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
    if (miss_checkpoint && ((const FILE_NAME_ATTR *)key)->file_name_length) {
        FILE_NAME_ATTR first = {0};
        return ntfs_index_lookup(&first, sizeof first, index);
    }
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
    encoding_fixture_names();
    ntfs_inode *encoding = create(root, "EnumEncoding", S_IFDIR);
    for (int i = 0; i < 5; i++) close_inode(create(encoding, encoding_names[i], S_IFREG));
    close_inode(encoding);
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
static int collect_attributes(void *opaque, const char *name, const nfsk_attr_t *attributes, int64_t cookie) {
    listing *out = opaque;
    nfsk_attr_t standalone;
    if (nfsk_getattr(out->volume, attributes->ino, &standalone)) { out->invalid++; return 1; }
    standalone.parent_ino = out->directory;
    if (memcmp(&standalone, attributes, sizeof standalone)) out->invalid++;
    return collect(opaque, name, attributes->ino, attributes->type, cookie);
}
static int count_attributes(void *opaque, const char *name, const nfsk_attr_t *attributes, int64_t cookie) {
    return count_entry(opaque, name, attributes->ino, attributes->type, cookie);
}

typedef struct {
    ntfs_fskit_volume *volume;
    uint64_t nested;
    unsigned seen;
    int count, invalid;
} encoding_check;

static int check_encoding(void *opaque, const char *name, uint64_t ino, uint32_t type, int64_t cookie) {
    encoding_check *check = opaque;
    int match = -1;
    for (int i = 0; i < 5; i++) if (!strcmp(name, encoding_expected[i])) match = i;
    if (match < 0 || type != NFSK_TYPE_FILE || !ino || cookie != ++check->count) {
        check->invalid++; return 1;
    }
    if (check->seen & (1U << match)) check->invalid++;
    check->seen |= 1U << match;
    // A nonempty nested walk overwrites its own temporary name many times.
    // The outer borrowed name must still be intact until this callback returns.
    if (check->nested) {
        int nested = 0;
        if (nfsk_readdir(check->volume, check->nested, 0, &nested, count_entry) || nested != 11 ||
            strcmp(name, encoding_expected[match])) check->invalid++;
    }
    return 0;
}

static int check_encoding_attributes(void *opaque, const char *name, const nfsk_attr_t *attributes, int64_t cookie) {
    return check_encoding(opaque, name, attributes->ino, attributes->type, cookie);
}

static void encoding_tests(ntfs_fskit_volume *v, uint64_t directory, uint64_t nested) {
    encoding_check check = { .volume = v, .nested = nested };
    CHECK(nfsk_readdir(v, directory, 0, &check, check_encoding) == 0 &&
          !check.invalid && check.seen == 31 && check.count == 5,
          "255-byte ASCII and 2295-byte NFD names survive nested enumeration without truncation");
    check = (encoding_check){ .volume = v, .nested = nested };
    CHECK(nfsk_readdir_attributes(v, directory, 0, &check, check_encoding_attributes) == 0 &&
          !check.invalid && check.seen == 31 && check.count == 5,
          "attribute enumeration preserves ASCII case, accents, supplementary characters and long Unicode names");
    for (int i = 0; i < 2; i++) {
        int expected_error = i ? ENOMEM : EILSEQ, before = conversion_faults, count = 0;
        int freed = conversion_partial_frees;
        conversion_error = expected_error;
        CHECK(nfsk_readdir(v, directory, 0, &count, count_entry) == -expected_error &&
              conversion_faults == before + 1 && !conversion_partial && conversion_partial_frees == freed + 1,
              "conversion failure propagates once, stops the walk and frees partial output");
        before = conversion_faults; count = 0;
        CHECK(nfsk_readdir_attributes(v, directory, 0, &count, count_attributes) == -expected_error &&
              conversion_faults == before + 1 && !conversion_partial && conversion_partial_frees == freed + 2,
              "attribute walk preserves conversion error and frees partial output");
        conversion_error = 0;
        check = (encoding_check){ .volume = v };
        CHECK(nfsk_readdir(v, directory, 0, &check, check_encoding) == 0 &&
              !check.invalid && check.seen == 31, "conversion failure remains retryable with complete spelling");
    }
}

static void canonical_lookup_tests(ntfs_fskit_volume *v, uint64_t directory) {
    track_conversion_result = 1;
    for (int i = 0; i < 5; i++) {
        int error = 0, freed = conversion_result_frees;
        uint64_t expected = nfsk_lookup(v, directory, encoding_names[i], &error);
        require(expected != 0, "canonical lookup fixture");
        char *name = (char *)1;
        uint64_t result = nfsk_lookup_name_alloc(v, directory, encoding_names[i], &name, &error);
        CHECK(result == expected && error == 0 && name && name == conversion_result &&
              !strcmp(name, encoding_expected[i]) && conversion_result_frees == freed,
              "owned canonical lookup returns complete spelling without premature free");
        nfsk_test_free(name);
        CHECK(!conversion_result && conversion_result_frees == freed + 1,
              "canonical result has exactly one caller-owned release");
    }
    int error = 0, freed = conversion_result_frees;
    uint64_t target = nfsk_lookup(v, directory, encoding_names[1], &error);
    char small[8], *name = (char *)1;
    fail_close_mft = target;
    CHECK(!nfsk_lookup_name(v, directory, encoding_names[1], small, sizeof small, &error) &&
          error == ENAMETOOLONG && !conversion_result && conversion_result_frees == freed + 1,
          "legacy capacity error precedes secondary close failure and frees conversion output");
    CHECK(nfsk_sync(v) == -EIO && nfsk_sync(v) == 0, "legacy short-buffer close failure retains retry ownership");

    freed = conversion_result_frees;
    fail_close_mft = target;
    CHECK(!nfsk_lookup_name_alloc(v, directory, encoding_names[1], &name, &error) &&
          error == EIO && !name && !conversion_result && conversion_result_frees == freed + 1,
          "failed child close frees owned canonical output without publishing it");
    CHECK(nfsk_sync(v) == -EIO && nfsk_sync(v) == 0, "owned-name child close failure retains retry ownership");
    fail_close_mft = directory; name = (char *)1;
    CHECK(!nfsk_lookup_name_alloc(v, directory, encoding_names[1], &name, &error) &&
          error == EIO && !name && !conversion_result,
          "failed parent close does not publish a canonical result");
    CHECK(nfsk_sync(v) == -EIO && nfsk_sync(v) == 0, "owned-name parent close failure remains recoverable");
    fail_close_mft = directory; name = (char *)1;
    CHECK(!nfsk_lookup_name_alloc(v, directory, "MissingCanonicalName", &name, &error) &&
          error == ENOENT && !name, "missing name retains first error over failed parent cleanup");
    CHECK(nfsk_sync(v) == -EIO && nfsk_sync(v) == 0, "missing-name secondary close failure remains recoverable");

    for (int i = 0; i < 2; i++) {
        conversion_error = i ? ENOMEM : EILSEQ;
        int before = conversion_faults, partial_freed = conversion_partial_frees;
        name = (char *)1;
        CHECK(!nfsk_lookup_name_alloc(v, directory, encoding_names[2], &name, &error) &&
              error == conversion_error && !name && conversion_faults == before + 1 &&
              !conversion_partial && conversion_partial_frees == partial_freed + 1,
              "owned lookup conversion failure frees partial output and preserves errno");
        conversion_error = 0;
        CHECK(nfsk_lookup_name_alloc(v, directory, encoding_expected[2], &name, &error) != 0 &&
              name && !strcmp(name, encoding_expected[2]), "canonical conversion failure can retry using decomposed input");
        nfsk_test_free(name);
    }
    name = (char *)1;
    CHECK(!nfsk_lookup_name_alloc(NULL, directory, encoding_names[1], &name, &error) &&
          error == EINVAL && !name, "invalid volume clears owned-name output");
    name = (char *)1;
    CHECK(!nfsk_lookup_name_alloc(v, directory, NULL, &name, &error) &&
          error == EINVAL && !name, "invalid input name clears owned-name output");
    CHECK(!nfsk_lookup_name_alloc(v, directory, encoding_names[1], NULL, &error) &&
          error == EINVAL, "owned-name lookup rejects a missing output slot");

    char canonical[256];
    for (int allocated = 0; allocated < 2; allocated++) {
        int faults = injected_faults;
        freed = conversion_result_frees; name = NULL;
        fail_search_mft = target; fail_search_after = 1;
        uint64_t result = allocated
            ? nfsk_lookup_name_alloc(v, directory, "a-readme mixed case.txt", &name, &error)
            : nfsk_lookup_name(v, directory, "a-readme mixed case.txt", canonical, sizeof canonical, &error);
        CHECK(!result && error == EIO && !name && !conversion_result &&
              injected_faults == faults + 1 && conversion_result_frees == freed + 1,
              "later FILE_NAME search error cannot turn a case-insensitive match into success");
        if (name) nfsk_test_free(name);
        fail_search_mft = UINT64_MAX; fail_search_after = -1;
    }
    CHECK(!conversion_result && !conversion_partial, "canonical lookup leaves no test-owned conversion output");
    track_conversion_result = 0;
}

static void parent_attribute_tests(ntfs_fskit_volume *v, uint64_t directory) {
    int error = 0;
    uint64_t items[] = {
        nfsk_lookup(v, directory, "MiXeD.txt", &error),
        nfsk_lookup(v, directory, "SubDirectory", &error)
    };
    require(items[0] && items[1], "parent attribute fixtures");
    const int errors[] = { EIO, ENXIO, ENOMEM, 0 };
    for (size_t item = 0; item < sizeof(items) / sizeof(items[0]); item++) {
        nfsk_attr_t expected, actual;
        CHECK(nfsk_getattr(v, items[item], &expected) == 0 && expected.parent_ino == directory,
              "file and directory attributes report their normal stored parent");
        for (size_t fault = 0; fault < sizeof(errors) / sizeof(errors[0]); fault++) {
            int previous = injected_faults;
            fail_search_mft = items[item]; fail_search_after = 0; search_error = errors[fault];
            int result = nfsk_getattr(v, items[item], &actual);
            CHECK(result == -(search_error ? search_error : EIO) &&
                  injected_faults == previous + 1 && search_contexts == 0,
                  "parent search failure cannot become successful unknown-parent attributes");
            fail_search_mft = UINT64_MAX; fail_search_after = -1; search_error = EIO;
            CHECK(nfsk_sync(v) == 0 && nfsk_getattr(v, items[item], &actual) == 0 &&
                  !memcmp(&expected, &actual, sizeof actual) && search_contexts == 0,
                  "parent search failure leaves sync clean and full attributes retryable");
        }
        for (int fault = 0; fault < 2; fault++) {
            int previous = injected_faults;
            fail_context_mft = items[item]; context_error = fault ? 0 : ENOMEM;
            CHECK(nfsk_getattr(v, items[item], &actual) == -ENOMEM &&
                  injected_faults == previous + 1 && search_contexts == 0,
                  "failed parent search-context allocation propagates ENOMEM without ownership");
            context_error = ENOMEM;
            CHECK(nfsk_sync(v) == 0 && nfsk_getattr(v, items[item], &actual) == 0 &&
                  !memcmp(&expected, &actual, sizeof actual) && search_contexts == 0,
                  "search-context allocation failure can retry with complete attributes");
        }
        int previous = injected_faults;
        fail_search_mft = items[item]; fail_search_after = 0; search_error = ENOENT;
        CHECK(nfsk_getattr(v, items[item], &actual) == 0 && actual.parent_ino == 0 &&
              actual.ino == items[item] && actual.type == expected.type &&
              injected_faults == previous + 1 && search_contexts == 0,
              "missing FILE_NAME retains successful unknown-parent fallback");
        fail_search_after = 0; search_error = ENXIO; fail_close_mft = items[item];
        previous = injected_faults;
        CHECK(nfsk_getattr(v, items[item], &actual) == -ENXIO &&
              injected_faults == previous + 2 && search_contexts == 0,
              "parent search error precedes secondary close failure");
        fail_search_mft = UINT64_MAX; fail_search_after = -1; search_error = EIO;
        CHECK(nfsk_sync(v) == -EIO && nfsk_sync(v) == 0 &&
              nfsk_getattr(v, items[item], &actual) == 0 &&
              !memcmp(&expected, &actual, sizeof actual),
              "secondary parent-query close failure retains sync error and retry ownership");
    }
    nfsk_attr_t root;
    int previous = injected_faults;
    fail_context_mft = FILE_root; fail_search_mft = FILE_root; fail_search_after = 0;
    CHECK(nfsk_getattr(v, NFSK_ROOT_INO, &root) == 0 && root.parent_ino == NFSK_PARENT_OF_ROOT &&
          injected_faults == previous && search_contexts == 0,
          "root parent sentinel bypasses FILE_NAME lookup and allocation");
    fail_context_mft = UINT64_MAX; fail_search_mft = items[0]; fail_search_after = 0;
    int count = 0;
    CHECK(nfsk_readdir_attributes(v, directory, 0, &count, count_attributes) == 0 && count == 11 &&
          injected_faults == previous && fail_search_after == 0 && search_contexts == 0,
          "attribute enumeration uses its known listing parent without a parent FILE_NAME search");
    fail_search_mft = UINT64_MAX; fail_search_after = -1;
}

static int reject_with_close_failure(void *opaque, const char *name, const nfsk_attr_t *attributes, int64_t cookie) {
    (void)name; (void)attributes; (void)cookie;
    fail_close_mft = *(uint64_t *)opaque;
    return 1;
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

static int collect_then_stop(void *opaque, const char *name, uint64_t ino, uint32_t type, int64_t cookie) {
    int rc = collect(opaque, name, ino, type, cookie);
    listing *out = opaque;
    return rc || out->count == out->limit;
}

static int mutate_then_stop(void *opaque, const char *name, uint64_t ino, uint32_t type, int64_t cookie) {
    listing *out = opaque;
    int rc = collect(opaque, name, ino, type, cookie);
    if (out->count == 7) {
        int error = 0;
        require(nfsk_create(out->volume, out->directory, "AAA-callback.txt", NFSK_TYPE_FILE, &error) != 0,
                "mutation inside enumeration callback");
        return 1;
    }
    return rc;
}

static void prime_page(ntfs_fskit_volume *v, uint64_t dir) {
    listing *p = new_listing(v, dir);
    p->limit = 7;
    require(nfsk_readdir(v, dir, 0, p, collect) == 0 && p->count == 7 && !p->invalid, "prime page boundary");
    free(p);
}

/* Compare with the public API's fresh ordinal walk, including all names, inode
 * identities, types and cookies. This also specifies behavior after mutation. */
static int suffix_matches(ntfs_fskit_volume *v, uint64_t dir, int64_t cookie) {
    listing *all = new_listing(v, dir), *tail = new_listing(v, dir);
    tail->cookie = cookie;
    int ok = nfsk_readdir(v, dir, 0, all, collect) == 0 &&
        nfsk_readdir(v, dir, cookie, tail, collect) == 0 && !all->invalid && !tail->invalid &&
        all->count >= cookie && tail->count == all->count - cookie &&
        !memcmp(tail->entries, all->entries + cookie, tail->count * sizeof(record));
    free(all); free(tail);
    return ok;
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
    encoding_tests(v, lookup(v, NFSK_ROOT_INO, "EnumEncoding"), small);
    canonical_lookup_tests(v, lookup(v, NFSK_ROOT_INO, "EnumEncoding"));
    parent_attribute_tests(v, small);
    listing *attrs = new_listing(v, small);
    attrs->nested_directory = empty;
    CHECK(nfsk_readdir_attributes(v, small, 0, attrs, collect_attributes) == 0 && attrs->count == 11 && !attrs->invalid,
          "combined enumeration matches every live attribute field for files, directories, links and special items");
    uint64_t attr_first_ino = attrs->entries[0].ino;
    free(attrs);
    for (int page = 1; page <= 64; page = page == 1 ? 7 : page == 7 ? 64 : 65) {
        attrs = new_listing(v, large);
        int before, rc = 0;
        do {
            before = attrs->count; attrs->limit = before + page;
            rc = nfsk_readdir_attributes(v, large, attrs->cookie, attrs, collect_attributes);
        } while (!rc && attrs->count != before);
        CHECK(!rc && attrs->count == 320 && !attrs->invalid, "combined enumeration preserves rejected-entry cookies at page sizes 1, 7 and 64");
        free(attrs);
    }
    uint64_t linked = lookup(v, small, "MiXeD.txt");
    CHECK(nfsk_link(v, linked, empty, "CrossParent", &error) == 0, "prepare a hard link in another directory");
    nfsk_attr_t before_link, after_link;
    CHECK(nfsk_getattr(v, linked, &before_link) == 0, "read context-free hard-link parent");
    attrs = new_listing(v, empty);
    CHECK(nfsk_readdir_attributes(v, empty, 0, attrs, collect_attributes) == 0 && attrs->count == 1 && !attrs->invalid &&
          nfsk_getattr(v, linked, &after_link) == 0 && after_link.parent_ino == before_link.parent_ino,
          "combined enumeration uses its listing parent without changing context-free hard-link identity");
    free(attrs);
    CHECK(nfsk_remove(v, empty, "CrossParent") == 0, "remove temporary cross-directory link");
    for (int fault = 0; fault < 3; fault++) {
        int called = 0, previous = injected_faults;
        if (fault == 0) fail_open_mft = attr_first_ino;
        if (fault == 1) fail_close_mft = attr_first_ino;
        if (fault == 2) fail_attr_mft = attr_first_ino;
        CHECK(nfsk_readdir_attributes(v, small, 0, &called, count_attributes) == -EIO && !called && injected_faults == previous + 1,
              "child open, attribute read and close errors stop before publishing attributes");
        if (fault == 1) CHECK(nfsk_sync(v) == -EIO && nfsk_sync(v) == 0, "combined child close retains retry ownership and saved error");
    }
    int previous = injected_faults;
    CHECK(nfsk_readdir_attributes(v, small, 0, &small, reject_with_close_failure) == -EIO && injected_faults == previous + 1,
          "a rejected entry does not hide a later directory-close error");
    CHECK(nfsk_sync(v) == -EIO && nfsk_sync(v) == 0, "directory close recovers after a stopped callback");
    fail_close_mft = attr_first_ino;
    CHECK(nfsk_getattr(v, attr_first_ino, &after_link) == -EIO && nfsk_sync(v) == -EIO && nfsk_sync(v) == 0,
          "standalone getattr also reports failed close and retains recovery ownership");
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
    conversion_calls = 0;
    CHECK(nfsk_readdir(v, large, 0, list, collect) == 0 && list->count == 320 && !list->invalid && allocation_entries > 0,
          "large-directory traversal covers index allocation blocks");
    printf("DIRECTORY CONVERSION: %d upstream calls for 320 ASCII entries (including callback lookups)\n", conversion_calls);
    int correct_names = 1;
    for (int i = 0; i < 320; i++) {
        char name[64];
        snprintf(name, sizeof name, "Entry-%04d-MiXeD.txt", i);
        if (!has_type(list, name, NFSK_TYPE_FILE)) correct_names = 0;
    }
    CHECK(correct_names, "all large-directory names preserve stored spelling without omissions");
    listing *pages = new_listing(v, large);
    int rc = 0;
    int page_index_calls = index_calls;
    for (int page = 0; page < 50; page++) {
        int before = pages->count;
        pages->limit = before + 7;
        rc = nfsk_readdir(v, large, pages->cookie, pages, collect);
        if (rc || pages->count == before) break;
    }
    CHECK(rc == 0 && pages->count == list->count && !pages->invalid &&
          !memcmp(pages->entries, list->entries, list->count * sizeof(record)),
          "seven-entry pages retry rejected entries with no duplicates, gaps, or cookie changes");
    CHECK(index_calls - page_index_calls < 320 * 3,
          "paged index traversal stays linear instead of rescanning every prefix");
    CHECK(suffix_matches(v, large, 7), "evicted early cookie falls back without changing the listing");
    prime_page(v, large);
    CHECK(suffix_matches(v, large, 7) && suffix_matches(v, large, 7),
          "repeated cached cookie retries the rejected entry consistently");
    miss_checkpoint = 1;
    CHECK(suffix_matches(v, large, 7), "missing cached key falls back to the original ordinal walk");
    miss_checkpoint = 0;
    prime_page(v, large);
    fail_next_after = 0;
    count = 0;
    CHECK(nfsk_readdir(v, large, 8, &count, count_entry) == -EIO && count == 0,
          "failure advancing a cached accepted entry is not reported as EOF");
    fail_next_after = -1;
    free(pages);
    pages = new_listing(v, large);
    for (int page = 0; page < 50; page++) {
        int before = pages->count;
        pages->limit = before + 7;
        rc = nfsk_readdir(v, large, pages->cookie, pages, collect_then_stop);
        if (rc || pages->count == before) break;
        prime_page(v, small); /* Interleave another directory on the same volume. */
    }
    CHECK(rc == 0 && pages->count == list->count && !pages->invalid &&
          !memcmp(pages->entries, list->entries, list->count * sizeof(record)),
          "stop-after-accept and interleaved directories preserve all entries");
    count = 0;
    CHECK(nfsk_readdir(v, large, INT64_MAX, &count, count_entry) == 0 && count == 0,
          "cookie beyond EOF returns an empty listing");
    free(pages);
    free(list);

    prime_page(v, large);
    uint64_t added = nfsk_create(v, large, "AAA-before-page.txt", NFSK_TYPE_FILE, &error);
    CHECK(added && suffix_matches(v, large, 7), "create before a page boundary invalidates its old position");
    prime_page(v, large);
    CHECK(nfsk_remove(v, large, "AAA-before-page.txt") == 0 && suffix_matches(v, large, 7),
          "remove before a page boundary invalidates its old position");
    prime_page(v, large);
    CHECK(nfsk_rename(v, large, "Entry-0000-MiXeD.txt", large, "ZZZ-renamed.txt") == 0 &&
          suffix_matches(v, large, 7), "rename across a page boundary keeps fresh-walk semantics");
    require(nfsk_rename(v, large, "ZZZ-renamed.txt", large, "Entry-0000-MiXeD.txt") == 0, "restore renamed fixture");
    uint64_t first_ino = lookup(v, large, "Entry-0000-MiXeD.txt");
    prime_page(v, large);
    CHECK(nfsk_link(v, first_ino, large, "AAA-link.txt", &error) == 0 && suffix_matches(v, large, 7),
          "a new hard link invalidates ordinal checkpoints");
    require(nfsk_remove(v, large, "AAA-link.txt") == 0, "remove temporary hard link");
    prime_page(v, large);
    fail_writes = 1;
    int64_t failed_write = nfsk_write(v, first_ino, 0, "retry", 5, &error);
    CHECK(failed_write < 0 && error == EIO, "write failure remains visible with a populated page cache");
    fail_writes = 0;
    (void)nfsk_sync(v);
    CHECK(nfsk_sync(v) == 0 && suffix_matches(v, large, 7),
          "failed-write recovery cannot reuse stale page positions");
    listing *mutated = new_listing(v, large);
    CHECK(nfsk_readdir(v, large, 0, mutated, mutate_then_stop) == 0 && mutated->count == 7 &&
          suffix_matches(v, large, 7), "a callback mutation cannot publish a stale checkpoint afterwards");
    free(mutated);
    require(nfsk_remove(v, large, "AAA-callback.txt") == 0, "remove callback fixture");
    prime_page(v, large);
    fail_reads = 1;
    count = 0;
    CHECK(nfsk_readdir(v, large, 7, &count, count_entry) == -EIO && count == 0,
          "cached resume still reports directory-open I/O failure");
    fail_reads = 0;
    CHECK(suffix_matches(v, large, 7), "cached resume recovers after directory-open failure");

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
