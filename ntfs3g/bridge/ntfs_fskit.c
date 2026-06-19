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
    if (!NDevOpen(dev)) { errno = EBADF; return -1; }
    if (NDevDirty(dev) && !NDevReadOnly(dev)) { nfsk_block_sync(c->resource); NDevClearDirty(dev); }
    NDevClearOpen(dev);
    return 0;
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

static uint32_t map_dt(unsigned dt_type) {
    switch (dt_type) {
        case NTFS_DT_DIR:     return NFSK_TYPE_DIR;
        case NTFS_DT_LNK:     return NFSK_TYPE_SYMLINK;
        case NTFS_DT_REPARSE: return NFSK_TYPE_SYMLINK;
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

int nfsk_getattr(ntfs_fskit_volume *v, uint64_t ino, nfsk_attr_t *out) {
    if (!v || !v->vol || !out) return -EINVAL;
    ntfs_inode *ni = ntfs_inode_open(v->vol, to_mref(ino));
    if (!ni) return -errno;

    memset(out, 0, sizeof(*out));
    out->ino = from_mft(ni->mft_no);
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
        out->type = NFSK_TYPE_SYMLINK;
        out->size = (uint64_t)ni->data_size;
        out->alloc_size = (uint64_t)ni->allocated_size;
        out->mode = 0777;
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
    return from_mft(MREF(mref));
}

/* ---- Directory enumeration (robust ordinal cookies) ---- */
struct fill_ctx { nfsk_dir_cb cb; void *ctx; int64_t skip; int64_t count; int stopped; };

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

    struct fill_ctx fc = { cb, ctx, start_cookie < 0 ? 0 : start_cookie, 0, 0 };
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
    ntfs_inode *dir = ntfs_inode_open(v->vol, to_mref(dir_ino));
    if (!dir) return -errno;

    ntfschar *uname = NULL;
    int ulen = ntfs_mbstoucs(name_utf8, &uname);
    if (ulen < 0) { int e = errno; ntfs_inode_close(dir); return -e; }

    u64 mref = ntfs_inode_lookup_by_name(dir, uname, ulen);
    if (mref == (u64)-1) { int e = errno ? errno : ENOENT; free(uname); ntfs_inode_close(dir); return -e; }
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
    ntfs_inode *ni = ntfs_inode_open(v->vol, to_mref(ino));
    if (!ni) return -errno;
    if (mtime_sec != INT64_MIN) { struct timespec ts = { (time_t)mtime_sec, (long)mtime_nsec }; ni->last_data_change_time = timespec2ntfs(ts); }
    if (atime_sec != INT64_MIN) { struct timespec ts = { (time_t)atime_sec, (long)atime_nsec }; ni->last_access_time = timespec2ntfs(ts); }
    ni->last_mft_change_time = ntfs_current_time();
    ntfs_inode_mark_dirty(ni);
    int rc = ntfs_inode_close(ni);
    return rc ? -errno : 0;
}

int nfsk_rename(ntfs_fskit_volume *v, uint64_t src_dir, const char *src_name,
                uint64_t dst_dir, const char *dst_name) {
    if (!v || !v->vol) return -EINVAL;
    if (v->read_only) return -EROFS;
    if (!src_name || !dst_name) return -EINVAL;
    if (src_dir == dst_dir && !strcmp(src_name, dst_name)) return 0;

    ntfs_inode *sdir = ntfs_inode_open(v->vol, to_mref(src_dir));
    if (!sdir) return -errno;
    ntfs_inode *ddir = (dst_dir == src_dir) ? sdir : ntfs_inode_open(v->vol, to_mref(dst_dir));
    if (!ddir) { int e = errno; ntfs_inode_close(sdir); return -e; }

    ntfschar *usrc = NULL, *udst = NULL;
    int slen = ntfs_mbstoucs(src_name, &usrc);
    int dlen = (slen < 0) ? -1 : ntfs_mbstoucs(dst_name, &udst);
    if (slen < 0 || dlen < 0) {
        int e = errno; free(usrc); free(udst);
        if (ddir != sdir) ntfs_inode_close(ddir);
        ntfs_inode_close(sdir);
        return -e;
    }

    int rc = 0, e = 0;
    int same_dir = (dst_dir == src_dir);
    u64 dref = ntfs_inode_lookup_by_name(ddir, udst, dlen);
    if (dref != (u64)-1) {
        ntfs_inode *over = ntfs_inode_open(v->vol, dref);
        if (over) {
            rc = ntfs_delete(v->vol, NULL, over, ddir, udst, dlen);
            if (rc) e = errno ? errno : EIO;
            if (same_dir) sdir = NULL;
            ddir = NULL;
            if (!rc) {
                sdir = ntfs_inode_open(v->vol, to_mref(src_dir));
                if (!sdir) { rc = -1; e = errno ? errno : EIO; }
                else {
                    ddir = same_dir ? sdir : ntfs_inode_open(v->vol, to_mref(dst_dir));
                    if (!ddir) { rc = -1; e = errno ? errno : EIO; }
                }
            }
        } else {
            rc = -1;
            e = errno ? errno : EIO;
        }
    }
    if (!rc) {
        u64 sref = ntfs_inode_lookup_by_name(sdir, usrc, slen);
        if (sref == (u64)-1) { rc = -1; e = errno ? errno : ENOENT; }
        else {
            ntfs_inode *ni = ntfs_inode_open(v->vol, sref);
            if (!ni) { rc = -1; e = errno; }
            else if (ntfs_link(ni, ddir, udst, dlen)) { rc = -1; e = errno ? errno : EIO; ntfs_inode_close(ni); }
            else {
                ntfs_inode_close(ni);
                ntfs_inode *ni2 = ntfs_inode_open(v->vol, sref);
                if (!ni2) { rc = -1; e = errno ? errno : EIO; }
                else {
                    int delete_closes_ddir = (ddir == sdir);
                    if (ntfs_delete(v->vol, NULL, ni2, sdir, usrc, slen)) { rc = -1; e = errno ? errno : EIO; }
                    if (delete_closes_ddir) ddir = NULL;
                    sdir = NULL;
                }
            }
        }
    }

    free(usrc); free(udst);
    if (ddir && ddir != sdir) ntfs_inode_close(ddir);
    if (sdir) ntfs_inode_close(sdir);
    return rc ? -e : 0;
}

int nfsk_readlink(ntfs_fskit_volume *v, uint64_t ino, char *buf, size_t cap) {
    (void)v; (void)ino; (void)buf; (void)cap;
    return -EINVAL;   /* symlink/reparse resolution not yet implemented */
}
