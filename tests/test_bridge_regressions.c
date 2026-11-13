#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <ntfs-3g/inode.h>
#include <ntfs-3g/attrib.h>
#include <ntfs-3g/volume.h>
#include <ntfs-3g/device.h>
#include <ntfs-3g/ntfstime.h>
#include <ntfs-3g/index.h>
#include <ntfs-3g/dir.h>
#include <ntfs-3g/runlist.h>
#include <ntfs-3g/unistr.h>
#include <ntfs-3g/reparse.h>
#include "ntfs_fskit.h"

typedef struct { int fd; int64_t size; } test_device;
static int failures, checks, fail_close_writes, inside_close;
static int inode_sync_calls, block_sync_calls, fail_inode_sync, fail_block_sync;
static int block_read_calls, block_write_calls, fail_all_writes;
static int injected_write_errno = EBUSY;
static int attr_read_calls, attr_write_calls, unsafe_attr_calls;
static int inspect_write_range, injected_read_errno, close_countdown;
static s64 observed_write_offset, observed_write_count;
static struct ntfs_device *observed_device;
static ntfs_volume *observed_volume;
static int fail_standard_information_once, failed_standard_information;
static ntfs_time older_standard_information_time;
static int fail_index_write_once, failed_index_writes;
static int64_t special_read_start, special_read_end;
static int special_read_armed, special_read_hits;
static int special_read_errno = EIO, special_short_prefix, special_published;
static uint64_t classify_fault_ino = UINT64_MAX, target_open_fault_ino = UINT64_MAX;
static int classify_countdown, classify_errno, classify_hits, classify_success_errno;
static int target_open_errno, target_open_hits;
static void *reparse_buffers[128];
static size_t reparse_sizes[128], reparse_live_bytes, reparse_peak_bytes;
static int fail_reparse_readall;
static uint64_t reparse_fault_ino = UINT64_MAX;
static int reparse_fault_errno, reparse_fault_hits, reparse_success_errno;
static int conversion_error, conversion_frees;
static void *conversion_partial;
static int malloc_countdown, malloc_faults;
#define CHECK(condition, message) do { checks++; if (!(condition)) { \
    failures++; fprintf(stderr, "FAIL: %s\n", message); \
} else { printf("PASS: %s\n", message); } } while (0)

/* The runner instruments only the unchanged upstream reparse translation unit.
 * Observe its actual readall-buffer lifetime, including rejection paths. */
void *nfsk_test_reparse_readall(ntfs_inode *ni, const ATTR_TYPES type,
                               ntfschar *name, u32 length, s64 *size) {
    if (fail_reparse_readall) { fail_reparse_readall = 0; errno = ENOMEM; return NULL; }
    if (ni->mft_no == reparse_fault_ino && type == AT_REPARSE_POINT) {
        reparse_fault_ino = UINT64_MAX; reparse_fault_hits++;
        errno = reparse_fault_errno; return NULL;
    }
    void *result = ntfs_attr_readall(ni, type, name, length, size);
    if (result) {
        if (reparse_success_errno) { errno = reparse_success_errno; reparse_success_errno = 0; }
        for (unsigned i = 0; i < 128; i++) if (!reparse_buffers[i]) {
            reparse_buffers[i] = result; reparse_sizes[i] = (size_t)*size;
            reparse_live_bytes += reparse_sizes[i];
            if (reparse_live_bytes > reparse_peak_bytes) reparse_peak_bytes = reparse_live_bytes;
            return result;
        }
        abort();
    }
    return result;
}
void nfsk_test_reparse_free(void *buffer) {
    for (unsigned i = 0; buffer && i < 128; i++) if (reparse_buffers[i] == buffer) {
        reparse_live_bytes -= reparse_sizes[i]; reparse_buffers[i] = NULL; break;
    }
    free(buffer);
}
int nfsk_test_ucstombs(const ntfschar *text, const int length, char **result, int capacity) {
    if (conversion_error) {
        *result = malloc(16); if (!*result) abort();
        memset(*result, '!', 16); conversion_partial = *result;
        errno = conversion_error; conversion_error = 0; return -1;
    }
    return ntfs_ucstombs(text, length, result, capacity);
}
void *nfsk_test_malloc(size_t size) {
    if (malloc_countdown > 0 && --malloc_countdown == 0) {
        malloc_faults++; errno = ENOMEM; return NULL;
    }
    return malloc(size);
}
void nfsk_test_free(void *buffer) {
    if (buffer && buffer == conversion_partial) {
        conversion_partial = NULL; conversion_frees++;
    }
    nfsk_test_reparse_free(buffer);
}

/* An independent build of unchanged upstream dir.c verifies this contract:
 * failed DATA open returns UNKNOWN while leaving the open errno intact. */
u32 nfsk_test_interix_types(ntfs_inode *ni) {
    if (ni->mft_no == classify_fault_ino && classify_countdown > 0 && --classify_countdown == 0) {
        classify_hits++; errno = classify_errno; return NTFS_DT_UNKNOWN;
    }
    u32 result = ntfs_interix_types(ni);
    if (classify_success_errno) {
        errno = classify_success_errno; classify_success_errno = 0;
    }
    return result;
}

ntfs_attr *nfsk_test_attr_open(ntfs_inode *ni, ATTR_TYPES type, ntfschar *name, u32 length) {
    if (ni->mft_no == target_open_fault_ino && type == AT_DATA && !length) {
        target_open_fault_ino = UINT64_MAX;
        target_open_hits++; errno = target_open_errno; return NULL;
    }
    return ntfs_attr_open(ni, type, name, length);
}

int64_t nfsk_block_pread(void *opaque, void *buf, int64_t off, int64_t count) {
    block_read_calls++;
    if (special_read_armed && off < special_read_end && count > special_read_start - off) {
        if (special_short_prefix) {
            special_short_prefix = 0;
            return pread(((test_device *)opaque)->fd, buf, count < 4 ? count : 4, off);
        }
        special_read_armed = 0; special_read_hits++;
        errno = special_read_errno;
        return special_read_errno ? -1 : 0;
    }
    return pread(((test_device *)opaque)->fd, buf, count, off);
}
int64_t nfsk_block_pwrite(void *opaque, const void *buf, int64_t off, int64_t count) {
    block_write_calls++;
    if (fail_index_write_once && count >= 4 && !memcmp(buf, "INDX", 4)) {
        fail_index_write_once = 0; failed_index_writes++; errno = EIO; return -1;
    }
    if (fail_all_writes) { errno = injected_write_errno; return -1; }
    if (fail_close_writes && inside_close) { errno = EIO; return -1; }
    return pwrite(((test_device *)opaque)->fd, buf, count, off);
}
int nfsk_block_sync(void *opaque) {
    block_sync_calls++;
    if (fail_block_sync) return -EIO;
    return fsync(((test_device *)opaque)->fd) ? -errno : 0;
}
uint64_t nfsk_block_total_bytes(void *opaque) { return ((test_device *)opaque)->size; }
uint32_t nfsk_block_sector_size(void *opaque) { (void)opaque; return 512; }
int nfsk_block_is_writable(void *opaque) { (void)opaque; return 1; }

/* Never pass deliberately invalid ranges to the uninstrumented upstream
 * library. Observe a missing bridge check, then fail before upstream arithmetic. */
static int safe_attr_range(s64 offset, s64 count) {
    if (offset < 0 || count < 0 || count > INT64_MAX - offset) {
        unsafe_attr_calls++; errno = ERANGE; return 0;
    }
    return 1;
}
s64 nfsk_test_attr_pread(ntfs_attr *na, s64 offset, s64 count, void *buffer) {
    attr_read_calls++;
    observed_device = na->ni->vol->dev;
    observed_volume = na->ni->vol;
    if (!safe_attr_range(offset, count)) return -1;
    if (injected_read_errno) { errno = injected_read_errno; return -1; }
    return ntfs_attr_pread(na, offset, count, buffer);
}
s64 nfsk_test_attr_pwrite(ntfs_attr *na, s64 offset, s64 count, const void *buffer) {
    attr_write_calls++;
    observed_device = na->ni->vol->dev;
    observed_volume = na->ni->vol;
    if (!safe_attr_range(offset, count)) return -1;
    if (inspect_write_range) {
        observed_write_offset = offset; observed_write_count = count;
        errno = ENOSPC; return -1;
    }
    return ntfs_attr_pwrite(na, offset, count, buffer);
}
static int inject_owned_close_error(void) {
    if (close_countdown > 0 && --close_countdown == 0) {
        // Match upstream's failure contract: the inode remains owned and live.
        errno = EIO; return 1;
    }
    return 0;
}

/* Only the bridge translation unit redirects close calls to these wrappers. */
int nfsk_test_inode_close(ntfs_inode *ni) {
    if (inject_owned_close_error()) return -1;
    inside_close++;
    int result = ntfs_inode_close(ni), saved = errno;
    inside_close--;
    errno = saved;
    return result;
}
int nfsk_test_inode_real_close(ntfs_inode *ni) {
    if (inject_owned_close_error()) return -1;
    inside_close++;
    int result = ntfs_inode_real_close(ni), saved = errno;
    inside_close--;
    errno = saved;
    return result;
}
int nfsk_test_inode_sync(ntfs_inode *ni) {
    inode_sync_calls++;
    if (fail_inode_sync) { errno = EIO; return -1; }
    // Model upstream's multi-stage failure: STANDARD_INFORMATION
    // fails, but the remaining MFT write succeeds and clears Dirty. The desired
    // inode fields still require retry even though its dirty bits are now clear.
    if (fail_standard_information_once) {
        fail_standard_information_once = 0;
        ntfs_time desired = ni->last_access_time;
        ni->last_access_time = older_standard_information_time;
        int result = ntfs_inode_sync(ni), saved = errno;
        ni->last_access_time = desired;
        if (!result) { failed_standard_information++; errno = EIO; return -1; }
        errno = saved;
        return result;
    }
    inside_close++;
    int result = ntfs_inode_sync(ni), saved = errno;
    inside_close--;
    errno = saved;
    return result;
}

static void metadata_sync_tests(ntfs_fskit_volume *v, const char *path) {
    CHECK(observed_volume != NULL && nfsk_sync(v) == 0, "prepare clean metadata sync observation");
    if (!observed_volume) return;
    inode_sync_calls = block_read_calls = block_write_calls = block_sync_calls = 0;
    int result = 0;
    for (int i = 0; i < 16 && !result; i++) result = nfsk_sync(v);
    printf("CLEAN SYNC: result=%d inode=%d read=%d write=%d flush=%d\n",
           result, inode_sync_calls, block_read_calls, block_write_calls, block_sync_calls);
    CHECK(!result && inode_sync_calls == 0 && block_read_calls == 0 && block_write_calls == 0,
          "clean sync does not rewrite unchanged metadata");
    CHECK(block_sync_calls == 16, "every explicit clean sync still reaches the backend flush");

    ntfs_inode *metadata[] = { observed_volume->lcnbmp_ni, observed_volume->mft_ni,
        observed_volume->mftmirr_ni, observed_volume->vol_ni, observed_volume->secure_ni };
    for (size_t i = 0; i < sizeof(metadata) / sizeof(metadata[0]); i++) {
        ntfs_inode *ni = metadata[i];
        if (!ni) continue;
        struct timespec stamp = { .tv_sec = 946684800 + (time_t)i, .tv_nsec = 123456700 };
        ni->last_access_time = timespec2ntfs(stamp);
        ntfs_inode_mark_dirty(ni);
        inode_sync_calls = block_write_calls = block_sync_calls = 0;
        CHECK(nfsk_sync(v) == 0 && inode_sync_calls >= 1 && block_write_calls > 0 &&
              block_sync_calls == 1 && !NInoDirty(ni), "changed metadata is written before its device flush");

        // Observe the image before writer teardown, which must not hide a skipped sync.
        ntfs_volume *fresh = ntfs_mount(path, NTFS_MNT_RDONLY | NTFS_MNT_FORENSIC);
        ntfs_inode *disk = fresh ? ntfs_inode_open(fresh, ni->mft_no) : NULL;
        CHECK(disk && disk->last_access_time == timespec2ntfs(stamp),
              "metadata timestamp is visible to an independent read-only handle before teardown");
        if (disk) CHECK(ntfs_inode_close(disk) == 0, "independent metadata observer closes cleanly");
        if (fresh) CHECK(ntfs_umount(fresh, FALSE) == 0, "independent metadata observer retires");
    }

    ntfs_inode *retry = observed_volume->lcnbmp_ni;
    older_standard_information_time = retry->last_access_time;
    struct timespec desired = { .tv_sec = 978307200, .tv_nsec = 456789000 };
    retry->last_access_time = timespec2ntfs(desired);
    ntfs_inode_mark_dirty(retry);
    fail_standard_information_once = 1;
    block_sync_calls = failed_standard_information = 0;
    CHECK(nfsk_sync(v) == -EIO && failed_standard_information == 1 && block_sync_calls == 0,
          "metadata phase error is reported even after upstream clears Dirty");
    inode_sync_calls = 0;
    CHECK(nfsk_sync(v) == -EIO && inode_sync_calls >= 1 && block_sync_calls == 1 && nfsk_sync(v) == 0,
          "failed metadata is retried before flush and its saved error is reported once");
    ntfs_volume *fresh = ntfs_mount(path, NTFS_MNT_RDONLY | NTFS_MNT_FORENSIC);
    ntfs_inode *disk = fresh ? ntfs_inode_open(fresh, retry->mft_no) : NULL;
    CHECK(disk && disk->last_access_time == timespec2ntfs(desired),
          "retry persists metadata omitted by the failed standard-information phase");
    if (disk) CHECK(ntfs_inode_close(disk) == 0, "retry observer closes");
    if (fresh) CHECK(ntfs_umount(fresh, FALSE) == 0, "retry observer retires");

    // Exercise the real index-destructor failure, not a replacement sync result.
    desired.tv_sec++;
    retry->last_access_time = timespec2ntfs(desired);
    ntfs_inode_mark_dirty(retry);
    NInoFileNameSetDirty(retry);
    fail_index_write_once = 1;
    failed_index_writes = block_sync_calls = 0;
    result = nfsk_sync(v);
    printf("INDEX SYNC: result=%d injected=%d flush=%d\n", result, failed_index_writes, block_sync_calls);
    CHECK(result == -EIO && failed_index_writes == 1 && block_sync_calls == 0,
          "metadata index write failure cannot become successful synchronization");
    fail_index_write_once = 0;
    CHECK(nfsk_sync(v) == -EIO && nfsk_sync(v) == 0,
          "metadata index failure retries and reports the saved error once");

    fresh = ntfs_mount(path, NTFS_MNT_RDONLY | NTFS_MNT_FORENSIC);
    ntfs_inode *root = fresh ? ntfs_inode_open(fresh, FILE_root) : NULL;
    ntfs_index_context *index = root ? ntfs_index_ctx_get(root, NTFS_INDEX_I30, 4) : NULL;
    _Alignas(FILE_NAME_ATTR) unsigned char key_buffer[offsetof(FILE_NAME_ATTR, file_name) + 7 * sizeof(ntfschar)] = {0};
    FILE_NAME_ATTR *key = (FILE_NAME_ATTR *)key_buffer;
    key->file_name_length = 7;
    for (int i = 0; i < 7; i++) key->file_name[i] = cpu_to_le16((unsigned char)"$Bitmap"[i]);
    CHECK(index && !ntfs_index_lookup(key, sizeof(key_buffer), index) &&
          ((FILE_NAME_ATTR *)index->data)->last_access_time == timespec2ntfs(desired),
          "retry persists the failed directory-index metadata before teardown");
    if (index) ntfs_index_ctx_put(index);
    if (root) CHECK(ntfs_inode_close(root) == 0, "index observer closes");
    if (fresh) CHECK(ntfs_umount(fresh, FALSE) == 0, "index observer retires");
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

static void verify_device_seek(struct ntfs_device *dev) {
    CHECK(dev != NULL, "observe actual bridge device operations through the mounted file image");
    if (!dev) return;
    s64 saved = dev->d_ops->seek(dev, 0, SEEK_CUR);
    CHECK(dev->d_ops->seek(dev, 1, SEEK_SET) == 1, "set a valid device position");
    errno = 0;
    CHECK(dev->d_ops->seek(dev, INT64_MAX, SEEK_CUR) == -1 && errno == EOVERFLOW &&
          dev->d_ops->seek(dev, 0, SEEK_CUR) == 1,
          "overflowing relative seek fails without changing the device position");
    CHECK(dev->d_ops->seek(dev, INT64_MAX, SEEK_SET) == INT64_MAX,
          "representable device position beyond EOF remains valid");
    errno = 0;
    CHECK(dev->d_ops->seek(dev, 1, SEEK_CUR) == -1 && errno == EOVERFLOW &&
          dev->d_ops->seek(dev, 0, SEEK_CUR) == INT64_MAX,
          "one-byte seek overflow cannot wrap the saved position");
    CHECK(dev->d_ops->seek(dev, -INT64_MAX, SEEK_CUR) == 0,
          "largest valid negative relative displacement returns to zero");
    errno = 0;
    CHECK(dev->d_ops->seek(dev, INT64_MIN, SEEK_CUR) == -1 && errno == EINVAL &&
          dev->d_ops->seek(dev, 0, SEEK_CUR) == 0,
          "minimum signed displacement is rejected without negating it");
    errno = 0;
    CHECK(dev->d_ops->seek(dev, INT64_MAX, SEEK_END) == -1 && errno == EOVERFLOW &&
          dev->d_ops->seek(dev, 0, SEEK_CUR) == 0,
          "end-relative overflow preserves the original device position");
    errno = 0;
    CHECK(dev->d_ops->seek(dev, 1, 99) == -1 && errno == EINVAL &&
          dev->d_ops->seek(dev, 0, SEEK_CUR) == 0,
          "invalid whence does not move the device position");
    CHECK(dev->d_ops->seek(dev, saved, SEEK_SET) == saved, "restore original device position after boundary tests");
}

static void verify_io_boundaries(ntfs_fskit_volume *v) {
    int error = 0;
    uint64_t ino = nfsk_create(v, NFSK_ROOT_INO, "IOBoundaries.txt", NFSK_TYPE_FILE, &error);
    CHECK(ino && nfsk_write(v, ino, 0, "01234567", 8, &error) == 8 && nfsk_sync(v) == 0,
          "prepare bounded I/O fixture");
    verify_device_seek(observed_device);
    char bytes[64]; memset(bytes, 0x5a, sizeof bytes);
    attr_read_calls = attr_write_calls = unsafe_attr_calls = 0;
    CHECK(nfsk_read(v, ino, 1, bytes, INT64_MAX, &error) == 7 && !memcmp(bytes, "1234567", 7) &&
          bytes[7] == 0x5a && unsafe_attr_calls == 0,
          "oversized read length clamps to EOF without signed overflow or oversized upstream request");
    attr_read_calls = 0; error = 0;
    CHECK(nfsk_read(v, ino, -1, bytes, 1, &error) == -1 && error == EINVAL && attr_read_calls == 0,
          "negative read offset is rejected before attribute I/O");
    error = 0;
    CHECK(nfsk_read(v, ino, -1, bytes, 0, &error) == -1 && error == EINVAL,
          "zero-byte read still rejects a negative offset");
    attr_read_calls = 0;
    CHECK(nfsk_read(v, ino, INT64_MAX, bytes, INT64_MAX, &error) == 0 && attr_read_calls == 0,
          "read beyond EOF returns zero without adding the offset and length");
    CHECK(nfsk_read(v, ino, INT64_MAX, NULL, 0, &error) == 0,
          "valid zero-byte read retains its no-buffer no-I/O contract");
    attr_write_calls = block_write_calls = 0; error = 0;
    CHECK(nfsk_write(v, ino, INT64_MAX, "x", 1, &error) == -1 && error == EFBIG &&
          attr_write_calls == 0 && block_write_calls == 0,
          "unrepresentable write end fails before any attribute or backend write");
    attr_write_calls = 0; error = 0;
    CHECK(nfsk_write(v, ino, 1, "x", INT64_MAX, &error) == -1 && error == EFBIG && attr_write_calls == 0,
          "oversized write count cannot reach upstream signed arithmetic");
    attr_write_calls = 0; error = 0;
    CHECK(nfsk_write(v, ino, -1, "x", 1, &error) == -1 && error == EINVAL && attr_write_calls == 0,
          "negative write offset is rejected before attribute I/O");
    error = 0;
    CHECK(nfsk_write(v, ino, -1, NULL, 0, &error) == -1 && error == EINVAL,
          "zero-byte write still rejects a negative offset");
    attr_write_calls = 0;
    CHECK(nfsk_write(v, ino, INT64_MAX, NULL, 0, &error) == 0 && attr_write_calls == 0,
          "valid zero-byte write retains its no-buffer no-I/O contract");
    inspect_write_range = 1; error = 0;
    CHECK(nfsk_write(v, ino, INT64_MAX - 1, "x", 1, &error) == -1 && error == ENOSPC &&
          observed_write_offset == INT64_MAX - 1 && observed_write_count == 1,
          "largest representable nonempty write is delegated without allocating an enormous file");
    inspect_write_range = 0;
    memset(bytes, 0, sizeof bytes);
    CHECK(nfsk_read(v, ino, 0, bytes, sizeof bytes, &error) == 8 && !memcmp(bytes, "01234567", 8) && nfsk_sync(v) == 0,
          "rejected boundary writes preserve existing bytes and synchronization");

    close_countdown = 1; error = 0;
    CHECK(nfsk_read(v, ino, 0, bytes, 8, &error) == -1 && error == EIO,
          "otherwise successful read reports an owned-inode final-close error");
    CHECK(nfsk_sync(v) == -EIO && nfsk_sync(v) == 0,
          "failed read close retains the inode and reports saved error once after recovery");
    close_countdown = 1; error = 0;
    CHECK(nfsk_read(v, ino, 8, bytes, 1, &error) == -1 && error == EIO,
          "EOF does not hide an error closing the opened inode");
    CHECK(nfsk_sync(v) == -EIO && nfsk_sync(v) == 0, "EOF close failure recovers");
    injected_read_errno = ENXIO; close_countdown = 1; error = 0;
    CHECK(nfsk_read(v, ino, 0, bytes, 8, &error) == -1 && error == ENXIO,
          "an earlier read error takes precedence over a later close error");
    injected_read_errno = 0;
    CHECK(nfsk_sync(v) == -EIO && nfsk_sync(v) == 0, "secondary close error still remains recoverable");
    close_countdown = 1; error = 0;
    CHECK(!nfsk_lookup(v, NFSK_ROOT_INO, "IOBoundaries.txt", &error) && error == EIO,
          "plain lookup propagates a parent final-close error");
    CHECK(nfsk_sync(v) == -EIO && nfsk_sync(v) == 0, "lookup parent close failure recovers");
    close_countdown = 2; error = 0;
    CHECK(!nfsk_lookup_name(v, NFSK_ROOT_INO, "ioboundaries.txt", bytes, sizeof bytes, &error) && error == EIO,
          "canonical lookup propagates the child final-close error");
    CHECK(nfsk_sync(v) == -EIO && nfsk_sync(v) == 0, "canonical lookup close failure recovers");
    close_countdown = 1; error = 0;
    CHECK(!nfsk_lookup(v, NFSK_ROOT_INO, "NoBoundaryEntry", &error) && error == ENOENT,
          "missing-name lookup preserves its primary error over cleanup failure");
    CHECK(nfsk_sync(v) == -EIO && nfsk_sync(v) == 0, "missing lookup cleanup retains failed inode ownership");
    uint64_t link = nfsk_symlink(v, NFSK_ROOT_INO, "IOBoundaryLink", "target", &error);
    CHECK(link != 0, "prepare a symlink for close-error propagation");
    close_countdown = 1; memset(bytes, 0x5a, sizeof bytes);
    CHECK(nfsk_readlink(v, link, bytes, sizeof bytes) == -EIO && bytes[0] == 0x5a,
          "readlink returns close failure before publishing target bytes");
    CHECK(nfsk_sync(v) == -EIO && nfsk_sync(v) == 0 &&
          nfsk_readlink(v, link, bytes, sizeof bytes) == 0 && !strcmp(bytes, "target"),
          "symlink target remains readable after close-error recovery");
    close_countdown = 1; memset(bytes, 0x5a, sizeof bytes);
    CHECK(nfsk_readlink(v, link, bytes, 1) == -ENAMETOOLONG && bytes[0] == 0x5a,
          "short readlink buffer keeps its size error over cleanup failure without truncation");
    CHECK(nfsk_sync(v) == -EIO && nfsk_sync(v) == 0, "short readlink cleanup remains recoverable");
    close_countdown = 1;
    CHECK(nfsk_readlink(v, ino, bytes, sizeof bytes) == -EINVAL,
          "invalid readlink target keeps its primary error when close also fails");
    CHECK(nfsk_sync(v) == -EIO && nfsk_sync(v) == 0, "invalid readlink cleanup remains recoverable");

    char *owned = bytes;
    CHECK(nfsk_readlink_alloc(NULL, link, &owned, 4096) == -EINVAL && !owned,
          "allocated readlink clears output on an invalid volume");
    owned = bytes;
    CHECK(nfsk_readlink_alloc(v, link, &owned, 0) == -EINVAL && !owned &&
          nfsk_readlink_alloc(v, link, NULL, 4096) == -EINVAL,
          "allocated readlink rejects zero capacity and missing output");
    CHECK(nfsk_readlink_alloc(v, link, &owned, 7) == 0 && owned && !strcmp(owned, "target"),
          "allocated readlink transfers a complete exact-capacity target");
    char *second = NULL;
    CHECK(nfsk_readlink_alloc(v, link, &second, 4096) == 0 && owned && second && owned != second &&
          !strcmp(owned, "target") && !strcmp(second, "target"),
          "allocated readlink results remain independently owned across later reads");
    nfsk_test_free(owned); nfsk_test_free(second); owned = NULL;
    CHECK(!reparse_live_bytes, "callers release both transferred reparse buffers");
    close_countdown = 1;
    CHECK(nfsk_readlink_alloc(v, link, &owned, 4096) == -EIO && !owned && !reparse_live_bytes,
          "allocated readlink frees its target rather than publishing on close failure");
    CHECK(nfsk_sync(v) == -EIO && nfsk_sync(v) == 0,
          "allocated readlink close failure retains sync error-once recovery");
    close_countdown = 1;
    CHECK(nfsk_readlink_alloc(v, link, &owned, 6) == -ENAMETOOLONG && !owned && !reparse_live_bytes,
          "allocated readlink preserves size error before a secondary close failure");
    CHECK(nfsk_sync(v) == -EIO && nfsk_sync(v) == 0,
          "allocated short-target close failure remains recoverable");
    close_countdown = 1;
    CHECK(nfsk_readlink_alloc(v, ino, &owned, 4096) == -EINVAL && !owned,
          "allocated readlink preserves invalid-target error before close failure");
    CHECK(nfsk_sync(v) == -EIO && nfsk_sync(v) == 0,
          "allocated invalid-target close failure remains recoverable");
}

typedef struct {
    const char *name;
    uint64_t ino, directory;
    ATTR_TYPES attribute;
    FILE_ATTR_FLAGS flags;
    int64_t start, end, size;
    unsigned char bytes[2048];
} special_fixture;
static special_fixture special_fixtures[2] = { { .name = "Interix" }, { .name = "WSL" } };
static special_fixture metadata_regular = { .name = "SystemMetadata", .attribute = AT_DATA };
static nfsk_attr_t metadata_preserved[2];
static char special_target[901];
static uint64_t malformed_reparse[3];
static uint64_t windows_relative;
static uint64_t external_long_link;

static void require_fixture(int condition, const char *message) {
    if (!condition) { fprintf(stderr, "Fixture failure: %s (errno=%d)\n", message, errno); exit(2); }
}

static void save_special_payload(special_fixture *fixture, ntfs_inode *file, ntfs_inode *directory) {
    fixture->ino = file->mft_no;
    fixture->directory = directory->mft_no;
    fixture->flags = file->flags;
    ntfs_attr *attribute = ntfs_attr_open(file, fixture->attribute, AT_UNNAMED, 0);
    require_fixture(attribute != NULL && (NAttrNonResident(attribute) || ntfs_attr_force_non_resident(attribute) == 0) &&
                    ntfs_attr_map_whole_runlist(attribute) == 0 && attribute->rl && attribute->rl[0].lcn >= 0,
                    "nonresident special payload");
    fixture->start = attribute->rl[0].lcn * file->vol->cluster_size;
    fixture->end = fixture->start + file->vol->cluster_size;
    fixture->size = attribute->data_size;
    require_fixture(fixture->size > 0 && fixture->size <= sizeof fixture->bytes &&
                    ntfs_attr_pread(attribute, 0, fixture->size, fixture->bytes) == fixture->size,
                    "save special payload");
    ntfs_attr_close(attribute);
}

static void prepare_special_read_fixtures(const char *path) {
    require_fixture(ntfs_set_char_encoding("UTF-8") == 0, "special encoding");
    ntfs_volume *volume = ntfs_mount(path, NTFS_MNT_NONE);
    require_fixture(volume != NULL, "special native mount");
    ntfs_inode *root = ntfs_inode_open(volume, FILE_root);
    require_fixture(root != NULL, "special root");
    ntfschar *name = NULL, *target = NULL;
    int length = ntfs_mbstoucs("SpecialReadErrors", &name);
    ntfs_inode *directory = ntfs_create(root, const_cpu_to_le32(0), name, length, S_IFDIR);
    free(name); name = NULL;
    require_fixture(directory != NULL, "special directory");
    memset(special_target, 't', sizeof special_target - 1);
    int target_length = ntfs_mbstoucs(special_target, &target);
    require_fixture(target_length > 0, "special target");
    for (int i = 0; i < 2; i++) {
        special_fixture *fixture = &special_fixtures[i];
        volume->special_files = i ? NTFS_FILES_WSL : NTFS_FILES_INTERIX;
        length = ntfs_mbstoucs(fixture->name, &name);
        ntfs_inode *file = ntfs_create_symlink(directory, const_cpu_to_le32(0), name, length, target, target_length);
        free(name); name = NULL;
        require_fixture(file != NULL, "special symlink");
        fixture->attribute = i ? AT_REPARSE_POINT : AT_DATA;
        save_special_payload(fixture, file, directory);
        require_fixture(ntfs_inode_close_in_dir(file, directory) == 0, "close special symlink");
    }
    length = ntfs_mbstoucs(metadata_regular.name, &name);
    ntfs_inode *system_file = ntfs_create(directory, const_cpu_to_le32(0), name, length, S_IFREG);
    free(name); name = NULL;
    require_fixture(system_file != NULL, "ordinary system-file fixture");
    system_file->flags |= FILE_ATTR_SYSTEM;
    NInoSetDirty(system_file); NInoFileNameSetDirty(system_file);
    unsigned char regular_payload[900]; memset(regular_payload, 'r', sizeof regular_payload);
    ntfs_attr *regular_data = ntfs_attr_open(system_file, AT_DATA, AT_UNNAMED, 0);
    require_fixture(regular_data && ntfs_attr_pwrite(regular_data, 0, sizeof regular_payload, regular_payload) == sizeof regular_payload,
                    "write ordinary system-file payload");
    ntfs_attr_close(regular_data);
    save_special_payload(&metadata_regular, system_file, directory);
    require_fixture(ntfs_inode_close_in_dir(system_file, directory) == 0, "close ordinary system file");
    volume->special_files = NTFS_FILES_WSL;
    for (int i = 0; i < 3; i++) {
        const char *names[] = { "MalformedReparse", "LargeMalformedReparse", "OversizedReparse" };
        length = ntfs_mbstoucs(names[i], &name);
        ntfs_inode *file = ntfs_create_symlink(directory, const_cpu_to_le32(0), name, length, target, target_length);
        free(name); name = NULL;
        require_fixture(file != NULL, "malformed reparse fixture");
        malformed_reparse[i] = file->mft_no;
        ntfs_attr *attribute = ntfs_attr_open(file, AT_REPARSE_POINT, AT_UNNAMED, 0);
        le16 zero = 0;
        require_fixture(attribute && ntfs_attr_pwrite(attribute, 4, 2, &zero) == 2, "malform reparse header");
        if (i) {
            /* Deliberately invalid image model. Only bypass the creator's
             * in-memory size check; never persist a changed $AttrDef. */
            ATTR_DEF *definition = ntfs_attr_find_in_attrdef(volume, AT_REPARSE_POINT);
            require_fixture(definition != NULL, "reparse attribute definition");
            sle64 previous_limit = definition->max_size;
            s64 size = i == 1 ? 65536 : 8 * 1024 * 1024;
            definition->max_size = cpu_to_sle64(size);
            require_fixture(ntfs_attr_truncate(attribute, size) == 0, "malformed reparse size");
            definition->max_size = previous_limit;
        }
        ntfs_attr_close(attribute);
        require_fixture(ntfs_inode_close_in_dir(file, directory) == 0, "close malformed reparse fixture");
    }
    free(target);
    length = ntfs_mbstoucs("WindowsRelative", &name);
    ntfs_inode *windows = ntfs_create(directory, const_cpu_to_le32(0), name, length, S_IFREG);
    free(name); name = NULL; target = NULL;
    /* Upstream resolves relative components to their on-disk case and rejects
     * a missing target. Interix exists in this directory; do not use a dangling
     * path as the successful Windows translation fixture. */
    target_length = ntfs_mbstoucs(".\\iNtErIx", &target);
    require_fixture(windows && target_length > 0, "Windows relative-link fixture");
    /* Native Windows symbolic-link header, with a terminated UTF-16 path. */
    unsigned char raw[256] = {0};
    REPARSE_POINT *point = (REPARSE_POINT *)raw;
    size_t payload = 12 + ((size_t)target_length + 1) * sizeof(ntfschar);
    point->reparse_tag = IO_REPARSE_TAG_SYMLINK;
    point->reparse_data_length = cpu_to_le16(payload);
    le16 target_bytes = cpu_to_le16(target_length * sizeof(ntfschar));
    le32 relative_flag = const_cpu_to_le32(1);
    memcpy(point->reparse_data + 2, &target_bytes, sizeof target_bytes);
    memcpy(point->reparse_data + 8, &relative_flag, sizeof relative_flag);
    memcpy(point->reparse_data + 12, target, target_length * sizeof(ntfschar));
    free(target);
    require_fixture(ntfs_set_ntfs_reparse_data(windows, (const char *)point, sizeof(REPARSE_POINT) + payload, 0) == 0,
                    "set Windows relative reparse data");
    char *translated = ntfs_make_symlink(windows, "/");
    require_fixture(translated && !strcmp(translated, "./Interix"), "upstream Windows relative translation");
    nfsk_test_reparse_free(translated);
    windows_relative = windows->mft_no;
    require_fixture(ntfs_inode_close_in_dir(windows, directory) == 0, "close Windows relative-link fixture");
    length = ntfs_mbstoucs("ExternalLongLink", &name);
    ntfs_inode *external = ntfs_create(directory, const_cpu_to_le32(0), name, length, S_IFREG);
    free(name);
    require_fixture(external != NULL, "external long-link fixture");
    size_t external_size = sizeof(REPARSE_POINT) + sizeof(le32) + 5000;
    REPARSE_POINT *external_point = calloc(1, external_size);
    require_fixture(external_point != NULL, "external target data");
    external_point->reparse_tag = IO_REPARSE_TAG_LX_SYMLINK;
    external_point->reparse_data_length = cpu_to_le16(sizeof(le32) + 5000);
    le32 wsl_type = const_cpu_to_le32(2);
    memcpy(external_point->reparse_data, &wsl_type, sizeof wsl_type);
    memset(external_point->reparse_data + sizeof wsl_type, 'z', 5000);
    require_fixture(ntfs_set_ntfs_reparse_data(external, (const char *)external_point, external_size, 0) == 0,
                    "set valid external WSL target above caller capacity");
    free(external_point);
    external_long_link = external->mft_no;
    require_fixture(ntfs_inode_close_in_dir(external, directory) == 0, "close external long link");
    require_fixture(ntfs_inode_close_in_dir(directory, root) == 0 && ntfs_inode_close(root) == 0 &&
                    ntfs_umount(volume, FALSE) == 0, "close special fixture volume");
}

static int special_name_callback(void *opaque, const char *name, uint64_t ino, uint32_t type, int64_t cookie) {
    (void)name; (void)type; (void)cookie;
    special_fixture *fixture = opaque;
    if (ino == fixture->ino) special_published++;
    return 0;
}

static int special_attr_callback(void *opaque, const char *name, const nfsk_attr_t *attributes, int64_t cookie) {
    return special_name_callback(opaque, name, attributes->ino, attributes->type, cookie);
}

static void arm_special_read(special_fixture *fixture) {
    special_read_start = fixture->start; special_read_end = fixture->end;
    special_read_hits = special_published = 0; special_read_armed = 1;
    block_write_calls = 0;
}

static void verify_special_reads(ntfs_fskit_volume *v) {
    require_fixture(nfsk_sync(v) == 0, "clean special-read entry");
    for (int i = 0; i < 2; i++) {
        special_fixture *fixture = &special_fixtures[i];
        char target[1024]; nfsk_attr_t attributes; int64_t region = -99;
        CHECK(nfsk_getattr(v, fixture->ino, &attributes) == 0 && attributes.type == NFSK_TYPE_SYMLINK &&
              nfsk_readlink(v, fixture->ino, target, sizeof target) == 0 && !strcmp(target, special_target),
              "nonresident Interix/WSL fixture is a readable symlink");
        const int errors[] = { EIO, ENXIO, ENOMEM, 0, 0 };
        for (unsigned fault = 0; fault < sizeof errors / sizeof errors[0]; fault++) {
            special_read_errno = errors[fault];
            int expected = special_read_errno ? special_read_errno : EIO;
            special_short_prefix = fault == 4;
            arm_special_read(fixture);
            int result = nfsk_getattr(v, fixture->ino, &attributes);
            special_read_armed = 0;
            CHECK(result == -expected && special_read_hits == 1 && block_write_calls == 0,
                  "special getattr reports a payload read error without regular-file fallback");
            special_short_prefix = fault == 4; arm_special_read(fixture);
            result = nfsk_readdir(v, fixture->directory, 0, fixture, special_name_callback);
            special_read_armed = 0;
            CHECK(result == -expected && special_read_hits == 1 && special_published == 0 && block_write_calls == 0,
                  "name listing stops before publishing a failed special-file classification");
            special_short_prefix = fault == 4; arm_special_read(fixture);
            result = nfsk_readdir_attributes(v, fixture->directory, 0, fixture, special_attr_callback);
            special_read_armed = 0;
            CHECK(result == -expected && special_read_hits == 1 && special_published == 0 && block_write_calls == 0,
                  "attribute listing stops before publishing a failed special-file classification");
            memset(target, '!', sizeof target);
            special_short_prefix = fault == 4; arm_special_read(fixture);
            result = nfsk_readlink(v, fixture->ino, target, sizeof target);
            special_read_armed = 0;
            CHECK(result == -expected && special_read_hits == 1 && target[0] == '!' && block_write_calls == 0,
                  "readlink preserves the real read error and leaves output untouched");
            char *owned_target = NULL;
            special_short_prefix = fault == 4; arm_special_read(fixture);
            result = nfsk_readlink_alloc(v, fixture->ino, &owned_target, sizeof target);
            special_read_armed = 0;
            CHECK(result == -expected && special_read_hits == 1 && !owned_target && block_write_calls == 0,
                  "allocated readlink preserves payload errors without transferring output");
            nfsk_test_free(owned_target);
            special_short_prefix = fault == 4; arm_special_read(fixture);
            result = nfsk_seek_region(v, fixture->ino, 0, true, &region);
            special_read_armed = 0;
            CHECK(result == -expected && special_read_hits == 1 && region == -99 && block_write_calls == 0,
                  "seek does not expose raw symlink data after a classification read error");
            special_short_prefix = fault == 4; arm_special_read(fixture);
            int64_t allocated = nfsk_preallocate(v, fixture->ino, 0, 0, false);
            special_read_armed = 0;
            CHECK(allocated == -expected && special_read_hits == 1 && block_write_calls == 0,
                  "preallocation rejects a classification read error before changing storage");
            special_short_prefix = fault == 4; arm_special_read(fixture);
            result = nfsk_truncate(v, fixture->ino, 1);
            special_read_armed = 0;
            printf("SPECIAL TRUNCATE: %s result=%d hits=%d writes=%d\n", fixture->name, result, special_read_hits, block_write_calls);
            CHECK(result == -expected && special_read_hits == 1 && block_write_calls == 0,
                  "truncate cannot shrink raw symlink data after a classification read error");
            CHECK(nfsk_sync(v) == 0 && nfsk_getattr(v, fixture->ino, &attributes) == 0 &&
                  attributes.type == NFSK_TYPE_SYMLINK && nfsk_readlink(v, fixture->ino, target, sizeof target) == 0 &&
                  !strcmp(target, special_target), "read-error retry preserves the symlink without poisoning sync");
        }
        special_read_errno = ENXIO;
        arm_special_read(fixture);
        close_countdown = 1;
        CHECK(nfsk_getattr(v, fixture->ino, &attributes) == -ENXIO && special_read_hits == 1,
              "special read error takes precedence over a secondary inode-close error");
        special_read_armed = 0;
        CHECK(nfsk_sync(v) == -EIO && nfsk_sync(v) == 0,
              "secondary close error retains its existing sync retry contract");
    }
    special_read_errno = EIO;
    nfsk_attr_t attributes;
    char target[1024]; memset(target, '!', sizeof target);
    /* The bridge-mounted volume supplies locase, so upstream translates the
     * existing component to lowercase (the native fixture mount above does not). */
    CHECK(nfsk_getattr(v, windows_relative, &attributes) == 0 && attributes.type == NFSK_TYPE_SYMLINK &&
          nfsk_readlink(v, windows_relative, target, sizeof target) == 0 &&
          !strcmp(target, "./interix") && !reparse_live_bytes,
          "validated Windows relative links retain upstream path translation and release buffers");
    char *owned_target = NULL;
    CHECK(nfsk_readlink_alloc(v, windows_relative, &owned_target, sizeof target) == 0 &&
          owned_target && !strcmp(owned_target, "./interix"),
          "allocated Windows target retains upstream translation");
    nfsk_test_free(owned_target); owned_target = NULL;
    int released_targets = 1;
    const uint64_t ownership_links[] = { windows_relative, external_long_link,
                                        special_fixtures[0].ino, special_fixtures[1].ino };
    for (unsigned kind = 0; kind < sizeof ownership_links / sizeof ownership_links[0]; kind++) {
        for (int repeat = 0; repeat < 32; repeat++) {
            if (nfsk_readlink_alloc(v, ownership_links[kind], &owned_target, 5001) || !owned_target)
                released_targets = 0;
            nfsk_test_free(owned_target); owned_target = NULL;
            if (reparse_live_bytes) released_targets = 0;
        }
    }
    CHECK(released_targets, "128 allocated target transfers release observed reparse buffers after every call");
    close_countdown = 1;
    CHECK(nfsk_readlink_alloc(v, external_long_link, &owned_target, 4096) == -ENAMETOOLONG &&
          !owned_target && !reparse_live_bytes,
          "allocated output keeps the caller limit even for valid external long targets and close errors");
    CHECK(nfsk_sync(v) == -EIO && nfsk_sync(v) == 0 &&
          nfsk_readlink_alloc(v, external_long_link, &owned_target, 5001) == 0 &&
          owned_target && strlen(owned_target) == 5000 && strspn(owned_target, "z") == 5000,
          "external long target stays complete and readable with sufficient capacity after retry");
    nfsk_test_free(owned_target); owned_target = NULL;
    memset(target, '!', sizeof target);
    conversion_error = EILSEQ; conversion_frees = 0;
    CHECK(nfsk_readlink(v, special_fixtures[0].ino, target, sizeof target) == -EILSEQ &&
          target[0] == '!' && conversion_frees == 1 && !conversion_partial,
          "failed Interix conversion frees partial output without publishing it");
    conversion_error = ENOMEM; conversion_frees = 0;
    CHECK(nfsk_getattr(v, special_fixtures[0].ino, &attributes) == -ENOMEM &&
          conversion_frees == 1 && !conversion_partial,
          "Interix allocation failure is not a successful regular-file classification");
    fail_reparse_readall = 1;
    CHECK(nfsk_getattr(v, special_fixtures[1].ino, &attributes) == -ENOMEM && !reparse_live_bytes,
          "reparse validation allocation failure preserves ENOMEM without retained data");
    fail_reparse_readall = 1;
    CHECK(nfsk_readlink_alloc(v, special_fixtures[1].ino, &owned_target, sizeof target) == -ENOMEM &&
          !owned_target && !reparse_live_bytes,
          "allocated readlink preserves reparse allocation failure with no output");
    conversion_error = EILSEQ; conversion_frees = 0;
    CHECK(nfsk_readlink_alloc(v, special_fixtures[0].ino, &owned_target, sizeof target) == -EILSEQ &&
          !owned_target && conversion_frees == 1 && !conversion_partial,
          "allocated Interix conversion failure releases partial output");
    CHECK(nfsk_readlink(v, special_fixtures[0].ino, target, sizeof target) == 0 &&
          !strcmp(target, special_target) && nfsk_sync(v) == 0,
          "conversion allocation failure remains retryable without a writeback latch");
    for (int i = 0; i < 3; i++) {
        int success = 1;
        reparse_peak_bytes = 0;
        for (int repeat = 0; repeat < 32; repeat++) {
            if (nfsk_getattr(v, malformed_reparse[i], &attributes) || attributes.type != NFSK_TYPE_FILE) success = 0;
        }
        CHECK(success && reparse_live_bytes == 0 && reparse_peak_bytes <= 65536,
              "repeated malformed reparse observation stays bounded and releases every returned buffer");
        /* Negative-control runs may have leaked upstream results; preserve
         * the failed assertion, then release only harness-observed pointers. */
        for (unsigned slot = 0; slot < 128; slot++)
            if (reparse_buffers[slot]) nfsk_test_reparse_free(reparse_buffers[slot]);
    }
}

static void verify_metadata_classification(ntfs_fskit_volume *v) {
    special_fixture *fixtures[] = { &special_fixtures[0], &metadata_regular };
    const int errors[] = { EIO, ENXIO, ENOMEM, 0, 0 };
    for (unsigned item = 0; item < 2; item++) {
        special_fixture *fixture = fixtures[item];
        nfsk_attr_t before, after;
        require_fixture(nfsk_getattr(v, fixture->ino, &before) == 0, "metadata baseline");
        for (int flags = 0; flags < 2; flags++) {
            nfsk_metadata_t allowed = { .valid = NFSK_SET_MTIME | (flags ? NFSK_SET_FLAGS : 0),
                .flags = before.flags, .mtime_sec = 1100000000 + flags };
            arm_special_read(fixture);
            int result = nfsk_set_metadata(v, fixture->ino, &allowed);
            special_read_armed = 0;
            CHECK(result == 0 && special_read_hits == 0 && nfsk_getattr(v, fixture->ino, &before) == 0 &&
                  before.mtime_sec == allowed.mtime_sec,
                  "timestamp-only and unchanged-hidden requests need no special-type read");
        }
        metadata_preserved[item] = before;
        for (unsigned fault = 0; fault < sizeof errors / sizeof errors[0]; fault++) {
            for (int mixed = 0; mixed < 2; mixed++) {
                require_fixture(nfsk_getattr(v, fixture->ino, &before) == 0, "metadata fault baseline");
                nfsk_metadata_t request = { .valid = NFSK_SET_FLAGS |
                        (mixed ? NFSK_SET_MTIME | NFSK_SET_ATIME | NFSK_SET_BTIME : 0),
                    .flags = before.flags ^ UF_HIDDEN,
                    .mtime_sec = 1200000000 + fault, .atime_sec = 1200000100 + fault,
                    .btime_sec = 1200000200 + fault };
                special_read_errno = errors[fault]; special_short_prefix = fault == 4;
                arm_special_read(fixture);
                int result = nfsk_set_metadata(v, fixture->ino, &request);
                special_read_armed = 0;
                printf("METADATA CLASSIFICATION: %s fault=%u mixed=%d result=%d hits=%d writes=%d\n",
                       fixture->name, fault, mixed, result, special_read_hits, block_write_calls);
                CHECK(result == -(errors[fault] ? errors[fault] : EIO) && special_read_hits == 1 && block_write_calls == 0,
                      "metadata rejects a classification read failure before flags or timestamp writes");
                CHECK(nfsk_sync(v) == 0 && nfsk_getattr(v, fixture->ino, &after) == 0 &&
                      !memcmp(&before, &after, sizeof after),
                      "failed metadata classification leaves every field unchanged and sync clean");
            }
        }
        require_fixture(nfsk_getattr(v, fixture->ino, &before) == 0, "metadata close-fault baseline");
        nfsk_metadata_t request = { .valid = NFSK_SET_FLAGS, .flags = before.flags ^ UF_HIDDEN };
        special_read_errno = ENXIO; arm_special_read(fixture); close_countdown = 1;
        int result = nfsk_set_metadata(v, fixture->ino, &request);
        special_read_armed = 0;
        CHECK(result == -ENXIO && special_read_hits == 1 && block_write_calls == 0,
              "metadata classification error precedes secondary inode-close failure");
        CHECK(nfsk_sync(v) == -EIO && nfsk_sync(v) == 0 && nfsk_getattr(v, fixture->ino, &after) == 0 &&
              !memcmp(&before, &after, sizeof after),
              "secondary close retry preserves all metadata after a failed classification");
        block_write_calls = 0;
        result = nfsk_set_metadata(v, fixture->ino, &request);
        if (!item) {
            CHECK(result == -ENOTSUP && block_write_calls == 0,
                  "retry without a read fault still protects Interix hidden transitions");
        } else {
            CHECK(result == 0 && nfsk_getattr(v, fixture->ino, &metadata_preserved[item]) == 0 &&
                  metadata_preserved[item].flags == request.flags && metadata_preserved[item].type == NFSK_TYPE_FILE,
                  "ordinary SYSTEM file hidden transition remains allowed after read recovery");
            metadata_regular.flags ^= FILE_ATTR_HIDDEN;
        }
    }
    special_read_errno = EIO;
}

static int native_time_matches(ntfs_time value, int64_t seconds, int64_t nanoseconds) {
    struct timespec time = ntfs2timespec(value);
    return time.tv_sec == seconds && time.tv_nsec == nanoseconds;
}

static void arm_classify_fault(special_fixture *fixture, int error, int countdown) {
    classify_fault_ino = fixture->ino; classify_errno = error;
    classify_countdown = countdown; classify_hits = special_published = 0;
    block_write_calls = 0;
}

static void verify_interix_open_errors(ntfs_fskit_volume *v) {
    special_fixture *fixtures[] = { &special_fixtures[0], &metadata_regular };
    const int errors[] = { ENOMEM, EIO, ENXIO };
    for (unsigned item = 0; item < 2; item++) {
        special_fixture *fixture = fixtures[item];
        nfsk_attr_t before, after;
        require_fixture(nfsk_getattr(v, fixture->ino, &before) == 0, "open-error attribute baseline");
        for (unsigned fault = 0; fault < sizeof errors / sizeof errors[0]; fault++) {
            for (int operation = 0; operation < 8; operation++) {
                char target[1024]; memset(target, '!', sizeof target);
                char *owned = NULL;
                int64_t region = -99, result = 0;
                nfsk_metadata_t metadata = { .valid = NFSK_SET_FLAGS, .flags = before.flags ^ UF_HIDDEN };
                arm_classify_fault(fixture, errors[fault], 1);
                switch (operation) {
                    case 0: result = nfsk_getattr(v, fixture->ino, &after); break;
                    case 1: result = nfsk_readdir(v, fixture->directory, 0, fixture, special_name_callback); break;
                    case 2: result = nfsk_readdir_attributes(v, fixture->directory, 0, fixture, special_attr_callback); break;
                    case 3: result = nfsk_readlink(v, fixture->ino, target, sizeof target); break;
                    case 4: result = nfsk_readlink_alloc(v, fixture->ino, &owned, sizeof target); break;
                    case 5: result = nfsk_seek_region(v, fixture->ino, 0, true, &region); break;
                    case 6: result = nfsk_preallocate(v, fixture->ino, 0, 0, false); break;
                    case 7: result = nfsk_set_metadata(v, fixture->ino, &metadata); break;
                }
                printf("INTERIX OPEN: %s errno=%d op=%d result=%lld hits=%d writes=%d published=%d\n",
                       fixture->name, errors[fault], operation, (long long)result,
                       classify_hits, block_write_calls, special_published);
                CHECK(result == -errors[fault] && classify_hits == 1 && block_write_calls == 0 &&
                      special_published == 0 && target[0] == '!' && !owned && region == -99,
                      "Interix attribute-open error cannot publish a type, target or successful operation");
                nfsk_test_free(owned); classify_fault_ino = UINT64_MAX; classify_countdown = 0;
                CHECK(nfsk_sync(v) == 0 && nfsk_getattr(v, fixture->ino, &after) == 0 &&
                      !memcmp(&before, &after, sizeof after),
                      "classification open failure has clean sync and complete unchanged retry");
            }
        }
        for (int missing = 0; missing < 2; missing++) {
            int error = missing ? ENOENT : 0;
            arm_classify_fault(fixture, error, 1);
            CHECK(nfsk_getattr(v, fixture->ino, &after) == 0 && after.type == NFSK_TYPE_FILE && classify_hits == 1,
                  "UNKNOWN with missing DATA or no errno keeps the established opaque-file fallback");
            arm_classify_fault(fixture, error, 1);
            nfsk_metadata_t metadata = { .valid = NFSK_SET_FLAGS, .flags = before.flags ^ UF_HIDDEN };
            CHECK(nfsk_set_metadata(v, fixture->ino, &metadata) == -ENOTSUP && classify_hits == 1 && !block_write_calls,
                  "opaque classification still cannot authorize a hidden transition");
            arm_classify_fault(fixture, error, 1);
            char target[1024]; memset(target, '!', sizeof target);
            CHECK(nfsk_readlink(v, fixture->ino, target, sizeof target) == -EINVAL && classify_hits == 1 && target[0] == '!',
                  "missing or unspecified classifier result retains invalid-link behavior");
        }
        classify_fault_ino = UINT64_MAX; classify_countdown = 0;
        classify_success_errno = ENOMEM;
        CHECK(nfsk_getattr(v, fixture->ino, &after) == 0 && !memcmp(&before, &after, sizeof after),
              "positive Interix classification remains valid despite a stale errno");
    }

    special_fixture *fixture = &special_fixtures[0];
    nfsk_attr_t before, after;
    require_fixture(nfsk_getattr(v, fixture->ino, &before) == 0, "target-open attribute baseline");
    for (unsigned fault = 0; fault < sizeof errors / sizeof errors[0]; fault++) {
        arm_classify_fault(fixture, errors[fault], 2);
        CHECK(nfsk_getattr(v, fixture->ino, &after) == -errors[fault] && classify_hits == 1 && !block_write_calls,
              "second Interix classifier failure survives target parsing into attributes");
        classify_fault_ino = UINT64_MAX; classify_countdown = 0;
        for (int operation = 0; operation < 3; operation++) {
            target_open_fault_ino = fixture->ino; target_open_errno = errors[fault]; target_open_hits = 0;
            block_write_calls = 0;
            char target[1024]; memset(target, '!', sizeof target); char *owned = NULL;
            int result = operation == 0 ? nfsk_getattr(v, fixture->ino, &after) :
                         operation == 1 ? nfsk_readlink(v, fixture->ino, target, sizeof target) :
                                          nfsk_readlink_alloc(v, fixture->ino, &owned, sizeof target);
            CHECK(result == -errors[fault] && target_open_hits == 1 && !block_write_calls && !owned && target[0] == '!',
                  "target DATA-open failure remains an operation error with no published output");
            nfsk_test_free(owned); target_open_fault_ino = UINT64_MAX;
            CHECK(nfsk_sync(v) == 0 && nfsk_getattr(v, fixture->ino, &after) == 0 &&
                  !memcmp(&before, &after, sizeof after), "failed target DATA open stays retryable without metadata changes");
        }
    }
    for (int source = 0; source < 2; source++) {
        if (!source) arm_classify_fault(fixture, ENXIO, 2);
        else { target_open_fault_ino = fixture->ino; target_open_errno = ENXIO; target_open_hits = 0; }
        close_countdown = 1;
        CHECK(nfsk_getattr(v, fixture->ino, &after) == -ENXIO &&
              (source ? target_open_hits : classify_hits) == 1,
              "target classification/open error precedes secondary close failure");
        classify_fault_ino = target_open_fault_ino = UINT64_MAX; classify_countdown = 0;
        CHECK(nfsk_sync(v) == -EIO && nfsk_sync(v) == 0 && nfsk_getattr(v, fixture->ino, &after) == 0 &&
              !memcmp(&before, &after, sizeof after), "target-open close failure retains ownership and exact retry attributes");
    }
    target_open_fault_ino = fixture->ino; target_open_errno = ENOENT; target_open_hits = 0;
    CHECK(nfsk_getattr(v, fixture->ino, &after) == 0 && after.type == NFSK_TYPE_FILE && target_open_hits == 1,
          "missing target DATA retains the prior opaque attribute fallback");
    target_open_fault_ino = UINT64_MAX;

    for (int operation = 0; operation < 3; operation++) {
        target_open_fault_ino = fixture->ino; target_open_errno = 0; target_open_hits = 0;
        char target[1024]; memset(target, '!', sizeof target); char *owned = NULL;
        int result = operation == 0 ? nfsk_getattr(v, fixture->ino, &after) :
                     operation == 1 ? nfsk_readlink(v, fixture->ino, target, sizeof target) :
                                      nfsk_readlink_alloc(v, fixture->ino, &owned, sizeof target);
        CHECK(result == -EIO && target_open_hits == 1 && target[0] == '!' && !owned,
              "failed target DATA open without errno reports EIO consistently to attributes and readlink");
        nfsk_test_free(owned); target_open_fault_ino = UINT64_MAX;
    }

    /* Last operation: the old classifier destroys this disposable target. The
     * independent native reopen below checks its complete saved payload. */
    arm_classify_fault(fixture, ENOMEM, 1);
    int result = nfsk_truncate(v, fixture->ino, 1);
    printf("INTERIX OPEN TRUNCATE: result=%d hits=%d writes=%d\n", result, classify_hits, block_write_calls);
    CHECK(result == -ENOMEM && classify_hits == 1 && !block_write_calls,
          "allocation failure cannot authorize truncating a symlink's raw DATA");
    classify_fault_ino = UINT64_MAX; classify_countdown = 0;
    CHECK(nfsk_sync(v) == 0, "classification allocation failure does not poison sync");
}

static void verify_special_read_reopen(const char *path) {
    ntfs_volume *volume = ntfs_mount(path, NTFS_MNT_RDONLY | NTFS_MNT_FORENSIC);
    require_fixture(volume != NULL, "special read-only observer");
    for (int i = 0; i < 3; i++) {
        special_fixture *fixture = i == 2 ? &metadata_regular : &special_fixtures[i];
        ntfs_inode *file = ntfs_inode_open(volume, fixture->ino);
        require_fixture(file != NULL, "reopen special inode");
        ntfs_attr *attribute = ntfs_attr_open(file, fixture->attribute, AT_UNNAMED, 0);
        unsigned char bytes[sizeof fixture->bytes];
        CHECK(attribute && attribute->data_size == fixture->size &&
              ntfs_attr_pread(attribute, 0, fixture->size, bytes) == fixture->size &&
              !memcmp(bytes, fixture->bytes, (size_t)fixture->size),
              "read-only reopen preserves all special-file payload bytes and length");
        if (attribute) ntfs_attr_close(attribute);
        if (i != 1) {
            nfsk_attr_t *expected = &metadata_preserved[i == 2];
            CHECK(file->flags == fixture->flags &&
                  native_time_matches(file->last_data_change_time, expected->mtime_sec, expected->mtime_nsec) &&
                  native_time_matches(file->last_access_time, expected->atime_sec, expected->atime_nsec) &&
                  native_time_matches(file->creation_time, expected->btime_sec, expected->btime_nsec) &&
                  native_time_matches(file->last_mft_change_time, expected->ctime_sec, expected->ctime_nsec),
                  "native read-only reopen preserves all flags and timestamps across rejected metadata changes");
        }
        require_fixture(ntfs_inode_close(file) == 0, "close special read-only inode");
    }
    require_fixture(ntfs_umount(volume, FALSE) == 0, "close special read-only observer");
}

static void arm_reparse_query(uint64_t ino, int error) {
    reparse_fault_ino = ino; reparse_fault_errno = error;
    reparse_fault_hits = special_published = block_write_calls = 0;
}

static void verify_reparse_query_errors(ntfs_fskit_volume *v, const char *path) {
    special_fixture windows = { .name = "WindowsRelative", .ino = windows_relative,
                                .directory = special_fixtures[1].directory };
    special_fixture *fixtures[] = { &special_fixtures[1], &windows };
    const int errors[] = { EIO, ENXIO, ENOMEM };
    for (unsigned item = 0; item < sizeof fixtures / sizeof fixtures[0]; item++) {
        special_fixture *fixture = fixtures[item];
        nfsk_attr_t before, after;
        require_fixture(nfsk_sync(v) == 0 && nfsk_getattr(v, fixture->ino, &before) == 0 &&
                        before.type == NFSK_TYPE_SYMLINK, "reparse-query baseline");
        ntfs_inode *file = ntfs_inode_open(observed_volume, fixture->ino);
        require_fixture(file != NULL, "native reparse-query observation");
        s64 saved_size = 0;
        void *saved = ntfs_attr_readall(file, AT_REPARSE_POINT, NULL, 0, &saved_size);
        FILE_ATTR_FLAGS saved_flags = file->flags;
        require_fixture(saved && saved_size > 0 && saved_size <= 65536, "save reparse payload");
        for (unsigned fault = 0; fault < sizeof errors / sizeof errors[0]; fault++) {
            arm_reparse_query(fixture->ino, errors[fault]);
            // Exercise the unchanged upstream validator, not a replacement result.
            REPARSE_POINT *point = ntfs_get_reparse_point(file);
            int observed = errno;
            printf("REPARSE PRODUCER: %s error=%d observed=%d hits=%d\n",
                   fixture->name, errors[fault], observed, reparse_fault_hits);
            CHECK(!point && observed == errors[fault] && reparse_fault_hits == 1 && !reparse_live_bytes,
                  "upstream reparse validator preserves readall query errors");
            nfsk_test_reparse_free(point);
        }
        require_fixture(ntfs_inode_close(file) == 0, "close native reparse-query observation");

        for (unsigned fault = 0; fault < sizeof errors / sizeof errors[0]; fault++) {
            for (int operation = 0; operation < 8; operation++) {
                char target[1024]; memset(target, '!', sizeof target);
                char *owned = NULL;
                int64_t region = -99, result = 0;
                arm_reparse_query(fixture->ino, errors[fault]);
                switch (operation) {
                    case 0: result = nfsk_getattr(v, fixture->ino, &after); break;
                    case 1: result = nfsk_readdir(v, fixture->directory, 0, fixture, special_name_callback); break;
                    case 2: result = nfsk_readdir_attributes(v, fixture->directory, 0, fixture, special_attr_callback); break;
                    case 3: result = nfsk_readlink(v, fixture->ino, target, sizeof target); break;
                    case 4: result = nfsk_readlink_alloc(v, fixture->ino, &owned, sizeof target); break;
                    case 5: result = nfsk_seek_region(v, fixture->ino, 0, true, &region); break;
                    case 6: result = nfsk_preallocate(v, fixture->ino, 0, 1, false); break;
                    case 7: result = nfsk_truncate(v, fixture->ino, 1); break;
                }
                printf("REPARSE QUERY: %s error=%d op=%d result=%lld hits=%d writes=%d published=%d\n",
                       fixture->name, errors[fault], operation, (long long)result,
                       reparse_fault_hits, block_write_calls, special_published);
                CHECK(result == -errors[fault] && reparse_fault_hits == 1 && !block_write_calls &&
                      !special_published && !reparse_live_bytes && !owned && target[0] == '!' && region == -99,
                      "reparse query failure propagates without publication, writes or retained buffers");
                nfsk_test_free(owned);
                reparse_fault_ino = UINT64_MAX;
            }
            CHECK(nfsk_sync(v) == 0 && nfsk_getattr(v, fixture->ino, &after) == 0 &&
                  !memcmp(&before, &after, sizeof after) && !reparse_live_bytes,
                  "reparse query errors allow clean sync and unchanged complete attribute retry");
        }

        const int opaque_errors[] = { ENOENT, EINVAL, EOVERFLOW, EOPNOTSUPP };
        for (unsigned fault = 0; fault < sizeof opaque_errors / sizeof opaque_errors[0]; fault++) {
            arm_reparse_query(fixture->ino, opaque_errors[fault]);
            CHECK(nfsk_getattr(v, fixture->ino, &after) == 0 && after.type == NFSK_TYPE_FILE &&
                  reparse_fault_hits == 1 && !block_write_calls && !reparse_live_bytes,
                  "missing, invalid, oversized and unsupported reparse data retain opaque fallback");
            char *owned = NULL;
            arm_reparse_query(fixture->ino, opaque_errors[fault]);
            CHECK(nfsk_readlink_alloc(v, fixture->ino, &owned, 1024) == -opaque_errors[fault] &&
                  !owned && reparse_fault_hits == 1 && !reparse_live_bytes,
                  "opaque reparse readlink retains its original error without an owned target");
            nfsk_test_free(owned);
        }
        reparse_success_errno = ENOMEM;
        CHECK(nfsk_getattr(v, fixture->ino, &after) == 0 && !memcmp(&before, &after, sizeof after) &&
              !reparse_success_errno && !reparse_live_bytes,
              "successful reparse validation ignores stale errno");
        arm_reparse_query(fixture->ino, 0);
        CHECK(nfsk_getattr(v, fixture->ino, &after) == -EIO && reparse_fault_hits == 1,
              "reparse query failure without errno becomes EIO");
        char *owned = NULL;
        arm_reparse_query(fixture->ino, 0);
        CHECK(nfsk_readlink_alloc(v, fixture->ino, &owned, 1024) == -EIO && !owned && reparse_fault_hits == 1,
              "reparse readlink failure without errno has consistent EIO and NULL output");
        nfsk_test_free(owned);
        arm_reparse_query(fixture->ino, ENXIO); close_countdown = 1;
        CHECK(nfsk_getattr(v, fixture->ino, &after) == -ENXIO && reparse_fault_hits == 1 && close_countdown == 0,
              "reparse query error precedes a secondary final-close error");
        CHECK(nfsk_sync(v) == -EIO && nfsk_sync(v) == 0 &&
              nfsk_getattr(v, fixture->ino, &after) == 0 && !memcmp(&before, &after, sizeof after),
              "reparse close failure retains ownership and retries without attribute changes");

        ntfs_volume *fresh = ntfs_mount(path, NTFS_MNT_RDONLY | NTFS_MNT_FORENSIC);
        file = fresh ? ntfs_inode_open(fresh, fixture->ino) : NULL;
        require_fixture(file != NULL, "native reparse-query reopen");
        s64 actual_size = 0;
        void *actual = ntfs_attr_readall(file, AT_REPARSE_POINT, NULL, 0, &actual_size);
        CHECK(actual && actual_size == saved_size && !memcmp(actual, saved, (size_t)saved_size) &&
              file->flags == saved_flags &&
              native_time_matches(file->last_data_change_time, before.mtime_sec, before.mtime_nsec) &&
              native_time_matches(file->last_access_time, before.atime_sec, before.atime_nsec) &&
              native_time_matches(file->creation_time, before.btime_sec, before.btime_nsec) &&
              native_time_matches(file->last_mft_change_time, before.ctime_sec, before.ctime_nsec),
              "native read-only reopen preserves reparse payload, flags and every timestamp");
        free(actual); free(saved);
        require_fixture(ntfs_inode_close(file) == 0 && ntfs_umount(fresh, FALSE) == 0,
                        "close reparse-query observer");
    }
}

static int count_native_children(void *opaque, const ntfschar *name, const int length,
        const int name_type, const s64 position, const MFT_REF reference, const unsigned type) {
    (void)name; (void)length; (void)name_type; (void)reference; (void)type;
    // Only positions 0/1 are synthetic dots. A literal on-disk dot must count.
    if (position < 2) return 0;
    (*(int *)opaque)++;
    return 0;
}

typedef struct {
    char input[2400], output[2400];
    ntfschar literal[256];
    int length;
} bom_namespace_name;

static bom_namespace_name bom_namespace_case(int index) {
    bom_namespace_name name = {0};
    int boms = index == 1 || index == 3 ? 2 : 1;
    for (int i = 0; i < boms; i++) {
        strcat(name.input, "\xef\xbb\xbf"); strcat(name.output, "\xef\xbb\xbf");
        name.literal[name.length++] = const_cpu_to_le16(0xfeff);
    }
    const char *suffix = index == 2 || index == 3 ? "Alpha" :
                         index == 4 ? "e\xcc\x81" : index == 5 ? "." : index == 6 ? ".." : "";
    strcat(name.input, suffix); strcat(name.output, suffix);
    if (index == 4) name.literal[name.length++] = const_cpu_to_le16(0xe9);
    else for (const unsigned char *p = (const unsigned char *)suffix; *p; p++)
        name.literal[name.length++] = cpu_to_le16(*p);
    if (index == 7) for (int i = 0; i < 254; i++) {
        strcat(name.input, "\xea\xb0\x81");
        strcat(name.output, "\xe1\x84\x80\xe1\x85\xa1\xe1\x86\xa8");
        name.literal[name.length++] = const_cpu_to_le16(0xac01);
    }
    if (index == 8) for (int i = 0; i < 127; i++) {
        strcat(name.input, "\xf0\x9f\x98\x80"); strcat(name.output, "\xf0\x9f\x98\x80");
        name.literal[name.length++] = const_cpu_to_le16(0xd83d);
        name.literal[name.length++] = const_cpu_to_le16(0xde00);
    }
    return name;
}

/* These observers use literal UTF16 units, never the conversion under test. */
static uint64_t native_bom_find(ntfs_volume *volume, uint64_t parent, const ntfschar *name, int length) {
    ntfs_inode *dir = ntfs_inode_open(volume, parent);
    require_fixture(dir != NULL, "native BOM observer parent");
    u64 ref = ntfs_inode_lookup_by_name(dir, name, length);
    require_fixture(ntfs_inode_close(dir) == 0, "close native BOM observer parent");
    return ref == (u64)-1 ? 0 : MREF(ref);
}

static uint64_t native_bom_create(uint64_t parent, const ntfschar *name, int length) {
    ntfs_inode *dir = ntfs_inode_open(observed_volume, parent);
    ntfs_inode *file = dir ? ntfs_create(dir, const_cpu_to_le32(0), name, length, S_IFREG) : NULL;
    require_fixture(file != NULL, "literal native BOM fixture");
    uint64_t ino = file->mft_no;
    require_fixture(ntfs_inode_close_in_dir(file, dir) == 0 && ntfs_inode_close(dir) == 0,
                    "close literal native BOM fixture");
    return ino;
}

typedef struct { uint64_t ino; const char *expected; int seen, matching, stop; } bom_listing;
static int bom_list(void *opaque, const char *name, uint64_t ino, uint32_t type, int64_t cookie) {
    (void)type; (void)cookie;
    bom_listing *list = opaque;
    if (ino == list->ino) { list->seen++; list->matching += !strcmp(name, list->expected); }
    return list->stop;
}
static int bom_list_attributes(void *opaque, const char *name, const nfsk_attr_t *attributes, int64_t cookie) {
    return bom_list(opaque, name, attributes->ino, attributes->type, cookie);
}

static void namespace_bom_tests(ntfs_fskit_volume *v, const char *path) {
    int error = 0, initial_checks = checks, initial_failures = failures;
    uint64_t parent = nfsk_create(v, NFSK_ROOT_INO, "NamespaceBOM", NFSK_TYPE_DIR, &error);
    require_fixture(parent != 0, "BOM fixture parent");
    const char payload[] = "BOM source and neighbor remain independent.";
    const ntfschar source_name[] = { cpu_to_le16('S'), cpu_to_le16('o'), cpu_to_le16('u'),
        cpu_to_le16('r'), cpu_to_le16('c'), cpu_to_le16('e') };
    const ntfschar moved_name[] = { cpu_to_le16('M'), cpu_to_le16('o'), cpu_to_le16('v'),
        cpu_to_le16('e'), cpu_to_le16('d') };
    for (int index = 0; index < 9; index++) {
        bom_namespace_name name = bom_namespace_case(index);
        for (int operation = 0; operation < 8; operation++) {
            char label[40]; snprintf(label, sizeof label, "Case-%d-%d", index, operation);
            uint64_t dir = nfsk_create(v, parent, label, NFSK_TYPE_DIR, &error);
            uint64_t source = nfsk_create(v, dir, "Source", NFSK_TYPE_FILE, &error);
            require_fixture(dir && source && nfsk_write(v, source, 0, payload, sizeof payload, &error) == sizeof payload &&
                            nfsk_sync(v) == 0, "BOM source payload");
            int has_neighbor = name.length > 1 && index != 5 && index != 6;
            uint64_t neighbor = has_neighbor ? native_bom_create(dir, name.literal + 1, name.length - 1) : 0;
            uint64_t original = operation >= 5 ? native_bom_create(dir, name.literal, name.length) : 0;
            require_fixture((!neighbor || nfsk_write(v, neighbor, 0, payload, sizeof payload, &error) == sizeof payload) &&
                            (!original || nfsk_write(v, original, 0, payload, sizeof payload, &error) == sizeof payload) &&
                            nfsk_sync(v) == 0, "BOM independent native names");
            uint64_t result_ino = 0; int result = 0;
            block_write_calls = 0; error = 0;
            switch (operation) {
                case 0: case 1:
                    result_ino = nfsk_create(v, dir, name.input, operation ? NFSK_TYPE_DIR : NFSK_TYPE_FILE, &error);
                    result = result_ino ? 0 : -error; break;
                case 2:
                    result = nfsk_link(v, source, dir, name.input, &error); result_ino = source; break;
                case 3:
                    result_ino = nfsk_symlink(v, dir, name.input, "../Source", &error);
                    result = result_ino ? 0 : -error; break;
                case 4:
                    result = nfsk_rename(v, dir, "Source", dir, name.input); result_ino = source; break;
                case 5:
                    result = nfsk_rename(v, dir, name.input, dir, "Moved"); result_ino = original; break;
                case 6: result = nfsk_remove(v, dir, name.input); break;
                default:
                    result_ino = nfsk_lookup(v, dir, name.input, &error);
                    result = result_ino == original ? 0 : -(error ? error : EIO); break;
            }
            CHECK(result == 0, "BOM namespace operation addresses the literal component");
            printf("NAMESPACE BOM: case=%d op=%d result=%d writes=%d original=%llu result_ino=%llu\n",
                   index, operation, result, block_write_calls, (unsigned long long)original, (unsigned long long)result_ino);
            if (operation != 5 && operation != 6) {
                char *owned = NULL, small[3] = {'!', '!', '!'};
                uint64_t found = nfsk_lookup_name_alloc(v, dir, name.input, &owned, &error);
                CHECK(found && found == result_ino && owned && !strcmp(owned, name.output),
                      "BOM canonical lookup returns every prefix and complete NFD suffix");
                CHECK(!nfsk_lookup_name(v, dir, name.input, small, sizeof small, &error) && error == ENAMETOOLONG &&
                      small[0] == '!', "BOM canonical capacity includes literal prefix and leaves short output untouched");
                if (operation == 7) {
                    bom_listing plain = { .ino = original, .expected = name.output };
                    bom_listing attributes = plain;
                    CHECK(nfsk_readdir(v, dir, 0, &plain, bom_list) == 0 && plain.seen == 1 && plain.matching == 1 &&
                          nfsk_readdir_attributes(v, dir, 0, &attributes, bom_list_attributes) == 0 &&
                          attributes.seen == 1 && attributes.matching == 1,
                          "both directory callbacks preserve literal BOM and complete normalized spelling");
                    CHECK(owned && !strcmp(owned, name.output), "owned canonical bytes survive subsequent enumerations");
                }
                nfsk_test_free(owned);
            }
            if (operation == 3) {
                char target[32] = {0};
                CHECK(result_ino && nfsk_readlink(v, result_ino, target, sizeof target) == 0 && !strcmp(target, "../Source"),
                      "BOM symlink basename leaves ordinary target contents intact");
            }
            require_fixture(nfsk_sync(v) == 0, "sync BOM operation");
            ntfs_volume *fresh = ntfs_mount(path, NTFS_MNT_RDONLY | NTFS_MNT_FORENSIC);
            require_fixture(fresh != NULL, "native BOM reopen");
            uint64_t actual = native_bom_find(fresh, dir, name.literal, name.length);
            CHECK(operation == 5 || operation == 6 ? actual == 0 : actual && actual == result_ino,
                  "native reopen confirms exact UTF16 name identity after namespace operation");
            CHECK(!neighbor || native_bom_find(fresh, dir, name.literal + 1, name.length - 1) == neighbor,
                  "native reopen preserves the distinct one-BOM-shorter neighbor");
            CHECK(native_bom_find(fresh, dir, source_name, 6) == (operation == 4 ? 0 : source) &&
                  (operation != 5 || native_bom_find(fresh, dir, moved_name, 5) == original),
                  "native reopen verifies both rename source and destination identities");
            uint64_t preserved[] = { source, neighbor };
            for (int i = 0; i < 2; i++) if (preserved[i]) {
                ntfs_inode *file = ntfs_inode_open(fresh, preserved[i]);
                ntfs_attr *data = file ? ntfs_attr_open(file, AT_DATA, AT_UNNAMED, 0) : NULL;
                char bytes[sizeof payload];
                CHECK(data && data->data_size == sizeof payload && ntfs_attr_pread(data, 0, sizeof bytes, bytes) == sizeof bytes &&
                      !memcmp(bytes, payload, sizeof bytes), "native reopen preserves source and neighbor payload with exact EOF");
                if (data) ntfs_attr_close(data);
                if (file) require_fixture(ntfs_inode_close(file) == 0, "close BOM payload observer");
            }
            require_fixture(ntfs_umount(fresh, FALSE) == 0, "close native BOM reopen");
        }
    }
    uint64_t dir = nfsk_create(v, parent, "Faults", NFSK_TYPE_DIR, &error);
    require_fixture(dir && nfsk_sync(v) == 0, "BOM fault directory");
    bom_namespace_name name = bom_namespace_case(2);
    uint64_t ino = native_bom_create(dir, name.literal, name.length);
    require_fixture(nfsk_sync(v) == 0, "BOM fault fixture sync");
    for (int error_index = 0; error_index < 2; error_index++) {
        int expected = error_index ? ENOMEM : EILSEQ;
        char *owned = NULL;
        conversion_error = expected; conversion_frees = 0;
        CHECK(!nfsk_lookup_name_alloc(v, dir, name.input, &owned, &error) && !owned && error == expected &&
              conversion_frees == 1 && !conversion_partial, "BOM suffix conversion failure releases partial output and keeps errno");
        conversion_error = 0; nfsk_test_free(owned);
        bom_listing list = { .ino = ino, .expected = name.output };
        conversion_error = expected; conversion_frees = 0;
        CHECK(nfsk_readdir(v, dir, 0, &list, bom_list) == -expected && !list.seen &&
              conversion_frees == 1 && !conversion_partial, "BOM enumeration conversion failure publishes no partial name");
        conversion_error = 0;
    }
    malloc_countdown = 1; malloc_faults = block_write_calls = 0;
    CHECK(!nfsk_create(v, dir, "\xef\xbb\xbf" "New", NFSK_TYPE_FILE, &error) && error == ENOMEM &&
          malloc_faults == 1 && !block_write_calls, "BOM input allocation failure performs no namespace writes");
    malloc_countdown = 0;
    char *owned = NULL;
    malloc_countdown = 2; malloc_faults = 0;
    CHECK(!nfsk_lookup_name_alloc(v, dir, name.input, &owned, &error) && error == ENOMEM && !owned && malloc_faults == 1,
          "BOM final output allocation failure releases the normalized suffix");
    malloc_countdown = 0; nfsk_test_free(owned); owned = NULL;
    bom_listing list = { .ino = ino, .expected = name.output };
    malloc_countdown = 1; malloc_faults = 0;
    CHECK(nfsk_readdir_attributes(v, dir, 0, &list, bom_list_attributes) == -ENOMEM && !list.seen && malloc_faults == 1,
          "BOM enumeration output allocation failure publishes no entry");
    malloc_countdown = 0;
    close_countdown = 2;
    CHECK(!nfsk_lookup_name_alloc(v, dir, name.input, &owned, &error) && error == EIO && !owned && close_countdown == 0,
          "BOM owned canonical result is withheld on final inode-close failure");
    close_countdown = 0; nfsk_test_free(owned); owned = NULL;
    int sync_error = nfsk_sync(v), recovered = nfsk_sync(v);
    CHECK(sync_error == -EIO && recovered == 0 &&
          nfsk_lookup_name_alloc(v, dir, name.input, &owned, &error) == ino && owned && !strcmp(owned, name.output),
          "BOM final-close ownership recovers with complete literal output");
    nfsk_test_free(owned);
    char too_long[260] = "\xef\xbb\xbf"; memset(too_long + 3, 'L', 255); too_long[258] = 0;
    block_write_calls = 0;
    CHECK(!nfsk_create(v, dir, too_long, NFSK_TYPE_FILE, &error) && error == ENAMETOOLONG && !block_write_calls,
          "literal BOM counts toward the 255 UTF16-unit namespace limit");
    CHECK(!nfsk_create(v, dir, "\xef\xbb\xbf\xff", NFSK_TYPE_FILE, &error) && error == EILSEQ,
          "invalid UTF8 after BOM remains an encoding error");
    CHECK(nfsk_sync(v) == 0, "BOM namespace batch ends with clean synchronization");
    printf("NAMESPACE BOM SUMMARY: %d checks, %d failures\n", checks - initial_checks, failures - initial_failures);
}

static void namespace_component_tests(ntfs_fskit_volume *v, const char *path) {
    const char *invalid[] = { NULL, "", ".", "..", "/", "part/name", "part/", "/part" };
    const char payload[] = "Component rejection must preserve this payload.";
    int error = 0;
    uint64_t parent = nfsk_create(v, NFSK_ROOT_INO, "NameComponentBoundaries", NFSK_TYPE_DIR, &error);
    require_fixture(parent != 0, "component fixture parent");
    for (size_t index = 0; index < sizeof invalid / sizeof invalid[0]; index++) {
        for (int operation = 0; operation < 5; operation++) {
            char label[64]; snprintf(label, sizeof label, "Case-%zu-%d", index, operation);
            uint64_t directory = nfsk_create(v, parent, label, NFSK_TYPE_DIR, &error);
            uint64_t source = nfsk_create(v, directory, "Source.bin", NFSK_TYPE_FILE, &error);
            uint64_t sentinel = nfsk_create(v, directory, "Sentinel.bin", NFSK_TYPE_FILE, &error);
            require_fixture(directory && source && sentinel &&
                nfsk_write(v, source, 0, payload, sizeof payload, &error) == sizeof payload && nfsk_sync(v) == 0,
                "isolated component namespace and payload");
            nfsk_attr_t source_before, directory_before, sentinel_before, actual;
            require_fixture(nfsk_getattr(v, source, &source_before) == 0 &&
                nfsk_getattr(v, directory, &directory_before) == 0 &&
                nfsk_getattr(v, sentinel, &sentinel_before) == 0, "component attribute baseline");
            block_write_calls = 0; error = 0;
            int result;
            uint64_t created = 0;
            switch (operation) {
                case 0: case 1:
                    created = nfsk_create(v, directory, invalid[index], operation ? NFSK_TYPE_DIR : NFSK_TYPE_FILE, &error);
                    result = created ? 0 : -error; break;
                case 2:
                    result = nfsk_link(v, source, directory, invalid[index], &error) ? -error : 0; break;
                case 3:
                    result = nfsk_rename(v, directory, "Source.bin", directory, invalid[index]); break;
                default:
                    created = nfsk_symlink(v, directory, invalid[index], "../Source.bin", &error);
                    result = created ? 0 : -error; break;
            }
            int immediate_writes = block_write_calls;
            int synced = nfsk_sync(v);
            printf("NAME COMPONENT: case=%zu op=%d result=%d writes=%d synced_writes=%d created=%llu\n",
                   index, operation, result, immediate_writes, block_write_calls, (unsigned long long)created);
            CHECK(result == -EINVAL && block_write_calls == 0 && synced == 0,
                  "invalid destination component is rejected without immediate or deferred writes");
            CHECK(nfsk_getattr(v, source, &actual) == 0 && !memcmp(&source_before, &actual, sizeof actual) &&
                  nfsk_getattr(v, directory, &actual) == 0 && !memcmp(&directory_before, &actual, sizeof actual) &&
                  nfsk_getattr(v, sentinel, &actual) == 0 && !memcmp(&sentinel_before, &actual, sizeof actual),
                  "invalid component preserves source, sentinel and directory attributes");

            ntfs_volume *fresh = ntfs_mount(path, NTFS_MNT_RDONLY | NTFS_MNT_FORENSIC);
            ntfs_inode *dir = fresh ? ntfs_inode_open(fresh, directory) : NULL;
            require_fixture(dir != NULL, "native component namespace observer");
            ntfschar *unicode = NULL;
            int length = ntfs_mbstoucs("Source.bin", &unicode);
            require_fixture(length > 0, "native component source name");
            u64 source_ref = ntfs_inode_lookup_by_name(dir, unicode, length);
            free(unicode); unicode = NULL;
            length = ntfs_mbstoucs("Sentinel.bin", &unicode);
            require_fixture(length > 0, "native component sentinel name");
            u64 sentinel_ref = ntfs_inode_lookup_by_name(dir, unicode, length);
            free(unicode);
            int children = 0; s64 position = 0;
            int listed = ntfs_readdir(dir, &position, &children, count_native_children);
            printf("COMPONENT REOPEN: case=%zu op=%d source=%d sentinel=%d children=%d\n",
                   index, operation, source_ref != (u64)-1 && MREF(source_ref) == source,
                   sentinel_ref != (u64)-1 && MREF(sentinel_ref) == sentinel, children);
            CHECK(!listed && children == 2 && source_ref != (u64)-1 && MREF(source_ref) == source &&
                  sentinel_ref != (u64)-1 && MREF(sentinel_ref) == sentinel,
                  "native reopen retains original names without a literal dot or slash entry");
            ntfs_inode *file = ntfs_inode_open(fresh, source);
            ntfs_attr *data = file ? ntfs_attr_open(file, AT_DATA, AT_UNNAMED, 0) : NULL;
            char bytes[sizeof payload];
            CHECK(data && data->data_size == sizeof payload &&
                  ntfs_attr_pread(data, 0, sizeof bytes, bytes) == sizeof bytes && !memcmp(bytes, payload, sizeof bytes),
                  "native reopen preserves source payload after an invalid component");
            if (data) ntfs_attr_close(data);
            require_fixture(file && ntfs_inode_close(file) == 0 && ntfs_inode_close(dir) == 0 &&
                            ntfs_umount(fresh, FALSE) == 0, "close native component observer");
        }
    }

    const char *valid[] = { ".hidden", "...", "a:b", "a\\b", "part／name", " ", "win:*?\"<>|chars" };
    uint64_t from = nfsk_create(v, parent, "ValidSource", NFSK_TYPE_DIR, &error);
    uint64_t to = nfsk_create(v, parent, "ValidTarget", NFSK_TYPE_DIR, &error);
    require_fixture(from && to, "valid component directories");
    for (size_t i = 0; i < sizeof valid / sizeof valid[0]; i++) {
        uint64_t source = nfsk_create(v, from, valid[i], NFSK_TYPE_FILE, &error);
        CHECK(source && nfsk_link(v, source, to, valid[i], &error) == 0 &&
              nfsk_lookup(v, to, valid[i], &error) == source,
              "POSIX punctuation, dotted names and slash-like Unicode remain valid for create/link");
        CHECK(nfsk_remove(v, to, valid[i]) == 0 && nfsk_rename(v, from, valid[i], to, valid[i]) == 0 &&
              nfsk_sync(v) == 0 && nfsk_lookup(v, to, valid[i], &error) == source,
              "valid components retain literal lookup, removal and cross-directory rename");
        const char target[] = "../nested/./target";
        uint64_t link = nfsk_symlink(v, from, valid[i], target, &error);
        char result[sizeof target];
        CHECK(link && nfsk_readlink(v, link, result, sizeof result) == 0 && !strcmp(result, target),
              "symlink basename validation leaves slash and dot components in target paths intact");
    }

    // Foreign names must remain addressable for repair/removal. Only new names
    // use the component predicate; don't apply it to lookup/remove/rename source.
    for (int i = 2; i <= 5; i++) {
        require_fixture(nfsk_sync(v) == 0, "sync before native foreign-name fixture");
        ntfs_inode *dir = ntfs_inode_open(observed_volume, from);
        ntfschar *unicode = NULL;
        int length = ntfs_mbstoucs(invalid[i], &unicode);
        ntfs_inode *file = dir && length > 0 ? ntfs_create(dir, const_cpu_to_le32(0), unicode, length, S_IFREG) : NULL;
        free(unicode);
        require_fixture(file != NULL, "native foreign component fixture");
        uint64_t ino = file->mft_no;
        require_fixture(ntfs_inode_close(file) == 0 && ntfs_inode_close(dir) == 0, "close native foreign fixture");
        CHECK(nfsk_lookup(v, from, invalid[i], &error) == ino,
              "literal lookup can still address a foreign dot or slash name");
        if (i % 2) {
            CHECK(nfsk_rename(v, from, invalid[i], from, "Repaired.bin") == 0 &&
                  nfsk_lookup(v, from, "Repaired.bin", &error) == ino && nfsk_remove(v, from, "Repaired.bin") == 0,
                  "rename can repair a foreign source component using a valid destination");
        } else {
            CHECK(nfsk_remove(v, from, invalid[i]) == 0 && !nfsk_lookup(v, from, invalid[i], &error) && error == ENOENT,
                  "literal removal can still clean up a foreign dot or slash name");
        }
    }
    CHECK(nfsk_sync(v) == 0, "component controls finish with a clean sync");
}

static void namespace_length_tests(ntfs_fskit_volume *v, const char *path) {
    const char payload[] = "Namespace rejection must preserve the original file.";
    int error = 0;
    uint64_t parent = nfsk_create(v, NFSK_ROOT_INO, "NameLengthBoundaries", NFSK_TYPE_DIR, &error);
    require_fixture(parent != 0, "name-length fixture parent");
    uint64_t directory = 0;
    for (int encoding = 0; encoding < 3; encoding++) {
        for (int units = 256; units <= 257; units++) {
            char name[2400] = {0};
            if (encoding == 0) memset(name, 'L', (size_t)units);
            else if (encoding == 1) {
                // NFD Hangul normalizes to one UTF-16 unit per syllable.
                for (int i = 0; i < units; i++)
                    memcpy(name + i * 9, "\xe1\x84\x80\xe1\x85\xa1\xe1\x86\xa8", 9);
            } else {
                name[0] = 'E';
                for (int i = 0; i < (units - 1) / 2; i++) memcpy(name + 1 + i * 4, "\xf0\x9f\x98\x80", 4);
                if (!(units % 2)) strcat(name, "T");
            }
            ntfschar *unicode = NULL;
            int converted = ntfs_mbstoucs(name, &unicode);
            require_fixture(converted == units, "exact normalized UTF-16 input length");
            free(unicode);
            for (int operation = 0; operation < 6; operation++) {
                char label[64]; snprintf(label, sizeof label, "Case-%d-%d-%d", encoding, units, operation);
                directory = nfsk_create(v, parent, label, NFSK_TYPE_DIR, &error);
                uint64_t source = nfsk_create(v, directory, "Source.bin", NFSK_TYPE_FILE, &error);
                uint64_t sentinel = nfsk_create(v, directory, "Sentinel.bin", NFSK_TYPE_FILE, &error);
                require_fixture(directory && source && sentinel &&
                    nfsk_write(v, source, 0, payload, sizeof payload, &error) == sizeof payload && nfsk_sync(v) == 0,
                    "name-length isolated namespace and payload");
                nfsk_attr_t source_before, directory_before, actual;
                require_fixture(nfsk_getattr(v, source, &source_before) == 0 &&
                    nfsk_getattr(v, directory, &directory_before) == 0, "name-length attribute baseline");
                block_write_calls = 0; error = 0;
                int result;
                uint64_t created = 0;
                switch (operation) {
                    case 0: case 1:
                        created = nfsk_create(v, directory, name, operation ? NFSK_TYPE_DIR : NFSK_TYPE_FILE, &error);
                        result = created ? 0 : -error; break;
                    case 2:
                        result = nfsk_link(v, source, directory, name, &error) ? -error : 0; break;
                    case 3:
                        result = nfsk_rename(v, directory, "Source.bin", directory, name); break;
                    case 4:
                        created = nfsk_symlink(v, directory, name, "Source.bin", &error);
                        result = created ? 0 : -error; break;
                    default:
                        result = nfsk_rename(v, directory, name, directory, "Unused.bin"); break;
                }
                printf("NAME LENGTH: encoding=%d units=%d op=%d result=%d writes=%d created=%llu\n",
                       encoding, units, operation, result, block_write_calls, (unsigned long long)created);
                CHECK(result == -ENAMETOOLONG && block_write_calls == 0,
                      "overlong normalized filename is rejected before any namespace writes");
                CHECK(nfsk_sync(v) == 0 && nfsk_getattr(v, source, &actual) == 0 &&
                      !memcmp(&source_before, &actual, sizeof actual) &&
                      nfsk_getattr(v, directory, &actual) == 0 && !memcmp(&directory_before, &actual, sizeof actual),
                      "overlong namespace request preserves source and parent attributes with clean sync");

                ntfs_volume *fresh = ntfs_mount(path, NTFS_MNT_RDONLY | NTFS_MNT_FORENSIC);
                ntfs_inode *dir = fresh ? ntfs_inode_open(fresh, directory) : NULL;
                require_fixture(dir != NULL, "native name-length namespace observer");
                ntfschar source_name[] = { cpu_to_le16('S'), cpu_to_le16('o'), cpu_to_le16('u'), cpu_to_le16('r'),
                    cpu_to_le16('c'), cpu_to_le16('e'), cpu_to_le16('.'), cpu_to_le16('b'), cpu_to_le16('i'), cpu_to_le16('n') };
                ntfschar *sentinel_name = NULL;
                int sentinel_length = ntfs_mbstoucs("Sentinel.bin", &sentinel_name);
                require_fixture(sentinel_length > 0, "native sentinel name");
                u64 source_ref = ntfs_inode_lookup_by_name(dir, source_name, 10);
                u64 sentinel_ref = ntfs_inode_lookup_by_name(dir, sentinel_name, sentinel_length);
                free(sentinel_name);
                int children = 0; s64 position = 0;
                int listed = ntfs_readdir(dir, &position, &children, count_native_children);
                printf("NAME REOPEN: encoding=%d units=%d op=%d source=%d sentinel=%d children=%d\n",
                       encoding, units, operation, source_ref != (u64)-1 && MREF(source_ref) == source,
                       sentinel_ref != (u64)-1 && MREF(sentinel_ref) == sentinel, children);
                CHECK(!listed && children == 2 && source_ref != (u64)-1 && MREF(source_ref) == source &&
                      sentinel_ref != (u64)-1 && MREF(sentinel_ref) == sentinel,
                      "native reopen retains both original names without a truncated alias");
                ntfs_inode *file = ntfs_inode_open(fresh, source);
                ntfs_attr *data = file ? ntfs_attr_open(file, AT_DATA, AT_UNNAMED, 0) : NULL;
                char bytes[sizeof payload];
                CHECK(data && data->data_size == sizeof payload &&
                      ntfs_attr_pread(data, 0, sizeof bytes, bytes) == sizeof bytes && !memcmp(bytes, payload, sizeof bytes),
                      "native reopen preserves the source payload after an overlong request");
                if (data) ntfs_attr_close(data);
                require_fixture(file && ntfs_inode_close(file) == 0 && ntfs_inode_close(dir) == 0 &&
                                ntfs_umount(fresh, FALSE) == 0, "close native name-length observer");
            }
        }
    }
    char too_long[258]; memset(too_long, 'Z', 257); too_long[257] = 0;
    close_countdown = 1; error = 0;
    CHECK(!nfsk_create(v, directory, too_long, NFSK_TYPE_FILE, &error) &&
          error == ENAMETOOLONG && close_countdown == 0,
          "name-length validation error precedes secondary parent-close failure");
    CHECK(nfsk_sync(v) == -EIO && nfsk_sync(v) == 0 && !nfsk_lookup(v, directory, "Z", &error) && error == ENOENT,
          "name-length parent close retains retry ownership without creating an alias");
}

static void empty_metadata_tests(ntfs_fskit_volume *v, const char *path) {
    const char payload[] = "Empty metadata must preserve this payload.";
    int error = 0;
    uint64_t ino = nfsk_create(v, NFSK_ROOT_INO, "EmptyMetadata.bin", NFSK_TYPE_FILE, &error);
    require_fixture(ino && nfsk_write(v, ino, 0, payload, sizeof payload, &error) == sizeof payload &&
                    nfsk_sync(v) == 0, "empty metadata payload");
    // A fixed old ctime makes accidental updates observable without sleeping.
    struct timespec stamp = { .tv_sec = 1000000000, .tv_nsec = 123456700 };
    ntfs_inode *file = ntfs_inode_open(observed_volume, ino);
    require_fixture(file != NULL, "empty metadata timestamp fixture");
    file->last_mft_change_time = timespec2ntfs(stamp);
    NInoSetDirty(file); NInoFileNameSetDirty(file);
    require_fixture(ntfs_inode_close(file) == 0 && nfsk_sync(v) == 0, "persist old ctime");
    nfsk_attr_t before, after;
    require_fixture(nfsk_getattr(v, ino, &before) == 0 && before.ctime_sec == stamp.tv_sec &&
                    before.ctime_nsec == stamp.tv_nsec, "observe old ctime");
    // Unselected fields, including otherwise invalid values, are ignored.
    nfsk_metadata_t empty = { .mtime_sec = INT64_MIN, .mtime_nsec = -1,
                             .atime_nsec = 1000000000, .flags = UINT32_MAX };
    for (int legacy = 0; legacy < 2; legacy++) {
        block_write_calls = 0;
        int result = legacy ? nfsk_set_times(v, ino, INT64_MIN, -1, INT64_MIN, 1000000000) :
                              nfsk_set_metadata(v, ino, &empty);
        printf("EMPTY METADATA: legacy=%d result=%d writes=%d\n", legacy, result, block_write_calls);
        CHECK(result == 0 && block_write_calls == 0, "empty metadata succeeds without backend writes");
        CHECK(nfsk_getattr(v, ino, &after) == 0 && !memcmp(&before, &after, sizeof after),
              "empty metadata preserves every attribute including ctime");
        block_write_calls = block_sync_calls = 0;
        CHECK(nfsk_sync(v) == 0 && block_write_calls == 0 && block_sync_calls == 1,
              "sync after empty metadata still flushes without rewriting metadata");

        close_countdown = 1;
        result = legacy ? nfsk_set_times(v, ino, INT64_MIN, 0, INT64_MIN, 0) :
                          nfsk_set_metadata(v, ino, &empty);
        CHECK(result == -EIO && close_countdown == 0,
              "empty metadata still reports its final-close error");
        CHECK(nfsk_set_metadata(v, ino, &empty) == -EIO &&
              nfsk_set_times(v, ino, INT64_MIN, 0, INT64_MIN, 0) == -EIO,
              "empty metadata cannot bypass retained writeback-error admission");
        CHECK(nfsk_sync(v) == -EIO && nfsk_sync(v) == 0,
              "empty metadata close failure retries and reports its saved error once");
        CHECK(nfsk_getattr(v, ino, &after) == 0 && !memcmp(&before, &after, sizeof after),
              "empty metadata close recovery preserves all attributes");
    }

    ntfs_volume *fresh = ntfs_mount(path, NTFS_MNT_RDONLY | NTFS_MNT_FORENSIC);
    file = fresh ? ntfs_inode_open(fresh, ino) : NULL;
    require_fixture(file != NULL, "empty metadata read-only observer");
    CHECK(file->last_mft_change_time == timespec2ntfs(stamp) &&
          native_time_matches(file->last_data_change_time, before.mtime_sec, before.mtime_nsec) &&
          native_time_matches(file->last_access_time, before.atime_sec, before.atime_nsec) &&
          native_time_matches(file->creation_time, before.btime_sec, before.btime_nsec),
          "native read-only reopen preserves all timestamps after empty calls and close retry");
    ntfs_attr *data = ntfs_attr_open(file, AT_DATA, AT_UNNAMED, 0);
    char saved[sizeof payload];
    CHECK(data && data->data_size == sizeof payload &&
          ntfs_attr_pread(data, 0, sizeof saved, saved) == sizeof saved && !memcmp(saved, payload, sizeof saved),
          "native read-only reopen preserves the complete empty-metadata payload");
    if (data) ntfs_attr_close(data);
    require_fixture(ntfs_inode_close(file) == 0 && ntfs_umount(fresh, FALSE) == 0,
                    "close empty metadata observer");

    nfsk_attr_t root_before;
    require_fixture(nfsk_getattr(v, NFSK_ROOT_INO, &root_before) == 0, "empty metadata root baseline");
    block_write_calls = 0;
    CHECK(nfsk_set_metadata(v, NFSK_ROOT_INO, &empty) == 0 && block_write_calls == 0 &&
          nfsk_getattr(v, NFSK_ROOT_INO, &after) == 0 && !memcmp(&root_before, &after, sizeof after),
          "empty root metadata preserves attributes without writes");
    CHECK(nfsk_set_metadata(NULL, ino, &empty) == -EINVAL && nfsk_set_metadata(v, ino, NULL) == -EINVAL,
          "empty metadata retains volume and request validation");
    CHECK(nfsk_set_metadata(v, FILE_Bitmap, &empty) == -EPERM &&
          nfsk_set_times(v, FILE_Bitmap, INT64_MIN, 0, INT64_MIN, 0) == -EPERM,
          "empty metadata retains reserved-inode rejection");

    nfsk_metadata_t selected = { .valid = NFSK_SET_MTIME, .mtime_sec = before.mtime_sec,
                                .mtime_nsec = before.mtime_nsec };
    block_write_calls = 0;
    CHECK(nfsk_set_metadata(v, ino, &selected) == 0 && block_write_calls > 0 &&
          nfsk_getattr(v, ino, &after) == 0 && after.ctime_sec != stamp.tv_sec &&
          after.mtime_sec == before.mtime_sec && after.mtime_nsec == before.mtime_nsec,
          "explicitly selecting the same timestamp remains a ctime-updating request");
    require_fixture(nfsk_remove(v, NFSK_ROOT_INO, "EmptyMetadata.bin") == 0 && nfsk_sync(v) == 0,
                    "retire empty metadata fixture");
    int missing = nfsk_getattr(v, ino, &after);
    require_fixture(missing < 0, "missing metadata inode");
    block_write_calls = 0;
    CHECK(nfsk_set_metadata(v, ino, &empty) == missing &&
          nfsk_set_times(v, ino, INT64_MIN, 0, INT64_MIN, 0) == missing && !block_write_calls,
          "empty metadata still observes the missing-inode error without writes");
}

static void verify_statfs_counters(ntfs_fskit_volume *v, const nfsk_statfs_t *expected) {
    int reads = block_read_calls, writes = block_write_calls, flushes = block_sync_calls;
    int allocation_failures = malloc_faults;
    malloc_countdown = 1;
    nfsk_statfs_counters_t counters = {0};
    nfsk_statfs_t legacy = {0};
    CHECK(nfsk_statfs_counters(v, &counters) == 0 && nfsk_statfs(v, &legacy) == 0,
          "numeric and legacy statistics remain available without allocations");
    CHECK(counters.cluster_size == expected->cluster_size && counters.total_clusters == expected->total_clusters &&
          counters.free_clusters == expected->free_clusters && counters.total_files == expected->total_files &&
          counters.free_files == expected->free_files && counters.volume_serial == expected->volume_serial &&
          counters.read_only == expected->read_only,
          "numeric statistics preserve every legacy counter and the cached serial");
    CHECK(!memcmp(&legacy, expected, sizeof legacy), "legacy statistics retain their complete layout and label");
    unsigned char saved[sizeof counters];
    memcpy(saved, &counters, sizeof saved);
    CHECK(nfsk_statfs_counters(NULL, &counters) == -EINVAL && !memcmp(&counters, saved, sizeof saved) &&
          nfsk_statfs_counters(v, NULL) == -EINVAL,
          "invalid numeric statistics arguments fail without publishing a result");
    CHECK(nfsk_statfs(NULL, &legacy) == -EINVAL && !memcmp(&legacy, expected, sizeof legacy) &&
          nfsk_statfs(v, NULL) == -EINVAL,
          "legacy statistics retain invalid-argument behavior");
    CHECK(reads == block_read_calls && writes == block_write_calls && flushes == block_sync_calls &&
          malloc_countdown == 1 && malloc_faults == allocation_failures,
          "statistics queries perform no backend I/O, flush or bridge allocation");
    malloc_countdown = 0;
}

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "Usage: %s <disposable-NTFS-image>\n", argv[0]); return 2; }
    test_device device = { .fd = open(argv[1], O_RDWR) };
    struct stat sb;
    if (device.fd < 0 || fstat(device.fd, &sb) || !S_ISREG(sb.st_mode)) return 2;
    device.size = sb.st_size;
    prepare_special_read_fixtures(argv[1]);
    int error = 0;
    ntfs_fskit_volume *v = nfsk_mount(&device, false, &error);
    if (!v) { fprintf(stderr, "mount: %d\n", error); return 2; }
    nfsk_statfs_t initial, allocated, removed, remounted;
    CHECK(nfsk_statfs(v, &initial) == 0 && initial.free_clusters > initial.total_clusters / 2,
          "a mostly empty fixture reports real free clusters");
    CHECK(initial.free_files > 0 && initial.free_files <= initial.total_files,
          "free inode counts are initialized and bounded");
    verify_statfs_counters(v, &initial);
    uint64_t ino = nfsk_create(v, NFSK_ROOT_INO, "IssueSpace.bin", NFSK_TYPE_FILE, &error);
    char data[65536]; memset(data, 'a', sizeof data);
    CHECK(ino && nfsk_write(v, ino, 0, data, sizeof data, &error) == sizeof data, "allocate 64 KiB");
    CHECK(nfsk_statfs(v, &allocated) == 0 && allocated.free_clusters < initial.free_clusters,
          "allocation reduces free clusters");
    verify_statfs_counters(v, &allocated);
    CHECK(nfsk_remove(v, NFSK_ROOT_INO, "IssueSpace.bin") == 0, "remove allocated file");
    CHECK(nfsk_statfs(v, &removed) == 0 && removed.free_clusters > allocated.free_clusters,
          "deletion releases free clusters");
    verify_statfs_counters(v, &removed);

    ino = nfsk_create(v, NFSK_ROOT_INO, "MiXeDCaSe.txt", NFSK_TYPE_FILE, &error);
    CHECK(ino != 0, "create mixed-case name");
    nfsk_umount(v);
    v = nfsk_mount(&device, false, &error);
    if (!v) return 2;
    CHECK(nfsk_statfs(v, &remounted) == 0 && remounted.free_clusters == removed.free_clusters,
          "free space agrees after remount");
    verify_statfs_counters(v, &remounted);
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
    uint64_t meta_ino = nfsk_create(v, NFSK_ROOT_INO, "MetadataRecovery.bin", NFSK_TYPE_FILE, &error);
    nfsk_metadata_t metadata = { .valid = NFSK_SET_FLAGS | NFSK_SET_BTIME | NFSK_SET_MTIME | NFSK_SET_ATIME,
        .flags = UF_HIDDEN, .btime_sec = 946684800, .btime_nsec = 123456700,
        .mtime_sec = 946684801, .mtime_nsec = 234567800, .atime_sec = 946684802, .atime_nsec = 345678900 };
    fail_inode_sync = 1;
    CHECK(meta_ino && nfsk_set_metadata(v, meta_ino, &metadata) == -EIO,
          "combined native metadata reports close/sync failure");
    nfsk_attr_t recovered_metadata;
    CHECK(nfsk_getattr(v, meta_ino, &recovered_metadata) == -EIO,
          "failed metadata inode remains owned and guarded");
    fail_inode_sync = 0;
    CHECK(nfsk_sync(v) == -EIO && nfsk_sync(v) == 0,
          "metadata recovery reports the saved error once before clean sync");
    CHECK(nfsk_getattr(v, meta_ino, &recovered_metadata) == 0 && recovered_metadata.flags == UF_HIDDEN &&
          recovered_metadata.btime_sec == metadata.btime_sec && recovered_metadata.btime_nsec == metadata.btime_nsec &&
          recovered_metadata.mtime_sec == metadata.mtime_sec && recovered_metadata.mtime_nsec == metadata.mtime_nsec &&
          recovered_metadata.atime_sec == metadata.atime_sec && recovered_metadata.atime_nsec == metadata.atime_nsec,
          "recovered native metadata preserves flags and all explicit timestamp precision");
    CHECK(write_ino && nfsk_write(v, write_ino, 0, data, sizeof data, &error) == sizeof data,
          "prepare nonresident file for writeback fault");
    CHECK(nfsk_set_times(v, write_ino, 1000000000, 0, INT64_MIN, 0) == 0 && nfsk_sync(v) == 0,
          "persist an old mtime before injection");
    fail_close_writes = 1;
    error = 0;
    int64_t written = nfsk_write(v, write_ino, 0, "new payload", 11, &error);
    inode_sync_calls = block_sync_calls = 0;
    int sync_result = nfsk_sync(v);
    CHECK((written < 0 && error == EIO) || sync_result == -EIO,
          "inode-close EIO is observable through write or sync");
    CHECK(sync_result == -EIO, "sync cannot report success while writeback fails");
    CHECK(inode_sync_calls == 1 && block_sync_calls == 0,
          "failed inode retry stops before further metadata or device flushes");
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

    empty_metadata_tests(v, argv[1]);
    namespace_length_tests(v, argv[1]);
    namespace_component_tests(v, argv[1]);
    namespace_bom_tests(v, argv[1]);
    metadata_sync_tests(v, argv[1]);
    // The old clean-inode fault site is redundant work. Inject into genuinely
    // dirty metadata so the required failure/retry contract remains exercised.
    ntfs_inode_mark_dirty(observed_volume->lcnbmp_ni);
    fail_inode_sync = 1;
    inode_sync_calls = block_sync_calls = 0;
    CHECK(nfsk_sync(v) == -EIO && inode_sync_calls == 1 && block_sync_calls == 0,
          "metadata sync failure stops the attempt and skips the device flush");
    fail_inode_sync = 0;
    CHECK(nfsk_sync(v) == -EIO && nfsk_sync(v) == 0,
          "metadata recovery reports the saved error once, then succeeds");
    fail_block_sync = 1;
    block_sync_calls = 0;
    CHECK(nfsk_sync(v) == -EIO && block_sync_calls == 1,
          "device flush failure is returned without retrying in the same attempt");
    fail_block_sync = 0;
    CHECK(nfsk_sync(v) == -EIO && nfsk_sync(v) == 0,
          "device flush recovers without hiding the previous error");

    fail_close_writes = 1;
    error = 0;
    uint64_t created = nfsk_create(v, NFSK_ROOT_INO, "IssueCreateWriteback.txt", NFSK_TYPE_FILE, &error);
    CHECK(!created && error == EIO, "create surfaces inode and parent writeback failures");
    inode_sync_calls = block_sync_calls = 0;
    CHECK(nfsk_sync(v) == -EIO && inode_sync_calls == 1 && block_sync_calls == 0,
          "multiple dirty inodes remain owned when the first retry fails");
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

    CHECK(nfsk_set_times(v, write_ino, INT64_MIN, 0, 1000000000, 123456700) == 0 && nfsk_sync(v) == 0,
          "explicit access-time changes still synchronize");
    fail_all_writes = 1;
    block_write_calls = 0;
    error = 0;
    CHECK(nfsk_read(v, write_ino, 0, payload, 11, &error) == 11 &&
          nfsk_read(v, write_ino, 0, payload, 11, &error) == 11 &&
          nfsk_read(v, write_ino, INT64_MAX, payload, 1, &error) == 0 && block_write_calls == 0,
          "repeated reads and EOF never issue atime writes, even with failed writes");
    CHECK(nfsk_getattr(v, write_ino, &attributes) == 0 && attributes.atime_sec == 1000000000 &&
          attributes.atime_nsec == 123456700 && block_write_calls == 0,
          "read-only observation preserves explicitly set atime and does not latch write errors");
    fail_all_writes = 0;
    CHECK(nfsk_sync(v) == 0, "no optional read-atime error contaminates synchronization");

    /* The block adapter can reject a new workspace before I/O with ENOMEM.
     * Check that this error survives libntfs and does not corrupt already
     * accepted data or discard dirty metadata during a retryable failure. */
    char before_budget[4096], after_budget[4096];
    CHECK(nfsk_read(v, write_ino, 512, before_budget, sizeof before_budget, &error) == sizeof before_budget,
          "save existing payload before workspace exhaustion");
    injected_write_errno = ENOMEM; fail_all_writes = 1; error = 0;
    CHECK(nfsk_write(v, write_ino, 512, data, sizeof before_budget, &error) == -1 && error == ENOMEM,
          "backend workspace exhaustion reaches the write caller as ENOMEM");
    fail_all_writes = 0;
    int budget_recovery = nfsk_sync(v);
    CHECK((budget_recovery == 0 || budget_recovery == -ENOMEM) && nfsk_sync(v) == 0 &&
          nfsk_read(v, write_ino, 512, after_budget, sizeof after_budget, &error) == sizeof after_budget &&
          !memcmp(before_budget, after_budget, sizeof before_budget),
          "pre-write exhaustion preserves the old payload and permits recovery");
    fail_all_writes = 1;
    CHECK(nfsk_set_times(v, write_ino, 1000000002, 0, INT64_MIN, 0) == -ENOMEM,
          "metadata workspace exhaustion is reported while dirty inode ownership is retained");
    CHECK(nfsk_sync(v) == -ENOMEM, "sync cannot hide a still-exhausted metadata workspace");
    fail_all_writes = 0; injected_write_errno = EBUSY;
    CHECK(nfsk_sync(v) == -ENOMEM && nfsk_sync(v) == 0 &&
          nfsk_getattr(v, write_ino, &attributes) == 0 && attributes.mtime_sec == 1000000002,
          "released workspace permits dirty retry and reports the saved error once");

    verify_io_boundaries(v);

    fail_block_sync = 1;
    CHECK(nfsk_sync(v) == -EIO, "prepare a prior flush failure for final release");
    block_read_calls = block_write_calls = block_sync_calls = 0;
    CHECK(nfsk_umount(v) == -EIO && block_read_calls == 0 && block_write_calls == 0 && block_sync_calls == 0,
          "final release reports prior failure without any repeated backend I/O");
    fail_block_sync = 0;
    v = nfsk_mount(&device, false, &error);
    if (!v) return 2;
    fail_block_sync = 1;
    block_sync_calls = 0;
    CHECK(nfsk_umount(v) == -EIO && block_sync_calls == 1,
          "first failure during final release prevents repeated library and close flushes");
    fail_block_sync = 0;
    v = nfsk_mount(&device, false, &error);
    if (!v) return 2;

    fail_close_writes = 1;
    CHECK(nfsk_set_times(v, write_ino, 1000000001, 0, INT64_MIN, 0) == -EIO,
          "prepare a retained dirty inode for failed final release");
    block_read_calls = block_write_calls = block_sync_calls = 0;
    CHECK(nfsk_umount(v) == -EIO && block_read_calls == 0 && block_write_calls == 0 && block_sync_calls == 0,
          "final release frees retained dirty inodes without retrying an unavailable backend");
    fail_close_writes = 0;
    v = nfsk_mount(&device, false, &error);
    if (!v) return 2;

    verify_special_reads(v);
    verify_metadata_classification(v);
    verify_interix_open_errors(v);
    verify_reparse_query_errors(v, argv[1]);
    require_fixture(nfsk_sync(v) == 0 && nfsk_umount(v) == 0, "close special read-error volume");
    verify_special_read_reopen(argv[1]);
    v = nfsk_mount(&device, false, &error);
    require_fixture(v != NULL, "remount after special read-only observer");
    uint64_t hibernation = nfsk_create(v, NFSK_ROOT_INO, "hiberfil.sys", NFSK_TYPE_FILE, &error);
    memset(data, 0, 4096); memcpy(data, "hibr", 4);
    CHECK(hibernation && nfsk_write(v, hibernation, 0, data, 4096, &error) == 4096,
          "create synthetic hibernation fixture in disposable image");
    nfsk_umount(v);
    v = nfsk_mount(&device, false, &error);
    CHECK(v && nfsk_statfs(v, &remounted) == 0 && remounted.read_only,
          "C statistics expose the effective read-only fallback");
    if (v) verify_statfs_counters(v, &remounted);
    nfsk_metadata_t empty = {0};
    block_write_calls = 0;
    CHECK(v && nfsk_set_metadata(v, write_ino, &empty) == -EROFS &&
          nfsk_set_times(v, write_ino, INT64_MIN, 0, INT64_MIN, 0) == -EROFS && !block_write_calls,
          "empty metadata retains read-only rejection without writes");
    if (v) nfsk_umount(v);
    close(device.fd);
    printf("%d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
