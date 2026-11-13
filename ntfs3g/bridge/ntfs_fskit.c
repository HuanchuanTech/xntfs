/*
 * ntfs_fskit.c - libntfs-3g logic behind the FSKit bridge.
 *
 * Pure C. Maps the nfsk_* C API (ntfs_fskit.h) onto libntfs-3g calls, mirroring
 * how ntfs-3g's src/ntfs-3g.c maps FUSE operations onto the same library.
 *
 * The block device is reached through a custom ntfs_device_operations whose
 * read/write call the nfsk_block_* functions implemented in ntfs_device_fskit.m.
 *
 * Compile with -DHAVE_CONFIG_H -I<ntfs-3g top> -I<ntfs-3g/include> so libntfs
 * struct layouts match the prebuilt libntfs-3g.a.
 */

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <sys/disk.h>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>

#include <ntfs-3g/types.h>
#include <ntfs-3g/param.h>
#include <ntfs-3g/endians.h>
#include <ntfs-3g/layout.h>
#include <ntfs-3g/device.h>
#include <ntfs-3g/volume.h>
#include <ntfs-3g/inode.h>
#include <ntfs-3g/dir.h>
#include <ntfs-3g/index.h>
#include <ntfs-3g/attrib.h>
#include <ntfs-3g/runlist.h>
#include <ntfs-3g/unistr.h>
#include <ntfs-3g/ntfstime.h>
#include <ntfs-3g/bootsect.h>
#include <ntfs-3g/logging.h>
#include <ntfs-3g/logfile.h>
#include <ntfs-3g/reparse.h>
#include <ntfs-3g/security.h>

#include "ntfs_fskit.h"

/* ---- Device context + operations backed by FSBlockDeviceResource ---- */
typedef struct nfsk_inode_ref {
    ntfs_inode *inode;
    struct nfsk_inode_ref *next;
} nfsk_inode_ref;

typedef struct nfsk_open_ref {
    MFT_REF ref;
    ntfschar *anchor;
    int anchor_length;
    bool open;
    struct nfsk_open_ref *next;
} nfsk_open_ref;

/* Page boundaries, not live index/inode handles. One stopped entry supports both
 * callbacks that accepted it and packers that rejected it for lack of space. */
enum { NFSK_DIRECTORY_CHECKPOINTS = 16 };
typedef struct {
    MFT_REF directory, indexed_file;
    int64_t ordinal;
    size_t key_length;
    unsigned char key[offsetof(FILE_NAME_ATTR, file_name) + NTFS_MAX_NAME_LEN * sizeof(ntfschar)];
} nfsk_directory_checkpoint;

typedef struct {
    void    *resource;   /* __bridge FSBlockDeviceResource* (owned by Swift) */
    int64_t  pos;
    nfsk_inode_ref *inodes;
    nfsk_open_ref *open_items;
    size_t retention_count; /* anchor owners, including failed-close retries */
    MFT_REF compressed_pending; /* fixed identity, including inode sequence */
    s64 compressed_safe_from; /* first unit containing no prior file bytes */
    ntfs_attr *compression_retry; /* only a failed close; never file-content cache */
    uint64_t write_failures;
    uint64_t read_failures;
    int last_read_error;
    int last_io_error;
    int writeback_error;
    int fatal_writeback_error;
    uint64_t boot_serial;  /* cached at mount; nfsk_statfs must not touch the backend */
    unsigned rename_seq;   /* owned by this volume's serial execution context */
    bool releasing;
    int release_error;     /* first error during irrevocable final release */
    uint64_t directory_generation;
    unsigned checkpoint_count, checkpoint_next;
    nfsk_directory_checkpoint checkpoints[NFSK_DIRECTORY_CHECKPOINTS];
} nfsk_devctx;

static void invalidate_directory_checkpoints(nfsk_devctx *ctx) {
    ctx->checkpoint_count = ctx->checkpoint_next = 0;
    ctx->directory_generation++;
}

static void record_release_error(nfsk_devctx *ctx, int error) {
    if (ctx->releasing && !ctx->release_error) ctx->release_error = error ? error : EIO;
}

static int dev_open(struct ntfs_device *dev, int flags) {
    if (NDevOpen(dev)) { errno = EBUSY; return -1; }
    NDevSetBlock(dev);
    if ((flags & O_RDWR) != O_RDWR) NDevSetReadOnly(dev);
    NDevSetOpen(dev);
    return 0;
}

static int dev_close(struct ntfs_device *dev) {
    nfsk_devctx *c = dev->d_private;
    int ret = 0;
    if (!NDevOpen(dev)) { errno = EBADF; return -1; }
    if (c->release_error) {
        errno = c->release_error;
        ret = -1;
    } else if (NDevDirty(dev) && !NDevReadOnly(dev)) {
        int r = nfsk_block_sync(c->resource);
        if (r == 0) NDevClearDirty(dev);   /* only forget dirty once the flush succeeds */
        else { errno = -r; record_release_error(c, errno); ret = -1; }
    }
    NDevClearOpen(dev);
    return ret;
}

static s64 dev_seek(struct ntfs_device *dev, s64 offset, int whence) {
    nfsk_devctx *c = dev->d_private;
    int64_t base;
    switch (whence) {
        case SEEK_SET: base = 0; break;
        case SEEK_CUR: base = c->pos; break;
        case SEEK_END: base = (int64_t)nfsk_block_total_bytes(c->resource); break;
        default: errno = EINVAL; return -1;
    }
    if (base < 0 || offset > INT64_MAX - base) { errno = EOVERFLOW; return -1; }
    if (offset < -base) { errno = EINVAL; return -1; }
    c->pos = base + offset;
    return c->pos;
}

static s64 dev_pread(struct ntfs_device *dev, void *buf, s64 count, s64 offset) {
    nfsk_devctx *c = dev->d_private;
    if (c->release_error) { errno = c->release_error; return -1; }
    s64 result = nfsk_block_pread(c->resource, buf, offset, count);
    if (result <= 0 && count > 0) {
        /* Some upstream special-file parsers replace a backend error with
         * "unsupported" or even a regular-file type. Preserve its identity
         * across that one synchronous parse, without latching a write error. */
        c->read_failures++;
        c->last_read_error = result < 0 && errno ? errno : EIO;
    }
    if (result < 0) record_release_error(c, errno);
    return result;
}

static s64 record_write_result(nfsk_devctx *ctx, s64 result) {
    if (result < 0) {
        ctx->write_failures++;
        ctx->last_io_error = errno ? errno : EIO;
        record_release_error(ctx, ctx->last_io_error);
    }
    return result;
}

static s64 dev_pwrite(struct ntfs_device *dev, const void *buf, s64 count, s64 offset) {
    nfsk_devctx *c = dev->d_private;
    if (c->release_error) { errno = c->release_error; return -1; }
    if (NDevReadOnly(dev)) { errno = EROFS; return -1; }
    /* Even a failed write may have changed some bytes. A conservative per-volume
     * invalidation also covers aliases, attribute changes and failed rollbacks. */
    invalidate_directory_checkpoints(c);
    NDevSetDirty(dev);
    return record_write_result(c, nfsk_block_pwrite(c->resource, buf, offset, count));
}

static s64 dev_read(struct ntfs_device *dev, void *buf, s64 count) {
    nfsk_devctx *c = dev->d_private;
    s64 r = dev_pread(dev, buf, count, c->pos);
    if (r > 0) c->pos += r;
    return r;
}

static s64 dev_write(struct ntfs_device *dev, const void *buf, s64 count) {
    nfsk_devctx *c = dev->d_private;
    s64 r = dev_pwrite(dev, buf, count, c->pos);
    if (r > 0) c->pos += r;
    return r;
}

static int dev_sync(struct ntfs_device *dev) {
    nfsk_devctx *c = dev->d_private;
    if (c->release_error) { errno = c->release_error; return -1; }
    if (NDevReadOnly(dev)) return 0;
    int r = nfsk_block_sync(c->resource);
    if (r == 0) NDevClearDirty(dev);
    else { errno = -r; record_release_error(c, errno); return -1; }
    return 0;
}

static int dev_stat(struct ntfs_device *dev, struct stat *buf) {
    nfsk_devctx *c = dev->d_private;
    memset(buf, 0, sizeof(*buf));
    buf->st_mode = S_IFBLK | 0600;
    buf->st_size = (off_t)nfsk_block_total_bytes(c->resource);
    buf->st_blksize = (blksize_t)nfsk_block_sector_size(c->resource);
    if (buf->st_blksize > 0) buf->st_blocks = buf->st_size / buf->st_blksize;
    return 0;
}

static int dev_ioctl(struct ntfs_device *dev, unsigned long request, void *argp) {
    nfsk_devctx *c = dev->d_private;
    switch (request) {
        case DKIOCGETBLOCKSIZE:
            *(uint32_t *)argp = nfsk_block_sector_size(c->resource);
            return 0;
        case DKIOCGETBLOCKCOUNT: {
            uint32_t s = nfsk_block_sector_size(c->resource);
            *(uint64_t *)argp = s ? nfsk_block_total_bytes(c->resource) / s : 0;
            return 0;
        }
        default: errno = ENOTTY; return -1;
    }
}

static struct ntfs_device_operations fskit_io_ops = {
    .open = dev_open, .close = dev_close, .seek = dev_seek,
    .read = dev_read, .write = dev_write, .pread = dev_pread, .pwrite = dev_pwrite,
    .sync = dev_sync, .stat = dev_stat, .ioctl = dev_ioctl,
};

/* ---- Volume wrapper + helpers ---- */
struct ntfs_fskit_volume {
    ntfs_volume *vol;
    nfsk_devctx *devctx;
    int          read_only;
};

static int nfsk_release_open_ref(ntfs_fskit_volume *v, nfsk_open_ref **slot);

static nfsk_devctx *volume_context(ntfs_volume *vol) { return vol->dev->d_private; }

/* Reserve ownership before opening: failed closes must retain their dirty inode.
 * Block new operations until synchronize retries it, avoiding duplicate live inodes. */
static ntfs_inode *nfsk_inode_open(ntfs_volume *vol, MFT_REF ref) {
    nfsk_devctx *ctx = volume_context(vol);
    if (ctx->writeback_error) { errno = ctx->writeback_error; return NULL; }
    nfsk_inode_ref *entry = calloc(1, sizeof(*entry));
    if (!entry) return NULL;
    ntfs_inode *ni = ntfs_inode_open(vol, ref);
    if (!ni) { int saved = errno; free(entry); errno = saved; return NULL; }
    entry->inode = ni;
    entry->next = ctx->inodes;
    ctx->inodes = entry;
    return ni;
}

static void nfsk_forget_inode(ntfs_inode *ni) {
    nfsk_inode_ref **entry = &volume_context(ni->vol)->inodes;
    while (*entry && (*entry)->inode != ni) entry = &(*entry)->next;
    if (*entry) { nfsk_inode_ref *old = *entry; *entry = old->next; free(old); }
}

static bool inode_has_changes(const ntfs_inode *ni) {
    if (NInoDirty(ni) || NInoAttrListDirty(ni) || NInoFileNameDirty(ni)) return true;
    for (int i = 0; i < ni->nr_extents; i++) {
        if (inode_has_changes(ni->extent_nis[i])) return true;
    }
    return false;
}

static MFT_REF nfsk_inode_reference(const ntfs_inode *ni) {
    return MK_MREF(ni->mft_no, le16_to_cpu(ni->mrec->sequence_number));
}

/* This batch may only recompress a tail wholly beyond the old logical and
 * initialized sizes. Recompressing an old half-full unit can expose encoded
 * bytes as pre-existing content before its new mapping reaches disk. */
static bool nfsk_new_compressed_tail(const ntfs_attr *attr) {
    const nfsk_devctx *ctx = volume_context(attr->ni->vol);
    uint64_t unit = (uint64_t)attr->ni->vol->cluster_size << STANDARD_COMPRESSION_UNIT;
    if (!NAttrNonResident(attr) || (attr->data_flags & ATTR_COMPRESSION_MASK) != ATTR_IS_COMPRESSED ||
        attr->ni->vol->cluster_size < 512 || unit > 65536 ||
        attr->compression_block_size != unit ||
        attr->compression_block_clusters != (1U << STANDARD_COMPRESSION_UNIT) ||
        attr->initialized_size <= 0 || attr->initialized_size > attr->data_size) return false;
    uint64_t last_unit = ((uint64_t)attr->initialized_size - 1) / unit * unit;
    return ctx->compressed_safe_from >= 0 && last_unit >= (uint64_t)ctx->compressed_safe_from;
}

/* On failure keep the attribute/runlist and its already-owned inode for sync.
 * Ordinary close must not immediately retry this failed compression operation. */
static int nfsk_compressed_pclose(ntfs_attr *attr) {
    nfsk_devctx *ctx = volume_context(attr->ni->vol);
    uint64_t failures = ctx->write_failures;
    uint64_t writes = ctx->directory_generation;
    int rc = 0;
    if (nfsk_new_compressed_tail(attr))
        rc = ntfs_attr_pclose(attr);
    if (rc || failures != ctx->write_failures) {
        int error = failures != ctx->write_failures ? ctx->last_io_error : (errno ? errno : EIO);
        ctx->compression_retry = attr;
        if (!ctx->writeback_error) ctx->writeback_error = error;
        /* Upstream may already have replaced raw data with encoded bytes before
         * a later bitmap/runlist error. Re-running pclose can encode those bytes
         * as file contents. Only a failure before any write attempt is retryable. */
        if (writes != ctx->directory_generation) ctx->fatal_writeback_error = error;
        errno = error;
        return -1;
    }
    ntfs_attr_close(attr);
    ctx->compression_retry = NULL;
    ctx->compressed_pending = 0;
    ctx->compressed_safe_from = 0;
    return 0;
}

static int nfsk_sync_inode(ntfs_inode *ni) {
    nfsk_devctx *ctx = volume_context(ni->vol);
    uint64_t failures = ctx->write_failures;
    /* The library's index-context destructor does not propagate write errors.
     * Flush while we still own the inode, so its filename index can be retried. */
    // ntfs_inode_sync rewrites STANDARD_INFORMATION even on a clean inode.
    // Calling it unconditionally turns lookups/reads into writes and also
    // prevents an error teardown from freeing intentionally discarded inodes.
    int rc = inode_has_changes(ni) ? ntfs_inode_sync(ni) : 0;
    if (rc || failures != ctx->write_failures) {
        int error = failures != ctx->write_failures ? ctx->last_io_error : (errno ? errno : EIO);
        NInoSetDirty(ni);
        NInoFileNameSetDirty(ni);
        errno = error;
        return -1;
    }
    return 0;
}

static int nfsk_real_close(ntfs_inode *ni) {
    nfsk_devctx *ctx = volume_context(ni->vol);
    if (ctx->compression_retry && ctx->compression_retry->ni == ni &&
        nfsk_compressed_pclose(ctx->compression_retry)) return -1;
    if (nfsk_sync_inode(ni)) return -1;
#if CACHE_NIDATA_SIZE
    // The caching close can retry/free an inode while still returning its first error.
    return ntfs_inode_real_close(ni);
#else
    return ntfs_inode_close(ni);
#endif
}

static int nfsk_inode_close(ntfs_inode *ni) {
    if (!ni) return 0;
    int saved = errno;
    nfsk_devctx *ctx = volume_context(ni->vol);
    if (ctx->compression_retry && ctx->compression_retry->ni == ni) {
        errno = ctx->writeback_error ? ctx->writeback_error : EIO;
        return -1;
    }
    nfsk_inode_ref **entry = &ctx->inodes;
    while (*entry && (*entry)->inode != ni) entry = &(*entry)->next;
    if (nfsk_real_close(ni)) {
        int error = errno ? errno : EIO;
        if (!ctx->writeback_error) ctx->writeback_error = error;
        errno = error;
        return -1;
    }
    if (*entry) { nfsk_inode_ref *old = *entry; *entry = old->next; free(old); }
    errno = saved;
    return 0;
}

static int nfsk_finish_compressed_inode(ntfs_inode *ni) {
    nfsk_devctx *ctx = volume_context(ni->vol);
    if (ctx->compressed_pending != nfsk_inode_reference(ni)) return 0;
    ntfs_attr *attr = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (!attr) {
        int error = errno ? errno : EIO;
        if (!ctx->writeback_error) ctx->writeback_error = error;
        errno = error;
        return -1;
    }
    return nfsk_compressed_pclose(attr);
}

static int nfsk_finish_compressed(ntfs_volume *vol) {
    nfsk_devctx *ctx = volume_context(vol);
    if (!ctx->compressed_pending) return 0;
    ntfs_inode *ni = nfsk_inode_open(vol, ctx->compressed_pending);
    if (!ni) return -1;
    int error = nfsk_inode_reference(ni) != ctx->compressed_pending ? ESTALE :
                (nfsk_finish_compressed_inode(ni) ? (errno ? errno : EIO) : 0);
    if (nfsk_inode_close(ni) && !error) error = errno ? errno : EIO;
    if (error) errno = error;
    return error ? -1 : 0;
}

static int nfsk_prepare_compressed(ntfs_attr *attr) {
    if ((attr->data_flags & ATTR_COMPRESSION_MASK) != ATTR_IS_COMPRESSED) return 0;
    nfsk_devctx *ctx = volume_context(attr->ni->vol);
    MFT_REF ref = nfsk_inode_reference(attr->ni);
    if (ctx->compressed_pending == ref) return 0;
    if (ctx->compressed_pending && nfsk_finish_compressed(attr->ni->vol)) return -1;
    uint64_t unit = (uint64_t)attr->ni->vol->cluster_size << STANDARD_COMPRESSION_UNIT;
    s64 end = attr->data_size > attr->initialized_size ? attr->data_size : attr->initialized_size;
    if (end < 0 || attr->ni->vol->cluster_size < 512 || unit > 65536 ||
        (uint64_t)end > INT64_MAX - (unit - 1)) return 0;
    ctx->compressed_safe_from = (s64)(((uint64_t)end + unit - 1) / unit * unit);
    ctx->compressed_pending = ref;
    return 0;
}

static nfsk_open_ref *nfsk_open_ref_for(ntfs_volume *vol, MFT_REF ref) {
    for (nfsk_open_ref *entry = volume_context(vol)->open_items; entry; entry = entry->next)
        if (MREF(entry->ref) == MREF(ref)) return entry;
    return NULL;
}

static bool nfsk_has_retention(ntfs_volume *vol, MFT_REF ref) {
    // Only retention queries can skip anchorless opens; registration/deletion
    // must still find them so the first unlink can install its anchor.
    if (!volume_context(vol)->retention_count) return false;
    nfsk_open_ref *entry = nfsk_open_ref_for(vol, ref);
    return entry && entry->anchor;
}

static bool nfsk_unlinked_directory(ntfs_inode *dir) {
    return nfsk_has_retention(dir->vol, dir->mft_no) &&
           le16_to_cpu(dir->mrec->link_count) == 1;
}

/* A WIN32/DOS name pair is removed by one ntfs_delete call. Its link_count is
 * two, but neither name keeps an open file alive after that deletion. */
static int nfsk_last_visible_link(ntfs_inode *ni) {
    unsigned links = le16_to_cpu(ni->mrec->link_count);
    if (links != 2) return links == 1;
    ntfs_attr_search_ctx *search = ntfs_attr_get_search_ctx(ni, NULL);
    if (!search) return -1;
    int result = 0, error = 0;
    while (!ntfs_attr_lookup(AT_FILE_NAME, AT_UNNAMED, 0, CASE_SENSITIVE, 0, NULL, 0, search)) {
        ATTR_RECORD *attr = search->attr;
        unsigned offset = le16_to_cpu(attr->value_offset), length = le32_to_cpu(attr->value_length);
        unsigned record = le32_to_cpu(attr->length);
        if (attr->non_resident || offset > record || length > record - offset || length < sizeof(FILE_NAME_ATTR)) {
            error = EIO; break;
        }
        FILE_NAME_ATTR *name = (FILE_NAME_ATTR *)((u8 *)attr + offset);
        if (name->file_name_type == FILE_NAME_DOS) { result = 1; break; }
    }
    if (!result && !error && errno != ENOENT) error = errno ? errno : EIO;
    ntfs_attr_put_search_ctx(search);
    if (error) { errno = error; return -1; }
    return result;
}

/* Keep an open item alive before deleting its last visible name. The root
 * anchor avoids preventing removal of the item's original parent directory. */
static int nfsk_preserve_open_item(ntfs_inode *ni, ntfs_inode *dir) {
    nfsk_open_ref *entry = nfsk_open_ref_for(ni->vol, ni->mft_no);
    if (!entry || !entry->open || entry->anchor) return 0;
    int last = nfsk_last_visible_link(ni);
    if (last <= 0) return last;
    if ((ni->mrec->flags & MFT_RECORD_IS_DIRECTORY) && ntfs_check_empty_dir(ni)) return -1;
    ntfs_inode *root = dir->mft_no == FILE_root ? dir : nfsk_inode_open(ni->vol, FILE_root);
    if (!root) return -1;
    int error = EEXIST;
    for (int attempt = 0; attempt < 32; attempt++) {
        char name[96];
        snprintf(name, sizeof name, ".xntfs-open-%016llx-%08x%08x",
                 (unsigned long long)ni->mft_no, arc4random(), arc4random());
        ntfschar *unicode = NULL;
        int length = ntfs_mbstoucs(name, &unicode);
        if (length < 0) { error = errno ? errno : ENOMEM; break; }
        errno = 0;
        MFT_REF existing = ntfs_inode_lookup_by_name(root, unicode, length);
        if (existing != (MFT_REF)-1) { free(unicode); continue; }
        if (errno != ENOENT) { error = errno ? errno : EIO; free(unicode); break; }
        if (ntfs_link(ni, root, unicode, length)) {
            error = errno ? errno : EIO;
            free(unicode);
            break;
        }
        entry->anchor = unicode;
        entry->anchor_length = length;
        volume_context(ni->vol)->retention_count++;
        error = 0;
        break;
    }
    if (root != dir && nfsk_inode_close(root) && !error) error = errno ? errno : EIO;
    if (error) errno = error;
    return error ? -1 : 0;
}

static bool nfsk_is_retention_name(ntfs_volume *vol, uint64_t dir_mft,
                                  const ntfschar *name, int length) {
    // Ordinary opens need no root-name filtering until an anchor is installed.
    if (dir_mft != FILE_root || !volume_context(vol)->retention_count) return false;
    for (nfsk_open_ref *entry = volume_context(vol)->open_items; entry; entry = entry->next) {
        if (entry->anchor && ntfs_names_are_equal(entry->anchor, entry->anchor_length,
                name, length, IGNORE_CASE, vol->upcase, vol->upcase_len)) return true;
    }
    return false;
}

static int nfsk_delete(ntfs_volume *vol, ntfs_inode *ni, ntfs_inode *dir,
                       const ntfschar *name, int length) {
    if (nfsk_finish_compressed_inode(ni) || nfsk_preserve_open_item(ni, dir)) {
        int saved = errno ? errno : EIO;
        nfsk_inode_close(ni);
        nfsk_inode_close(dir);
        errno = saved;
        return -1;
    }
    // ntfs_delete consumes both pointers, including on failure.
    nfsk_forget_inode(ni);
    nfsk_forget_inode(dir);
    int rc = ntfs_delete(vol, NULL, ni, dir, name, length);
    if (rc && (errno == EIO || errno == EBUSY || errno == ENOSPC)) {
        nfsk_devctx *ctx = volume_context(vol);
        // The namespace may already have changed. Never run a destructive rollback
        // or acknowledge a successful sync after an unrecoverable internal writeback.
        ctx->fatal_writeback_error = ctx->writeback_error = errno;
    }
    return rc;
}

static inline u64 to_mref(uint64_t ino) {
    return (ino == NFSK_ROOT_INO) ? (u64)FILE_root : (u64)ino;
}
static inline uint64_t from_mft(u64 mft_no) {
    return (mft_no == (u64)FILE_root) ? NFSK_ROOT_INO : (uint64_t)mft_no;
}

/* NTFS records 0..15 are reserved metadata ($MFT, $MFTMirr, $LogFile, $Volume,
 * $Bitmap, $Boot, $Extend, ...). FILE_root (5) is the visible root, remapped to
 * NFSK_ROOT_INO; every other sub-FILE_first_user record is metadata that must never
 * be exposed as a file — its raw MFT number also collides with reserved FSKit item
 * IDs ($MFT=0=invalid, $MFTMirr=1=parentOfRoot, $LogFile=2=root). */
static inline int is_reserved_mft(u64 mft_no) {
    return mft_no < (u64)FILE_first_user && mft_no != (u64)FILE_root;
}

/* Returns 1 = directory, 0 = non-directory, -1 = error (errno set). When the inode
 * is a directory and empty_out != NULL, *empty_out is set to 1 (empty) or 0 (not).
 * A real emptiness-probe failure (EIO/corruption — NOT "directory not empty") is
 * reported as -1 with errno, so it is never silently turned into ENOTEMPTY. */
static int nfsk_isdir(ntfs_volume *vol, u64 ref, int *empty_out) {
    ntfs_inode *ni = nfsk_inode_open(vol, ref);
    if (!ni) return -1;
    int isdir = (ni->mrec->flags & MFT_RECORD_IS_DIRECTORY) ? 1 : 0;
    int ret = isdir, saved = 0;
    if (empty_out) {
        *empty_out = 1;
        if (isdir) {
            errno = 0;
            if (ntfs_check_empty_dir(ni) != 0) {
                if (errno == ENOTEMPTY) *empty_out = 0;
                else { ret = -1; saved = errno ? errno : EIO; }   /* real I/O error */
            }
        }
    }
    nfsk_inode_close(ni);
    if (ret == -1 && saved) errno = saved;
    return ret;
}

/* Read the first FILE_NAME parent, preserving missing-name vs. read/allocation
 * errors. The root has no parent MFT; leave the output at (u64)-1 on failure. */
static int nfsk_parent_mft_raw(ntfs_inode *ni, u64 *pmft) {
    *pmft = (u64)-1;
    if (ni->mft_no == (u64)FILE_root) return 0;
    ntfs_attr_search_ctx *ctx = ntfs_attr_get_search_ctx(ni, NULL);
    if (!ctx) return -(errno ? errno : ENOMEM);
    int result = 0;
    if (!ntfs_attr_lookup(AT_FILE_NAME, AT_UNNAMED, 0, CASE_SENSITIVE, 0, NULL, 0, ctx)) {
        const FILE_NAME_ATTR *fn = (const FILE_NAME_ATTR *)
            ((const u8 *)ctx->attr + le16_to_cpu(ctx->attr->value_offset));
        *pmft = MREF(le64_to_cpu(fn->parent_directory));
    } else result = -(errno ? errno : EIO);
    ntfs_attr_put_search_ctx(ctx);
    return result;
}

/* Parent directory (in our numbering) for attributes. NTFS hard links give one inode
 * several FILE_NAME attrs in different directories; we report the first — a stable,
 * deterministic choice — because FSKit identity is per fileID and cannot represent
 * multiple parents. A missing name or reserved parent leaves *parent at 0 for
 * Swift's lookup hint; real errors fail the query. Enumeration supplies its own
 * listing parent and does not call this helper. */
static int nfsk_parent_ino(ntfs_inode *ni, uint64_t *parent) {
    *parent = 0;
    if (ni->mft_no == (u64)FILE_root) { *parent = NFSK_PARENT_OF_ROOT; return 0; }
    u64 pmft;
    int result = nfsk_parent_mft_raw(ni, &pmft);
    if (result && result != -ENOENT) return result;
    if (pmft != (u64)-1 && !is_reserved_mft(pmft)) *parent = from_mft(pmft);
    return 0;
}

/* Returns 1 if `sref` is `dst_dir` itself or an ancestor of it — i.e. moving the
 * directory `sref` into `dst_dir` would create a cycle (mv A A/B/C). 0 if not, -1 on
 * error (errno set). Walks dst_dir's FILE_NAME parent chain up toward the root. */
static int nfsk_dir_contains(ntfs_volume *vol, u64 sref, uint64_t dst_dir) {
    u64 cur = to_mref(dst_dir);
    for (int guard = 0; guard < 65536; guard++) {
        if (MREF(cur) == MREF(sref)) return 1;
        if (MREF(cur) == (u64)FILE_root) return 0;
        ntfs_inode *ni = nfsk_inode_open(vol, cur);
        if (!ni) return -1;                                /* errno from ntfs_inode_open */
        u64 par;
        int result = nfsk_parent_mft_raw(ni, &par);
        nfsk_inode_close(ni);                              /* clobbers errno, so set it below */
        if (result || par == (u64)-1) { errno = EIO; return -1; } /* unreadable parent chain */
        cur = par;
    }
    errno = ELOOP;   /* chain too long → cyclic/corrupt metadata, not a real ancestry */
    return -1;
}

static uint32_t map_dt(unsigned dt_type) {
    switch (dt_type) {
        case NTFS_DT_DIR:     return NFSK_TYPE_DIR;
        /* Reparse links are classified separately after checking their target. */
        case NTFS_DT_LNK:     return NFSK_TYPE_FILE;
        case NTFS_DT_REPARSE: return NFSK_TYPE_FILE;
        case NTFS_DT_FIFO:    return NFSK_TYPE_FIFO;
        case NTFS_DT_SOCK:    return NFSK_TYPE_SOCKET;
        case NTFS_DT_BLK:     return NFSK_TYPE_BLOCKDEV;
        case NTFS_DT_CHR:     return NFSK_TYPE_CHARDEV;
        case NTFS_DT_REG:
        default:              return NFSK_TYPE_FILE;
    }
}

static struct ntfs_device *make_device(void *resource, nfsk_devctx **out_ctx) {
    nfsk_devctx *c = calloc(1, sizeof(*c));
    if (!c) { errno = ENOMEM; return NULL; }
    c->resource = resource;
    c->pos = 0;
    struct ntfs_device *dev = ntfs_device_alloc("ntfs-fskit", 0, &fskit_io_ops, c);
    if (!dev) { free(c); return NULL; }
    *out_ctx = c;
    return dev;
}

/* The durable NTFS volume serial: a 64-bit value in the boot sector at offset 0x48
 * (le64). ntfs-3g treats it as "Irrelevant" and doesn't cache it, so read it straight
 * from the backend. Used to give the volume a stable identity instead of a weak label+size
 * hash: the serial is immutable, so identity survives relabels and stays distinct between
 * independently-formatted same-label/same-size volumes. (A block-level clone copies the
 * serial, so clones intentionally share identity — inherent to any on-disk id.)
 * This issues block I/O, so read it before serving mounted-volume requests — never
 * from nfsk_statfs() (see nfsk_devctx.boot_serial). */
static uint64_t read_boot_serial(void *resource) {
    unsigned char b[8];
    if (nfsk_block_pread(resource, b, 0x48, (int64_t)sizeof b) != (int64_t)sizeof b) return 0;
    uint64_t s = 0;
    for (int i = 0; i < 8; i++) s |= (uint64_t)b[i] << (8 * i);
    return s;
}

/* ---- Lifecycle ---- */
static int nfsk_name_to_utf8(const ntfschar *name, int length, char **output);

/* Native mount already owns $Volume and its decoded name. Correct the valid
 * label's literal BOM prefix once, before publishing this volume or probe.
 * Normal labels and the native fallback for malformed Unicode stay unchanged. */
static int nfsk_preserve_volume_name(ntfs_volume *vol) {
    ntfs_attr_search_ctx *search = ntfs_attr_get_search_ctx(vol->vol_ni, NULL);
    if (!search) { if (!errno) errno = ENOMEM; return -1; }
    int error = 0;
    if (ntfs_attr_lookup(AT_VOLUME_NAME, AT_UNNAMED, 0, CASE_SENSITIVE, 0, NULL, 0, search)) {
        if (errno != ENOENT) error = errno ? errno : EIO;
    } else {
        const ATTR_RECORD *attr = search->attr;
        unsigned offset = le16_to_cpu(attr->value_offset), bytes = le32_to_cpu(attr->value_length);
        unsigned record = le32_to_cpu(attr->length);
        if (attr->non_resident || offset > record || bytes > record - offset || (offset & 1)) error = EIO;
        else if (bytes >= sizeof(ntfschar) && bytes <= 256 && !(bytes & 1)) {
            const ntfschar *label = (const ntfschar *)((const u8 *)attr + offset);
            if (label[0] == const_cpu_to_le16(0xfeff)) {
                char *name = NULL;
                if (nfsk_name_to_utf8(label, (int)(bytes / sizeof(ntfschar)), &name) < 0) {
                    if (errno != EILSEQ) error = errno ? errno : EIO;
                } else {
                    free(vol->vol_name);
                    vol->vol_name = name;
                    name = NULL;
                }
                free(name);
            }
        }
    }
    ntfs_attr_put_search_ctx(search);
    if (error) errno = error;
    return error ? -1 : 0;
}

ntfs_fskit_volume *nfsk_mount(void *resource, bool read_only, int *out_errno) {
    nfsk_devctx *ctx = NULL;
    struct ntfs_device *dev = make_device(resource, &ctx);
    if (!dev) { if (out_errno) *out_errno = errno; return NULL; }

    ntfs_mount_flags flags = NTFS_MNT_MAY_RDONLY;
    if (read_only) flags |= NTFS_MNT_RDONLY;

    ntfs_volume *vol = ntfs_device_mount(dev, flags);
    if (!vol) {
        if (out_errno) *out_errno = errno ? errno : EIO;
        ntfs_device_free(dev);
        free(ctx);
        return NULL;
    }
    if (ntfs_volume_get_free_space(vol) || ntfs_set_ignore_case(vol) || nfsk_preserve_volume_name(vol)) {
        int saved = errno ? errno : EIO;
        ntfs_umount(vol, TRUE);
        free(ctx);
        if (out_errno) *out_errno = saved;
        return NULL;
    }
    /* Cache the immutable serial before the volume starts serving requests. Re-reading
     * it from nfsk_statfs() added synchronous block I/O to the FSKit request path, where
     * a blocked read was observed to stall the volume under write load. */
    ctx->boot_serial = read_boot_serial(resource);
    /* ntfs_make_symlink/ntfs_get_abslink resolve an *absolute* reparse target relative to
     * vol->abs_mnt_point (the `mnt_point` arg is ignored — it's __attribute__((unused))).
     * ntfs_device_mount leaves abs_mnt_point NULL (only the FUSE layer sets it), so an
     * absolute Windows symlink/junction would strlen(NULL) and crash. Anchor it at "/"
     * (read-only literal; ntfs_get_abslink only reads it).
     * LIMITATION: the bridge can't know the real /Volumes/<name> mount point (FSKit assigns
     * it only after load), so an *absolute* Windows symlink/junction resolves best-effort
     * under "/" (e.g. //target or //.NTFS-3G/...), not the true volume path. RELATIVE symlinks
     * — the common POSIX case — are unaffected and resolve correctly. */
    vol->abs_mnt_point = "/";

    ntfs_fskit_volume *w = calloc(1, sizeof(*w));
    if (!w) { if (out_errno) *out_errno = ENOMEM; ntfs_umount(vol, TRUE); free(ctx); return NULL; }
    w->vol = vol;
    w->devctx = ctx;
    w->read_only = read_only || NVolReadOnly(vol);
    return w;
}

static int probe(void *resource, char *name_out, size_t name_cap, char **owned_name, uint64_t *serial_out) {
    nfsk_devctx *ctx = NULL;
    struct ntfs_device *dev = make_device(resource, &ctx);
    if (!dev) return 0;
    ntfs_volume *vol = ntfs_device_mount(dev, NTFS_MNT_RDONLY | NTFS_MNT_FORENSIC);
    if (!vol) { ntfs_device_free(dev); free(ctx); return 0; }
    if (((name_out && name_cap) || owned_name) && nfsk_preserve_volume_name(vol)) {
        ntfs_umount(vol, TRUE); free(ctx); return 0;
    }
    if (name_out && name_cap) {
        name_out[0] = '\0';
        if (vol->vol_name) { strncpy(name_out, vol->vol_name, name_cap - 1); name_out[name_cap - 1] = '\0'; }
    }
    if (owned_name) { *owned_name = vol->vol_name; vol->vol_name = NULL; }
    ntfs_umount(vol, TRUE);
    /* Read the serial after umount so only this code touches the backend. */
    if (serial_out) *serial_out = read_boot_serial(resource);
    free(ctx);
    return 1;
}

int nfsk_probe(void *resource, char *name_out, size_t name_cap, uint64_t *serial_out) {
    return probe(resource, name_out, name_cap, NULL, serial_out);
}

int nfsk_probe_name_alloc(void *resource, char **name_out, uint64_t *serial_out) {
    if (!name_out) return 0;
    *name_out = NULL;
    return probe(resource, NULL, 0, name_out, serial_out);
}

const char *nfsk_volume_name(ntfs_fskit_volume *v) {
    return v && v->vol ? v->vol->vol_name : NULL;
}

int nfsk_quick_check(void *resource, int *reason) {
    if (reason) *reason = NFSK_CHECK_METADATA;
    if (!resource) return -EINVAL;
    nfsk_devctx *ctx = NULL;
    struct ntfs_device *dev = make_device(resource, &ctx);
    if (!dev) return -(errno ? errno : ENOMEM);

    /* This validates the boot sector, MFT/MFTMirr and core system files without
     * replaying or resetting the journal, even if the backend allows writes. */
    ntfs_volume *vol = ntfs_device_mount(dev, NTFS_MNT_RDONLY | NTFS_MNT_FORENSIC);
    if (!vol) {
        int error = errno ? errno : EIO;
        ntfs_device_free(dev);
        free(ctx);
        return -error;
    }

    int error = 0, diagnostic = NFSK_CHECK_CLEAN;
    ntfs_inode *log_inode = NULL;
    ntfs_attr *log_data = NULL;
    RESTART_PAGE_HEADER *restart = NULL;
    if (vol->flags & (VOLUME_IS_DIRTY | VOLUME_CHKDSK_UNDERWAY)) {
        diagnostic = NFSK_CHECK_DIRTY;
        error = EIO;
        goto done;
    }
    if (ntfs_volume_check_hiberfile(vol, 0)) {
        error = errno ? errno : EIO;
        diagnostic = error == EPERM ? NFSK_CHECK_HIBERNATED : NFSK_CHECK_METADATA;
        goto done;
    }
    log_inode = ntfs_inode_open(vol, FILE_LogFile);
    if (!log_inode) {
        error = errno ? errno : EIO;
        diagnostic = NFSK_CHECK_JOURNAL;
        goto done;
    }
    log_data = ntfs_attr_open(log_inode, AT_DATA, AT_UNNAMED, 0);
    if (!log_data) {
        error = errno ? errno : EIO;
        diagnostic = NFSK_CHECK_JOURNAL;
        goto done;
    }
    errno = 0;
    if (!ntfs_check_logfile(log_data, &restart) ||
        !ntfs_is_logfile_clean(log_data, restart) ||
        (restart && restart->major_ver == const_cpu_to_le16(2) &&
         restart->minor_ver == const_cpu_to_le16(0))) {
        error = errno ? errno : EIO;
        diagnostic = NFSK_CHECK_JOURNAL;
    }
done:
    free(restart);
    if (log_data) ntfs_attr_close(log_data);
    if (log_inode && ntfs_inode_close(log_inode) && !error) {
        error = errno ? errno : EIO;
        diagnostic = NFSK_CHECK_METADATA;
    }
    if (ntfs_umount(vol, TRUE) && !error) {
        error = errno ? errno : EIO;
        diagnostic = NFSK_CHECK_METADATA;
    }
    free(ctx);
    if (reason) *reason = diagnostic;
    return -error;
}

static void discard_inode_changes(ntfs_inode *ni) {
    if (!ni) return;
    NInoClearDirty(ni);
    NInoAttrListClearDirty(ni);
    NInoFileNameClearDirty(ni);
    for (int i = 0; i < ni->nr_extents; i++) discard_inode_changes(ni->extent_nis[i]);
}

int nfsk_umount(ntfs_fskit_volume *v) {
    if (!v) return 0;
    nfsk_devctx *ctx = v->devctx;
    // This call destroys the handle even on error. Recoverable synchronization
    // uses nfsk_sync instead and retains all dirty inode ownership for retry.
    ctx->releasing = true;
    ctx->release_error = ctx->fatal_writeback_error ? ctx->fatal_writeback_error : ctx->writeback_error;
    for (nfsk_open_ref *entry = ctx->open_items; entry; entry = entry->next) entry->open = false;
    int error = ctx->release_error;
    if (v->vol && !error) {
        int rc = nfsk_sync(v);
        if (rc) { error = -rc; record_release_error(ctx, error); }
    }
    while (v->devctx && v->devctx->open_items) {
        nfsk_open_ref *entry = v->devctx->open_items;
        // Failed sync leaves recovery links on disk; free just the bookkeeping.
        v->devctx->open_items = entry->next;
        if (entry->anchor) v->devctx->retention_count--;
        free(entry->anchor);
        free(entry);
    }
    // Release failed compression before its retained inode.
    ntfs_attr_close(ctx->compression_retry);
    ctx->compression_retry = NULL;
    ctx->compressed_pending = 0;
    ctx->compressed_safe_from = 0;
    while (v->devctx && v->devctx->inodes) {
        nfsk_inode_ref *entry = v->devctx->inodes;
        ntfs_inode *ni = entry->inode;
        discard_inode_changes(ni);
        (void)nfsk_real_close(ni);
        v->devctx->inodes = entry->next;
        free(entry);
    }
    if (v->vol) {
        if (error) {
            // Let libntfs free its metadata without retrying dirty inode writes.
            discard_inode_changes(v->vol->lcnbmp_ni);
            discard_inode_changes(v->vol->mft_ni);
            discard_inode_changes(v->vol->mftmirr_ni);
            discard_inode_changes(v->vol->vol_ni);
            discard_inode_changes(v->vol->secure_ni);
        }
        if (ntfs_umount(v->vol, TRUE) && !error) error = errno ? errno : EIO;
    }
    if (!error) error = ctx->release_error;
    free(v->devctx);
    free(v);
    return -error;
}

int nfsk_sync(ntfs_fskit_volume *v) {
    if (!v || !v->vol) return -EINVAL;
    if (v->read_only) return 0;
    nfsk_devctx *ctx = v->devctx;
    int saved = ctx->writeback_error, current = ctx->fatal_writeback_error;
    if (current) goto failed;

    // A failed sync must retain its dirty inodes and stop this attempt. Visiting
    // the remaining inodes/metadata or flushing the device after an error can
    // multiply the device's timeout by the number of pending operations.
    nfsk_inode_ref **entry = &ctx->inodes;
    while (*entry) {
        nfsk_inode_ref *pending = *entry;
        if (nfsk_real_close(pending->inode)) {
            current = errno ? errno : EIO;
            goto failed;
        } else {
            *entry = pending->next;
            free(pending);
        }
    }
    // Retried inodes are now clean; allow open-file cleanup to reopen them.
    ctx->writeback_error = 0;
    if (nfsk_finish_compressed(v->vol)) {
        current = errno ? errno : EIO;
        goto failed;
    }
    nfsk_open_ref **opened = &ctx->open_items;
    while (*opened) {
        if ((*opened)->open) { opened = &(*opened)->next; continue; }
        int rc = nfsk_release_open_ref(v, opened);
        if (rc) {
            current = -rc;
            goto failed;
        }
    }
    ntfs_inode *metadata[] = { v->vol->lcnbmp_ni, v->vol->mft_ni,
                              v->vol->mftmirr_ni, v->vol->vol_ni, v->vol->secure_ni };
    for (size_t i = 0; i < sizeof(metadata) / sizeof(metadata[0]); i++) {
        if (metadata[i] && nfsk_sync_inode(metadata[i])) {
            current = errno ? errno : EIO;
            goto failed;
        }
    }
    // Explicit sync still requires a backend flush when no metadata changed;
    // ntfs_device_sync would skip it when the device dirty flag is clear.
    if (dev_sync(v->vol->dev)) current = errno ? errno : EIO;
failed:
    ctx->writeback_error = current;
    // Preserve the first saved error for one successful recovery attempt too.
    return -(current ? current : saved);
}

int nfsk_statfs_counters(ntfs_fskit_volume *v, nfsk_statfs_counters_t *out) {
    if (!v || !v->vol || !out) return -EINVAL;
    ntfs_volume *vol = v->vol;
    memset(out, 0, sizeof(*out));
    out->cluster_size = vol->cluster_size;
    out->total_clusters = vol->nr_clusters;
    s64 freec = vol->free_clusters; if (freec < 0) freec = 0;
    out->free_clusters = (uint64_t)freec;
    if (vol->mftbmp_na) out->total_files = ((uint64_t)vol->mftbmp_na->allocated_size << 3);
    s64 freem = vol->free_mft_records; if (freem < 0) freem = 0;
    out->free_files = (uint64_t)freem;
    out->read_only = v->read_only ? 1 : 0;
    /* Report the serial without block I/O on FSKit's request queue.
     * No fallback read here — a zero cached serial stays zero. */
    out->volume_serial = v->devctx ? v->devctx->boot_serial : 0;
    return 0;
}

int nfsk_statfs(ntfs_fskit_volume *v, nfsk_statfs_t *out) {
    if (!out) return -EINVAL;
    nfsk_statfs_counters_t counters;
    int rc = nfsk_statfs_counters(v, &counters);
    if (rc) return rc;
    memset(out, 0, sizeof(*out));
    out->cluster_size = counters.cluster_size;
    out->total_clusters = counters.total_clusters;
    out->free_clusters = counters.free_clusters;
    out->total_files = counters.total_files;
    out->free_files = counters.free_files;
    out->volume_serial = counters.volume_serial;
    out->read_only = counters.read_only;
    if (v->vol->vol_name) {
        strncpy(out->volume_name, v->vol->vol_name, sizeof(out->volume_name) - 1);
        out->volume_name[sizeof(out->volume_name) - 1] = '\0';
    }
    return 0;
}

/* ---- Attributes ---- */
static void fill_times(nfsk_attr_t *out, ntfs_inode *ni) {
    struct timespec ts;
    ts = ntfs2timespec(ni->last_data_change_time); out->mtime_sec = ts.tv_sec; out->mtime_nsec = ts.tv_nsec;
    ts = ntfs2timespec(ni->last_access_time);      out->atime_sec = ts.tv_sec; out->atime_nsec = ts.tv_nsec;
    ts = ntfs2timespec(ni->last_mft_change_time);  out->ctime_sec = ts.tv_sec; out->ctime_nsec = ts.tv_nsec;
    ts = ntfs2timespec(ni->creation_time);         out->btime_sec = ts.tv_sec; out->btime_nsec = ts.tv_nsec;
}

/* UNKNOWN means DATA could not be opened, while REG can also mask a failed
 * magic read. Preserve those errors separately from absent/opaque attributes.
 * A successful type may leave errno unchanged, so errno alone is not failure. */
static int nfsk_interix_type(ntfs_inode *ni) {
    nfsk_devctx *ctx = volume_context(ni->vol);
    uint64_t failures = ctx->read_failures;
    errno = 0;
    int type = ntfs_interix_types(ni);
    int error = errno;
    if (ctx->read_failures != failures) return -ctx->last_read_error;
    if (type == NTFS_DT_UNKNOWN && error && error != ENOENT) return -error;
    return type;
}

/* Keep the native target converter's raw UTF8/PATH_MAX bound, including the BOM.
 * FEFF and FFFD have equal UTF16/UTF8 widths and neither changes under NFC/NFD.
 * Temporarily substituting in our owned input prevents CF from consuming FEFF;
 * the caller still owns any partial output when conversion fails. */
static int nfsk_target_to_utf8(ntfschar *target, int length, char **output) {
    if (!length || target[0] != const_cpu_to_le16(0xfeff))
        return ntfs_ucstombs(target, length, output, 0);
    target[0] = const_cpu_to_le16(0xfffd);
    int result = ntfs_ucstombs(target, length, output, 0);
    target[0] = const_cpu_to_le16(0xfeff);
    if (result >= 0) {
        if (result < 3 || !*output || memcmp(*output, "\xef\xbf\xbd", 3)) {
            errno = EILSEQ;
            return -1;
        }
        memcpy(*output, "\xef\xbb\xbf", 3);
    }
    return result;
}

/* Record representation metadata only; native make_symlink still decides path
 * validity, resolution, case and drive mappings. These consumed syntax prefixes
 * are ASCII, so native conversion can lose at most one of the path's FEFF units.
 * Arbitrary non-ASCII drive-like strings are intentionally not inferred here. */
static int nfsk_windows_target_boms(const REPARSE_POINT *point, size_t *output_offset) {
    size_t header = point->reparse_tag == IO_REPARSE_TAG_MOUNT_POINT ? 8 : 12;
    size_t payload = le16_to_cpu(point->reparse_data_length);
    if (payload < header) return 0;
    le16 offset_bytes, length_bytes;
    memcpy(&offset_bytes, point->reparse_data, sizeof offset_bytes);
    memcpy(&length_bytes, point->reparse_data + 2, sizeof length_bytes);
    size_t offset = le16_to_cpu(offset_bytes), bytes = le16_to_cpu(length_bytes);
    if (((offset | bytes) & 1) || offset > payload - header || bytes > payload - header - offset || !bytes)
        return 0;
    const ntfschar *path = (const ntfschar *)(point->reparse_data + header + offset);
    size_t length = bytes / sizeof(ntfschar);
    if (path[0] == const_cpu_to_le16(0xfeff) &&
        (length == 1 || path[1] != const_cpu_to_le16(':'))) *output_offset = 0;
    else {
        size_t component;
        if (length >= 2 && path[0] == const_cpu_to_le16('\\')) {
            component = 1;
            if (length >= 8 && path[1] == const_cpu_to_le16('?') && path[2] == const_cpu_to_le16('?') &&
                path[3] == const_cpu_to_le16('\\')) {
                unsigned drive = le16_to_cpu(path[4]);
                if (!((drive >= 'A' && drive <= 'Z') || (drive >= 'a' && drive <= 'z')) ||
                    path[5] != const_cpu_to_le16(':') || path[6] != const_cpu_to_le16('\\')) return 0;
                component = 7;
            }
        } else if (length >= 4 && path[1] == const_cpu_to_le16(':') && path[2] == const_cpu_to_le16('\\')) {
            unsigned drive = le16_to_cpu(path[0]);
            if (!((drive >= 'A' && drive <= 'Z') || (drive >= 'a' && drive <= 'z'))) return 0;
            component = 3;
        } else return 0;
        if (path[component] != const_cpu_to_le16(0xfeff)) return 0;
        *output_offset = 2; /* Both native absolute helpers are anchored at "/". */
    }
    int boms = 0;
    for (size_t i = 0; i < length; i++) {
        if (!path[i]) return 0;
        if (path[i] == const_cpu_to_le16(0xfeff)) boms++;
    }
    return boms;
}

/* A reparse point counts as a symlink for us only when ntfs_make_symlink can actually
 * produce a target. ntfs_possible_symlink only checks the reparse tag, not the data, so a
 * junction / corrupt reparse with a symlink-ish tag would otherwise be typed SYMLINK yet
 * fail readlink afterwards; classifying by the real parse keeps the reported type in sync
 * with what readSymbolicLink can resolve. */
static char *read_symlink_target(ntfs_inode *ni, int *operation_error) {
    if (ni->flags & FILE_ATTR_REPARSE_POINT) {
        /* make_symlink leaks its readall buffer when structural validation
         * fails. The exported validator frees that buffer on failure and
         * retains readall's existing 64 KiB bound. No parsed state is cached. */
        errno = 0;
        REPARSE_POINT *point = ntfs_get_reparse_point(ni);
        if (!point) {
            int error = errno ? errno : EIO;
            /* Preserve opaque data policy without hiding a failed query. */
            if (error != ENOENT && error != EINVAL && error != EOVERFLOW && error != EOPNOTSUPP)
                *operation_error = -error;
            errno = error;
            return NULL;
        }
        if (point->reparse_tag == IO_REPARSE_TAG_LX_SYMLINK) {
            /* The upstream validator checked the le32 WSL type and length.
             * Unlike Windows links, the remaining bytes are already a UTF-8
             * target. Reuse this owned buffer, leaving room for its NUL in the
             * removed header, instead of rereading/reallocating the attribute. */
            size_t length = le16_to_cpu(point->reparse_data_length) - sizeof(le32);
            memmove(point, point->reparse_data + sizeof(le32), length);
            ((char *)point)[length] = 0;
            return (char *)point;
        }
        bool supported = point->reparse_tag == IO_REPARSE_TAG_MOUNT_POINT ||
            point->reparse_tag == IO_REPARSE_TAG_SYMLINK;
        size_t bom_offset = 0;
        int boms = supported ? nfsk_windows_target_boms(point, &bom_offset) : 0;
        free(point);
        if (!supported) { errno = EOPNOTSUPP; return NULL; }
        char *target = ntfs_make_symlink(ni, "/");
        if (!target || !boms) return target;
        int remaining = 0;
        for (const char *p = target; (p = strstr(p, "\xef\xbb\xbf")); p += 3) remaining++;
        /* Mapped fallback already retains the BOM. Counting the whole target
         * also distinguishes a real BOM-prefixed .NTFS-3G directory from that
         * fallback, and avoids duplicating a single-BOM converter fallback. */
        if (remaining + 1 != boms) return target;
        size_t length = strlen(target);
        if (bom_offset > length || (bom_offset && memcmp(target, "//", bom_offset))) {
            free(target); errno = EIO; *operation_error = -EIO; return NULL;
        }
        char *preserved = malloc(length + 4);
        if (!preserved) { free(target); errno = ENOMEM; return NULL; }
        memcpy(preserved, target, bom_offset);
        memcpy(preserved + bom_offset, "\xef\xbb\xbf", 3);
        memcpy(preserved + bom_offset + 3, target + bom_offset, length - bom_offset + 1);
        free(target);
        return preserved;
    }
    int type = ni->flags & FILE_ATTR_SYSTEM ? nfsk_interix_type(ni) : NTFS_DT_UNKNOWN;
    if (type < 0) {
        *operation_error = type;
        errno = -type;
        return NULL;
    }
    if (type != NTFS_DT_LNK) {
        errno = EINVAL;
        return NULL;
    }
    ntfs_attr *data = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (!data) {
        if (!errno) errno = EIO;
        if (errno != ENOENT) *operation_error = -errno;
        return NULL;
    }
    char *target = NULL;
    int error = EINVAL;
    size_t prefix = offsetof(INTX_FILE, target);
    if (data->data_size > (s64)prefix && data->data_size <= (s64)(prefix + 4096 * sizeof(ntfschar)) &&
        !((data->data_size - prefix) % sizeof(ntfschar))) {
        INTX_FILE *link = malloc((size_t)data->data_size);
        if (!link) error = ENOMEM;
        else {
            if (ntfs_attr_pread(data, 0, data->data_size, link) != data->data_size) error = errno ? errno : EIO;
            else if (link->magic == INTX_SYMBOLIC_LINK) {
                if (nfsk_target_to_utf8(link->target, (int)((data->data_size - prefix) / sizeof(ntfschar)), &target) < 0) {
                    error = errno ? errno : EILSEQ;
                    free(target);
                    target = NULL;
                }
            }
            free(link);
        }
    }
    ntfs_attr_close(data);
    if (!target) errno = error;
    return target;
}

/* Distinguish proven operation failures from malformed/unsupported targets,
 * whose existing opaque-file fallback cannot be decided by errno alone. */
static char *nfsk_symlink_target(ntfs_inode *ni, int *operation_error) {
    int ignored_error;
    if (!operation_error) operation_error = &ignored_error;
    *operation_error = 0;
    nfsk_devctx *ctx = ni->vol->dev->d_private;
    uint64_t failures = ctx->read_failures;
    char *target = read_symlink_target(ni, operation_error);
    if (ctx->read_failures != failures) {
        free(target);
        errno = ctx->last_read_error;
        *operation_error = -errno;
        return NULL;
    }
    return target;
}

/* Positive NFSK_TYPE, zero for opaque data, negative errno for a failed read. */
static int nfsk_inode_type_size(ntfs_inode *ni, uint64_t *symlink_size) {
    if (ni->mrec->flags & MFT_RECORD_IS_DIRECTORY) return NFSK_TYPE_DIR;
    if (!(ni->flags & (FILE_ATTR_REPARSE_POINT | FILE_ATTR_SYSTEM))) return NFSK_TYPE_FILE;
    if (!(ni->flags & FILE_ATTR_REPARSE_POINT)) {
        int type = nfsk_interix_type(ni);
        if (type < 0) return type;
        if (type != NTFS_DT_LNK) return map_dt(type);
    }
    int operation_error;
    char *target = nfsk_symlink_target(ni, &operation_error);
    if (!target) {
        if (operation_error) return operation_error;
        return errno == ENOMEM ? -ENOMEM : 0;
    }
    if (symlink_size) *symlink_size = (uint64_t)strlen(target);
    free(target);
    return NFSK_TYPE_SYMLINK;
}

static int nfsk_inode_type(ntfs_inode *ni) {
    return nfsk_inode_type_size(ni, NULL);
}

static int nfsk_inode_attributes(ntfs_fskit_volume *v, ntfs_inode *ni,
                                  uint64_t parent, nfsk_attr_t *out) {
    memset(out, 0, sizeof(*out));
    out->ino = from_mft(ni->mft_no);
    out->parent_ino = parent;
    if (!parent) {
        int result = nfsk_parent_ino(ni, &out->parent_ino);
        if (result) return result;
    }
    out->nlink = le16_to_cpu(ni->mrec->link_count);
    bool retained = nfsk_has_retention(v->vol, ni->mft_no);
    if (retained && out->nlink) out->nlink--;
    /* Formatters may mark the NTFS root HIDDEN | SYSTEM. Exposing HIDDEN here
     * hides the entire mounted volume in macOS, not just an ordinary item. */
    out->flags = ni->mft_no != FILE_root && (ni->flags & FILE_ATTR_HIDDEN) ? UF_HIDDEN : 0;

    uint64_t symlink_size = 0;
    int type = nfsk_inode_type_size(ni, &symlink_size);
    if (type < 0) return type;
    if (type == NFSK_TYPE_DIR) {
        out->type = NFSK_TYPE_DIR;
        if (!test_nino_flag(ni, KnownSize)) {
            ntfs_attr *na = ntfs_attr_open(ni, AT_INDEX_ALLOCATION, NTFS_INDEX_I30, 4);
            if (na) { ni->data_size = na->data_size; ni->allocated_size = na->allocated_size;
                      set_nino_flag(ni, KnownSize); ntfs_attr_close(na); }
            else if (errno != ENOENT) return -(errno ? errno : EIO);
        }
        out->size = (uint64_t)ni->data_size;
        out->alloc_size = (uint64_t)ni->allocated_size;
        out->mode = 0777;
        if (out->nlink == 0 && !retained) out->nlink = 1;
    } else if (type == NFSK_TYPE_SYMLINK) {
        // Use the same parsed target for classification and POSIX size.
        // Unresolvable/opaque reparse points retain the regular-file path.
        out->type = NFSK_TYPE_SYMLINK;
        out->size = out->alloc_size = symlink_size;
        out->mode = 0777;
    } else {
        out->type = type ? type : NFSK_TYPE_FILE;
        ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
        if (na) { out->size = (uint64_t)na->data_size;
                  out->alloc_size = (uint64_t)((na->data_flags & (ATTR_IS_SPARSE | ATTR_IS_COMPRESSED)) ? na->compressed_size : na->allocated_size);
                  ntfs_attr_close(na); }
        else if (errno == ENOENT) { out->size = (uint64_t)ni->data_size; out->alloc_size = (uint64_t)ni->allocated_size; }
        else return -(errno ? errno : EIO);
        out->mode = (ni->flags & FILE_ATTR_READONLY) ? 0444 : 0666;
    }
    fill_times(out, ni);
    return 0;
}

int nfsk_getattr(ntfs_fskit_volume *v, uint64_t ino, nfsk_attr_t *out) {
    if (!v || !v->vol || !out) return -EINVAL;
    if (is_reserved_mft(to_mref(ino))) return -ENOENT;
    ntfs_inode *ni = nfsk_inode_open(v->vol, to_mref(ino));
    if (!ni) return -(errno ? errno : EIO);
    int result = nfsk_inode_attributes(v, ni, 0, out);
    if (nfsk_inode_close(ni) && !result) result = -(errno ? errno : EIO);
    return result;
}

uint64_t nfsk_lookup(ntfs_fskit_volume *v, uint64_t dir_ino, const char *name_utf8, int *out_errno) {
    return nfsk_lookup_name(v, dir_ino, name_utf8, NULL, 0, out_errno);
}

/* macOS normalization consumes a leading UTF8 BOM. In a filesystem name every BOM
 * is content, so normalize only the suffix and retain the literal prefix.
 * Non-BOM names keep the original converter and its allocation behavior. */
static int nfsk_name_to_unicode(const char *name, ntfschar **output) {
    if (strncmp(name, "\xef\xbb\xbf", 3)) return ntfs_mbstoucs(name, output);
    int prefix = 0;
    do {
        if (++prefix >= PATH_MAX) { errno = ENAMETOOLONG; return -1; }
        name += 3;
    } while (!strncmp(name, "\xef\xbb\xbf", 3));
    ntfschar *suffix = NULL;
    int length = *name ? ntfs_mbstoucs(name, &suffix) : 0;
    if (length < 0) return -1;
    /* Preserve the native converter's total UTF16 limit, including the NUL. */
    if (length >= PATH_MAX - prefix) { free(suffix); errno = ENAMETOOLONG; return -1; }
    ntfschar *text = malloc((size_t)(prefix + length + 1) * sizeof(ntfschar));
    if (!text) { free(suffix); errno = ENOMEM; return -1; }
    for (int i = 0; i < prefix; i++) text[i] = const_cpu_to_le16(0xfeff);
    if (length) memcpy(text + prefix, suffix, (size_t)length * sizeof(ntfschar));
    text[prefix + length] = const_cpu_to_le16(0);
    free(suffix);
    *output = text;
    return prefix + length;
}

/* FILE_NAME values and standard volume labels contain at most 255 UTF16 units. Keep the
 * suffix's allocated NFD result, which can exceed PATH_MAX after normalization. */
static int nfsk_name_to_utf8(const ntfschar *name, int length, char **output) {
    int prefix = 0;
    while (prefix < length && name[prefix] == const_cpu_to_le16(0xfeff)) prefix++;
    if (!prefix) return ntfs_ucstombs(name, length, output, 0);
    char *suffix = NULL;
    int bytes = prefix < length ? ntfs_ucstombs(name + prefix, length - prefix, &suffix, 0) : 0;
    if (bytes < 0) { int saved = errno; free(suffix); errno = saved; return -1; }
    int total = prefix * 3 + bytes;
    char *text = malloc((size_t)total + 1);
    if (!text) { free(suffix); errno = ENOMEM; return -1; }
    for (int i = 0; i < prefix; i++) memcpy(text + i * 3, "\xef\xbb\xbf", 3);
    if (bytes) memcpy(text + prefix * 3, suffix, (size_t)bytes);
    text[total] = '\0';
    free(suffix);
    *output = text;
    return total;
}

static uint64_t lookup_name(ntfs_fskit_volume *v, uint64_t dir_ino, const char *name_utf8,
                            char *canonical_name, size_t capacity, char **allocated_name, int *out_errno) {
    if (!v || !v->vol || !name_utf8 || (canonical_name && !capacity)) {
        if (out_errno) *out_errno = EINVAL; return 0;
    }
    if (out_errno) *out_errno = 0;
    ntfs_inode *dir = nfsk_inode_open(v->vol, to_mref(dir_ino));
    if (!dir) { if (out_errno) *out_errno = errno; return 0; }

    ntfschar *uname = NULL;
    int ulen = nfsk_name_to_unicode(name_utf8, &uname);
    if (ulen < 0) { if (out_errno) *out_errno = errno; nfsk_inode_close(dir); return 0; }
    if (nfsk_is_retention_name(v->vol, dir->mft_no, uname, ulen)) {
        free(uname); nfsk_inode_close(dir);
        if (out_errno) *out_errno = ENOENT;
        return 0;
    }
    u64 mref = ntfs_inode_lookup_by_name(dir, uname, ulen);
    int saved = mref == (u64)-1 ? (errno ? errno : ENOENT) : 0;
    if (nfsk_inode_close(dir) && !saved) saved = errno ? errno : EIO;
    if (!saved && is_reserved_mft(MREF(mref))) saved = ENOENT;
    char *owned_name = NULL;
    if (!saved && (canonical_name || allocated_name)) {
        ntfs_inode *ni = nfsk_inode_open(v->vol, mref);
        if (!ni) saved = errno ? errno : EIO;
        else {
            ntfs_attr_search_ctx *search = ntfs_attr_get_search_ctx(ni, NULL);
            if (!search) saved = errno ? errno : ENOMEM;
            else {
                saved = ENOENT;
                int search_result;
                while (!(search_result = ntfs_attr_lookup(AT_FILE_NAME, AT_UNNAMED, 0, CASE_SENSITIVE, 0, NULL, 0, search))) {
                    const FILE_NAME_ATTR *fn = (const FILE_NAME_ATTR *)
                        ((const u8 *)search->attr + le16_to_cpu(search->attr->value_offset));
                    if (MREF(le64_to_cpu(fn->parent_directory)) != to_mref(dir_ino) ||
                        !ntfs_names_are_equal(fn->file_name, fn->file_name_length, uname, ulen,
                                              IGNORE_CASE, v->vol->upcase, v->vol->upcase_len)) continue;
                    // Only the selected spelling is retained. A later matching
                    // FILE_NAME replaces it; no list or persistent cache grows.
                    free(owned_name);
                    owned_name = NULL;
                    char *text = NULL;
                    int length = nfsk_name_to_utf8(fn->file_name, fn->file_name_length, &text);
                    if (length < 0) saved = errno ? errno : EILSEQ;
                    else if (canonical_name && (size_t)length >= capacity) saved = ENAMETOOLONG;
                    else {
                        if (canonical_name) memcpy(canonical_name, text, length + 1);
                        else { owned_name = text; text = NULL; }
                        saved = 0;
                    }
                    free(text);
                    if (saved || ntfs_names_are_equal(fn->file_name, fn->file_name_length, uname, ulen,
                                                      CASE_SENSITIVE, NULL, 0)) break;
                }
                // A case-insensitive candidate is not permission to hide a
                // later search failure while looking for the exact spelling.
                if (search_result && errno != ENOENT) saved = errno ? errno : EIO;
                ntfs_attr_put_search_ctx(search);
            }
            if (nfsk_inode_close(ni) && !saved) saved = errno ? errno : EIO;
        }
    }
    free(uname);
    if (saved) { free(owned_name); if (out_errno) *out_errno = saved; return 0; }
    if (allocated_name) *allocated_name = owned_name;
    return from_mft(MREF(mref));
}

uint64_t nfsk_lookup_name(ntfs_fskit_volume *v, uint64_t dir_ino, const char *name_utf8,
                          char *canonical_name, size_t capacity, int *out_errno) {
    return lookup_name(v, dir_ino, name_utf8, canonical_name, capacity, NULL, out_errno);
}

uint64_t nfsk_lookup_name_alloc(ntfs_fskit_volume *v, uint64_t dir_ino, const char *name_utf8,
                                char **canonical_name, int *out_errno) {
    if (!canonical_name) { if (out_errno) *out_errno = EINVAL; return 0; }
    *canonical_name = NULL;
    // NFD may exceed 1024 bytes for a valid 255-code-unit FILE_NAME. Transfer
    // the existing upstream conversion result only after the lookup closes.
    return lookup_name(v, dir_ino, name_utf8, NULL, 0, canonical_name, out_errno);
}

/* ---- Directory enumeration (robust ordinal cookies) ---- */
static const nfsk_directory_checkpoint *directory_checkpoint(nfsk_devctx *ctx,
        MFT_REF directory, int64_t cookie) {
    if (cookie <= 0) return NULL;
    for (unsigned i = 0; i < ctx->checkpoint_count; i++) {
        const nfsk_directory_checkpoint *point = &ctx->checkpoints[i];
        if (point->directory == directory &&
            (point->ordinal == cookie || point->ordinal - 1 == cookie)) return point;
    }
    return NULL;
}

static bool directory_key_valid(const INDEX_ENTRY *entry, const ntfs_inode *dir) {
    size_t length = le16_to_cpu(entry->length), key_length = le16_to_cpu(entry->key_length);
    size_t overhead = offsetof(INDEX_ENTRY, key) +
        ((entry->ie_flags & INDEX_ENTRY_NODE) ? sizeof(VCN) : 0);
    if (length < overhead || key_length < offsetof(FILE_NAME_ATTR, file_name) ||
        key_length > length - overhead ||
        ntfs_index_entry_inconsistent(entry, COLLATION_FILE_NAME, dir->mft_no)) return false;
    const FILE_NAME_ATTR *fn = &entry->key.file_name;
    return fn->file_name_length && fn->file_name_type <= FILE_NAME_WIN32_AND_DOS &&
        offsetof(FILE_NAME_ATTR, file_name) + fn->file_name_length * sizeof(ntfschar) <= key_length;
}

static void save_directory_checkpoint(nfsk_devctx *ctx, MFT_REF directory,
        const INDEX_ENTRY *entry, int64_t ordinal) {
    nfsk_directory_checkpoint *point = &ctx->checkpoints[ctx->checkpoint_next];
    point->directory = directory;
    point->indexed_file = le64_to_cpu(entry->indexed_file);
    point->ordinal = ordinal;
    point->key_length = offsetof(FILE_NAME_ATTR, file_name) +
        entry->key.file_name.file_name_length * sizeof(ntfschar);
    memcpy(point->key, &entry->key.file_name, point->key_length);
    ctx->checkpoint_next = (ctx->checkpoint_next + 1) % NFSK_DIRECTORY_CHECKPOINTS;
    if (ctx->checkpoint_count < NFSK_DIRECTORY_CHECKPOINTS) ctx->checkpoint_count++;
}

static int nfsk_directory_entry_type(ntfs_volume *vol, MFT_REF ref,
                                     FILE_ATTR_FLAGS flags, uint32_t *type) {
    *type = (flags & FILE_ATTR_I30_INDEX_PRESENT) ? NFSK_TYPE_DIR : NFSK_TYPE_FILE;
    if ((flags & FILE_ATTR_REPARSE_POINT) ||
        ((flags & FILE_ATTR_SYSTEM) && !(flags & FILE_ATTR_I30_INDEX_PRESENT))) {
        ntfs_inode *ni = nfsk_inode_open(vol, ref);
        if (!ni) return -(errno ? errno : EIO);
        int parsed = nfsk_inode_type(ni);
        int result = parsed < 0 ? parsed : 0;
        if (!result) *type = parsed ? (uint32_t)parsed : NFSK_TYPE_FILE;
        if (nfsk_inode_close(ni) && !result) result = -(errno ? errno : EIO);
        return result;
    }
    return 0;
}

/* ASCII is unchanged by UTF-8/NFD conversion. Borrow a callback-local buffer
 * for this common case; all other names retain upstream Unicode/error behavior.
 * FILE_NAME stores an 8-bit code-unit count, so 256 bytes includes the NUL. */
static bool directory_ascii_name(const FILE_NAME_ATTR *fn, char out[256]) {
    for (unsigned i = 0; i < fn->file_name_length; i++) {
        uint16_t c = le16_to_cpu(fn->file_name[i]);
        if (!c || c > 0x7f) return false;
        out[i] = (char)c;
    }
    out[fn->file_name_length] = 0;
    return true;
}

static int directory_read(ntfs_fskit_volume *v, uint64_t dir_ino, int64_t start_cookie,
                           void *ctx, nfsk_dir_cb cb, nfsk_dir_attr_cb attr_cb) {
    if (!v || !v->vol || (!cb && !attr_cb)) return -EINVAL;
    ntfs_inode *dir = nfsk_inode_open(v->vol, to_mref(dir_ino));
    if (!dir) {
        int saved = errno ? errno : EIO;
        invalidate_directory_checkpoints(v->devctx);
        return -saved;
    }

    int saved = 0;
    uint64_t generation = v->devctx->directory_generation;
    MFT_REF directory = MK_MREF(dir->mft_no, le16_to_cpu(dir->mrec->sequence_number));
    int64_t ordinal = 0, skip = start_cookie < 0 ? 0 : start_cookie;
    ntfs_index_context *index = NULL;
    if (!(dir->mrec->flags & MFT_RECORD_IS_DIRECTORY)) { saved = ENOTDIR; goto out; }
    index = ntfs_index_ctx_get(dir, NTFS_INDEX_I30, 4);
    if (!index) { saved = errno ? errno : ENOMEM; goto out; }

    /* An empty filename sorts before all entries. ENOENT still returns its
     * insertion position. Read stored names from $I30: ntfs_readdir lowercases
     * them in ignore-case mode, which must stay enabled for all other operations. */
    FILE_NAME_ATTR first = {0};
    const nfsk_directory_checkpoint *point = directory_checkpoint(v->devctx, directory, skip);
    bool resume_after = false;
lookup_position:
    errno = 0;
    int found = ntfs_index_lookup(point ? (const void *)point->key : &first,
                                 point ? (int)point->key_length : sizeof first, index);
    if (found && errno != ENOENT) {
        saved = errno ? errno : EIO;
        goto out;
    }
    if (index->bad_index || !index->entry || !index->ir ||
        index->ir->type != AT_FILE_NAME || index->ir->collation_rule != COLLATION_FILE_NAME) {
        saved = EIO;
        goto out;
    }
    if (point) {
        if (!(index->entry->ie_flags & INDEX_ENTRY_END) && !directory_key_valid(index->entry, dir)) {
            saved = EIO;
            goto out;
        }
        /* A missing or changed key is a cache miss, never an excuse to skip data.
         * Preserve the original ordinal semantics by walking from the beginning. */
        if (found || (index->entry->ie_flags & INDEX_ENTRY_END) ||
            le64_to_cpu(index->entry->indexed_file) != point->indexed_file ||
            le16_to_cpu(index->entry->key_length) < point->key_length ||
            memcmp(&index->entry->key.file_name, point->key, point->key_length)) {
            invalidate_directory_checkpoints(v->devctx);
            point = NULL;
            ntfs_index_ctx_reinit(index);
            goto lookup_position;
        }
        ordinal = skip;
        resume_after = skip == point->ordinal;
    }
    INDEX_ENTRY *entry = index->entry;
    if (resume_after) {
        errno = 0;
        entry = ntfs_index_next(entry, index);
        if (!entry && errno) saved = errno;
    }
    while (entry) {
        if (!(entry->ie_flags & INDEX_ENTRY_END)) {
            if (!directory_key_valid(entry, dir)) {
                saved = EIO;
                break;
            }
            const FILE_NAME_ATTR *fn = &entry->key.file_name;
            MFT_REF ref = le64_to_cpu(entry->indexed_file);
            FILE_ATTR_FLAGS flags = fn->file_attributes;
            if (fn->file_name_type == FILE_NAME_DOS || MREF(ref) < FILE_first_user ||
                ((flags & FILE_ATTR_HIDDEN) && !NVolShowHidFiles(v->vol))) goto next_entry;
            if (nfsk_is_retention_name(v->vol, dir->mft_no, fn->file_name, fn->file_name_length)) goto next_entry;

            char ascii_name[256], *allocated_name = NULL;
            const char *name = ascii_name;
            if (!directory_ascii_name(fn, ascii_name)) {
                if (nfsk_name_to_utf8(fn->file_name, fn->file_name_length, &allocated_name) < 0) {
                    saved = errno ? errno : EILSEQ;
                    free(allocated_name);
                    break;
                }
                name = allocated_name;
            }
            if (!strcmp(name, ".") || !strcmp(name, "..")) { free(allocated_name); goto next_entry; }
            if (ordinal == INT64_MAX) { free(allocated_name); saved = EOVERFLOW; break; }
            ordinal++;
            if (ordinal <= skip) { free(allocated_name); goto next_entry; }

            int stopped;
            if (attr_cb) {
                ntfs_inode *ni = nfsk_inode_open(v->vol, ref);
                if (!ni) { saved = errno ? errno : EIO; free(allocated_name); break; }
                nfsk_attr_t attributes;
                int rc = nfsk_inode_attributes(v, ni, from_mft(dir->mft_no), &attributes);
                if (nfsk_inode_close(ni) && !rc) rc = -(errno ? errno : EIO);
                if (rc) { saved = -rc; free(allocated_name); break; }
                stopped = attr_cb(ctx, name, &attributes, ordinal);
            } else {
                uint32_t type;
                int rc = nfsk_directory_entry_type(v->vol, ref, flags, &type);
                if (rc) { free(allocated_name); saved = -rc; break; }
                stopped = cb(ctx, name, from_mft(MREF(ref)), type, ordinal);
            }
            free(allocated_name);
            if (stopped) {
                if (generation == v->devctx->directory_generation)
                    save_directory_checkpoint(v->devctx, directory, entry, ordinal);
                break;
            }
        }
next_entry:
        /* Callbacks and name conversions may leave errno set on success. */
        errno = 0;
        entry = ntfs_index_next(entry, index);
        if (!entry && errno) saved = errno;
    }
out:
    if (index) {
        /* A failed walk can clear entry while still owning index buffers. */
        if (saved) index->bad_index = TRUE;
        ntfs_index_ctx_put(index);
    }
    if (nfsk_inode_close(dir) && !saved) saved = errno ? errno : EIO;
    if (saved) invalidate_directory_checkpoints(v->devctx);
    return -saved;
}

int nfsk_readdir(ntfs_fskit_volume *v, uint64_t dir_ino, int64_t start_cookie, void *ctx, nfsk_dir_cb cb) {
    return directory_read(v, dir_ino, start_cookie, ctx, cb, NULL);
}

int nfsk_readdir_attributes(ntfs_fskit_volume *v, uint64_t dir_ino, int64_t start_cookie,
                            void *ctx, nfsk_dir_attr_cb cb) {
    return directory_read(v, dir_ino, start_cookie, ctx, NULL, cb);
}

/* ---- File I/O ---- */
/* Release safety boundary: the native compressed write/close path can change
 * data or allocation before returning ENOSPC/EIO. Refuse before mutation rather
 * than promise rollback. Existing streams are identified by their own flags;
 * absent named DATA follows the same inheritance rules as ntfs_attr_add. */
static int nfsk_data_mutation_error(const ntfs_inode *ni, const ntfs_attr *attr) {
    if (attr) return (attr->data_flags & ATTR_COMPRESSION_MASK) ? ENOTSUP : 0;
    return ((ni->flags & FILE_ATTR_COMPRESSED) && ni->vol->major_ver >= 3 &&
            NVolCompression(ni->vol) && ni->vol->cluster_size <= MAX_COMPRESSION_CLUSTER_SIZE)
           ? ENOTSUP : 0;
}

int nfsk_check_write_access(ntfs_fskit_volume *v, uint64_t ino) {
    if (!v || !v->vol) return -EINVAL;
    if (v->read_only) return -EROFS;
    if (is_reserved_mft(to_mref(ino))) return -EPERM;
    ntfs_inode *ni = nfsk_inode_open(v->vol, to_mref(ino));
    if (!ni) return -(errno ? errno : EIO);
    int type = nfsk_inode_type(ni);
    int saved = type < 0 ? -type : 0;
    if (type == NFSK_TYPE_FILE) {
        ntfs_attr *attr = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
        if (!attr) saved = errno ? errno : EIO;
        else {
            saved = nfsk_data_mutation_error(ni, attr);
            ntfs_attr_close(attr);
        }
    }
    if (nfsk_inode_close(ni) && !saved) saved = errno ? errno : EIO;
    return -saved;
}

int64_t nfsk_read(ntfs_fskit_volume *v, uint64_t ino, int64_t offset, void *buf, int64_t len, int *out_errno) {
    if (!v || !v->vol || offset < 0 || len < 0) { if (out_errno) *out_errno = EINVAL; return -1; }
    if (is_reserved_mft(to_mref(ino))) { if (out_errno) *out_errno = EPERM; return -1; }
    if (len == 0) return 0;
    ntfs_inode *ni = nfsk_inode_open(v->vol, to_mref(ino));
    if (!ni) { if (out_errno) *out_errno = errno; return -1; }
    ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (!na) { if (out_errno) *out_errno = errno; nfsk_inode_close(ni); return -1; }

    int64_t result;
    s64 max = na->data_size;
    if (offset >= max) { result = 0; goto done; }
    if (len > max - offset) len = max - offset;

    int64_t total = 0;
    while (len > 0) {
        s64 r = ntfs_attr_pread(na, offset + total, len, (char *)buf + total);
        if (r <= 0) { if (total == 0) { if (out_errno) *out_errno = errno ? errno : EIO; total = -1; } break; }
        total += r; len -= r;
    }
    result = total;
done:
    ntfs_attr_close(na);
    // Reads do not implicitly write atime. Even tiny reads used to write MFT
    // records and poison later reads on failure. Explicit time setters remain.
    if (nfsk_inode_close(ni) && result >= 0) {
        if (out_errno) *out_errno = errno ? errno : EIO;
        return -1;
    }
    return result;
}

int64_t nfsk_write(ntfs_fskit_volume *v, uint64_t ino, int64_t offset, const void *buf, int64_t len, int *out_errno) {
    if (!v || !v->vol || offset < 0 || len < 0) { if (out_errno) *out_errno = EINVAL; return -1; }
    if (v->read_only) { if (out_errno) *out_errno = EROFS; return -1; }
    if (is_reserved_mft(to_mref(ino))) { if (out_errno) *out_errno = EPERM; return -1; }
    if (len == 0) return 0;
    if (len > INT64_MAX - offset) { if (out_errno) *out_errno = EFBIG; return -1; }
    ntfs_inode *ni = nfsk_inode_open(v->vol, to_mref(ino));
    if (!ni) { if (out_errno) *out_errno = errno; return -1; }
    ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (!na) { if (out_errno) *out_errno = errno; nfsk_inode_close(ni); return -1; }

    int64_t total = 0;
    int mutation_error = nfsk_data_mutation_error(ni, na);
    if (mutation_error || nfsk_prepare_compressed(na)) {
        if (out_errno) *out_errno = mutation_error ? mutation_error : (errno ? errno : EIO);
        ntfs_attr_close(na);
        nfsk_inode_close(ni);
        return -1;
    }
    uint64_t failures = v->devctx->write_failures;
    while (len > 0) {
        s64 r = ntfs_attr_pwrite(na, offset + total, len, (const char *)buf + total);
        if ((r < len || v->devctx->write_failures != failures) &&
            v->devctx->compressed_pending == nfsk_inode_reference(ni))
            v->devctx->compressed_safe_from = INT64_MAX; /* no extra close after uncertain data I/O */
        if (r <= 0) { if (total == 0) { if (out_errno) *out_errno = errno ? errno : EIO; total = -1; } break; }
        total += r; len -= r;
    }
    ntfs_attr_close(na);
    if (total > 0) { ni->flags |= FILE_ATTR_ARCHIVE; ntfs_inode_update_times(ni, NTFS_UPDATE_MCTIME); }
    if (nfsk_inode_close(ni) && total >= 0) {
        if (out_errno) *out_errno = errno ? errno : EIO;
        return -1;
    }
    return total;
}

/* ---- Extended attributes: named $DATA, never the unnamed file contents ---- */
static int xattr_name_error(const char *name) {
    if (!name || !*name) return EINVAL;
    if (strlen(name) > NFSK_MAX_XATTR_NAME) return ENAMETOOLONG;
    /* Do not expose NTFS/ntfs-3g private streams through a user xattr API. */
    if (name[0] == '$' || !strncmp(name, "ntfs-3g.", 8)) return EPERM;
    /* Windows uses this ADS as WOF file contents, rather than user metadata. */
    if (!strcasecmp(name, "WofCompressedData")) return EPERM;
    return 0;
}

static int xattr_unicode_name(const char *name, ntfschar **unicode) {
    int error = xattr_name_error(name);
    if (error) return -error;
    /* Attribute names are byte-sensitive, unlike normalized file names. Avoid
     * changing ntfs-3g's process-global filename normalization setting. */
    /* CF's UTF8 decoder consumes a leading BOM. Here it is name content:
     * losing it can alias another stream, including unnamed file DATA. */
    int leading_boms = 0;
    while (!strncmp(name, "\xef\xbb\xbf", 3)) { leading_boms++; name += 3; }
    CFStringRef string = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingUTF8);
    if (!string) return -EILSEQ;
    CFIndex length = CFStringGetLength(string), bytes = 0;
    *unicode = calloc((size_t)length + leading_boms + 1, sizeof(ntfschar));
    if (!*unicode) { CFRelease(string); return -ENOMEM; }
    for (int i = 0; i < leading_boms; i++) (*unicode)[i] = const_cpu_to_le16(0xfeff);
    CFIndex converted = CFStringGetBytes(string, CFRangeMake(0, length), kCFStringEncodingUTF16LE,
                                        0, false, (UInt8 *)(*unicode + leading_boms), length * 2, &bytes);
    CFRelease(string);
    return converted == length && bytes == length * 2 ? (int)length + leading_boms : -EILSEQ;
}

static int xattr_utf8_name(const ntfschar *unicode, int length, char *name) {
    CFStringRef string = CFStringCreateWithBytes(kCFAllocatorDefault, (const UInt8 *)unicode,
                                                length * 2, kCFStringEncodingUTF16LE, false);
    if (!string) return -EILSEQ;
    CFIndex bytes = 0;
    CFIndex converted = CFStringGetBytes(string, CFRangeMake(0, CFStringGetLength(string)),
                                        kCFStringEncodingUTF8, 0, false, (UInt8 *)name,
                                        NFSK_MAX_XATTR_NAME, &bytes);
    CFIndex characters = CFStringGetLength(string);
    CFRelease(string);
    if (converted != characters) return -ENAMETOOLONG;
    name[bytes] = 0;
    return (size_t)bytes == strlen(name) ? (int)bytes : -EINVAL;
}

static int xattr_read_value(ntfs_attr *attr, void *buf, size_t size) {
    size_t done = 0;
    while (done < size) {
        s64 count = ntfs_attr_pread(attr, done, size - done, (char *)buf + done);
        if (count <= 0) return -(count < 0 && errno ? errno : EIO);
        if ((uint64_t)count > size - done) return -EIO;
        done += (size_t)count;
    }
    return 0;
}

enum xattr_mapping_state { XATTR_MAPPING_UNKNOWN, XATTR_MAPPING_VALID, XATTR_MAPPING_CORRUPT };
static enum xattr_mapping_state xattr_check_mapping(ntfs_attr *attr);

/* Restoring EOF after a failed close must not free physical clusters or edit
 * attribute extents: that would add a new interruption window to recovery.
 * With the xattr size and geometry bounds, this visits at most 272 VCNs. */
static bool xattr_shrink_keeps_allocated_clusters(const ntfs_attr *attr, size_t size) {
    const ntfs_volume *vol = attr->ni->vol;
    if (!NAttrNonResident(attr) || NInoAttrList(attr->ni) || attr->ni->nr_extents ||
        (attr->data_flags & ATTR_COMPRESSION_MASK) != ATTR_IS_COMPRESSED ||
        attr->compression_block_clusters != (1U << STANDARD_COMPRESSION_UNIT) ||
        vol->cluster_size < 512 || !attr->compression_block_size ||
        (uint64_t)attr->compression_block_size != (uint64_t)vol->cluster_size * attr->compression_block_clusters ||
        attr->data_size <= (s64)size || attr->data_size > NFSK_MAX_XATTR_SIZE ||
        attr->initialized_size < (s64)size || attr->initialized_size > attr->data_size ||
        attr->allocated_size < attr->data_size ||
        (uint64_t)attr->allocated_size > NFSK_MAX_XATTR_SIZE + (uint64_t)attr->compression_block_size ||
        attr->allocated_size % attr->compression_block_size) return false;
    uint64_t unit = attr->compression_block_size;
    VCN first = (VCN)((size + unit - 1) / unit) * attr->compression_block_clusters;
    VCN end = attr->allocated_size / vol->cluster_size;
    for (VCN vcn = first; vcn < end; vcn++)
        if (ntfs_rl_vcn_to_lcn(attr->rl, vcn) != LCN_HOLE) return false;
    return true;
}

static int xattr_write_value(ntfs_attr *attr, const void *buf, size_t size, size_t done, bool restoring) {
    /* Keep the old tail until all new bytes have been written. */
    while (done < size) {
        s64 count = ntfs_attr_pwrite(attr, done, size - done, (const char *)buf + done);
        if (count <= 0) return -(count < 0 && errno ? errno : EIO);
        done += (size_t)count;
    }
    nfsk_devctx *ctx = volume_context(attr->ni->vol);
    uint64_t generation = ctx->directory_generation;
    if (ntfs_attr_pclose(attr)) {
        int saved = errno ? errno : EIO;
        /* Keep the close error even if restoring EOF also fails. The caller
         * still enters fatal recovery; this is not a successful close retry. */
        if (restoring && ctx->directory_generation == generation &&
            xattr_shrink_keeps_allocated_clusters(attr, size) &&
            xattr_check_mapping(attr) == XATTR_MAPPING_VALID)
            (void)ntfs_attr_truncate(attr, (s64)size);
        return -saved;
    }
    if (ntfs_attr_truncate(attr, (s64)size)) return -(errno ? errno : EIO);
    return 0;
}

static int64_t xattr_get(ntfs_fskit_volume *v, uint64_t ino, const char *name,
                         void *buf, size_t size, void **owned) {
    if (!v || !v->vol) return -EINVAL;
    if (is_reserved_mft(to_mref(ino))) return -EPERM;
    ntfschar *unicode = NULL;
    int length = xattr_unicode_name(name, &unicode);
    if (length < 0) { free(unicode); return length; }
    ntfs_inode *ni = nfsk_inode_open(v->vol, to_mref(ino));
    if (!ni) { int error = errno ? errno : EIO; free(unicode); return -error; }
    ntfs_attr *attr = ntfs_attr_open(ni, AT_DATA, unicode, length);
    int64_t result;
    if (!attr) {
        result = -(errno == ENOENT ? ENOATTR : (errno ? errno : EIO));
    } else if (attr->data_size < 0) {
        result = -EIO;
    } else if (attr->data_size > NFSK_MAX_XATTR_SIZE) {
        result = -E2BIG;
    } else {
        result = attr->data_size;
        if (owned && result) {
            size = (size_t)result;
            buf = malloc(size);
            if (!buf) result = -ENOMEM;
        }
        if (result >= 0 && buf) {
            if (size < (size_t)result) result = -ERANGE;
            else {
                int rc = xattr_read_value(attr, buf, (size_t)result);
                if (rc) result = rc;
            }
        }
    }
    if (attr) ntfs_attr_close(attr);
    free(unicode);
    if (nfsk_inode_close(ni) && result >= 0) result = -(errno ? errno : EIO);
    if (owned) {
        if (result < 0) free(buf);
        else *owned = buf;
    }
    return result;
}

int64_t nfsk_getxattr(ntfs_fskit_volume *v, uint64_t ino, const char *name, void *buf, size_t size) {
    return xattr_get(v, ino, name, buf, size, NULL);
}

int64_t nfsk_getxattr_alloc(ntfs_fskit_volume *v, uint64_t ino, const char *name, void **out) {
    if (!out) return -EINVAL;
    *out = NULL;
    return xattr_get(v, ino, name, NULL, 0, out);
}

static int64_t xattr_list(ntfs_fskit_volume *v, uint64_t ino, char *buf, size_t size, char **owned) {
    if (!v || !v->vol) return -EINVAL;
    if (is_reserved_mft(to_mref(ino))) return -EPERM;
    ntfs_inode *ni = nfsk_inode_open(v->vol, to_mref(ino));
    if (!ni) return -(errno ? errno : EIO);
    ntfs_attr_search_ctx *search = ntfs_attr_get_search_ctx(ni, NULL);
    int saved = search ? 0 : (errno ? errno : EIO);
    size_t total = 0;
    if (search) {
        while (true) {
            errno = 0;
            if (ntfs_attr_lookup(AT_DATA, NULL, 0, CASE_SENSITIVE, 0, NULL, 0, search)) {
                if (errno != ENOENT) saved = errno ? errno : EIO;
                break;
            }
            if (!search->attr->name_length) continue;
            char name[NFSK_MAX_XATTR_NAME + 1];
            int length = xattr_utf8_name((ntfschar *)((char *)search->attr + le16_to_cpu(search->attr->name_offset)),
                                         search->attr->name_length, name);
            if (length == -ENAMETOOLONG || length == -EINVAL) continue;
            if (length < 0) { saved = -length; break; }
            if (xattr_name_error(name)) continue;
            size_t bytes = (size_t)length + 1;
            if (total > NFSK_MAX_XATTR_SIZE - bytes) { saved = E2BIG; break; }
            if (owned && total + bytes > size) {
                // bytes <= 128; each growth fits the next complete name.
                size_t capacity = size ? size * 2 : 256;
                if (capacity > NFSK_MAX_XATTR_SIZE) capacity = NFSK_MAX_XATTR_SIZE;
                char *grown = realloc(buf, capacity);
                if (!grown) { saved = ENOMEM; break; }
                buf = grown;
                size = capacity;
            }
            if (buf && (total > size || bytes > size - total)) { saved = ERANGE; break; }
            if (buf) memcpy(buf + total, name, bytes);
            total += bytes;
        }
        ntfs_attr_put_search_ctx(search);
    }
    if (nfsk_inode_close(ni) && !saved) saved = errno ? errno : EIO;
    if (owned) {
        if (saved) free(buf);
        else *owned = buf;
    }
    return saved ? -saved : (int64_t)total;
}

int64_t nfsk_listxattr(ntfs_fskit_volume *v, uint64_t ino, char *buf, size_t size) {
    return xattr_list(v, ino, buf, size, NULL);
}

int64_t nfsk_listxattr_alloc(ntfs_fskit_volume *v, uint64_t ino, char **out) {
    if (!out) return -EINVAL;
    *out = NULL;
    return xattr_list(v, ino, NULL, 0, out);
}

/* Only positively identified corrupt mapping pairs justify skipping rollback
 * or discarding its cached record. A blanket fatal-error close ban can instead
 * leave an older mapping pointing at data already rewritten by compression. */
static enum xattr_mapping_state xattr_check_mapping(ntfs_attr *attr) {
    int saved = errno;
    enum xattr_mapping_state state = XATTR_MAPPING_UNKNOWN;
    ntfs_attr_search_ctx *search = ntfs_attr_get_search_ctx(attr->ni, NULL);
    if (search && !ntfs_attr_lookup(attr->type, attr->name, attr->name_len,
                                   CASE_SENSITIVE, 0, NULL, 0, search) &&
        search->attr->non_resident) {
        runlist_element *runs = ntfs_mapping_pairs_decompress(attr->ni->vol, search->attr, NULL);
        state = runs ? XATTR_MAPPING_VALID :
                (errno == EIO ? XATTR_MAPPING_CORRUPT : XATTR_MAPPING_UNKNOWN);
        free(runs);
    }
    if (search) ntfs_attr_put_search_ctx(search);
    errno = saved;
    return state;
}

static bool xattr_mapping_is_corrupt(ntfs_attr *attr) {
    return xattr_check_mapping(attr) == XATTR_MAPPING_CORRUPT;
}

/* Preserve complete, initialized compression units whose bytes are unchanged.
 * For an identical fully initialized value, preserve an already compressed
 * partial tail too. A raw tail can be changed by pclose, so it still needs the
 * original write/rollback path. The mapped tail's last cluster must be a hole.
 * Rewriting an existing leading hole can leave stale mapping pairs upstream.
 * The existing bounded old-value buffer also identifies the rollback prefix. */
static size_t xattr_unchanged_prefix(const ntfs_attr *attr, const void *old,
                                     size_t old_size, const void *value, size_t size) {
    if (!NAttrNonResident(attr) ||
        (attr->data_flags & ATTR_COMPRESSION_MASK) != ATTR_IS_COMPRESSED ||
        attr->compression_block_clusters != (1U << STANDARD_COMPRESSION_UNIT) ||
        !attr->compression_block_size || attr->initialized_size < 0) return 0;
    size_t limit = size < old_size ? size : old_size;
    if ((uint64_t)attr->initialized_size < limit) limit = (size_t)attr->initialized_size;
    size_t unit = attr->compression_block_size, prefix = 0;
    while (unit <= limit - prefix &&
           !memcmp((const char *)old + prefix, (const char *)value + prefix, unit))
        prefix += unit;
    if (old_size == size && limit == size && prefix < size && size - prefix < unit &&
        ntfs_rl_vcn_to_lcn(attr->rl,
                          (VCN)(prefix / unit + 1) * attr->compression_block_clusters - 1) == LCN_HOLE &&
        !memcmp((const char *)old + prefix, (const char *)value + prefix, size - prefix))
        prefix = size;
    return prefix;
}

/* A valid-looking runlist can still reference a cluster freed by failed
 * compression recovery. Check only the bounded, mapped xattr allocation.
 * An unreadable bitmap or unknown mapping is not positive corruption proof. */
static bool xattr_references_free_cluster(ntfs_attr *attr) {
    ntfs_volume *vol = attr->ni->vol;
    if (!NAttrNonResident(attr) ||
        (attr->data_flags & ATTR_COMPRESSION_MASK) != ATTR_IS_COMPRESSED ||
        attr->compression_block_clusters != (1U << STANDARD_COMPRESSION_UNIT) ||
        attr->allocated_size < 0 || vol->cluster_size < 512 || !vol->lcnbmp_na ||
        (uint64_t)attr->compression_block_size != (uint64_t)vol->cluster_size * attr->compression_block_clusters ||
        (uint64_t)attr->allocated_size > NFSK_MAX_XATTR_SIZE + (uint64_t)attr->compression_block_size ||
        attr->allocated_size % vol->cluster_size)
        return false;
    int saved = errno;
    bool corrupt = false;
    VCN count = attr->allocated_size / vol->cluster_size;
    s64 byte_offset = -1;
    unsigned char value = 0;
    for (VCN vcn = 0; vcn < count; vcn++) {
        LCN lcn = ntfs_rl_vcn_to_lcn(attr->rl, vcn);
        if (lcn == LCN_HOLE) continue;
        if (lcn < 0 || lcn >= vol->nr_clusters) break;
        if ((lcn >> 3) != byte_offset) {
            if (ntfs_attr_pread(vol->lcnbmp_na, lcn >> 3, 1, &value) != 1) break;
            byte_offset = lcn >> 3;
        }
        if (!(value & (1U << (lcn & 7)))) { corrupt = true; break; }
    }
    errno = saved;
    return corrupt;
}

int nfsk_setxattr(ntfs_fskit_volume *v, uint64_t ino, const char *name,
                  const void *value, size_t size, int policy) {
    if (!v || !v->vol || policy < NFSK_XATTR_SET || policy > NFSK_XATTR_DELETE ||
        (size && !value) || (policy == NFSK_XATTR_DELETE && (value || size))) return -EINVAL;
    if (v->read_only) return -EROFS;
    if (is_reserved_mft(to_mref(ino))) return -EPERM;
    if (size > NFSK_MAX_XATTR_SIZE) return -E2BIG;
    ntfschar *unicode = NULL;
    int length = xattr_unicode_name(name, &unicode);
    if (length < 0) { free(unicode); return length; }
    ntfs_inode *ni = nfsk_inode_open(v->vol, to_mref(ino));
    if (!ni) { int error = errno ? errno : EIO; free(unicode); return -error; }
    ntfs_attr *attr = ntfs_attr_open(ni, AT_DATA, unicode, length);
    int saved = 0;
    void *previous = NULL;
    size_t previous_size = 0, prefix = 0;
    bool created = false, retain_inode = false;
    if (!attr && errno != ENOENT) { saved = errno ? errno : EIO; goto done; }
    if (attr && policy == NFSK_XATTR_CREATE) { saved = EEXIST; goto done; }
    if (!attr && (policy == NFSK_XATTR_REPLACE || policy == NFSK_XATTR_DELETE)) {
        saved = ENOATTR; goto done;
    }
    if (nfsk_data_mutation_error(ni, attr)) {
        /* ENOTSUP makes Darwin fall back to AppleDouble and report success. */
        saved = EPERM;
        goto done;
    }
    if (policy == NFSK_XATTR_DELETE) {
        if (ntfs_attr_rm(attr)) saved = errno ? errno : EIO;
        goto changed;
    }
    if (attr) {
        if (attr->data_size < 0) { saved = EIO; goto done; }
        if (attr->data_size > NFSK_MAX_XATTR_SIZE) { saved = E2BIG; goto done; }
        previous_size = (size_t)attr->data_size;
        if (previous_size) {
            previous = malloc(previous_size);
            if (!previous) { saved = ENOMEM; goto done; }
            int rc = xattr_read_value(attr, previous, previous_size);
            if (rc) { saved = -rc; goto done; }
        }
    } else {
        if (ntfs_attr_add(ni, AT_DATA, unicode, length, NULL, 0)) { saved = errno ? errno : EIO; goto done; }
        created = true;
        attr = ntfs_attr_open(ni, AT_DATA, unicode, length);
        if (!attr) {
            saved = errno ? errno : EIO;
            if (ntfs_attr_remove(ni, AT_DATA, unicode, length))
                v->devctx->fatal_writeback_error = v->devctx->writeback_error = errno ? errno : EIO;
            goto done;
        }
    }
    if (!created) prefix = xattr_unchanged_prefix(attr, previous, previous_size, value, size);
    saved = -xattr_write_value(attr, value, size, prefix, false);
    if (saved) {
        /* A failed replacement must not silently discard the old metadata. */
        bool corrupt_mapping = !created && xattr_mapping_is_corrupt(attr);
        int rollback = corrupt_mapping ? -EIO :
                       (created ? ntfs_attr_rm(attr) : xattr_write_value(attr, previous, previous_size, prefix, true));
        if (!created && !corrupt_mapping && xattr_references_free_cluster(attr)) {
            corrupt_mapping = true;
            rollback = -EIO;
        }
        if (rollback) {
            v->devctx->fatal_writeback_error = v->devctx->writeback_error = EIO;
            retain_inode = corrupt_mapping || xattr_mapping_is_corrupt(attr);
        }
        goto done;
    }
changed:
    if (!saved) {
        if (!(ni->flags & FILE_ATTR_ARCHIVE)) { ni->flags |= FILE_ATTR_ARCHIVE; NInoFileNameSetDirty(ni); }
        ntfs_inode_update_times(ni, NTFS_UPDATE_CTIME);
    }
done:
    if (attr) ntfs_attr_close(attr);
    free(previous);
    free(unicode);
    /* The existing inode registry owns retained state until error teardown;
     * nfsk_sync must keep returning the fatal error without flushing it. */
    if (!retain_inode && nfsk_inode_close(ni) && !saved) saved = errno ? errno : EIO;
    return -saved;
}

/* ---- Namespace mutation ---- */
/* New names are single components. Keep literal lookup/removal/rename sources
 * available to repair foreign entries; symlink contents remain paths. */
static bool nfsk_valid_new_name(const char *name) {
    return name && *name && !strchr(name, '/') && strcmp(name, ".") && strcmp(name, "..");
}

uint64_t nfsk_create(ntfs_fskit_volume *v, uint64_t dir_ino, const char *name_utf8, uint32_t type, int *out_errno) {
    if (!v || !v->vol || !nfsk_valid_new_name(name_utf8)) { if (out_errno) *out_errno = EINVAL; return 0; }
    if (v->read_only) { if (out_errno) *out_errno = EROFS; return 0; }
    if (type != NFSK_TYPE_DIR && type != NFSK_TYPE_FILE) { if (out_errno) *out_errno = ENOTSUP; return 0; }
    if (is_reserved_mft(to_mref(dir_ino))) { if (out_errno) *out_errno = EPERM; return 0; }
    ntfs_inode *dir = nfsk_inode_open(v->vol, to_mref(dir_ino));
    if (!dir) { if (out_errno) *out_errno = errno; return 0; }
    if (nfsk_unlinked_directory(dir)) {
        nfsk_inode_close(dir); if (out_errno) *out_errno = ENOENT; return 0;
    }

    ntfschar *uname = NULL;
    int ulen = nfsk_name_to_unicode(name_utf8, &uname);
    if (ulen < 0) { if (out_errno) *out_errno = errno; nfsk_inode_close(dir); return 0; }
    /* Native namespace calls take u8 lengths; check after NFC conversion. */
    if (ulen > NTFS_MAX_NAME_LEN) {
        free(uname); nfsk_inode_close(dir);
        if (out_errno) *out_errno = ENAMETOOLONG;
        return 0;
    }

    errno = 0;
    u64 existing = ntfs_inode_lookup_by_name(dir, uname, ulen);
    if (existing != (u64)-1 || errno != ENOENT) {
        int saved = existing != (u64)-1 ? EEXIST : (errno ? errno : EIO);
        free(uname); nfsk_inode_close(dir);
        if (out_errno) *out_errno = saved;
        return 0;
    }
    nfsk_inode_ref *owned = calloc(1, sizeof(*owned));
    if (!owned) { free(uname); nfsk_inode_close(dir); if (out_errno) *out_errno = ENOMEM; return 0; }
    mode_t kind = (type == NFSK_TYPE_DIR) ? S_IFDIR : S_IFREG;
    ntfs_inode *ni = ntfs_create(dir, const_cpu_to_le32(0), uname, ulen, kind);
    free(uname);
    if (!ni) { if (out_errno) *out_errno = errno ? errno : EIO; free(owned); nfsk_inode_close(dir); return 0; }
    owned->inode = ni; owned->next = v->devctx->inodes; v->devctx->inodes = owned;
    uint64_t new_ino = from_mft(ni->mft_no);
    nfsk_inode_close(ni);
    nfsk_inode_close(dir);
    if (v->devctx->writeback_error) { if (out_errno) *out_errno = v->devctx->writeback_error; return 0; }
    return new_ino;
}

int nfsk_remove(ntfs_fskit_volume *v, uint64_t dir_ino, const char *name_utf8) {
    if (!v || !v->vol || !name_utf8) return -EINVAL;
    if (v->read_only) return -EROFS;
    if (is_reserved_mft(to_mref(dir_ino))) return -EPERM;
    ntfs_inode *dir = nfsk_inode_open(v->vol, to_mref(dir_ino));
    if (!dir) return -errno;

    ntfschar *uname = NULL;
    int ulen = nfsk_name_to_unicode(name_utf8, &uname);
    if (ulen < 0) { int e = errno; nfsk_inode_close(dir); return -e; }
    if (nfsk_is_retention_name(v->vol, dir->mft_no, uname, ulen)) {
        free(uname); nfsk_inode_close(dir); return -ENOENT;
    }

    u64 mref = ntfs_inode_lookup_by_name(dir, uname, ulen);
    if (mref == (u64)-1) { int e = errno ? errno : ENOENT; free(uname); nfsk_inode_close(dir); return -e; }
    if (is_reserved_mft(MREF(mref))) { free(uname); nfsk_inode_close(dir); return -EPERM; }  /* don't remove metadata */
    ntfs_inode *ni = nfsk_inode_open(v->vol, mref);
    if (!ni) { int e = errno; free(uname); nfsk_inode_close(dir); return -e; }
    int rc = nfsk_delete(v->vol, ni, dir, uname, ulen);
    int e = rc ? (errno ? errno : EIO) : 0;
    free(uname);
    return rc ? -e : 0;
}

int nfsk_truncate(ntfs_fskit_volume *v, uint64_t ino, uint64_t size) {
    if (!v || !v->vol) return -EINVAL;
    if (v->read_only) return -EROFS;
    if (size > INT64_MAX) return -EFBIG;
    if (is_reserved_mft(to_mref(ino))) return -EPERM;
    ntfs_inode *ni = nfsk_inode_open(v->vol, to_mref(ino));
    if (!ni) return -errno;
    int type = nfsk_inode_type(ni);
    if (type != NFSK_TYPE_FILE) {
        int error = type < 0 ? -type : (type == NFSK_TYPE_DIR ? EISDIR : ENOTSUP);
        nfsk_inode_close(ni);
        return -error;
    }
    ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (!na) { int e = errno; nfsk_inode_close(ni); return -e; }
    int mutation_error = nfsk_data_mutation_error(ni, na);
    if (mutation_error) {
        ntfs_attr_close(na);
        nfsk_inode_close(ni);
        return -mutation_error;
    }
    int rc = nfsk_prepare_compressed(na);
    if (!rc && (na->data_flags & ATTR_COMPRESSION_MASK) && size > (uint64_t)na->data_size &&
        size > (uint64_t)na->initialized_size) {
        /* Like ntfs_fuse_trunc: compressed truncate alone may stop at the next
         * unit boundary. Let pwrite initialize the gap and set the exact EOF. */
        char zero = 0;
        s64 written = ntfs_attr_pwrite(na, (s64)size - 1, 1, &zero);
        rc = written == 1 ? 0 : -1;
        if (!written) errno = EIO;
    } else if (!rc) {
        rc = ntfs_attr_truncate(na, (s64)size);
    }
    if (!rc && na->data_size != (s64)size) { errno = EIO; rc = -1; }
    int e = rc ? (errno ? errno : EIO) : 0;
    if (rc && v->devctx->compressed_pending == nfsk_inode_reference(ni))
        v->devctx->compressed_safe_from = INT64_MAX;
    ntfs_attr_close(na);
    if (!rc) { ni->flags |= FILE_ATTR_ARCHIVE; ntfs_inode_update_times(ni, NTFS_UPDATE_MCTIME); }
    if (nfsk_inode_close(ni) && !e) e = errno ? errno : EIO;
    return e ? -e : 0;
}

int nfsk_set_times(ntfs_fskit_volume *v, uint64_t ino,
                   int64_t mtime_sec, int64_t mtime_nsec, int64_t atime_sec, int64_t atime_nsec) {
    nfsk_metadata_t metadata = {0};
    if (mtime_sec != INT64_MIN) metadata.valid |= NFSK_SET_MTIME;
    if (atime_sec != INT64_MIN) metadata.valid |= NFSK_SET_ATIME;
    metadata.mtime_sec = mtime_sec; metadata.mtime_nsec = mtime_nsec;
    metadata.atime_sec = atime_sec; metadata.atime_nsec = atime_nsec;
    return nfsk_set_metadata(v, ino, &metadata);
}

static bool nfsk_valid_time(int64_t sec, int64_t nsec) {
    __int128 ticks = ((__int128)sec + 11644473600LL) * 10000000 + nsec / 100;
    return nsec >= 0 && nsec < 1000000000 && ticks >= 0 && ticks <= INT64_MAX;
}

int nfsk_validate_metadata(const nfsk_metadata_t *m) {
    if (!m || (m->valid & ~(NFSK_SET_MTIME | NFSK_SET_ATIME | NFSK_SET_BTIME | NFSK_SET_FLAGS))) return -EINVAL;
    if (((m->valid & NFSK_SET_MTIME) && !nfsk_valid_time(m->mtime_sec, m->mtime_nsec)) ||
        ((m->valid & NFSK_SET_ATIME) && !nfsk_valid_time(m->atime_sec, m->atime_nsec)) ||
        ((m->valid & NFSK_SET_BTIME) && !nfsk_valid_time(m->btime_sec, m->btime_nsec))) return -EINVAL;
    if ((m->valid & NFSK_SET_FLAGS) && (m->flags & ~UF_HIDDEN)) return -ENOTSUP;
    return 0;
}

int nfsk_set_metadata(ntfs_fskit_volume *v, uint64_t ino, const nfsk_metadata_t *m) {
    if (!v || !v->vol) return -EINVAL;
    if (v->read_only) return -EROFS;
    int valid = nfsk_validate_metadata(m);
    if (valid) return valid;
    if (is_reserved_mft(to_mref(ino))) return -EPERM;
    uint32_t fields = m->valid;
    if (to_mref(ino) == FILE_root && (fields & NFSK_SET_FLAGS)) {
        /* The root is always visible in macOS. Clearing its exposed flags is
         * a no-op; retain the original NTFS flags for other operating systems.
         * Resolve flag-only requests before opening an inode for writeback. */
        if (m->flags & UF_HIDDEN) return -ENOTSUP;
        fields &= ~NFSK_SET_FLAGS;
        if (!fields) return 0;
    }
    ntfs_inode *ni = nfsk_inode_open(v->vol, to_mref(ino));
    if (!ni) return -errno;
    /* HIDDEN distinguishes some Interix special files from ordinary data. */
    if ((fields & NFSK_SET_FLAGS) &&
        (!!(m->flags & UF_HIDDEN) != !!(ni->flags & FILE_ATTR_HIDDEN)) &&
        !(ni->flags & FILE_ATTR_REPARSE_POINT) &&
        (ni->flags & FILE_ATTR_SYSTEM)) {
        int type = nfsk_interix_type(ni);
        int error = type < 0 ? -type :
                    (type != NTFS_DT_REG ? ENOTSUP : 0);
        if (error) {
            nfsk_inode_close(ni);
            return -error;
        }
    }
    if (fields & NFSK_SET_FLAGS) {
        /* This API takes a complete native-endian mask. Preserve every flag
         * other than HIDDEN, including directory compression and private bits. */
        u32 attributes = le32_to_cpu(ni->flags);
        if (m->flags & UF_HIDDEN) attributes |= le32_to_cpu(FILE_ATTR_HIDDEN);
        else attributes &= ~le32_to_cpu(FILE_ATTR_HIDDEN);
        if (ntfs_set_ntfs_attrib(ni, (const char *)&attributes, sizeof(attributes), 0)) {
            int error = errno ? errno : EIO;
            nfsk_inode_close(ni);
            return -error;
        }
    }
    if (fields & NFSK_SET_MTIME) { struct timespec ts = { (time_t)m->mtime_sec, (long)m->mtime_nsec }; ni->last_data_change_time = timespec2ntfs(ts); }
    if (fields & NFSK_SET_ATIME) { struct timespec ts = { (time_t)m->atime_sec, (long)m->atime_nsec }; ni->last_access_time = timespec2ntfs(ts); }
    if (fields & NFSK_SET_BTIME) { struct timespec ts = { (time_t)m->btime_sec, (long)m->btime_nsec }; ni->creation_time = timespec2ntfs(ts); }
    /* Empty requests still validate inode access and close, without changing it. */
    if (fields) ntfs_inode_update_times(ni, NTFS_UPDATE_CTIME);
    int rc = nfsk_inode_close(ni);
    return rc ? -errno : 0;
}

/*
 * Rename helpers. libntfs has no path-based front-end (that lives in ntfs-3g's
 * FUSE layer, which we don't link), so these mirror src/ntfs-3g.c's rename logic
 * on top of the inode primitives. Each is self-contained — it re-opens its
 * directory by inode number — because ntfs_delete() closes BOTH the target inode
 * and its directory inode (libntfs-3g/dir.c, out:), while ntfs_link() closes neither.
 */

/* Add directory entry `name` in directory #dir_no pointing at inode `ref`. */
static int nfsk_link_name(ntfs_volume *vol, uint64_t dir_no, u64 ref,
                          const ntfschar *name, int name_len) {
    ntfs_inode *dir = nfsk_inode_open(vol, to_mref(dir_no));
    if (!dir) return -1;
    if (nfsk_unlinked_directory(dir)) { nfsk_inode_close(dir); errno = ENOENT; return -1; }
    ntfs_inode *ni = nfsk_inode_open(vol, ref);
    if (!ni) { int e = errno; nfsk_inode_close(dir); errno = e; return -1; }
    errno = 0;
    u64 existing = ntfs_inode_lookup_by_name(dir, name, name_len);
    if (existing != (u64)-1 || errno != ENOENT) {
        int e = existing != (u64)-1 ? EEXIST : (errno ? errno : EIO);
        nfsk_inode_close(ni); nfsk_inode_close(dir); errno = e; return -1;
    }
    int r = ntfs_link(ni, dir, name, name_len);   /* closes neither inode */
    int e = errno;
    nfsk_inode_close(ni);
    nfsk_inode_close(dir);
    if (r) { errno = e; return -1; }
    return 0;
}

/* Remove directory entry `name` from directory #dir_no. */
static int nfsk_unlink_name(ntfs_volume *vol, uint64_t dir_no,
                            const ntfschar *name, int name_len) {
    ntfs_inode *dir = nfsk_inode_open(vol, to_mref(dir_no));
    if (!dir) return -1;
    u64 ref = ntfs_inode_lookup_by_name(dir, name, name_len);
    if (ref == (u64)-1) { int e = errno; nfsk_inode_close(dir); errno = e ? e : ENOENT; return -1; }
    ntfs_inode *ni = nfsk_inode_open(vol, ref);
    if (!ni) { int e = errno; nfsk_inode_close(dir); errno = e; return -1; }
    /* ntfs_delete closes BOTH ni and dir, even on failure. */
    return nfsk_delete(vol, ni, dir, name, name_len) ? -1 : 0;
}

int nfsk_open_item(ntfs_fskit_volume *v, uint64_t ino) {
    if (!v || !v->vol) return -EINVAL;
    if (is_reserved_mft(to_mref(ino))) return -EPERM;
    nfsk_open_ref *existing = nfsk_open_ref_for(v->vol, to_mref(ino));
    if (existing) { existing->open = true; return 0; }
    ntfs_inode *ni = nfsk_inode_open(v->vol, to_mref(ino));
    if (!ni) return -(errno ? errno : EIO);
    if (nfsk_inode_close(ni)) return -(errno ? errno : EIO);
    nfsk_open_ref *entry = calloc(1, sizeof(*entry));
    if (!entry) return -ENOMEM;
    entry->ref = to_mref(ino);
    entry->open = true;
    entry->next = v->devctx->open_items;
    v->devctx->open_items = entry;
    return 0;
}

static int nfsk_release_open_ref(ntfs_fskit_volume *v, nfsk_open_ref **slot) {
    nfsk_open_ref *entry = *slot;
    entry->open = false;
    if (entry->anchor && nfsk_unlink_name(v->vol, NFSK_ROOT_INO, entry->anchor, entry->anchor_length)) {
        if (errno != ENOENT) return -(errno ? errno : EIO);
    }
    *slot = entry->next;
    if (entry->anchor) v->devctx->retention_count--;
    free(entry->anchor);
    free(entry);
    return 0;
}

int nfsk_close_item(ntfs_fskit_volume *v, uint64_t ino) {
    if (!v || !v->vol) return -EINVAL;
    nfsk_open_ref **slot = &v->devctx->open_items;
    while (*slot && MREF((*slot)->ref) != to_mref(ino)) slot = &(*slot)->next;
    if (*slot) (*slot)->open = false;
    if (v->devctx->compressed_pending && MREF(v->devctx->compressed_pending) == to_mref(ino) &&
        nfsk_finish_compressed(v->vol)) return -(errno ? errno : EIO);
    return *slot ? nfsk_release_open_ref(v, slot) : 0;
}

/*
 * Replace an existing, different destination, mirroring
 * src/ntfs-3g.c:ntfs_fuse_safe_rename(). The destination is first backed up under a
 * temp name, the source is moved into place, and only then is the backup dropped —
 * with the destination restored on any failure. So a failed link never destroys the
 * destination's data (the flaw in the previous delete-first implementation). A
 * non-empty-directory destination fails cleanly at step (2): ntfs_delete refuses it.
 */
static int nfsk_safe_overwrite(ntfs_volume *vol,
                               uint64_t src_dir, const ntfschar *usrc, int slen, u64 sref,
                               uint64_t dst_dir, const ntfschar *udst, int dlen, u64 dref) {
    ntfschar *utmp = NULL;
    int tmplen = 0, e;
    /* Pick a temp name that does not already exist in the destination directory. */
    {
        ntfs_inode *ddir = nfsk_inode_open(vol, to_mref(dst_dir));
        if (!ddir) return -1;
        int found = 0;
        for (int tries = 0; tries < 4096; tries++) {
            char tmpname[64];
            snprintf(tmpname, sizeof(tmpname), "ntfs3g-rn-%016llx-%u",
                     (unsigned long long)MREF(dref), ++((nfsk_devctx *)vol->dev->d_private)->rename_seq);
            free(utmp); utmp = NULL;
            tmplen = ntfs_mbstoucs(tmpname, &utmp);
            if (tmplen < 0) { nfsk_inode_close(ddir); free(utmp); return -1; }
            errno = 0;
            u64 ex = ntfs_inode_lookup_by_name(ddir, utmp, tmplen);
            if (ex == (u64)-1) {
                if (errno == 0 || errno == ENOENT) { found = 1; break; }   /* name is free */
                int le = errno; nfsk_inode_close(ddir); free(utmp); errno = le; return -1;
            }
        }
        nfsk_inode_close(ddir);
        if (!found) { free(utmp); errno = EEXIST; return -1; }
    }

    /* (1) back up the destination under the temp name */
    if (nfsk_link_name(vol, dst_dir, dref, utmp, tmplen)) {
        e = errno; free(utmp); errno = e; return -1;
    }
    /* (2) remove the destination's original name */
    if (nfsk_unlink_name(vol, dst_dir, udst, dlen)) {
        e = errno;                                    /* dst keeps its name */
        nfsk_unlink_name(vol, dst_dir, utmp, tmplen); /* drop the backup */
        free(utmp); errno = e; return -1;
    }
    /* (3) give the source the destination's name */
    if (nfsk_link_name(vol, dst_dir, sref, udst, dlen)) {
        e = errno;
        if (nfsk_link_name(vol, dst_dir, dref, udst, dlen) == 0)  /* restore dst */
            nfsk_unlink_name(vol, dst_dir, utmp, tmplen);
        free(utmp); errno = e; return -1;
    }
    /* (4) drop the source's old name */
    if (nfsk_unlink_name(vol, src_dir, usrc, slen)) {
        e = errno;
        if (nfsk_unlink_name(vol, dst_dir, udst, dlen) == 0) {        /* undo (3) */
            if (nfsk_link_name(vol, dst_dir, dref, udst, dlen) == 0)  /* restore dst */
                nfsk_unlink_name(vol, dst_dir, utmp, tmplen);
        }
        free(utmp); errno = e; return -1;
    }
    /* success: the source holds the destination name; dropping the backup frees the
       destination's data (its last reference). The rename has already succeeded, so a
       cleanup failure is logged (leaving an orphan temp link) rather than reported as
       a rename error. */
    if (nfsk_unlink_name(vol, dst_dir, utmp, tmplen) != 0)
        ntfs_log_error("xntfs: rename left an orphan temp backup link (errno %d)\n", errno);
    free(utmp);
    return 0;
}

/*
 * Rename src_dir/src_name -> dst_dir/dst_name, mirroring src/ntfs-3g.c's
 * ntfs_fuse_rename(): a rename whose destination resolves to the same inode (a
 * case-only change, or another hard-link name) is a no-op; an existing, different
 * destination is replaced recoverably; otherwise the new name is linked before the
 * old name is unlinked, so the source is never lost if the unlink fails.
 */
int nfsk_rename(ntfs_fskit_volume *v, uint64_t src_dir, const char *src_name,
                uint64_t dst_dir, const char *dst_name) {
    if (!v || !v->vol) return -EINVAL;
    if (v->read_only) return -EROFS;
    if (!src_name || !nfsk_valid_new_name(dst_name)) return -EINVAL;

    ntfs_volume *vol = v->vol;
    if (is_reserved_mft(to_mref(src_dir)) || is_reserved_mft(to_mref(dst_dir))) return -EPERM;
    ntfschar *usrc = NULL, *udst = NULL;
    int slen, dlen, rc = 0, e = 0, src_isdir = 0;
    u64 sref = (u64)-1, dref = (u64)-1;

    slen = nfsk_name_to_unicode(src_name, &usrc);
    if (slen < 0) { e = errno; rc = -1; goto out; }
    if (slen > NTFS_MAX_NAME_LEN) { e = ENAMETOOLONG; rc = -1; goto out; }
    dlen = nfsk_name_to_unicode(dst_name, &udst);
    if (dlen < 0) { e = errno; rc = -1; goto out; }
    if (dlen > NTFS_MAX_NAME_LEN) { e = ENAMETOOLONG; rc = -1; goto out; }
    if (nfsk_is_retention_name(vol, to_mref(src_dir), usrc, slen) ||
        nfsk_is_retention_name(vol, to_mref(dst_dir), udst, dlen)) {
        e = ENOENT; rc = -1; goto out;
    }

    /* Resolve the source inode. */
    {
        ntfs_inode *sdir = nfsk_inode_open(vol, to_mref(src_dir));
        if (!sdir) { e = errno; rc = -1; goto out; }
        sref = ntfs_inode_lookup_by_name(sdir, usrc, slen);
        e = errno;
        nfsk_inode_close(sdir);
        if (sref == (u64)-1) { e = e ? e : ENOENT; rc = -1; goto out; }
    }
    if (is_reserved_mft(MREF(sref))) { e = EPERM; rc = -1; goto out; }  /* can't move metadata */

    src_isdir = nfsk_isdir(vol, sref, NULL);
    if (src_isdir < 0) { e = errno ? errno : EIO; rc = -1; goto out; }
    /* Moving a directory into its own subtree would create a cycle (mv A A/B/C). */
    if (src_isdir && src_dir != dst_dir) {
        int desc = nfsk_dir_contains(vol, sref, dst_dir);
        if (desc < 0) { e = errno ? errno : EIO; rc = -1; goto out; }
        if (desc)     { e = EINVAL; rc = -1; goto out; }
    }

    /* Resolve the destination inode (may be absent). A -1 result means "not found"
       only when errno is ENOENT/unset; any other errno is a real error (corruption or
       I/O) and must abort rather than fall through to the "no destination" path. */
    {
        ntfs_inode *ddir = nfsk_inode_open(vol, to_mref(dst_dir));
        if (!ddir) { e = errno; rc = -1; goto out; }
        errno = 0;
        dref = ntfs_inode_lookup_by_name(ddir, udst, dlen);
        int le = errno;
        nfsk_inode_close(ddir);
        if (dref == (u64)-1 && le != 0 && le != ENOENT) { e = le; rc = -1; goto out; }
    }

    if (dref != (u64)-1) {
        /* Same underlying file (case-only rename, or another hard-link name): a
           no-op, exactly as upstream ntfs_fuse_rename treats it. The on-disk name
           keeps its existing case. */
        if (MREF(dref) == MREF(sref)) { rc = 0; goto out; }
        if (is_reserved_mft(MREF(dref))) { e = EPERM; rc = -1; goto out; }  /* don't clobber metadata */
        /* POSIX type compatibility + empty-target checks, before any mutation. */
        int dst_empty = 0;
        int dst_isdir = nfsk_isdir(vol, dref, &dst_empty);
        if (dst_isdir < 0) { e = errno ? errno : EIO; rc = -1; goto out; }
        if (dst_isdir && !src_isdir)  { e = EISDIR;    rc = -1; goto out; }  /* file over dir      */
        if (!dst_isdir && src_isdir)  { e = ENOTDIR;   rc = -1; goto out; }  /* dir over non-dir   */
        if (dst_isdir && !dst_empty)  { e = ENOTEMPTY; rc = -1; goto out; }  /* over non-empty dir */
        /* Replace an existing, different destination — recoverable. */
        if (nfsk_safe_overwrite(vol, src_dir, usrc, slen, sref,
                                dst_dir, udst, dlen, dref)) { e = errno; rc = -1; }
        goto out;
    }

    /* No existing destination: link the new name, then unlink the old; if the
       unlink fails, undo the new link. The new name is always created before the
       old is removed, so the source is never lost. */
    if (nfsk_link_name(vol, dst_dir, sref, udst, dlen)) { e = errno; rc = -1; goto out; }
    if (nfsk_unlink_name(vol, src_dir, usrc, slen)) {
        e = errno; rc = -1;
        nfsk_unlink_name(vol, dst_dir, udst, dlen);   /* undo the new link */
    }

out:
    free(usrc); free(udst);
    if (!rc && v->devctx->writeback_error) return -v->devctx->writeback_error;
    return rc ? -e : 0;
}

/* Hard link: add `name` in dir_ino as another name for inode `target_ino`. NTFS keeps
 * a link count + multiple FILE_NAME attributes, so this is a thin wrapper over ntfs_link
 * (the bridge is inode-keyed — no path map to update). Directories can't be hard-linked. */
int nfsk_link(ntfs_fskit_volume *v, uint64_t target_ino, uint64_t dir_ino,
              const char *name_utf8, int *out_errno) {
    if (!v || !v->vol || !nfsk_valid_new_name(name_utf8)) { if (out_errno) *out_errno = EINVAL; return -1; }
    if (v->read_only) { if (out_errno) *out_errno = EROFS; return -1; }
    if (is_reserved_mft(to_mref(target_ino)) || is_reserved_mft(to_mref(dir_ino))) {
        if (out_errno) *out_errno = EPERM; return -1;
    }
    int isdir = nfsk_isdir(v->vol, to_mref(target_ino), NULL);
    if (isdir < 0) { if (out_errno) *out_errno = errno ? errno : EIO; return -1; }
    /* FSKit expects ENOTSUP when hard links aren't supported for the object's type (a dir). */
    if (isdir)     { if (out_errno) *out_errno = ENOTSUP; return -1; }

    ntfschar *uname = NULL;
    int ulen = nfsk_name_to_unicode(name_utf8, &uname);
    if (ulen < 0) { if (out_errno) *out_errno = errno; return -1; }
    if (ulen > NTFS_MAX_NAME_LEN) {
        free(uname); if (out_errno) *out_errno = ENAMETOOLONG; return -1;
    }
    int r = nfsk_link_name(v->vol, dir_ino, to_mref(target_ino), uname, ulen);
    int e = errno;
    free(uname);
    if (!r && v->devctx->writeback_error) { r = -1; e = v->devctx->writeback_error; }
    if (r) { if (out_errno) *out_errno = e ? e : EIO; return -1; }
    return 0;
}

uint64_t nfsk_symlink(ntfs_fskit_volume *v, uint64_t dir_ino, const char *name,
                      const char *target, int *out_errno) {
    int error = 0;
    uint64_t ino = 0;
    ntfschar *unicode = NULL, *link = NULL;
    ntfs_inode *dir = NULL;
    nfsk_inode_ref *owned = NULL;
    if (!v || !v->vol || !nfsk_valid_new_name(name) || !target || !*target) { error = EINVAL; goto done; }
    if (v->read_only) { error = EROFS; goto done; }
    if (is_reserved_mft(to_mref(dir_ino))) { error = EPERM; goto done; }
    if (strlen(target) >= 4096) { error = ENAMETOOLONG; goto done; }
    int length = nfsk_name_to_unicode(name, &unicode);
    int link_length = nfsk_name_to_unicode(target, &link);
    if (length < 0 || link_length < 0) { error = errno ? errno : EILSEQ; goto done; }
    if (length > NTFS_MAX_NAME_LEN || link_length > 4096) { error = ENAMETOOLONG; goto done; }
    dir = nfsk_inode_open(v->vol, to_mref(dir_ino));
    if (!dir) { error = errno ? errno : EIO; goto done; }
    if (nfsk_unlinked_directory(dir)) { error = ENOENT; goto done; }
    errno = 0;
    MFT_REF existing = ntfs_inode_lookup_by_name(dir, unicode, length);
    if (existing != (MFT_REF)-1 || errno != ENOENT) {
        error = existing != (MFT_REF)-1 ? EEXIST : (errno ? errno : EIO);
        goto done;
    }
    owned = calloc(1, sizeof(*owned));
    if (!owned) { error = ENOMEM; goto done; }
    int previous_format = v->vol->special_files;
    v->vol->special_files = NTFS_FILES_WSL;
    bool preserve_bom = link_length && link[0] == const_cpu_to_le16(0xfeff);
    /* Native WSL creation converts back to UTF8. Retain its original type,
     * compression and length rules with the same-width substitution above. */
    if (preserve_bom) link[0] = const_cpu_to_le16(0xfffd);
    ntfs_inode *ni = ntfs_create_symlink(dir, const_cpu_to_le32(0), unicode, length, link, link_length);
    if (preserve_bom) link[0] = const_cpu_to_le16(0xfeff);
    v->vol->special_files = previous_format;
    if (!ni) { error = errno ? errno : EIO; goto done; }
    owned->inode = ni; owned->next = v->devctx->inodes; v->devctx->inodes = owned;
    owned = NULL;
    if (preserve_bom) {
        nfsk_devctx *ctx = v->devctx;
        uint64_t writes = ctx->directory_generation, failures = ctx->write_failures;
        uint64_t reads = ctx->read_failures;
        errno = 0;
        ntfs_attr *attr = ntfs_attr_open(ni, AT_REPARSE_POINT, AT_UNNAMED, 0);
        if (!attr) error = errno ? errno : EIO;
        else {
            errno = 0;
            /* Only these three bytes differ. No tag, length, index or attribute
             * resize is needed; correct the payload before final inode closes. */
            if (ntfs_attr_pwrite(attr, sizeof(REPARSE_POINT) + sizeof(le32), 3, "\xef\xbb\xbf") != 3)
                error = errno ? errno : EIO;
            ntfs_attr_close(attr);
        }
        if (ctx->write_failures != failures) error = ctx->last_io_error;
        else if (ctx->read_failures != reads) error = ctx->last_read_error;
        if (error) {
            if (ctx->directory_generation != writes || ctx->read_failures != reads) {
                /* A failed correction may already have reached disk. Retain both
                 * owned inodes, block admission and let error teardown free them
                 * without a destructive rollback or another write attempt. */
                ctx->fatal_writeback_error = ctx->writeback_error = error;
            } else {
                int result = nfsk_delete(v->vol, ni, dir, unicode, length);
                int cleanup_error = errno ? errno : EIO;
                if (ctx->write_failures != failures) cleanup_error = ctx->last_io_error;
                else if (ctx->read_failures != reads) cleanup_error = ctx->last_read_error;
                if (result || ctx->write_failures != failures || ctx->read_failures != reads)
                    ctx->fatal_writeback_error = ctx->writeback_error = cleanup_error;
            }
            /* Successful or failed delete consumes both inode pointers; the
             * fatal-I/O branch deliberately keeps them in the owned registry. */
            dir = NULL;
            goto done;
        }
    }
    ino = from_mft(ni->mft_no);
    /* A resident directory index is still in dir->mrec. Publish it before
     * syncing the symlink's FILE_NAME through a freshly opened parent. */
    if (nfsk_inode_close(dir)) error = errno ? errno : EIO;
    dir = NULL;
    if (!error && nfsk_inode_close(ni)) error = errno ? errno : EIO;
done:
    if (dir && nfsk_inode_close(dir) && !error) error = errno ? errno : EIO;
    free(owned); free(unicode); free(link);
    if (out_errno) *out_errno = error;
    return error ? 0 : ino;
}

int nfsk_rename_volume(ntfs_fskit_volume *v, const char *name) {
    if (!v || !v->vol || !name || !*name) return -EINVAL;
    if (v->read_only) return -EROFS;
    if (v->devctx->writeback_error) return -v->devctx->writeback_error;
    if (strpbrk(name, "\\/:*?\"<>|")) return -EINVAL;
    for (const unsigned char *p = (const unsigned char *)name; *p; p++)
        if (*p < 32) return -EINVAL;
    ntfschar *unicode = NULL;
    int length = nfsk_name_to_unicode(name, &unicode);
    if (length < 0) return -(errno ? errno : EILSEQ);
    int error = length >= 128 ? ENAMETOOLONG : 0;
    char *preserved = NULL;
    /* Allocate the corrected cache before the write. Native rename decodes
     * through the same BOM-consuming normalization as native mount. */
    if (!error && length && unicode[0] == const_cpu_to_le16(0xfeff) &&
        nfsk_name_to_utf8(unicode, length, &preserved) < 0) error = errno ? errno : EILSEQ;
    /* AT_VOLUME_NAME contains exactly the label's UTF-16 code units, without NUL. */
    if (!error && ntfs_volume_rename(v->vol, unicode, length)) error = errno ? errno : EIO;
    if (!error && preserved) {
        free(v->vol->vol_name);
        v->vol->vol_name = preserved;
        preserved = NULL;
    }
    free(preserved);
    free(unicode);
    if (!error) return nfsk_sync(v);
    return -error;
}

/* ntfsfallocate uses the same public attribute APIs to preserve logical EOF
 * after allocating clusters. Do not expose the uninitialized reserved tail. */
static int nfsk_restore_data_size(ntfs_attr *data, ntfs_attr_search_ctx *search, s64 size, s64 initialized) {
    ntfs_attr_reinit_search_ctx(search);
    int error = 0;
    if (ntfs_attr_lookup(AT_DATA, AT_UNNAMED, 0, CASE_SENSITIVE, 0, NULL, 0, search)) error = errno ? errno : EIO;
    else if (!search->attr->non_resident) {
        if (data->data_size != size) error = EIO;
    } else {
        data->data_size = size;
        data->initialized_size = initialized;
        search->attr->data_size = cpu_to_sle64(size);
        search->attr->initialized_size = cpu_to_sle64(initialized);
        data->ni->data_size = size;
        data->ni->allocated_size = data->allocated_size;
        ntfs_inode_mark_dirty(search->ntfs_ino);
        NInoFileNameSetDirty(data->ni);
    }
    return -error;
}

int64_t nfsk_preallocate(ntfs_fskit_volume *v, uint64_t ino, int64_t offset,
                         int64_t length, bool from_eof) {
    if (!v || !v->vol || length < 0 || (!from_eof && offset < 0)) return -EINVAL;
    if (v->read_only) return -EROFS;
    if (is_reserved_mft(to_mref(ino))) return -EPERM;
    ntfs_inode *ni = nfsk_inode_open(v->vol, to_mref(ino));
    if (!ni) return -(errno ? errno : EIO);
    ntfs_attr *data = NULL;
    ntfs_attr_search_ctx *search = NULL;
    int64_t result = 0;
    int type = nfsk_inode_type(ni);
    if (type < 0) { result = type; goto done; }
    if (type != NFSK_TYPE_FILE) { result = type == NFSK_TYPE_DIR ? -EISDIR : -ENOTSUP; goto done; }
    data = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (!data) { result = -(errno ? errno : EIO); goto done; }
    if (data->data_flags & (ATTR_COMPRESSION_MASK | ATTR_IS_ENCRYPTED | ATTR_IS_SPARSE)) {
        result = -ENOTSUP; goto done;
    }
    if (!length) goto done;
    s64 previous = NAttrNonResident(data) ? data->allocated_size : 0;
    s64 size = data->data_size, initialized = data->initialized_size;
    s64 start = from_eof ? previous : offset;
    s64 mask = v->vol->cluster_size - 1;
    if (start > INT64_MAX - length || start + length > INT64_MAX - mask) { result = -EFBIG; goto done; }
    s64 target = (start + length + mask) & ~mask;
    if (target <= previous) goto done;
    if (((target - previous) >> v->vol->cluster_size_bits) > v->vol->free_clusters) {
        result = -ENOSPC; goto done;
    }
    search = ntfs_attr_get_search_ctx(ni, NULL);
    if (!search) { result = -(errno ? errno : ENOMEM); goto done; }
    if (ntfs_attr_truncate_solid(data, target)) result = -(errno ? errno : EIO);
    int restore = nfsk_restore_data_size(data, search, size, initialized);
    if (restore) {
        v->devctx->fatal_writeback_error = v->devctx->writeback_error = -restore;
        result = restore;
    }
    if (!result) {
        result = data->allocated_size - previous;
        ntfs_inode_update_times(ni, NTFS_UPDATE_CTIME);
    }
done:
    if (search) ntfs_attr_put_search_ctx(search);
    if (data) ntfs_attr_close(data);
    if (nfsk_inode_close(ni) && result >= 0) result = -(errno ? errno : EIO);
    return result;
}

int nfsk_seek_region(ntfs_fskit_volume *v, uint64_t ino, int64_t offset,
                     bool seek_data, int64_t *result) {
    if (!v || !v->vol || !result || offset < 0) return -EINVAL;
    if (is_reserved_mft(to_mref(ino))) return -EPERM;
    ntfs_inode *ni = nfsk_inode_open(v->vol, to_mref(ino));
    if (!ni) return -(errno ? errno : EIO);
    ntfs_attr *data = NULL;
    int error = 0;
    int type = nfsk_inode_type(ni);
    if (type < 0) { error = -type; goto done; }
    if (type != NFSK_TYPE_FILE) { error = type == NFSK_TYPE_DIR ? EISDIR : ENOTSUP; goto done; }
    data = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (!data) { error = errno ? errno : EIO; goto done; }
    if (offset >= data->data_size) { error = ENXIO; goto done; }
    if (!NAttrNonResident(data) || (data->data_flags & ATTR_COMPRESSION_MASK)) {
        *result = seek_data ? offset : data->data_size;
        goto done;
    }
    if (ntfs_attr_map_whole_runlist(data)) { error = errno ? errno : EIO; goto done; }
    if (!data->rl) { error = EIO; goto done; }
    *result = seek_data ? -1 : data->data_size;
    for (runlist_element *run = data->rl; run && run->length; run++) {
        if (run->vcn < 0 || run->length < 0 || run->lcn < LCN_HOLE ||
            run->vcn > (INT64_MAX >> v->vol->cluster_size_bits) - run->length) {
            error = EIO; break;
        }
        int64_t start = run->vcn << v->vol->cluster_size_bits;
        int64_t end = (run->vcn + run->length) << v->vol->cluster_size_bits;
        if (end <= offset) continue;
        if (start >= data->data_size) break;
        if ((run->lcn != LCN_HOLE) == seek_data) {
            *result = start > offset ? start : offset;
            break;
        }
    }
    if (!error && *result < 0) error = ENXIO;
done:
    if (data) ntfs_attr_close(data);
    if (nfsk_inode_close(ni) && !error) error = errno ? errno : EIO;
    return -error;
}

/* Preserve the caller's capacity and size-error precedence before close.
 * Both callers own the target only after final close succeeds. */
static int readlink_target(ntfs_fskit_volume *v, uint64_t ino, size_t cap, char **out) {
    *out = NULL;
    if (!v || !v->vol || !cap || is_reserved_mft(to_mref(ino))) return -EINVAL;
    ntfs_inode *ni = nfsk_inode_open(v->vol, to_mref(ino));
    if (!ni) return -errno;
    /* Absolute Windows targets retain upstream's best-effort root translation. */
    char *target = nfsk_symlink_target(ni, NULL);
    int saved = target ? 0 : (errno ? errno : EINVAL);
    if (!saved && strlen(target) >= cap) saved = ENAMETOOLONG;
    if (nfsk_inode_close(ni) && !saved) saved = errno ? errno : EIO;
    if (saved) free(target);
    else *out = target;
    return -saved;
}

int nfsk_readlink(ntfs_fskit_volume *v, uint64_t ino, char *buf, size_t cap) {
    if (!buf || cap == 0) return -EINVAL;
    char *target = NULL;
    int result = readlink_target(v, ino, cap, &target);
    if (!result) memcpy(buf, target, strlen(target) + 1);
    free(target);
    return result;
}

int nfsk_readlink_alloc(ntfs_fskit_volume *v, uint64_t ino, char **target, size_t cap) {
    if (!target) return -EINVAL;
    return readlink_target(v, ino, cap, target);
}
