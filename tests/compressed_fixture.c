/* Bounded ordinary-file fixture generator and bridge exerciser. Never OS mounts. */
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/resource.h>
#include <unistd.h>
#include <time.h>
#include <ntfs-3g/attrib.h>
#include <ntfs-3g/dir.h>
#include <ntfs-3g/inode.h>
#include <ntfs-3g/runlist.h>
#include <ntfs-3g/unistr.h>
#include <ntfs-3g/volume.h>
#include "ntfs_fskit.h"

enum { MAX_PAYLOAD = 1 << 20, MAX_IMAGE = 128 << 20 };
static int pclose_calls, inside_pclose, fail_pclose, fail_read, fail_write, fail_flush;
static int fail_after_pclose, fail_inode_sync, io_calls, pclose_reads, pclose_writes;
static int attrs_live, attrs_peak;
static int failed_pclose_write_attempts;
static ntfs_volume *observed_volume;
static int fail_one_byte, fail_close_after_zero;
static int inside_data_write, data_reads, data_writes, fail_data_read, fail_data_write;
static int data_read_injected, data_write_injected;
static int stop_after_data_fault;
static int closing_runlist_dirty;
static int pclose_fail_injected, read_injected, write_injected, flush_injected, metadata_injected;
static int fail_mapping_oom, mapping_oom_injected, mapping_calls;
static int allocation_reads, allocation_read_injected, fail_allocation_read;
static int truncate_calls, truncate_injected, fail_truncate;
static int backend_writes, data_write_calls, attr_add_calls, attr_rm_calls;
static FILE *write_trace;
static uint64_t trace_events, trace_payload;
static void require(int ok, const char *step);

/* Test-only write/flush transcript: bounded, host-endian 32-byte records,
 * followed by the bytes actually accepted by a successful pwrite. */
static void trace_result(uint64_t operation, int64_t offset, uint64_t count, int64_t result, const void *data) {
    if (!write_trace) return;
    int saved = errno;
    uint64_t bytes = operation == 1 && result > 0 ? (uint64_t)result : 0;
    uint64_t record[4] = {operation, (uint64_t)offset, count, (uint64_t)result};
    require(++trace_events <= 4096 && bytes <= count && bytes <= (64U << 20) &&
            trace_payload <= (64U << 20) - bytes,
            "bounded write trace");
    trace_payload += bytes;
    require(fwrite(record, sizeof record, 1, write_trace) == 1 &&
            (!bytes || fwrite(data, 1, bytes, write_trace) == bytes), "save write trace");
    errno = saved;
}

s64 nfsk_fixture_attr_pread(ntfs_attr *attr, s64 offset, s64 count, void *data) {
    if (attr->ni->mft_no == FILE_Bitmap) {
        allocation_reads++;
        if (fail_allocation_read) {
            int mode = fail_allocation_read;
            fail_allocation_read = 0;
            allocation_read_injected++;
            errno = mode == 2 ? ENOMEM : EIO;
            return mode == 3 ? 0 : -1;
        }
    }
    return ntfs_attr_pread(attr, offset, count, data);
}

int nfsk_fixture_attr_truncate(ntfs_attr *attr, const s64 size) {
    truncate_calls++;
    if (fail_truncate) {
        int mode = fail_truncate;
        fail_truncate = 0;
        truncate_injected++;
        if (mode == 3 && ntfs_attr_truncate(attr, size)) return -1;
        errno = mode == 2 ? ENOMEM : EIO;
        return -1;
    }
    return ntfs_attr_truncate(attr, size);
}

runlist_element *nfsk_fixture_mapping_pairs_decompress(const ntfs_volume *vol,
                                                      const ATTR_RECORD *attr, runlist_element *old) {
    mapping_calls++;
    if (fail_mapping_oom > 0 && --fail_mapping_oom == 0) {
        mapping_oom_injected++;
        errno = ENOMEM;
        return NULL;
    }
    return ntfs_mapping_pairs_decompress(vol, attr, old);
}

s64 nfsk_fixture_attr_pwrite(ntfs_attr *attr, s64 offset, s64 count, const void *data) {
    data_write_calls++;
    if (count == 1 && fail_one_byte) {
        int mode = fail_one_byte; fail_one_byte = 0;
        errno = mode == 1 ? ENOSPC : 0;
        return mode == 1 ? -1 : 0;
    }
    inside_data_write++;
    s64 result = ntfs_attr_pwrite(attr, offset, count, data);
    inside_data_write--;
    if (stop_after_data_fault && (data_read_injected || data_write_injected || result < count)) {
        int error = errno;
        printf("{\"stage\":\"upstream-pwrite-return\",\"result\":%lld,\"errno\":%d,"
               "\"offset\":%lld,\"count\":%lld,\"data_reads\":%d,\"data_writes\":%d,"
               "\"size\":%lld,\"initialized\":%lld,\"allocated\":%lld}\n",
               (long long)result, error, (long long)offset, (long long)count, data_reads, data_writes,
               (long long)attr->data_size, (long long)attr->initialized_size, (long long)attr->allocated_size);
        fflush(stdout);
        if (write_trace) require(!fflush(write_trace), "flush partial write trace");
        _Exit(0); /* Preserve the image before bridge retry/rollback/close. */
    }
    if (result == 1 && fail_close_after_zero) { fail_close_after_zero = 0; fail_inode_sync = 1; }
    return result;
}

ntfs_attr *nfsk_fixture_attr_open(ntfs_inode *ni, const ATTR_TYPES type, ntfschar *name, u32 length) {
    ntfs_attr *attr = ntfs_attr_open(ni, type, name, length);
    observed_volume = ni->vol;
    if (attr && ++attrs_live > attrs_peak) attrs_peak = attrs_live;
    return attr;
}
void nfsk_fixture_attr_close(ntfs_attr *attr) {
    if (attr) {
        closing_runlist_dirty = !!NAttrRunlistDirty(attr);
        attrs_live--;
    }
    ntfs_attr_close(attr);
}

int nfsk_fixture_attr_add(ntfs_inode *ni, ATTR_TYPES type, ntfschar *name,
                         u8 name_len, const u8 *value, s64 size) {
    attr_add_calls++;
    return ntfs_attr_add(ni, type, name, name_len, value, size);
}

int nfsk_fixture_attr_rm(ntfs_attr *attr) {
    attr_rm_calls++;
    return ntfs_attr_rm(attr);
}

/* Only bridge/backend translation units redirect calls; seed/read use libntfs directly. */
int nfsk_fixture_attr_pclose(ntfs_attr *attr) {
    pclose_calls++;
    if (fail_pclose) { fail_pclose--; pclose_fail_injected++; errno = EIO; return -1; }
    inside_pclose++;
    int writes = pclose_writes;
    int result = ntfs_attr_pclose(attr), saved = errno;
    inside_pclose--;
    if (result) failed_pclose_write_attempts = pclose_writes - writes;
    if (!result && fail_after_pclose) { fail_after_pclose = 0; fail_inode_sync = 1; }
    errno = saved;
    return result;
}
int nfsk_fixture_inode_sync(ntfs_inode *ni) {
    if (fail_inode_sync) { fail_inode_sync = 0; metadata_injected++; errno = EIO; return -1; }
    return ntfs_inode_sync(ni);
}
ssize_t nfsk_fixture_pread(int fd, void *buf, size_t count, off_t offset) {
    io_calls++;
    if (inside_pclose) {
        pclose_reads++;
        if (fail_read > 0 && --fail_read == 0) { read_injected++; errno = EIO; return -1; }
    }
    if (inside_data_write) {
        data_reads++;
        if (fail_data_read > 0 && --fail_data_read == 0) {
            data_read_injected++; errno = EIO; return -1;
        }
    }
    return pread(fd, buf, count, offset);
}
ssize_t nfsk_fixture_pwrite(int fd, const void *buf, size_t count, off_t offset) {
    io_calls++;
    backend_writes++;
    if (inside_pclose) {
        pclose_writes++;
        if (fail_write > 0 && --fail_write == 0) {
            write_injected++; errno = EIO; trace_result(1, offset, count, -1, NULL); return -1;
        }
    }
    if (inside_data_write) {
        data_writes++;
        if (fail_data_write > 0 && --fail_data_write == 0) {
            data_write_injected++; errno = EIO; trace_result(1, offset, count, -1, NULL); return -1;
        }
    }
    ssize_t result = pwrite(fd, buf, count, offset);
    trace_result(1, offset, count, result, buf);
    return result;
}
int nfsk_fixture_fsync(int fd) {
    io_calls++;
    if (fail_flush) { fail_flush = 0; flush_injected++; errno = EIO; trace_result(2, 0, 0, -1, NULL); return -1; }
    int result = fsync(fd);
    trace_result(2, 0, 0, result, NULL);
    return result;
}
static void require(int ok, const char *step) {
    if (!ok) { fprintf(stderr, "FAIL %s: %s\n", step, strerror(errno)); exit(2); }
}
static unsigned char *payload(const char *path, size_t *length) {
    struct stat st;
    int fd = open(path, O_RDONLY | O_NOFOLLOW);
    require(fd >= 0 && !fstat(fd, &st) && S_ISREG(st.st_mode) && st.st_size >= 0 &&
            st.st_size <= MAX_PAYLOAD, "bounded payload");
    *length = (size_t)st.st_size;
    unsigned char *data = malloc(*length + 1);
    require(data != NULL && read(fd, data, *length) == (ssize_t)*length, "read payload");
    close(fd);
    return data;
}
static ntfs_inode *file_inode(ntfs_volume *vol, const char *name) {
    ntfs_inode *dir = ntfs_inode_open(vol, FILE_root);
    require(dir != NULL, "root inode");
    ntfschar *wide = NULL;
    int length = ntfs_mbstoucs(name, &wide);
    require(length > 0, "name");
    MFT_REF ref = ntfs_inode_lookup_by_name(dir, wide, length);
    free(wide);
    require(!ntfs_inode_close(dir) && ref != (MFT_REF)-1, "lookup");
    ntfs_inode *ni = ntfs_inode_open(vol, ref);
    require(ni != NULL, "file inode");
    return ni;
}
static void library_action(int argc, char **argv) {
    const char *action = argv[1];
    int seed_plain = !strcmp(action, "seed-stream-plain");
    int seed_compressed = !strcmp(action, "seed-stream-compressed");
    int seed_named = !strcmp(action, "seed-stream") || seed_plain || seed_compressed;
    int truncate_named = !strcmp(action, "raw-truncate-stream");
    int read_named = !strcmp(action, "read-stream");
    int named = read_named || seed_named || truncate_named;
    int readonly = !strcmp(action, "read") || read_named;
    if (named) require(argc == (seed_named ? 7 : 6), "named stream args");
    if (seed_named) require(!strcmp(argv[6], "0") || !strcmp(argv[6], "1"), "seed close flag");
    ntfs_volume *vol = ntfs_mount(argv[2], readonly ? NTFS_MNT_RDONLY : 0);
    require(vol != NULL, "library open image");
    ntfs_inode *ni;
    if (!strcmp(action, "seed-directory")) {
        require(argc == 4, "seed directory args");
        ntfs_inode *dir = ntfs_inode_open(vol, FILE_root);
        require(dir != NULL, "seed directory root");
        ntfschar *name = NULL;
        int length = ntfs_mbstoucs(argv[3], &name);
        require(length > 0 && length <= NTFS_MAX_NAME_LEN, "seed directory name");
        ni = ntfs_create(dir, const_cpu_to_le32(0), name, length, S_IFDIR);
        free(name);
        require(ni != NULL && !ntfs_inode_close(dir), "seed directory create");
        ni->flags |= FILE_ATTR_COMPRESSED;
        NInoSetDirty(ni);
    } else if (!strcmp(action, "seed")) {
        require(argc == 7, "seed args");
        ntfs_inode *dir = ntfs_inode_open(vol, FILE_root);
        require(dir != NULL, "seed root");
        ntfschar *name = NULL;
        int length = ntfs_mbstoucs(argv[3], &name);
        require(length > 0, "seed name");
        ni = ntfs_create(dir, const_cpu_to_le32(0), name, length, S_IFREG);
        free(name);
        require(ni != NULL && !ntfs_inode_close(dir), "create");
        if (atoi(argv[5])) ni->flags |= FILE_ATTR_COMPRESSED;
        NInoSetDirty(ni);
        ntfs_attr *attr = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
        require(attr != NULL, "seed attr");
        size_t length_bytes;
        unsigned char *data = payload(argv[4], &length_bytes);
        if (length_bytes) require(ntfs_attr_pwrite(attr, 0, length_bytes, data) == (s64)length_bytes, "seed write");
        free(data);
        if (atoi(argv[6])) require(!ntfs_attr_pclose(attr), "seed pclose");
        ntfs_attr_close(attr);
    } else {
        require(readonly || seed_named || truncate_named ||
                !strcmp(action, "pclose") || !strcmp(action, "raw-truncate"), "library action");
        ni = file_inode(vol, argv[3]);
        ntfschar *stream_name = NULL;
        int stream_length = 0;
        if (named) {
            stream_length = ntfs_mbstoucs(argv[4], &stream_name);
            require(stream_length > 0 && stream_length <= 127, "bounded stream name");
        }
        FILE_ATTR_FLAGS original_flags = ni->flags;
        if (seed_plain) NVolClearCompression(vol);
        if (seed_compressed) ni->flags |= FILE_ATTR_COMPRESSED;
        if (seed_named)
            require(!ntfs_attr_add(ni, AT_DATA, stream_name, stream_length, NULL, 0), "new named attr");
        ntfs_attr *attr = ntfs_attr_open(ni, AT_DATA, named ? stream_name : AT_UNNAMED, stream_length);
        require(attr != NULL && attr->data_size >= 0 &&
                attr->data_size <= (readonly && !named ? 4 << 20 : MAX_PAYLOAD), "inspect attr");
        if (seed_named) {
            size_t bytes;
            unsigned char *data = payload(argv[5], &bytes);
            require(bytes <= NFSK_MAX_XATTR_SIZE, "bounded named seed");
            if (bytes) require(ntfs_attr_pwrite(attr, 0, bytes, data) == (s64)bytes, "named seed write");
            free(data);
            if (argv[6][0] == '1') require(!ntfs_attr_pclose(attr), "named seed close");
        }
        if (seed_compressed) ni->flags = original_flags;
        if (!strcmp(action, "pclose")) require(!ntfs_attr_pclose(attr), "explicit pclose");
        if (!strcmp(action, "raw-truncate") || truncate_named) {
            require(argc == (named ? 6 : 5), "raw truncate args");
            const char *text = argv[named ? 5 : 4];
            char *end = NULL;
            errno = 0;
            long long requested = strtoll(text, &end, 10);
            require(end != text && !*end && !errno && requested >= 0 && requested <= MAX_PAYLOAD,
                    "bounded truncate size");
            require(!ntfs_attr_truncate(attr, requested), "raw truncate");
        }
        if (readonly) {
            require(argc == (named ? 6 : 5), "read args");
            unsigned char data[65536];
            int fd = open(argv[named ? 5 : 4], O_WRONLY | O_CREAT | O_EXCL, 0600);
            require(fd >= 0, "new library readback");
            for (s64 offset = 0; offset < attr->data_size;) {
                s64 count = attr->data_size - offset;
                if (count > (s64)sizeof data) count = sizeof data;
                require(ntfs_attr_pread(attr, offset, count, data) == count, "library read");
                require(write(fd, data, count) == count, "save library bytes");
                offset += count;
            }
            require(!close(fd), "close library readback");
        }
        printf("{\"inode\":%llu,\"size\":%lld,\"initialized\":%lld,\"allocated\":%lld,"
               "\"compressed_size\":%lld,\"flags\":%u,\"unit\":%u,\"nonresident\":%d}\n",
               (unsigned long long)ni->mft_no, (long long)attr->data_size, (long long)attr->initialized_size,
               (long long)attr->allocated_size, (long long)attr->compressed_size,
               le16_to_cpu(attr->data_flags), attr->compression_block_size, !!NAttrNonResident(attr));
        ntfs_attr_close(attr);
        free(stream_name);
    }
    require(!ntfs_inode_close(ni), "library inode close");
    require(!ntfs_umount(vol, FALSE), "library close image");
}
static void bridge_action(int argc, char **argv) {
    require(argc >= 6, "bridge args");
    int error = 0;
    void *backend = nfsk_backend_from_file(argv[2], 1, &error);
    require(backend != NULL, "bridge backend");
    ntfs_fskit_volume *vol = nfsk_mount(backend, 0, &error);
    require(vol != NULL, "bridge volume");
    uint64_t ino = nfsk_lookup(vol, NFSK_ROOT_INO, argv[3], &error);
    require(ino != 0, "bridge lookup");
    int64_t result;
    if (!strcmp(argv[4], "truncate")) {
        result = nfsk_truncate(vol, ino, strtoull(argv[5], NULL, 10));
    } else {
        require(argc == 7 && !strcmp(argv[4], "write"), "write args");
        size_t size;
        unsigned char *data = payload(argv[6], &size);
        require(!nfsk_open_item(vol, ino), "bridge open item");
        result = nfsk_write(vol, ino, strtoll(argv[5], NULL, 10), data, size, &error);
        free(data);
        require(!nfsk_close_item(vol, ino), "bridge close item");
    }
    int sync = nfsk_sync(vol);
    nfsk_attr_t attrs;
    int getattr = nfsk_getattr(vol, ino, &attrs);
    int release = nfsk_umount(vol);
    nfsk_backend_free(backend);
    printf("{\"result\":%lld,\"errno\":%d,\"sync\":%d,\"getattr\":%d,\"size\":%llu,\"release\":%d}\n",
           (long long)result, error, sync, getattr, (unsigned long long)(getattr ? 0 : attrs.size), release);
}

static void lifecycle_action(int argc, char **argv) {
    require(argc == 5 || argc == 6, "lifecycle args");
    if (argc == 6) {
        int fd = open(argv[5], O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
        require(fd >= 0 && (write_trace = fdopen(fd, "wb")) != NULL, "new lifecycle trace");
    }
    const char *mode = argv[4];
    int reference = !strncmp(mode, "reference-", 10);
    if (reference) mode += 10;
    int error = 0;
    void *backend = nfsk_backend_from_file(argv[2], 1, &error);
    require(backend != NULL, "lifecycle backend");
    ntfs_fskit_volume *vol = nfsk_mount(backend, 0, &error);
    require(vol != NULL, "lifecycle mount");
    uint64_t ino = nfsk_lookup(vol, NFSK_ROOT_INO, argv[3], &error);
    nfsk_attr_t attrs;
    require(ino != 0 && !nfsk_getattr(vol, ino, &attrs), "lifecycle lookup");
    uint64_t old_size = attrs.size;
    unsigned char data[701]; memset(data, 'R', sizeof data);
    int legacy = strcmp(mode, "modern") && strcmp(mode, "reclaim");
    if (legacy) require(!nfsk_open_item(vol, ino), "lifecycle open");
    int before = pclose_calls;
    for (int i = 0; i < 7; i++) {
        require(nfsk_write(vol, ino, old_size + i * 100, data, 100, &error) == 100, "incremental append");
    }
    require(pclose_calls == before, "same-file writes do not force pclose");
    int removed = !strcmp(mode, "unlink") || !strcmp(mode, "unlink-fail");
    if (removed) {
        require(!nfsk_remove(vol, NFSK_ROOT_INO, argv[3]), "unlink open compressed file");
        require(!nfsk_lookup(vol, NFSK_ROOT_INO, argv[3], &error), "unlinked name is absent");
        require(nfsk_write(vol, ino, old_size + 700, data, 1, &error) == 1, "write after unlink");
    }
    int early_error = 0;
    if (!strcmp(mode, "delete-fail")) {
        fail_pclose = 1;
        early_error = nfsk_remove(vol, NFSK_ROOT_INO, argv[3]);
        require(early_error == -EIO, "failed finalization prevents delete");
    }
    if (!strcmp(mode, "switch") || !strcmp(mode, "switch-fail")) {
        uint64_t other = nfsk_lookup(vol, NFSK_ROOT_INO, "Mixed", &error);
        require(other != 0, "switch lookup");
        int fault = !strcmp(mode, "switch-fail");
        if (fault) fail_pclose = 1;
        int64_t written = nfsk_write(vol, other, 19, data, 7, &error);
        if (fault) {
            require(written == -1 && error == EIO, "failed pending close prevents other-file write");
            early_error = -error;
        } else require(written == 7, "write another compressed file");
        require(pclose_calls == before + 1, "single pending slot finalizes previous file");
    }
    uint64_t before_finish_events = trace_events;
    if (!strcmp(mode, "pclose-fail") || !strcmp(mode, "unlink-fail") || !strcmp(mode, "release-prior-fail")) fail_pclose = 1;
    if (!strncmp(mode, "read-fail-", 10)) fail_read = atoi(mode + 10);
    if (!strncmp(mode, "write-fail-", 11)) fail_write = atoi(mode + 11);
    if (!strcmp(mode, "metadata-fail")) fail_after_pclose = 1;
    if (!strcmp(mode, "flush-fail")) fail_flush = 1;
    if (!strcmp(mode, "release-fail")) fail_pclose = 1;
    if (reference) {
        /* Capture the exported upstream call's immediate failure state without
         * wrapper recovery, inode close, sync or umount changing that evidence. */
        require(observed_volume != NULL, "reference volume");
        ntfs_inode *ni = ntfs_inode_open(observed_volume, ino);
        require(ni != NULL, "reference inode");
        ntfs_attr *attr = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
        require(attr != NULL, "reference attribute");
        int rc = nfsk_fixture_attr_pclose(attr);
        require(rc != 0 && failed_pclose_write_attempts > 0, "upstream partial-pclose failure");
        printf("{\"upstream_pclose\":%d,\"errno\":%d,\"writes_before_failure\":%d,\"cleanup\":false}\n",
               rc, errno, failed_pclose_write_attempts);
        fflush(stdout);
        if (write_trace) require(!fflush(write_trace), "flush reference lifecycle trace");
        _Exit(0);
    }
    int first = 0, retry = 0, clean = 0, release = 0, blocked = 0, retained = 0, fatal = 0;
    if (!strncmp(mode, "release", 7) && strcmp(mode, "release-prior-fail")) {
        release = nfsk_umount(vol); vol = NULL;
        require(release == -EIO, "final release reports pclose error");
    } else {
        int use_sync = !strcmp(mode, "sync") || !strcmp(mode, "switch") || !strcmp(mode, "flush-fail");
        first = early_error ? early_error : (use_sync ? nfsk_sync(vol) : nfsk_close_item(vol, ino));
        int fault = strstr(mode, "fail") != NULL;
        if (fault) {
            require(first == -EIO, "first compression/sync failure propagates");
            retained = attrs_live;
            require(retained == ((!strcmp(mode, "metadata-fail") || !strcmp(mode, "flush-fail")) ? 0 : 1),
                    "failed pclose keeps exactly one attribute; completed pclose frees it");
            error = 0;
            blocked = nfsk_write(vol, ino, 0, data, 1, &error) == -1 && error == EIO;
            require(blocked, "failed compression retains guard and excludes new writes");
            fatal = failed_pclose_write_attempts > 0;
            if (fatal) {
                int calls = io_calls, closes = pclose_calls;
                retry = nfsk_sync(vol);
                clean = nfsk_sync(vol);
                require(retry == -EIO && clean == -EIO && pclose_calls == closes && io_calls == calls,
                        "uncertain pclose mutation stays failed without unsafe retry or I/O");
                release = nfsk_umount(vol); vol = NULL;
                require(release == -EIO && calls == io_calls, "fatal pclose release does no further I/O");
            } else if (!strcmp(mode, "release-prior-fail")) {
                int calls = io_calls;
                release = nfsk_umount(vol); vol = NULL;
                require(release == -EIO && calls == io_calls, "irrevocable release does no I/O after prior error");
            } else {
                retry = nfsk_sync(vol);
                require(retry == -EIO, "successful recovery reports saved error once");
                clean = nfsk_sync(vol);
                require(!clean, "subsequent sync succeeds");
            }
        } else require(!first, "normal compression lifecycle");
        if (vol) {
            require(!nfsk_sync(vol), "final clean sync");
            if (!strcmp(mode, "delete-fail"))
                require(nfsk_lookup(vol, NFSK_ROOT_INO, argv[3], &error) == ino, "failed delete retains name");
            if (removed) require(nfsk_getattr(vol, ino, &attrs) != 0, "final close reclaims open-unlinked inode");
            release = nfsk_umount(vol); vol = NULL;
            require(!release, "clean release");
        }
    }
    require(attrs_live == 0, "no retained bridge attributes after release");
    nfsk_backend_free(backend);
    printf("{\"first\":%d,\"retry\":%d,\"clean\":%d,\"release\":%d,\"blocked\":%d,"
           "\"pclose_calls\":%d,\"pclose_reads\":%d,\"pclose_writes\":%d,\"removed\":%d,"
           "\"attrs_peak\":%d,\"attrs_live\":%d,\"attrs_retained_on_error\":%d,\"fatal\":%d,"
           "\"before_finish_events\":%llu,\"pclose_fail_injected\":%d,\"read_injected\":%d,"
           "\"write_injected\":%d,\"flush_injected\":%d,\"metadata_injected\":%d}\n",
           first, retry, clean, release, blocked, pclose_calls, pclose_reads, pclose_writes, removed,
           attrs_peak, attrs_live, retained, fatal, (unsigned long long)before_finish_events,
           pclose_fail_injected, read_injected, write_injected, flush_injected, metadata_injected);
    if (write_trace) require(!fclose(write_trace), "close lifecycle trace");
}

/* Ordinary multi-write boundaries for the bounded finalization candidate.
 * Keep expected disk contents in the independent Python runner, not this hook. */
static void finalization_boundary_action(int argc, char **argv) {
    require(argc == 5, "finalization boundary args");
    const char *mode = argv[4];
    int error = 0;
    void *backend = nfsk_backend_from_file(argv[2], 1, &error);
    require(backend != NULL, "boundary backend");
    ntfs_fskit_volume *vol = nfsk_mount(backend, 0, &error);
    require(vol != NULL, "boundary mount");
    uint64_t ino = nfsk_lookup(vol, NFSK_ROOT_INO, argv[3], &error);
    nfsk_attr_t attr;
    nfsk_statfs_t stats;
    require(ino && !nfsk_getattr(vol, ino, &attr) && !nfsk_statfs(vol, &stats), "boundary initial state");
    uint64_t original = attr.size, unit = (uint64_t)stats.cluster_size * 16;
    require(unit >= 8192 && unit <= 65536, "boundary geometry");
    uint64_t offset = original, amount = 700, shrink = UINT64_MAX;
    if (!strcmp(mode, "append-large")) amount = (2U << 20) + 123;
    else if (!strcmp(mode, "append-cross")) amount = unit + 701;
    else if (!strcmp(mode, "overwrite-old")) offset = 17;
    else if (!strcmp(mode, "grow-shrink-old")) {
        require(original > 50, "old shrink input");
        amount = unit * 2 + 701; shrink = original - 50;
    } else if (!strcmp(mode, "grow-shrink-new")) {
        amount = unit * 2 + 700; shrink = unit + 400;
    } else if (!strcmp(mode, "truncate-grow")) amount = 0;
    else if (!strcmp(mode, "data-read-error")) amount = unit + 700;
    else require(!strcmp(mode, "data-write-error") ||
                 !strcmp(mode, "plain-error") || !strcmp(mode, "plain-write"), "known boundary mode");
    unsigned char data[8191]; memset(data, 'R', sizeof data);
    for (uint64_t done = 0; done < amount;) {
        uint64_t count = amount - done < sizeof data ? amount - done : sizeof data;
        require(nfsk_write(vol, ino, offset + done, data, count, &error) == (int64_t)count,
                "boundary normal write");
        done += count;
    }
    int64_t write_result = (int64_t)amount;
    int write_error = 0, synthetic_injected = 0;
    if (!strcmp(mode, "data-read-error") || !strcmp(mode, "data-write-error")) {
        if (!strcmp(mode, "data-read-error")) fail_data_read = 1;
        else fail_data_write = 1;
        error = 0;
        /* Rewriting a completed unit requires a real compressed read. An
         * append into its raw tail may have no read site at all. */
        uint64_t at = !strcmp(mode, "data-read-error") ? 0 : original + amount;
        write_result = nfsk_write(vol, ino, at, data, 100, &error);
        write_error = error;
        require(data_read_injected + data_write_injected == 1, "actual single data fault");
    } else if (!strcmp(mode, "plain-error") || !strcmp(mode, "plain-write")) {
        uint64_t plain = nfsk_lookup(vol, NFSK_ROOT_INO, "Plain", &error);
        require(plain != 0, "plain boundary lookup");
        int fault = !strcmp(mode, "plain-error");
        if (fault) fail_one_byte = 1;
        error = 0;
        write_result = nfsk_write(vol, plain, 17, data, fault ? 1 : 50, &error);
        write_error = error;
        synthetic_injected = fault && !fail_one_byte;
        require(fault ? write_result == -1 && error == ENOSPC && synthetic_injected : write_result == 50,
                "plain write boundary result");
    } else if (!strcmp(mode, "truncate-grow")) {
        require(!nfsk_truncate(vol, ino, original + unit * 2 + 701), "boundary truncate grow");
    }
    if (shrink != UINT64_MAX) require(!nfsk_truncate(vol, ino, shrink), "boundary shrink");
    int before = pclose_calls;
    int sync = nfsk_sync(vol), close = nfsk_close_item(vol, ino);
    int retry = nfsk_sync(vol), clean = nfsk_sync(vol);
    int release = nfsk_umount(vol);
    nfsk_backend_free(backend);
    require(attrs_live == 0, "boundary attribute release");
    printf("{\"original_size\":%llu,\"unit\":%llu,\"write_result\":%lld,\"write_error\":%d,"
           "\"sync\":%d,\"close\":%d,\"retry\":%d,\"clean\":%d,\"release\":%d,"
           "\"pclose_before_finish\":%d,\"pclose_calls\":%d,\"attrs_peak\":%d,\"attrs_live\":%d,"
           "\"data_read_injected\":%d,\"data_write_injected\":%d,\"synthetic_injected\":%d}\n",
           (unsigned long long)original, (unsigned long long)unit, (long long)write_result, write_error,
           sync, close, retry, clean, release, before, pclose_calls, attrs_peak, attrs_live,
           data_read_injected, data_write_injected, synthetic_injected);
}

static uint64_t nanoseconds(clockid_t clock) {
    struct timespec ts;
    require(!clock_gettime(clock, &ts), "clock");
    return (uint64_t)ts.tv_sec * 1000000000 + (uint64_t)ts.tv_nsec;
}

static void truncate_fault_action(int argc, char **argv) {
    require(argc == 5, "truncate fault args");
    const char *mode = argv[4];
    int error = 0;
    void *backend = nfsk_backend_from_file(argv[2], 1, &error);
    require(backend != NULL, "truncate fault backend");
    ntfs_fskit_volume *vol = nfsk_mount(backend, 0, &error);
    require(vol != NULL, "truncate fault volume");
    uint64_t ino = nfsk_lookup(vol, NFSK_ROOT_INO, argv[3], &error);
    nfsk_attr_t attr;
    nfsk_statfs_t stat;
    require(ino && !nfsk_getattr(vol, ino, &attr) && !nfsk_statfs(vol, &stat), "truncate fault size");
    uint64_t target = attr.size + (uint64_t)stat.cluster_size * 32 + 23;
    if (!strcmp(mode, "enospc")) fail_one_byte = 1;
    else if (!strcmp(mode, "zero")) fail_one_byte = 2;
    else { require(!strcmp(mode, "close"), "truncate fault mode"); fail_close_after_zero = 1; }
    int result = nfsk_truncate(vol, ino, target);
    require(result == (!strcmp(mode, "enospc") ? -ENOSPC : -EIO), "truncate failure is not success");
    int first_sync = nfsk_sync(vol);
    require(first_sync == (!strcmp(mode, "close") ? -EIO : 0) && !nfsk_sync(vol), "truncate recovery");
    require(!nfsk_getattr(vol, ino, &attr), "truncate final size");
    require(!nfsk_umount(vol) && attrs_live == 0, "truncate fault release");
    nfsk_backend_free(backend);
    printf("{\"result\":%d,\"sync\":%d,\"target\":%llu,\"size\":%llu}\n", result, first_sync,
           (unsigned long long)target, (unsigned long long)attr.size);
}
static void benchmark_action(int argc, char **argv) {
    require(argc == 5, "benchmark args");
    int error = 0, eager = !strcmp(argv[4], "eager");
    require(eager || !strcmp(argv[4], "batch"), "benchmark mode");
    void *backend = nfsk_backend_from_file(argv[2], 1, &error);
    require(backend != NULL, "benchmark backend");
    ntfs_fskit_volume *vol = nfsk_mount(backend, 0, &error);
    require(vol != NULL, "benchmark mount");
    uint64_t ino = nfsk_lookup(vol, NFSK_ROOT_INO, argv[3], &error);
    nfsk_attr_t attr;
    require(ino != 0 && !nfsk_getattr(vol, ino, &attr), "benchmark file");
    unsigned char data[512]; memset(data, 'B', sizeof data);
    uint64_t start = nanoseconds(CLOCK_MONOTONIC), cpu = nanoseconds(CLOCK_PROCESS_CPUTIME_ID);
    for (int i = 0; i < 512; i++) {
        require(nfsk_write(vol, ino, attr.size + (uint64_t)i * sizeof data, data, sizeof data, &error) == sizeof data,
                "benchmark append");
        if (eager) require(!nfsk_close_item(vol, ino), "eager finalization");
    }
    require(!nfsk_close_item(vol, ino) && !nfsk_sync(vol), "benchmark final close/sync");
    uint64_t elapsed = nanoseconds(CLOCK_MONOTONIC) - start;
    cpu = nanoseconds(CLOCK_PROCESS_CPUTIME_ID) - cpu;
    struct rusage usage;
    require(!getrusage(RUSAGE_SELF, &usage), "getrusage");
    require(!nfsk_umount(vol), "benchmark release");
    nfsk_backend_free(backend);
    printf("{\"mode\":\"%s\",\"operations\":512,\"wall_ns\":%llu,\"cpu_ns\":%llu,\"rss_bytes\":%ld,\"pclose_calls\":%d}\n",
           argv[4], (unsigned long long)elapsed, (unsigned long long)cpu, usage.ru_maxrss, pclose_calls);
}
/* Observe the actual public bridge boundary before sync/close can mask a write.
 * No expected-result assertion here: the Python oracle also runs the old source. */
static void write_guard_action(int argc, char **argv) {
    require(argc == 6, "guard args: image file operation value-or-size");
    int error = 0, readonly = !strcmp(argv[1], "guard-ro");
    void *backend = nfsk_backend_from_file(argv[2], !readonly, &error);
    require(backend != NULL, "guard backend");
    ntfs_fskit_volume *vol = nfsk_mount(backend, readonly, &error);
    require(vol != NULL, "guard mount");
    uint64_t ino = nfsk_lookup(vol, NFSK_ROOT_INO, argv[3], &error);
    nfsk_attr_t before = {0}, after = {0};
    require(ino && !nfsk_getattr(vol, ino, &before) && !nfsk_open_item(vol, ino), "guard lookup/open");
    const char *key = "com.apple.testCompressed", *mode = argv[4];
    int64_t old_xattr = nfsk_getxattr(vol, ino, key, NULL, 0);
    int writes = backend_writes, pwrite_count = data_write_calls, close_count = pclose_calls;
    int truncate_count = truncate_calls, adds = attr_add_calls, removes = attr_rm_calls;
    int64_t result;
    if (!strcmp(mode, "truncate")) {
        result = nfsk_truncate(vol, ino, strtoull(argv[5], NULL, 10));
    } else if (!strcmp(mode, "open-write")) {
        result = nfsk_check_write_access(vol, ino);
    } else if (!strcmp(mode, "write") || !strcmp(mode, "append") || !strcmp(mode, "zero-write")) {
        size_t size;
        unsigned char *data = payload(argv[5], &size);
        if (!strcmp(mode, "zero-write")) size = 0;
        result = nfsk_write(vol, ino, !strcmp(mode, "append") ? (int64_t)before.size : 0, data, size, &error);
        if (result < 0) result = -(error ? error : EIO);
        free(data);
    } else {
        int policy = NFSK_XATTR_SET;
        if (!strcmp(mode, "xattr-create")) policy = NFSK_XATTR_CREATE;
        else if (!strcmp(mode, "xattr-replace")) policy = NFSK_XATTR_REPLACE;
        else if (!strcmp(mode, "xattr-delete")) policy = NFSK_XATTR_DELETE;
        else if (!strcmp(mode, "xattr-read-fail-2")) fail_data_read = 2;
        else if (!strcmp(mode, "xattr-read-fail-3")) fail_data_read = 3;
        else if (!strcmp(mode, "xattr-write-fail-3")) fail_data_write = 3;
        else require(!strcmp(mode, "xattr-set"), "known guard operation");
        size_t size = 0;
        unsigned char *data = policy == NFSK_XATTR_DELETE ? NULL : payload(argv[5], &size);
        result = nfsk_setxattr(vol, ino, key, data, size, policy);
        free(data);
    }
    int operation_writes = backend_writes - writes;
    int mutations = data_write_calls - pwrite_count + pclose_calls - close_count +
                    truncate_calls - truncate_count + attr_add_calls - adds + attr_rm_calls - removes;
    int getattr_status = nfsk_getattr(vol, ino, &after);
    unsigned char buffer[16];
    int64_t read_status = nfsk_read(vol, ino, 0, buffer, sizeof buffer, &error);
    int64_t new_xattr = nfsk_getxattr(vol, ino, key, NULL, 0);
    int closed = nfsk_close_item(vol, ino), first = nfsk_sync(vol), second = nfsk_sync(vol);
    int final_pclose = pclose_calls - close_count;
    int release = nfsk_umount(vol);
    nfsk_backend_free(backend);
    printf("{\"result\":%lld,\"operation_writes\":%d,\"mutation_calls\":%d,"
           "\"getattr\":%d,\"before_size\":%llu,\"after_size\":%llu,\"read\":%lld,"
           "\"old_xattr\":%lld,\"new_xattr\":%lld,\"close\":%d,\"sync\":%d,\"second_sync\":%d,"
           "\"release\":%d,\"pclose_calls\":%d,\"attrs_live\":%d,\"attrs_peak\":%d,"
           "\"faults_reached\":%d}\n",
           (long long)result, operation_writes, mutations, getattr_status,
           (unsigned long long)before.size, (unsigned long long)after.size, (long long)read_status,
           (long long)old_xattr, (long long)new_xattr, closed, first, second, release,
           final_pclose, attrs_live, attrs_peak, data_read_injected + data_write_injected);
}

static void xattr_action(int argc, char **argv) {
    require(argc == 6 || argc == 7, "xattr args: image file payload mode [new trace file]");
    if (argc == 7) {
        int fd = open(argv[6], O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
        require(fd >= 0 && (write_trace = fdopen(fd, "wb")) != NULL, "new trace file");
    }
    const char *mode = argv[5];
    const char *truncate_prefixes[] = {"truncate-fail-", "truncate-oom-", "truncate-after-fail-"};
    for (size_t i = 0; i < sizeof truncate_prefixes / sizeof truncate_prefixes[0]; i++) {
        size_t length = strlen(truncate_prefixes[i]);
        if (!strncmp(mode, truncate_prefixes[i], length)) {
            fail_truncate = (int)i + 1;
            mode += length;
            break;
        }
    }
    const char *allocation_prefixes[] = {"allocation-read-fail-", "allocation-oom-", "allocation-short-"};
    for (size_t i = 0; i < sizeof allocation_prefixes / sizeof allocation_prefixes[0]; i++) {
        size_t length = strlen(allocation_prefixes[i]);
        if (!strncmp(mode, allocation_prefixes[i], length)) {
            fail_allocation_read = (int)i + 1;
            mode += length;
            break;
        }
    }
    const char late_oom_prefix[] = "mapping-oom-late-", oom_prefix[] = "mapping-oom-";
    if (!strncmp(mode, late_oom_prefix, sizeof(late_oom_prefix) - 1)) {
        fail_mapping_oom = 2;
        mode += sizeof(late_oom_prefix) - 1;
    } else if (!strncmp(mode, oom_prefix, sizeof(oom_prefix) - 1)) {
        fail_mapping_oom = 1;
        mode += sizeof(oom_prefix) - 1;
    }
    const char stop_prefix[] = "before-rollback-";
    if (!strncmp(mode, stop_prefix, sizeof(stop_prefix) - 1)) {
        stop_after_data_fault = 1;
        mode += sizeof(stop_prefix) - 1;
    }
    int snapshot = !strncmp(mode, "snapshot-", 9);
    if (snapshot) mode += 9;
    int error = 0;
    void *backend = nfsk_backend_from_file(argv[2], 1, &error);
    require(backend != NULL, "xattr backend");
    ntfs_fskit_volume *vol = nfsk_mount(backend, 0, &error);
    require(vol != NULL, "xattr mount");
    uint64_t ino = nfsk_lookup(vol, NFSK_ROOT_INO, argv[3], &error);
    require(ino != 0, "xattr file");
    size_t size;
    unsigned char *data = payload(argv[4], &size);
    require(size <= NFSK_MAX_XATTR_SIZE, "xattr size");
    if (!strncmp(mode, "rollback-read-fail-", 19)) {
        fail_pclose = 1;
        fail_read = atoi(mode + 19);
        require(fail_read > 0 && fail_read <= 128, "bounded rollback read fault");
    } else if (!strncmp(mode, "rollback-write-fail-", 20)) {
        fail_pclose = 1;
        fail_write = atoi(mode + 20);
        require(fail_write > 0 && fail_write <= 128, "bounded rollback write fault");
    } else if (!strncmp(mode, "data-read-fail-", 15)) fail_data_read = atoi(mode + 15);
    else if (!strncmp(mode, "data-write-fail-", 16)) fail_data_write = atoi(mode + 16);
    else if (!strncmp(mode, "read-fail-", 10)) fail_read = atoi(mode + 10);
    else if (!strncmp(mode, "write-fail-", 11)) fail_write = atoi(mode + 11);
    else if (!strcmp(mode, "pclose-fail")) fail_pclose = 1;
    else if (!strcmp(mode, "rollback-fail")) fail_pclose = 2;
    else if (!strcmp(mode, "metadata-fail")) fail_after_pclose = 1;
    else if (!strcmp(mode, "flush-fail")) fail_flush = 1;
    else require(!strcmp(mode, "normal") || !strcmp(mode, "delete") ||
                 !strcmp(mode, "space-retry"), "known xattr mode");
    const char *name = "com.apple.testCompressed";
    if (!strcmp(mode, "space-retry")) {
        int initial = nfsk_setxattr(vol, ino, name, data, size, NFSK_XATTR_SET);
        int removed = nfsk_remove(vol, NFSK_ROOT_INO, "SpaceFiller");
        int retried = removed ? removed : nfsk_setxattr(vol, ino, name, data, size, NFSK_XATTR_SET);
        free(data);
        int sync = nfsk_sync(vol), release = nfsk_umount(vol);
        nfsk_backend_free(backend);
        require(attrs_live == 0, "space retry ownership");
        printf("{\"initial\":%d,\"removed\":%d,\"retried\":%d,\"sync\":%d,\"release\":%d,"
               "\"attrs_live\":%d,\"attrs_peak\":%d}\n",
               initial, removed, retried, sync, release, attrs_live, attrs_peak);
        if (write_trace) require(!fclose(write_trace), "close retry trace");
        return;
    }
    int result = !strcmp(mode, "delete") ? nfsk_setxattr(vol, ino, name, NULL, 0, NFSK_XATTR_DELETE) :
                 nfsk_setxattr(vol, ino, name, data, size, NFSK_XATTR_SET);
    free(data);
    int after_operation = io_calls, closes = pclose_calls;
    int first = 0, second = 0, release = 0;
    if (!snapshot) {
        first = nfsk_sync(vol);
        second = nfsk_sync(vol);
        release = nfsk_umount(vol);
        nfsk_backend_free(backend);
        require(attrs_live == 0, "xattr release ownership");
    }
    printf("{\"result\":%d,\"first_sync\":%d,\"second_sync\":%d,\"release\":%d,\"snapshot\":%d,"
           "\"operation_io\":%d,\"later_io\":%d,\"pclose_calls\":%d,\"later_pclose\":%d,"
           "\"pclose_reads\":%d,\"pclose_writes\":%d,\"attrs_live\":%d,\"attrs_peak\":%d,"
           "\"data_reads\":%d,\"data_writes\":%d,\"data_read_injected\":%d,\"data_write_injected\":%d,"
           "\"closing_runlist_dirty\":%d,\"pclose_fail_injected\":%d,\"read_injected\":%d,"
           "\"write_injected\":%d,\"flush_injected\":%d,\"metadata_injected\":%d,"
           "\"mapping_calls\":%d,\"mapping_oom_injected\":%d,"
           "\"allocation_reads\":%d,\"allocation_read_injected\":%d,"
           "\"truncate_calls\":%d,\"truncate_injected\":%d}\n",
           result, first, second, release, snapshot, after_operation, io_calls - after_operation,
           closes, pclose_calls - closes, pclose_reads, pclose_writes, attrs_live, attrs_peak,
           data_reads, data_writes, data_read_injected, data_write_injected, closing_runlist_dirty,
           pclose_fail_injected, read_injected, write_injected, flush_injected, metadata_injected,
           mapping_calls, mapping_oom_injected, allocation_reads, allocation_read_injected,
           truncate_calls, truncate_injected);
    if (snapshot) {
        fflush(stdout);
        if (write_trace) require(!fflush(write_trace), "flush snapshot trace");
        _Exit(0);
    }
    if (write_trace) require(!fclose(write_trace), "close write trace");
}

/* Reserve real clusters through the bridge; never edit bitmap bytes directly.
 * The filler and blockers keep EOF zero, so no large payload/cache is needed. */
static void space_action(int argc, char **argv) {
    require((argc == 4 || (argc == 5 && !strcmp(argv[3], "near-full"))) &&
            (!strcmp(argv[3], "near-full") || !strcmp(argv[3], "fragmented")), "space args");
    int fragmented = !strcmp(argv[3], "fragmented"), error = 0;
    uint64_t remaining = 8;
    if (argc == 5) {
        char *end = NULL;
        errno = 0;
        unsigned long requested = strtoul(argv[4], &end, 10);
        require(end != argv[4] && !*end && !errno && requested <= 512, "space free cluster bound");
        remaining = requested;
    }
    void *backend = nfsk_backend_from_file(argv[2], 1, &error);
    require(backend != NULL, "space backend");
    ntfs_fskit_volume *vol = nfsk_mount(backend, 0, &error);
    require(vol != NULL, "space mount");
    uint64_t filler = nfsk_create(vol, NFSK_ROOT_INO, "SpaceFiller", NFSK_TYPE_FILE, &error);
    nfsk_statfs_t before, after;
    require(filler && !nfsk_statfs(vol, &before), "space initial stats");
    require(before.free_clusters > 1024, "space initial headroom");
    uint64_t leave = fragmented ? 512 : remaining;
    /* The upstream allocator may miss tiny scattered gaps in a large request.
     * For exact boundary fixtures, consume the last <=32 clusters one at a time. */
    if (argc == 5 && leave < 32) leave = 32;
    int64_t bytes = (int64_t)(before.free_clusters - leave) * before.cluster_size;
    require(nfsk_preallocate(vol, filler, 0, bytes, true) == bytes, "space filler allocation");
    if (!fragmented && remaining < leave) {
        for (uint64_t i = remaining; i < leave; i++) {
            require(nfsk_preallocate(vol, filler, 0, before.cluster_size, true) == before.cluster_size,
                    "space final cluster allocation");
        }
    }
    if (fragmented) {
        char name[32];
        for (int i = 0; i < 128; i++) {
            snprintf(name, sizeof name, "SpaceBlocker-%03d", i);
            uint64_t ino = nfsk_create(vol, NFSK_ROOT_INO, name, NFSK_TYPE_FILE, &error);
            require(ino && nfsk_preallocate(vol, ino, 0, before.cluster_size, true) == before.cluster_size,
                    "space blocker allocation");
        }
        require(!nfsk_sync(vol) && !nfsk_statfs(vol, &after) && after.free_clusters > 8,
                "space blocker stats");
        bytes = (int64_t)(after.free_clusters - 8) * after.cluster_size;
        require(nfsk_preallocate(vol, filler, 0, bytes, true) == bytes, "space remaining allocation");
        for (int i = 0; i < 128; i += 2) {
            snprintf(name, sizeof name, "SpaceBlocker-%03d", i);
            require(!nfsk_remove(vol, NFSK_ROOT_INO, name), "space alternating holes");
        }
    }
    require(!nfsk_sync(vol) && !nfsk_statfs(vol, &after), "space final stats");
    require(!nfsk_umount(vol), "space release");
    nfsk_backend_free(backend);
    printf("{\"layout\":\"%s\",\"cluster_size\":%u,\"free_before\":%llu,\"free_after\":%llu}\n",
           argv[3], after.cluster_size, (unsigned long long)before.free_clusters,
           (unsigned long long)after.free_clusters);
}
int main(int argc, char **argv) {
    require(argc >= 4, "arguments");
    struct stat st;
    require(!lstat(argv[2], &st) && S_ISREG(st.st_mode) && st.st_nlink == 1 &&
            st.st_size >= 512 && st.st_size <= MAX_IMAGE, "independent bounded image");
    if (!strcmp(argv[1], "guard") || !strcmp(argv[1], "guard-ro")) write_guard_action(argc, argv);
    else if (!strcmp(argv[1], "bridge")) bridge_action(argc, argv);
    else if (!strcmp(argv[1], "lifecycle")) lifecycle_action(argc, argv);
    else if (!strcmp(argv[1], "finalization-boundary")) finalization_boundary_action(argc, argv);
    else if (!strcmp(argv[1], "benchmark")) benchmark_action(argc, argv);
    else if (!strcmp(argv[1], "truncate-fault")) truncate_fault_action(argc, argv);
    else if (!strcmp(argv[1], "xattr")) xattr_action(argc, argv);
    else if (!strcmp(argv[1], "space")) space_action(argc, argv);
    else library_action(argc, argv);
    return 0;
}
