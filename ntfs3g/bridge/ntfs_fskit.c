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
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/disk.h>
#include <unistd.h>

#include <ntfs-3g/types.h>
#include <ntfs-3g/param.h>
#include <ntfs-3g/endians.h>
#include <ntfs-3g/layout.h>
#include <ntfs-3g/device.h>
#include <ntfs-3g/volume.h>
#include <ntfs-3g/inode.h>
#include <ntfs-3g/dir.h>
#include <ntfs-3g/attrib.h>
#include <ntfs-3g/unistr.h>
#include <ntfs-3g/ntfstime.h>
#include <ntfs-3g/bootsect.h>
#include <ntfs-3g/logging.h>
#include <ntfs-3g/reparse.h>

#include "ntfs_fskit.h"

/* ---- Device context + operations backed by FSBlockDeviceResource ---- */
typedef struct {
    void    *resource;   /* __bridge FSBlockDeviceResource* (owned by Swift) */
    int64_t  pos;
} nfsk_devctx;

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
    if (NDevDirty(dev) && !NDevReadOnly(dev)) {
        int r = nfsk_block_sync(c->resource);
        if (r == 0) NDevClearDirty(dev);   /* only forget dirty once the flush succeeds */
        else { errno = -r; ret = -1; }      /* keep dirty so the failure isn't masked */
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
    int64_t np = base + offset;
    if (np < 0) { errno = EINVAL; return -1; }
    c->pos = np;
    return np;
}

static s64 dev_pread(struct ntfs_device *dev, void *buf, s64 count, s64 offset) {
    nfsk_devctx *c = dev->d_private;
    return nfsk_block_pread(c->resource, buf, offset, count);
}

static s64 dev_pwrite(struct ntfs_device *dev, const void *buf, s64 count, s64 offset) {
    nfsk_devctx *c = dev->d_private;
    if (NDevReadOnly(dev)) { errno = EROFS; return -1; }
    NDevSetDirty(dev);
    return nfsk_block_pwrite(c->resource, buf, offset, count);
}

static s64 dev_read(struct ntfs_device *dev, void *buf, s64 count) {
    nfsk_devctx *c = dev->d_private;
    s64 r = nfsk_block_pread(c->resource, buf, c->pos, count);
    if (r > 0) c->pos += r;
    return r;
}

static s64 dev_write(struct ntfs_device *dev, const void *buf, s64 count) {
    nfsk_devctx *c = dev->d_private;
    if (NDevReadOnly(dev)) { errno = EROFS; return -1; }
    NDevSetDirty(dev);
    s64 r = nfsk_block_pwrite(c->resource, buf, c->pos, count);
    if (r > 0) c->pos += r;
    return r;
}

static int dev_sync(struct ntfs_device *dev) {
    nfsk_devctx *c = dev->d_private;
    if (NDevReadOnly(dev)) return 0;
    int r = nfsk_block_sync(c->resource);
    if (r == 0) NDevClearDirty(dev);
    else { errno = -r; return -1; }
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
    ntfs_inode *ni = ntfs_inode_open(vol, ref);
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
    ntfs_inode_close(ni);
    if (ret == -1 && saved) errno = saved;
    return ret;
}

/* Raw parent MFT number from the inode's first FILE_NAME attribute, or (u64)-1 for
 * the root or when the record can't be read. */
static u64 nfsk_parent_mft_raw(ntfs_inode *ni) {
    if (ni->mft_no == (u64)FILE_root) return (u64)-1;
    ntfs_attr_search_ctx *ctx = ntfs_attr_get_search_ctx(ni, NULL);
    if (!ctx) return (u64)-1;
    u64 pmft = (u64)-1;
    if (!ntfs_attr_lookup(AT_FILE_NAME, AT_UNNAMED, 0, CASE_SENSITIVE, 0, NULL, 0, ctx)) {
        const FILE_NAME_ATTR *fn = (const FILE_NAME_ATTR *)
            ((const u8 *)ctx->attr + le16_to_cpu(ctx->attr->value_offset));
        pmft = MREF(le64_to_cpu(fn->parent_directory));
    }
    ntfs_attr_put_search_ctx(ctx);
    return pmft;
}

/* Parent directory (in our numbering) for attributes. NTFS hard links give one inode
 * several FILE_NAME attrs in different directories; we report the first — a stable,
 * deterministic choice — because FSKit identity is per fileID and cannot represent
 * multiple parents. Returns 0 when it can't be read (Swift then falls back to the
 * lookup hint, and enumeration overrides this with the listing directory). */
static uint64_t nfsk_parent_ino(ntfs_inode *ni) {
    if (ni->mft_no == (u64)FILE_root) return NFSK_PARENT_OF_ROOT;
    u64 pmft = nfsk_parent_mft_raw(ni);
    if (pmft == (u64)-1 || is_reserved_mft(pmft)) return 0;
    return from_mft(pmft);
}

/* Returns 1 if `sref` is `dst_dir` itself or an ancestor of it — i.e. moving the
 * directory `sref` into `dst_dir` would create a cycle (mv A A/B/C). 0 if not, -1 on
 * error (errno set). Walks dst_dir's FILE_NAME parent chain up toward the root. */
static int nfsk_dir_contains(ntfs_volume *vol, u64 sref, uint64_t dst_dir) {
    u64 cur = to_mref(dst_dir);
    for (int guard = 0; guard < 65536; guard++) {
        if (MREF(cur) == MREF(sref)) return 1;
        if (MREF(cur) == (u64)FILE_root) return 0;
        ntfs_inode *ni = ntfs_inode_open(vol, cur);
        if (!ni) return -1;                                /* errno from ntfs_inode_open */
        u64 par = nfsk_parent_mft_raw(ni);
        ntfs_inode_close(ni);                              /* clobbers errno, so set it below */
        if (par == (u64)-1) { errno = EIO; return -1; }    /* unreadable parent chain */
        cur = par;
    }
    errno = ELOOP;   /* chain too long → cyclic/corrupt metadata, not a real ancestry */
    return -1;
}

static uint32_t map_dt(unsigned dt_type) {
    switch (dt_type) {
        case NTFS_DT_DIR:     return NFSK_TYPE_DIR;
        /* Default reparse/link entries to FILE here; bridge_filldir upgrades the ones
           that are resolvable symlinks to SYMLINK (it has the inode to probe). */
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

/* ---- Lifecycle ---- */
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

int nfsk_probe(void *resource, char *name_out, size_t name_cap) {
    nfsk_devctx *ctx = NULL;
    struct ntfs_device *dev = make_device(resource, &ctx);
    if (!dev) return 0;
    ntfs_volume *vol = ntfs_device_mount(dev, NTFS_MNT_RDONLY | NTFS_MNT_FORENSIC);
    if (!vol) { ntfs_device_free(dev); free(ctx); return 0; }
    if (name_out && name_cap) {
        name_out[0] = '\0';
        if (vol->vol_name) { strncpy(name_out, vol->vol_name, name_cap - 1); name_out[name_cap - 1] = '\0'; }
    }
    ntfs_umount(vol, TRUE);
    free(ctx);
    return 1;
}

void nfsk_umount(ntfs_fskit_volume *v) {
    if (!v) return;
    if (v->vol) ntfs_umount(v->vol, TRUE);
    free(v->devctx);
    free(v);
}

int nfsk_sync(ntfs_fskit_volume *v) {
    if (!v || !v->vol) return -EINVAL;
    if (v->read_only) return 0;
    if (ntfs_device_sync(v->vol->dev)) return -errno;
    return 0;
}

int nfsk_statfs(ntfs_fskit_volume *v, nfsk_statfs_t *out) {
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
    if (vol->vol_name) { strncpy(out->volume_name, vol->vol_name, sizeof(out->volume_name) - 1);
                         out->volume_name[sizeof(out->volume_name) - 1] = '\0'; }
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

/* A reparse point counts as a symlink for us only when ntfs_make_symlink can actually
 * produce a target. ntfs_possible_symlink only checks the reparse tag, not the data, so a
 * junction / corrupt reparse with a symlink-ish tag would otherwise be typed SYMLINK yet
 * fail readlink afterwards; classifying by the real parse keeps the reported type in sync
 * with what readSymbolicLink can resolve. */
static int nfsk_is_readable_symlink(ntfs_inode *ni) {
    if (!(ni->flags & FILE_ATTR_REPARSE_POINT)) return 0;
    char *target = ntfs_make_symlink(ni, "/");
    if (!target) return 0;
    free(target);
    return 1;
}

int nfsk_getattr(ntfs_fskit_volume *v, uint64_t ino, nfsk_attr_t *out) {
    if (!v || !v->vol || !out) return -EINVAL;
    if (is_reserved_mft(to_mref(ino))) return -ENOENT;   /* metadata is not a file */
    ntfs_inode *ni = ntfs_inode_open(v->vol, to_mref(ino));
    if (!ni) return -errno;

    memset(out, 0, sizeof(*out));
    out->ino = from_mft(ni->mft_no);
    out->parent_ino = nfsk_parent_ino(ni);
    out->nlink = le16_to_cpu(ni->mrec->link_count);

    int is_dir = (ni->mrec->flags & MFT_RECORD_IS_DIRECTORY) ? 1 : 0;
    if (is_dir) {
        out->type = NFSK_TYPE_DIR;
        if (!test_nino_flag(ni, KnownSize)) {
            ntfs_attr *na = ntfs_attr_open(ni, AT_INDEX_ALLOCATION, NTFS_INDEX_I30, 4);
            if (na) { ni->data_size = na->data_size; ni->allocated_size = na->allocated_size;
                      set_nino_flag(ni, KnownSize); ntfs_attr_close(na); }
        }
        out->size = (uint64_t)ni->data_size;
        out->alloc_size = (uint64_t)ni->allocated_size;
        out->mode = 0777;
        if (out->nlink == 0) out->nlink = 1;
    } else if (ni->flags & FILE_ATTR_REPARSE_POINT) {
        /* Reparse points whose target actually parses are exposed as symlinks (so readlink
           works) with the POSIX symlink size = target string length; other tags
           (unresolvable junctions, dedup, ...) stay opaque regular files. */
        char *target = ntfs_make_symlink(ni, "/");
        if (target) {
            out->type = NFSK_TYPE_SYMLINK;
            out->size = (uint64_t)strlen(target);
            out->alloc_size = out->size;
            out->mode = 0777;
            free(target);
        } else {
            out->type = NFSK_TYPE_FILE;
            out->size = (uint64_t)ni->data_size;
            out->alloc_size = (uint64_t)ni->allocated_size;
            out->mode = (ni->flags & FILE_ATTR_READONLY) ? 0444 : 0666;
        }
    } else {
        out->type = NFSK_TYPE_FILE;
        ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
        if (na) { out->size = (uint64_t)na->data_size; out->alloc_size = (uint64_t)na->allocated_size; ntfs_attr_close(na); }
        else    { out->size = (uint64_t)ni->data_size; out->alloc_size = (uint64_t)ni->allocated_size; }
        out->mode = (ni->flags & FILE_ATTR_READONLY) ? 0444 : 0666;
    }
    fill_times(out, ni);
    ntfs_inode_close(ni);
    return 0;
}

uint64_t nfsk_lookup(ntfs_fskit_volume *v, uint64_t dir_ino, const char *name_utf8, int *out_errno) {
    if (!v || !v->vol) { if (out_errno) *out_errno = EINVAL; return 0; }
    ntfs_inode *dir = ntfs_inode_open(v->vol, to_mref(dir_ino));
    if (!dir) { if (out_errno) *out_errno = errno; return 0; }

    ntfschar *uname = NULL;
    int ulen = ntfs_mbstoucs(name_utf8, &uname);
    if (ulen < 0) { if (out_errno) *out_errno = errno; ntfs_inode_close(dir); return 0; }
    u64 mref = ntfs_inode_lookup_by_name(dir, uname, ulen);
    free(uname);
    ntfs_inode_close(dir);
    if (mref == (u64)-1) { if (out_errno) *out_errno = errno ? errno : ENOENT; return 0; }
    if (is_reserved_mft(MREF(mref))) { if (out_errno) *out_errno = ENOENT; return 0; }  /* don't expose metadata */
    return from_mft(MREF(mref));
}

/* ---- Directory enumeration (robust ordinal cookies) ---- */
struct fill_ctx { ntfs_volume *vol; nfsk_dir_cb cb; void *ctx; int64_t skip; int64_t count; int stopped; };

static int bridge_filldir(void *dirent, const ntfschar *name, const int name_len,
                          const int name_type, const s64 pos, const MFT_REF mref,
                          const unsigned dt_type) {
    (void)pos;
    struct fill_ctx *fc = dirent;
    if (fc->stopped) return 1;
    if (name_type == FILE_NAME_DOS) return 0;
    if (MREF(mref) < FILE_first_user) return 0;   /* hide NTFS metadata ($MFT, $Boot, ...) */

    char *u = NULL;
    int l = ntfs_ucstombs(name, name_len, &u, 0);
    if (l < 0) return 0;
    if (!strcmp(u, ".") || !strcmp(u, "..")) { free(u); return 0; }

    int64_t ordinal = fc->count;
    fc->count++;
    if (ordinal < fc->skip) { free(u); return 0; }

    uint32_t type = map_dt(dt_type);
    if (dt_type == NTFS_DT_REPARSE || dt_type == NTFS_DT_LNK) {
        /* Match getattr: a resolvable symlink lists as SYMLINK so FSKit offers readlink. */
        ntfs_inode *eni = ntfs_inode_open(fc->vol, mref);
        if (eni) {
            if (nfsk_is_readable_symlink(eni))
                type = NFSK_TYPE_SYMLINK;
            ntfs_inode_close(eni);
        }
    }
    uint64_t ino = from_mft(MREF(mref));
    int r = fc->cb(fc->ctx, u, ino, type, ordinal + 1);
    free(u);
    if (r != 0) { fc->stopped = 1; return 1; }
    return 0;
}

int nfsk_readdir(ntfs_fskit_volume *v, uint64_t dir_ino, int64_t start_cookie, void *ctx, nfsk_dir_cb cb) {
    if (!v || !v->vol || !cb) return -EINVAL;
    ntfs_inode *dir = ntfs_inode_open(v->vol, to_mref(dir_ino));
    if (!dir) return -errno;

    struct fill_ctx fc = { v->vol, cb, ctx, start_cookie < 0 ? 0 : start_cookie, 0, 0 };
    s64 pos = 0;
    errno = 0;
    int rc = ntfs_readdir(dir, &pos, &fc, bridge_filldir);
    ntfs_inode_close(dir);
    if (rc && !fc.stopped) return -(errno ? errno : EIO);
    return 0;
}

/* ---- File I/O ---- */
int64_t nfsk_read(ntfs_fskit_volume *v, uint64_t ino, int64_t offset, void *buf, int64_t len, int *out_errno) {
    if (!v || !v->vol || len < 0) { if (out_errno) *out_errno = EINVAL; return -1; }
    if (is_reserved_mft(to_mref(ino))) { if (out_errno) *out_errno = EPERM; return -1; }
    if (len == 0) return 0;
    ntfs_inode *ni = ntfs_inode_open(v->vol, to_mref(ino));
    if (!ni) { if (out_errno) *out_errno = errno; return -1; }
    ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (!na) { if (out_errno) *out_errno = errno; ntfs_inode_close(ni); return -1; }

    int64_t result;
    s64 max = na->data_size;
    if (offset >= max) { result = 0; goto done; }
    if (offset + len > max) len = max - offset;

    int64_t total = 0;
    while (len > 0) {
        s64 r = ntfs_attr_pread(na, offset + total, len, (char *)buf + total);
        if (r <= 0) { if (total == 0) { if (out_errno) *out_errno = errno ? errno : EIO; total = -1; } break; }
        total += r; len -= r;
    }
    result = total;
done:
    ntfs_attr_close(na);
    if (!v->read_only && result >= 0) ntfs_inode_update_times(ni, NTFS_UPDATE_ATIME);
    ntfs_inode_close(ni);
    return result;
}

int64_t nfsk_write(ntfs_fskit_volume *v, uint64_t ino, int64_t offset, const void *buf, int64_t len, int *out_errno) {
    if (!v || !v->vol || len < 0) { if (out_errno) *out_errno = EINVAL; return -1; }
    if (v->read_only) { if (out_errno) *out_errno = EROFS; return -1; }
    if (is_reserved_mft(to_mref(ino))) { if (out_errno) *out_errno = EPERM; return -1; }
    if (len == 0) return 0;
    ntfs_inode *ni = ntfs_inode_open(v->vol, to_mref(ino));
    if (!ni) { if (out_errno) *out_errno = errno; return -1; }
    ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (!na) { if (out_errno) *out_errno = errno; ntfs_inode_close(ni); return -1; }

    int64_t total = 0;
    while (len > 0) {
        s64 r = ntfs_attr_pwrite(na, offset + total, len, (const char *)buf + total);
        if (r <= 0) { if (total == 0) { if (out_errno) *out_errno = errno ? errno : EIO; total = -1; } break; }
        total += r; len -= r;
    }
    ntfs_attr_close(na);
    if (total > 0) { ni->flags |= FILE_ATTR_ARCHIVE; ntfs_inode_update_times(ni, NTFS_UPDATE_MCTIME); }
    ntfs_inode_close(ni);
    return total;
}

/* ---- Namespace mutation ---- */
uint64_t nfsk_create(ntfs_fskit_volume *v, uint64_t dir_ino, const char *name_utf8, uint32_t type, int *out_errno) {
    if (!v || !v->vol) { if (out_errno) *out_errno = EINVAL; return 0; }
    if (v->read_only) { if (out_errno) *out_errno = EROFS; return 0; }
    if (is_reserved_mft(to_mref(dir_ino))) { if (out_errno) *out_errno = EPERM; return 0; }
    ntfs_inode *dir = ntfs_inode_open(v->vol, to_mref(dir_ino));
    if (!dir) { if (out_errno) *out_errno = errno; return 0; }

    ntfschar *uname = NULL;
    int ulen = ntfs_mbstoucs(name_utf8, &uname);
    if (ulen < 0) { if (out_errno) *out_errno = errno; ntfs_inode_close(dir); return 0; }

    mode_t kind = (type == NFSK_TYPE_DIR) ? S_IFDIR : S_IFREG;
    ntfs_inode *ni = ntfs_create(dir, const_cpu_to_le32(0), uname, ulen, kind);
    free(uname);
    if (!ni) { if (out_errno) *out_errno = errno ? errno : EIO; ntfs_inode_close(dir); return 0; }
    uint64_t new_ino = from_mft(ni->mft_no);
    ntfs_inode_close(ni);
    ntfs_inode_close(dir);
    return new_ino;
}

int nfsk_remove(ntfs_fskit_volume *v, uint64_t dir_ino, const char *name_utf8) {
    if (!v || !v->vol) return -EINVAL;
    if (v->read_only) return -EROFS;
    if (is_reserved_mft(to_mref(dir_ino))) return -EPERM;
    ntfs_inode *dir = ntfs_inode_open(v->vol, to_mref(dir_ino));
    if (!dir) return -errno;

    ntfschar *uname = NULL;
    int ulen = ntfs_mbstoucs(name_utf8, &uname);
    if (ulen < 0) { int e = errno; ntfs_inode_close(dir); return -e; }

    u64 mref = ntfs_inode_lookup_by_name(dir, uname, ulen);
    if (mref == (u64)-1) { int e = errno ? errno : ENOENT; free(uname); ntfs_inode_close(dir); return -e; }
    if (is_reserved_mft(MREF(mref))) { free(uname); ntfs_inode_close(dir); return -EPERM; }  /* don't remove metadata */
    ntfs_inode *ni = ntfs_inode_open(v->vol, mref);
    if (!ni) { int e = errno; free(uname); ntfs_inode_close(dir); return -e; }
    int rc = ntfs_delete(v->vol, NULL, ni, dir, uname, ulen);   /* always closes ni and dir */
    int e = rc ? (errno ? errno : EIO) : 0;
    free(uname);
    return rc ? -e : 0;
}

int nfsk_truncate(ntfs_fskit_volume *v, uint64_t ino, uint64_t size) {
    if (!v || !v->vol) return -EINVAL;
    if (v->read_only) return -EROFS;
    if (is_reserved_mft(to_mref(ino))) return -EPERM;
    ntfs_inode *ni = ntfs_inode_open(v->vol, to_mref(ino));
    if (!ni) return -errno;
    ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (!na) { int e = errno; ntfs_inode_close(ni); return -e; }
    int rc = ntfs_attr_truncate(na, (s64)size);
    int e = rc ? (errno ? errno : EIO) : 0;
    ntfs_attr_close(na);
    if (!rc) { ni->flags |= FILE_ATTR_ARCHIVE; ntfs_inode_update_times(ni, NTFS_UPDATE_MCTIME); }
    ntfs_inode_close(ni);
    return rc ? -e : 0;
}

int nfsk_set_times(ntfs_fskit_volume *v, uint64_t ino,
                   int64_t mtime_sec, int64_t mtime_nsec, int64_t atime_sec, int64_t atime_nsec) {
    if (!v || !v->vol) return -EINVAL;
    if (v->read_only) return -EROFS;
    if (is_reserved_mft(to_mref(ino))) return -EPERM;
    ntfs_inode *ni = ntfs_inode_open(v->vol, to_mref(ino));
    if (!ni) return -errno;
    if (mtime_sec != INT64_MIN) { struct timespec ts = { (time_t)mtime_sec, (long)mtime_nsec }; ni->last_data_change_time = timespec2ntfs(ts); }
    if (atime_sec != INT64_MIN) { struct timespec ts = { (time_t)atime_sec, (long)atime_nsec }; ni->last_access_time = timespec2ntfs(ts); }
    ni->last_mft_change_time = ntfs_current_time();
    ntfs_inode_mark_dirty(ni);
    int rc = ntfs_inode_close(ni);
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
    ntfs_inode *dir = ntfs_inode_open(vol, to_mref(dir_no));
    if (!dir) return -1;
    ntfs_inode *ni = ntfs_inode_open(vol, ref);
    if (!ni) { int e = errno; ntfs_inode_close(dir); errno = e; return -1; }
    int r = ntfs_link(ni, dir, name, name_len);   /* closes neither inode */
    int e = errno;
    ntfs_inode_close(ni);
    ntfs_inode_close(dir);
    if (r) { errno = e; return -1; }
    return 0;
}

/* Remove directory entry `name` from directory #dir_no. */
static int nfsk_unlink_name(ntfs_volume *vol, uint64_t dir_no,
                            const ntfschar *name, int name_len) {
    ntfs_inode *dir = ntfs_inode_open(vol, to_mref(dir_no));
    if (!dir) return -1;
    u64 ref = ntfs_inode_lookup_by_name(dir, name, name_len);
    if (ref == (u64)-1) { int e = errno; ntfs_inode_close(dir); errno = e ? e : ENOENT; return -1; }
    ntfs_inode *ni = ntfs_inode_open(vol, ref);
    if (!ni) { int e = errno; ntfs_inode_close(dir); errno = e; return -1; }
    /* ntfs_delete closes BOTH ni and dir, even on failure. */
    return ntfs_delete(vol, NULL, ni, dir, name, name_len) ? -1 : 0;
}

/* Unique temp-name disambiguator; all bridge calls run under the volume lock. */
static unsigned nfsk_rename_seq = 0;

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
        ntfs_inode *ddir = ntfs_inode_open(vol, to_mref(dst_dir));
        if (!ddir) return -1;
        int found = 0;
        for (int tries = 0; tries < 4096; tries++) {
            char tmpname[64];
            snprintf(tmpname, sizeof(tmpname), "ntfs3g-rn-%016llx-%u",
                     (unsigned long long)MREF(dref), ++nfsk_rename_seq);
            free(utmp); utmp = NULL;
            tmplen = ntfs_mbstoucs(tmpname, &utmp);
            if (tmplen < 0) { ntfs_inode_close(ddir); free(utmp); return -1; }
            errno = 0;
            u64 ex = ntfs_inode_lookup_by_name(ddir, utmp, tmplen);
            if (ex == (u64)-1) {
                if (errno == 0 || errno == ENOENT) { found = 1; break; }   /* name is free */
                int le = errno; ntfs_inode_close(ddir); free(utmp); errno = le; return -1;
            }
        }
        ntfs_inode_close(ddir);
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
    if (!src_name || !dst_name) return -EINVAL;
    if (src_dir == dst_dir && !strcmp(src_name, dst_name)) return 0;

    ntfs_volume *vol = v->vol;
    if (is_reserved_mft(to_mref(src_dir)) || is_reserved_mft(to_mref(dst_dir))) return -EPERM;
    ntfschar *usrc = NULL, *udst = NULL;
    int slen, dlen, rc = 0, e = 0, src_isdir = 0;
    u64 sref = (u64)-1, dref = (u64)-1;

    slen = ntfs_mbstoucs(src_name, &usrc);
    if (slen < 0) { e = errno; rc = -1; goto out; }
    dlen = ntfs_mbstoucs(dst_name, &udst);
    if (dlen < 0) { e = errno; rc = -1; goto out; }

    /* Resolve the source inode. */
    {
        ntfs_inode *sdir = ntfs_inode_open(vol, to_mref(src_dir));
        if (!sdir) { e = errno; rc = -1; goto out; }
        sref = ntfs_inode_lookup_by_name(sdir, usrc, slen);
        e = errno;
        ntfs_inode_close(sdir);
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
        ntfs_inode *ddir = ntfs_inode_open(vol, to_mref(dst_dir));
        if (!ddir) { e = errno; rc = -1; goto out; }
        errno = 0;
        dref = ntfs_inode_lookup_by_name(ddir, udst, dlen);
        int le = errno;
        ntfs_inode_close(ddir);
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
    return rc ? -e : 0;
}

/* Hard link: add `name` in dir_ino as another name for inode `target_ino`. NTFS keeps
 * a link count + multiple FILE_NAME attributes, so this is a thin wrapper over ntfs_link
 * (the bridge is inode-keyed — no path map to update). Directories can't be hard-linked. */
int nfsk_link(ntfs_fskit_volume *v, uint64_t target_ino, uint64_t dir_ino,
              const char *name_utf8, int *out_errno) {
    if (!v || !v->vol || !name_utf8) { if (out_errno) *out_errno = EINVAL; return -1; }
    if (v->read_only) { if (out_errno) *out_errno = EROFS; return -1; }
    if (is_reserved_mft(to_mref(target_ino)) || is_reserved_mft(to_mref(dir_ino))) {
        if (out_errno) *out_errno = EPERM; return -1;
    }
    int isdir = nfsk_isdir(v->vol, to_mref(target_ino), NULL);
    if (isdir < 0) { if (out_errno) *out_errno = errno ? errno : EIO; return -1; }
    /* FSKit expects ENOTSUP when hard links aren't supported for the object's type (a dir). */
    if (isdir)     { if (out_errno) *out_errno = ENOTSUP; return -1; }

    ntfschar *uname = NULL;
    int ulen = ntfs_mbstoucs(name_utf8, &uname);
    if (ulen < 0) { if (out_errno) *out_errno = errno; return -1; }
    int r = nfsk_link_name(v->vol, dir_ino, to_mref(target_ino), uname, ulen);
    int e = errno;
    free(uname);
    if (r) { if (out_errno) *out_errno = e ? e : EIO; return -1; }
    return 0;
}

int nfsk_readlink(ntfs_fskit_volume *v, uint64_t ino, char *buf, size_t cap) {
    if (!v || !v->vol || !buf || cap == 0) return -EINVAL;
    if (is_reserved_mft(to_mref(ino))) return -EINVAL;
    ntfs_inode *ni = ntfs_inode_open(v->vol, to_mref(ino));
    if (!ni) return -errno;
    if (!(ni->flags & FILE_ATTR_REPARSE_POINT) || !ntfs_possible_symlink(ni)) {
        ntfs_inode_close(ni);
        return -EINVAL;   /* not a symlink we can resolve */
    }
    /* "/" mount point: a Windows *absolute* target is rewritten relative to the mount
       root (best effort); relative targets — the common POSIX case — pass through as-is. */
    char *target = ntfs_make_symlink(ni, "/");
    int saved = errno;
    ntfs_inode_close(ni);
    if (!target) return -(saved ? saved : EINVAL);
    size_t tlen = strlen(target);
    if (tlen >= cap) { free(target); return -ENAMETOOLONG; }   /* don't silently truncate the target */
    memcpy(buf, target, tlen + 1);
    free(target);
    return 0;
}
