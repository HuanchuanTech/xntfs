/*
 * ntfs_fskit.h - Swift-facing C API bridging FSKit to libntfs-3g.
 *
 * Opaque, ObjC/Swift-friendly surface. No libntfs-3g types leak through, so the
 * Swift bridging header can import it without dragging in libntfs headers (whose
 * `enum BOOL` collides with ObjC's BOOL).
 *
 * Two translation units back this header:
 *   - ntfs_fskit.c        : libntfs-3g logic (pure C, no FSKit/ObjC).
 *   - ntfs_device_fskit.m : block I/O over FSBlockDeviceResource (ObjC).
 */

#ifndef NTFS_FSKIT_H
#define NTFS_FSKIT_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Item types — values intentionally match FSKit's FSItemType enum. */
enum {
    NFSK_TYPE_UNKNOWN   = 0,
    NFSK_TYPE_FILE      = 1,
    NFSK_TYPE_DIR       = 2,
    NFSK_TYPE_SYMLINK   = 3,
    NFSK_TYPE_FIFO      = 4,
    NFSK_TYPE_CHARDEV   = 5,
    NFSK_TYPE_BLOCKDEV  = 6,
    NFSK_TYPE_SOCKET    = 7,
};

/* Inode reported for the root directory (matches FSItem.Identifier.rootDirectory). */
#define NFSK_ROOT_INO 2ULL
/* Parent reported for the root directory (matches FSItem.Identifier.parentOfRoot). */
#define NFSK_PARENT_OF_ROOT 1ULL

typedef struct ntfs_fskit_volume ntfs_fskit_volume;

/* Memory-only numeric statistics for callers that do not need a label copy. */
typedef struct {
    uint32_t cluster_size;
    uint64_t total_clusters;
    uint64_t free_clusters;
    uint64_t total_files;
    uint64_t free_files;
    uint64_t volume_serial;
    uint8_t  read_only;
} nfsk_statfs_counters_t;

typedef struct {
    uint32_t cluster_size;
    uint64_t total_clusters;
    uint64_t free_clusters;
    uint64_t total_files;
    uint64_t free_files;
    uint64_t volume_serial;      /* NTFS 64-bit boot-sector serial; 0 if unreadable */
    uint8_t  read_only;
    char     volume_name[1024];  /* Legacy bounded UTF-8 copy; use nfsk_volume_name for the complete name. */
} nfsk_statfs_t;

typedef struct {
    uint64_t ino;
    uint64_t parent_ino;   /* parent dir in our numbering; 0 if unknown */
    uint32_t type;         /* NFSK_TYPE_* */
    uint32_t mode;         /* synthesized POSIX permission bits */
    uint32_t flags;        /* supported BSD flags, currently UF_HIDDEN */
    uint32_t nlink;
    uint64_t size;
    uint64_t alloc_size;
    int64_t  mtime_sec;  int64_t mtime_nsec;
    int64_t  atime_sec;  int64_t atime_nsec;
    int64_t  ctime_sec;  int64_t ctime_nsec;
    int64_t  btime_sec;  int64_t btime_nsec;
} nfsk_attr_t;

/* Directory enumeration callback. Return 0 to continue, non-zero to stop.
 * `cookie` is an opaque resume position for the *next* entry. */
typedef int (*nfsk_dir_cb)(void *ctx, const char *name_utf8,
                           uint64_t ino, uint32_t type, int64_t cookie);
/* Full live attributes from the same child-inode open. The listing directory
 * supplies parent_ino. Both pointers are borrowed for this callback only, after
 * the child inode has closed successfully. Return nonzero to stop normally. */
typedef int (*nfsk_dir_attr_cb)(void *ctx, const char *name_utf8,
                                const nfsk_attr_t *attributes, int64_t cookie);

/* --- lifecycle --- */
ntfs_fskit_volume *nfsk_mount(void *resource, bool read_only, int *out_errno);
int  nfsk_probe(void *resource, char *name_out, size_t name_cap, uint64_t *serial_out);
/* Same recognition/serial policy as nfsk_probe. On recognition (1), transfers
 * the complete cached UTF-8/NFD name, including an empty name; caller frees it.
 * Failure (0) leaves *name_out NULL. name_out must be non-NULL. */
int  nfsk_probe_name_alloc(void *resource, char **name_out, uint64_t *serial_out);
/* Complete cached UTF-8/NFD name, borrowed until rename or unmount. No backend
 * I/O or allocation. Serialize access with the volume; NULL for an invalid v. */
const char *nfsk_volume_name(ntfs_fskit_volume *v);
/* Final release always destroys v. Returns the first error as negative errno.
 * Use nfsk_sync before release when failed writes must remain retryable. */
int nfsk_umount(ntfs_fskit_volume *v);
int  nfsk_sync(ntfs_fskit_volume *v);
int  nfsk_statfs(ntfs_fskit_volume *v, nfsk_statfs_t *out);
/* Same numeric values as nfsk_statfs, without its legacy name buffer. No I/O
 * or allocation; caller serializes access to v. Invalid arguments return
 * -EINVAL without changing out. Cached serial 0 never causes a fallback read. */
int  nfsk_statfs_counters(ntfs_fskit_volume *v, nfsk_statfs_counters_t *out);

/* Read-only mount preflight, not a full consistency scan or repair. The resource
 * must not be mounted writable elsewhere. Returns 0 or -errno and a diagnostic. */
enum {
    NFSK_CHECK_CLEAN = 0,
    NFSK_CHECK_METADATA = 1,
    NFSK_CHECK_DIRTY = 2,
    NFSK_CHECK_HIBERNATED = 3,
    NFSK_CHECK_JOURNAL = 4,
};
int  nfsk_quick_check(void *resource, int *reason);

/* --- item operations --- */
int      nfsk_getattr(ntfs_fskit_volume *v, uint64_t ino, nfsk_attr_t *out);
uint64_t nfsk_lookup(ntfs_fskit_volume *v, uint64_t dir_ino, const char *name_utf8, int *out_errno);
uint64_t nfsk_lookup_name(ntfs_fskit_volume *v, uint64_t dir_ino, const char *name_utf8,
                          char *canonical_name, size_t capacity, int *out_errno);
/* On success, returns the inode and an owned complete UTF-8/NFD spelling from
 * one FILE_NAME (at most 255 UTF-16 units before normalization). Caller frees
 * *canonical_name. On failure returns 0 and leaves *canonical_name NULL. */
uint64_t nfsk_lookup_name_alloc(ntfs_fskit_volume *v, uint64_t dir_ino, const char *name_utf8,
                                char **canonical_name, int *out_errno);
int      nfsk_readdir(ntfs_fskit_volume *v, uint64_t dir_ino, int64_t start_cookie, void *ctx, nfsk_dir_cb cb);
int      nfsk_readdir_attributes(ntfs_fskit_volume *v, uint64_t dir_ino, int64_t start_cookie,
                                 void *ctx, nfsk_dir_attr_cb cb);
/* Negative offset/length fails with EINVAL. Read lengths clamp at EOF without
 * signed addition; a positive write ending above INT64_MAX fails with EFBIG
 * before inode/attribute mutation. Otherwise-successful reads also report a
 * final inode-close failure; their caller buffer may already contain bytes. */
/* Preflight writable opens before the kernel caches user bytes. Negative errno;
 * no open-reference ownership or mutation. Other item types retain their policy. */
int      nfsk_check_write_access(ntfs_fskit_volume *v, uint64_t ino);
int64_t  nfsk_read(ntfs_fskit_volume *v, uint64_t ino, int64_t offset, void *buf, int64_t len, int *out_errno);
int64_t  nfsk_write(ntfs_fskit_volume *v, uint64_t ino, int64_t offset, const void *buf, int64_t len, int *out_errno);
uint64_t nfsk_create(ntfs_fskit_volume *v, uint64_t dir_ino, const char *name_utf8, uint32_t type, int *out_errno);
int      nfsk_link(ntfs_fskit_volume *v, uint64_t target_ino, uint64_t dir_ino, const char *name_utf8, int *out_errno);
int      nfsk_remove(ntfs_fskit_volume *v, uint64_t dir_ino, const char *name_utf8);
int      nfsk_truncate(ntfs_fskit_volume *v, uint64_t ino, uint64_t size);
int      nfsk_set_times(ntfs_fskit_volume *v, uint64_t ino,
                        int64_t mtime_sec, int64_t mtime_nsec,
                        int64_t atime_sec, int64_t atime_nsec);
enum {
    NFSK_SET_MTIME = 1,
    NFSK_SET_ATIME = 2,
    NFSK_SET_BTIME = 4,
    NFSK_SET_FLAGS = 8,
};
typedef struct {
    uint32_t valid;
    uint32_t flags;
    int64_t mtime_sec, mtime_nsec;
    int64_t atime_sec, atime_nsec;
    int64_t btime_sec, btime_nsec;
} nfsk_metadata_t;
int      nfsk_validate_metadata(const nfsk_metadata_t *metadata);
int      nfsk_set_metadata(ntfs_fskit_volume *v, uint64_t ino, const nfsk_metadata_t *metadata);
uint64_t nfsk_symlink(ntfs_fskit_volume *v, uint64_t dir_ino, const char *name,
                      const char *target, int *out_errno);
int      nfsk_rename_volume(ntfs_fskit_volume *v, const char *name);
int64_t  nfsk_preallocate(ntfs_fskit_volume *v, uint64_t ino, int64_t offset,
                          int64_t length, bool from_eof);
int      nfsk_seek_region(ntfs_fskit_volume *v, uint64_t ino, int64_t offset,
                          bool seek_data, int64_t *result);

/* FSKit open/close describe access modes, not descriptor counts. Opening is
 * idempotent and records legacy open-unlink ownership. Call close for both
 * modern and legacy final closes (or successful reclaim), even without a prior
 * open record: it also finalizes eligible newly written compressed tail units.
 * Existing half-full tail units keep their prior representation. */
int      nfsk_open_item(ntfs_fskit_volume *v, uint64_t ino);
int      nfsk_close_item(ntfs_fskit_volume *v, uint64_t ino);
int      nfsk_rename(ntfs_fskit_volume *v, uint64_t src_dir, const char *src_name,
                     uint64_t dst_dir, const char *dst_name);
int      nfsk_readlink(ntfs_fskit_volume *v, uint64_t ino, char *buf, size_t cap);
/* Same cap (including NUL) and errors as nfsk_readlink, without a caller buffer.
 * Returns 0 and an owned complete target; caller frees *target.
 * On error returns negative errno and leaves *target NULL, including close errors. */
int      nfsk_readlink_alloc(ntfs_fskit_volume *v, uint64_t ino, char **target, size_t cap);

/* Native xattrs use same-named NTFS data streams (ntfs-3g openxattr mapping).
 * FSKit transfers whole values, so bound per-request memory consumption. */
enum {
    NFSK_MAX_XATTR_SIZE = 128 * 1024,
    NFSK_MAX_XATTR_NAME = 127,
    NFSK_XATTR_SET = 0,
    NFSK_XATTR_CREATE = 1,
    NFSK_XATTR_REPLACE = 2,
    NFSK_XATTR_DELETE = 3,
};
/* get/list return byte counts or -errno; NULL buffers query the required size.
 * list returns NUL-terminated names concatenated without an extra terminator. */
int64_t nfsk_getxattr(ntfs_fskit_volume *v, uint64_t ino, const char *name, void *buf, size_t size);
int64_t nfsk_listxattr(ntfs_fskit_volume *v, uint64_t ino, char *buf, size_t size);
/* Single-pass reads. Return length or negative errno. On success the caller
 * owns *out and must free it; empty results and every error leave *out NULL.
 * out must be non-NULL. Successful calls close their temporary libntfs objects
 * before transfer; failed closes retain the existing sync/retry ownership. */
int64_t nfsk_getxattr_alloc(ntfs_fskit_volume *v, uint64_t ino, const char *name, void **out);
int64_t nfsk_listxattr_alloc(ntfs_fskit_volume *v, uint64_t ino, char **out);
int     nfsk_setxattr(ntfs_fskit_volume *v, uint64_t ino, const char *name,
                     const void *value, size_t size, int policy);

/* --- Backend (implemented in ntfs_device_fskit.m) ---
 * A backend wraps either an FSBlockDeviceResource (a real disk/partition) or an
 * opened image file, behind one I/O interface. Create one, pass the returned
 * opaque pointer to nfsk_mount / nfsk_probe (as the `resource` argument), and
 * release it with nfsk_backend_free after umount. Access and release must be
 * serialized: scratch belongs to this backend and synchronous I/O must finish
 * before release. Block geometry is a snapshot for this backend's lifetime. */
void *nfsk_backend_from_block(void *block_resource, int allow_write);  /* __bridge FSBlockDeviceResource* */
void *nfsk_backend_from_file(const char *path, int writable, int *out_err);
void  nfsk_backend_free(void *backend);

/* I/O over a backend (the `backend` arg is what nfsk_backend_* returns).
 * A read failure returns -1/errno; its output buffer may already be modified.
 * Writes may modify a prefix before returning -1/errno. Large nonaligned block
 * writes prepare both edge sectors before writing them and the direct middle
 * in order; they do not provide an all-or-nothing transaction.
 * Nonaligned block I/O needing a sector workspace above 256 KiB returns ENOTSUP
 * without I/O. Writes need at most two such sectors; retained scratch is capped
 * at 256 KiB per backend and 2 MiB per process. All workspace allocations,
 * including temporaries and realloc overlap, share an 8 MiB process budget.
 * Retained-budget overflow uses temporary storage; total-budget overflow returns
 * ENOMEM before this backend request's I/O, without waiting. These limits exclude
 * caller/FSKit/library allocations and do not cap total process RAM. */
int64_t  nfsk_block_pread(void *backend, void *buf, int64_t offset, int64_t count);
int64_t  nfsk_block_pwrite(void *backend, const void *buf, int64_t offset, int64_t count);
int      nfsk_block_sync(void *backend);
uint64_t nfsk_block_total_bytes(void *backend);
uint32_t nfsk_block_sector_size(void *backend);
int      nfsk_block_is_writable(void *backend);

#ifdef __cplusplus
}
#endif

#endif /* NTFS_FSKIT_H */
