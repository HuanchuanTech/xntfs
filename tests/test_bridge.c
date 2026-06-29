/*
 * test_bridge.c - Standalone functional test of the NTFS<->FSKit bridge.
 *
 * Drives the SAME ntfs_fskit.c code path that the FSKit extension uses, but
 * backs the block layer with a plain file descriptor instead of an
 * FSBlockDeviceResource. This proves the ntfs-3g adaptation actually mounts,
 * enumerates, reads, writes, and creates on a real NTFS image — independent of
 * the OS-level FSKit extension loading (which is gated by code-signing
 * entitlements).
 *
 * Provides its own nfsk_block_* implementations, so ntfs_device_fskit.m is NOT
 * linked into this test.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include "ntfs_fskit.h"

/* ---- file-backed block layer (replaces ntfs_device_fskit.m) ---- */
typedef struct { int fd; int64_t size; } testres;

int64_t nfsk_block_pread(void *r, void *buf, int64_t off, int64_t count) {
    testres *t = r;
    if (off >= t->size) return 0;
    if (off + count > t->size) count = t->size - off;
    ssize_t n = pread(t->fd, buf, (size_t)count, (off_t)off);
    if (n < 0) return -1;
    return n;
}
int64_t nfsk_block_pwrite(void *r, const void *buf, int64_t off, int64_t count) {
    testres *t = r;
    if (off + count > t->size) count = t->size - off;
    ssize_t n = pwrite(t->fd, buf, (size_t)count, (off_t)off);
    if (n < 0) return -1;
    return n;
}
int      nfsk_block_sync(void *r) { return fsync(((testres*)r)->fd) ? -errno : 0; }
uint64_t nfsk_block_total_bytes(void *r) { return (uint64_t)((testres*)r)->size; }
uint32_t nfsk_block_sector_size(void *r) { (void)r; return 512; }
int      nfsk_block_is_writable(void *r) { (void)r; return 1; }

/* ---- enumeration callback ---- */
static int dir_cb(void *ctx, const char *name, uint64_t ino, uint32_t type, int64_t cookie) {
    int *count = ctx;
    const char *ts = type == NFSK_TYPE_DIR ? "DIR " :
                     type == NFSK_TYPE_FILE ? "FILE" :
                     type == NFSK_TYPE_SYMLINK ? "LNK " : "??? ";
    printf("    [%s] %-28s ino=%llu cookie=%lld\n", ts, name,
           (unsigned long long)ino, (long long)cookie);
    (*count)++;
    return 0;
}

static uint64_t find_child(ntfs_fskit_volume *v, uint64_t dir, const char *name) {
    int e = 0;
    uint64_t ino = nfsk_lookup(v, dir, name, &e);
    return ino;
}

/* ---- assertion-based checks (rename / metadata / parentID) ---- */
#define U(x) ((unsigned long long)(x))
static int g_pass = 0, g_fail = 0;
#define CHECK(cond, ...) do { \
    if (cond) { g_pass++; printf("  [PASS] "); } \
    else      { g_fail++; printf("  [FAIL] "); } \
    printf(__VA_ARGS__); printf("\n"); \
} while (0)

/* Best-effort removal of scratch names left by a prior (possibly crashed) run. */
static void pre_clean(ntfs_fskit_volume *v) {
    uint64_t sub = find_child(v, NFSK_ROOT_INO, "t_sub");
    if (sub) { nfsk_remove(v, sub, "t_x.txt"); nfsk_remove(v, NFSK_ROOT_INO, "t_sub"); }
    uint64_t d = find_child(v, NFSK_ROOT_INO, "t_d");
    if (d) {
        uint64_t s = find_child(v, d, "sub"); if (s) nfsk_remove(v, d, "sub");
        nfsk_remove(v, d, "c.txt"); nfsk_remove(v, d, "loop");
        nfsk_remove(v, NFSK_ROOT_INO, "t_d");
    }
    uint64_t pd = find_child(v, NFSK_ROOT_INO, "t_pdir");
    if (pd) { nfsk_remove(v, pd, "child.txt"); nfsk_remove(v, NFSK_ROOT_INO, "t_pdir"); }
    const char *flat[] = { "t_a.txt","t_b.txt","t_src.txt","t_dst.txt","t_x.txt","t_f.txt","t_d2","t_rootfile.txt" };
    for (int i = 0; i < 8; i++)
        if (find_child(v, NFSK_ROOT_INO, flat[i])) nfsk_remove(v, NFSK_ROOT_INO, flat[i]);
}

static void test_rename_simple(ntfs_fskit_volume *v) {
    printf("-- rename: simple (no existing dest) --\n");
    int e = 0;
    uint64_t a = nfsk_create(v, NFSK_ROOT_INO, "t_a.txt", NFSK_TYPE_FILE, &e);
    CHECK(a != 0, "create t_a.txt (ino=%llu)", U(a));
    int rc = nfsk_rename(v, NFSK_ROOT_INO, "t_a.txt", NFSK_ROOT_INO, "t_b.txt");
    CHECK(rc == 0, "rename t_a.txt -> t_b.txt (rc=%d)", rc);
    CHECK(find_child(v, NFSK_ROOT_INO, "t_a.txt") == 0, "old name gone");
    uint64_t b = find_child(v, NFSK_ROOT_INO, "t_b.txt");
    CHECK(b == a, "new name same inode (%llu == %llu)", U(b), U(a));
    nfsk_remove(v, NFSK_ROOT_INO, "t_b.txt");
}

static void test_rename_overwrite(ntfs_fskit_volume *v) {
    printf("-- rename: overwrite file-over-file (recoverable) --\n");
    int e = 0;
    uint64_t src = nfsk_create(v, NFSK_ROOT_INO, "t_src.txt", NFSK_TYPE_FILE, &e);
    uint64_t dst = nfsk_create(v, NFSK_ROOT_INO, "t_dst.txt", NFSK_TYPE_FILE, &e);
    const char *sc = "SRC-CONTENT";
    if (src) nfsk_write(v, src, 0, sc, (int64_t)strlen(sc), &e);
    if (dst) { const char *dc = "DST-OLD"; nfsk_write(v, dst, 0, dc, (int64_t)strlen(dc), &e); }
    CHECK(src && dst && src != dst, "created t_src=%llu t_dst=%llu", U(src), U(dst));
    int rc = nfsk_rename(v, NFSK_ROOT_INO, "t_src.txt", NFSK_ROOT_INO, "t_dst.txt");
    CHECK(rc == 0, "rename t_src -> t_dst overwrite (rc=%d)", rc);
    CHECK(find_child(v, NFSK_ROOT_INO, "t_src.txt") == 0, "t_src gone");
    uint64_t now = find_child(v, NFSK_ROOT_INO, "t_dst.txt");
    CHECK(now == src, "t_dst now has src inode (%llu == %llu)", U(now), U(src));
    char buf[64]; memset(buf, 0, sizeof buf);
    if (now) nfsk_read(v, now, 0, buf, sizeof(buf) - 1, &e);
    CHECK(strcmp(buf, sc) == 0, "t_dst content is src's (<<<%s>>>)", buf);
    nfsk_remove(v, NFSK_ROOT_INO, "t_dst.txt");
}

static void test_rename_crossdir(ntfs_fskit_volume *v) {
    printf("-- rename: cross-directory + parentID --\n");
    int e = 0;
    uint64_t sub = nfsk_create(v, NFSK_ROOT_INO, "t_sub", NFSK_TYPE_DIR, &e);
    uint64_t x = nfsk_create(v, NFSK_ROOT_INO, "t_x.txt", NFSK_TYPE_FILE, &e);
    CHECK(sub && x, "created t_sub=%llu t_x.txt=%llu", U(sub), U(x));
    int rc = nfsk_rename(v, NFSK_ROOT_INO, "t_x.txt", sub, "t_x.txt");
    CHECK(rc == 0, "rename root/t_x.txt -> t_sub/t_x.txt (rc=%d)", rc);
    CHECK(find_child(v, NFSK_ROOT_INO, "t_x.txt") == 0, "root no longer has t_x.txt");
    uint64_t moved = find_child(v, sub, "t_x.txt");
    CHECK(moved == x, "moved file same inode (%llu == %llu)", U(moved), U(x));
    nfsk_attr_t a; int gr = (moved ? nfsk_getattr(v, moved, &a) : -1);
    CHECK(gr == 0 && a.parent_ino == sub, "moved file parent_ino == t_sub (%llu want %llu)", U(a.parent_ino), U(sub));
    if (moved) nfsk_remove(v, sub, "t_x.txt");
    nfsk_remove(v, NFSK_ROOT_INO, "t_sub");
}

static void test_rename_errors(ntfs_fskit_volume *v) {
    printf("-- rename: type / non-empty / cycle errors --\n");
    int e = 0;
    uint64_t f = nfsk_create(v, NFSK_ROOT_INO, "t_f.txt", NFSK_TYPE_FILE, &e);
    uint64_t d = nfsk_create(v, NFSK_ROOT_INO, "t_d", NFSK_TYPE_DIR, &e);
    uint64_t child = (d ? nfsk_create(v, d, "c.txt", NFSK_TYPE_FILE, &e) : 0);
    CHECK(f && d && child, "setup t_f.txt + non-empty t_d/");
    int rc = nfsk_rename(v, NFSK_ROOT_INO, "t_f.txt", NFSK_ROOT_INO, "t_d");
    CHECK(rc == -EISDIR, "file over dir -> EISDIR (rc=%d want %d)", rc, -EISDIR);
    rc = nfsk_rename(v, NFSK_ROOT_INO, "t_d", NFSK_ROOT_INO, "t_f.txt");
    CHECK(rc == -ENOTDIR, "dir over file -> ENOTDIR (rc=%d want %d)", rc, -ENOTDIR);
    uint64_t d2 = nfsk_create(v, NFSK_ROOT_INO, "t_d2", NFSK_TYPE_DIR, &e);
    rc = nfsk_rename(v, NFSK_ROOT_INO, "t_d2", NFSK_ROOT_INO, "t_d");
    CHECK(rc == -ENOTEMPTY, "dir over non-empty dir -> ENOTEMPTY (rc=%d want %d)", rc, -ENOTEMPTY);
    uint64_t sub = (d ? nfsk_create(v, d, "sub", NFSK_TYPE_DIR, &e) : 0);
    rc = nfsk_rename(v, NFSK_ROOT_INO, "t_d", d, "loop");
    CHECK(rc == -EINVAL, "move dir into itself -> EINVAL (rc=%d want %d)", rc, -EINVAL);
    rc = (sub ? nfsk_rename(v, NFSK_ROOT_INO, "t_d", sub, "loop") : -EINVAL);
    CHECK(rc == -EINVAL, "move dir into own subtree -> EINVAL (rc=%d want %d)", rc, -EINVAL);
    if (sub) nfsk_remove(v, d, "sub");
    nfsk_remove(v, d, "c.txt");
    nfsk_remove(v, NFSK_ROOT_INO, "t_d");
    nfsk_remove(v, NFSK_ROOT_INO, "t_d2");
    nfsk_remove(v, NFSK_ROOT_INO, "t_f.txt");
}

static void test_metadata_protection(ntfs_fskit_volume *v) {
    printf("-- metadata: reserved records hidden/protected --\n");
    int e = 0;
    const char *meta[] = { "$MFT", "$MFTMirr", "$LogFile", "$Volume", "$Bitmap", "$Boot" };
    for (int i = 0; i < 6; i++) {
        e = 0;
        uint64_t m = nfsk_lookup(v, NFSK_ROOT_INO, meta[i], &e);
        CHECK(m == 0, "lookup %s blocked (ino=%llu err=%d)", meta[i], U(m), e);
    }
    nfsk_attr_t a;
    CHECK(nfsk_getattr(v, 3, &a) < 0, "getattr(reserved ino 3 / $Volume) fails");
    CHECK(nfsk_getattr(v, 0, &a) < 0, "getattr(reserved ino 0 / $MFT) fails");
    CHECK(nfsk_remove(v, NFSK_ROOT_INO, "$Volume") != 0, "remove $Volume blocked");
}

static void test_parent_id(ntfs_fskit_volume *v) {
    printf("-- parentID: parent_ino reflects directory --\n");
    int e = 0;
    uint64_t d = nfsk_create(v, NFSK_ROOT_INO, "t_pdir", NFSK_TYPE_DIR, &e);
    uint64_t f = (d ? nfsk_create(v, d, "child.txt", NFSK_TYPE_FILE, &e) : 0);
    nfsk_attr_t a;
    int rc = (f ? nfsk_getattr(v, f, &a) : -1);
    CHECK(rc == 0 && a.parent_ino == d, "child parent_ino == t_pdir (%llu want %llu)", U(a.parent_ino), U(d));
    uint64_t rf = nfsk_create(v, NFSK_ROOT_INO, "t_rootfile.txt", NFSK_TYPE_FILE, &e);
    rc = (rf ? nfsk_getattr(v, rf, &a) : -1);
    CHECK(rc == 0 && a.parent_ino == NFSK_ROOT_INO, "root file parent_ino == root (%llu want %llu)", U(a.parent_ino), U(NFSK_ROOT_INO));
    if (f) nfsk_remove(v, d, "child.txt");
    nfsk_remove(v, NFSK_ROOT_INO, "t_pdir");
    nfsk_remove(v, NFSK_ROOT_INO, "t_rootfile.txt");
}

static void test_hardlink(ntfs_fskit_volume *v) {
    printf("-- hard link: nfsk_link / nlink / remove-one-name --\n");
    int e = 0;
    uint64_t f = nfsk_create(v, NFSK_ROOT_INO, "t_hl.txt", NFSK_TYPE_FILE, &e);
    CHECK(f != 0, "create t_hl.txt (ino=%llu)", U(f));
    const char *msg = "hardlink-via-bridge";
    nfsk_write(v, f, 0, msg, (int64_t)strlen(msg), &e);
    int lrc = nfsk_link(v, f, NFSK_ROOT_INO, "t_hl-b.txt", &e);
    CHECK(lrc == 0, "nfsk_link t_hl.txt -> t_hl-b.txt (rc=%d err=%d)", lrc, e);
    uint64_t b = find_child(v, NFSK_ROOT_INO, "t_hl-b.txt");
    CHECK(b == f, "2nd name is the same inode (%llu == %llu)", U(b), U(f));
    nfsk_attr_t a;
    CHECK(nfsk_getattr(v, f, &a) == 0 && a.nlink == 2, "nlink == 2 after link (got %u)", a.nlink);
    /* Remove the first name; the inode lives on via the 2nd. Read via that name's ino. */
    nfsk_remove(v, NFSK_ROOT_INO, "t_hl.txt");
    char buf[64]; int re = 0;
    int64_t n = nfsk_read(v, b, 0, buf, sizeof(buf) - 1, &re);
    if (n > 0) buf[n] = 0; else buf[0] = 0;
    CHECK(n == (int64_t)strlen(msg) && strcmp(buf, msg) == 0,
          "survivor reads after unlinking 1st name (<<<%s>>>)", buf);
    CHECK(nfsk_getattr(v, b, &a) == 0 && a.nlink == 1, "nlink == 1 after one unlink (got %u)", a.nlink);
    /* POSIX: no hard links to directories. */
    uint64_t d = nfsk_create(v, NFSK_ROOT_INO, "t_hl_dir", NFSK_TYPE_DIR, &e);
    e = 0;
    int drc = nfsk_link(v, d, NFSK_ROOT_INO, "t_hl_dir2", &e);
    CHECK(drc != 0 && e == ENOTSUP, "hard link to a directory refused ENOTSUP (rc=%d err=%d)", drc, e);
    nfsk_remove(v, NFSK_ROOT_INO, "t_hl-b.txt");
    nfsk_remove(v, NFSK_ROOT_INO, "t_hl_dir");
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <writable-ntfs-image>\n"
                        "  The test MUTATES the image — pass a throwaway copy, not the repo's test.ntfs.\n",
                argv[0]);
        return 1;
    }
    const char *path = argv[1];

    int fd = open(path, O_RDWR);
    if (fd < 0) { perror("open"); return 1; }
    struct stat sb; fstat(fd, &sb);
    testres tr = { fd, sb.st_size };

    printf("== MOUNT %s (%lld bytes) ==\n", path, (long long)sb.st_size);
    int err = 0;
    ntfs_fskit_volume *v = nfsk_mount(&tr, false, &err);
    if (!v) { fprintf(stderr, "nfsk_mount failed: errno=%d (%s)\n", err, strerror(err)); return 2; }

    nfsk_statfs_t st;
    nfsk_statfs(v, &st);
    printf("  label='%s' clusterSize=%u totalClusters=%llu freeClusters=%llu ro=%d\n",
           st.volume_name, st.cluster_size,
           (unsigned long long)st.total_clusters,
           (unsigned long long)st.free_clusters, st.read_only);

    printf("== ENUMERATE ROOT ==\n");
    int count = 0;
    int rc = nfsk_readdir(v, NFSK_ROOT_INO, 0, &count, dir_cb);
    printf("  rc=%d entries=%d\n", rc, count);

    printf("== READ hello.txt ==\n");
    uint64_t hino = find_child(v, NFSK_ROOT_INO, "hello.txt");
    if (hino) {
        nfsk_attr_t a; nfsk_getattr(v, hino, &a);
        printf("  ino=%llu size=%llu type=%u\n", (unsigned long long)hino,
               (unsigned long long)a.size, a.type);
        char buf[512]; memset(buf, 0, sizeof buf);
        int64_t n = nfsk_read(v, hino, 0, buf, sizeof(buf) - 1, &err);
        printf("  read %lld bytes: <<<%s>>>\n", (long long)n, buf);
    } else printf("  hello.txt NOT FOUND\n");

    printf("== WRITE: append to hello.txt ==\n");
    if (hino) {
        nfsk_attr_t a; nfsk_getattr(v, hino, &a);
        const char *extra = "[appended by FSKit bridge test]\n";
        int64_t n = nfsk_write(v, hino, (int64_t)a.size, extra, (int64_t)strlen(extra), &err);
        printf("  wrote %lld bytes at offset %llu (err=%d)\n",
               (long long)n, (unsigned long long)a.size, err);
    }

    printf("== CREATE new file 'created_by_bridge.txt' ==\n");
    if (find_child(v, NFSK_ROOT_INO, "created_by_bridge.txt"))   /* idempotent across runs */
        nfsk_remove(v, NFSK_ROOT_INO, "created_by_bridge.txt");
    uint64_t nino = nfsk_create(v, NFSK_ROOT_INO, "created_by_bridge.txt", NFSK_TYPE_FILE, &err);
    CHECK(nino != 0, "create created_by_bridge.txt (ino=%llu err=%d)", U(nino), err);
    if (nino) {
        const char *msg = "This file was created through the NTFS-3G FSKit bridge.\n";
        int64_t n = nfsk_write(v, nino, 0, msg, (int64_t)strlen(msg), &err);
        printf("  wrote %lld bytes\n", (long long)n);
    }

    printf("== CREATE directory 'newdir' + file inside ==\n");
    {
        uint64_t old = find_child(v, NFSK_ROOT_INO, "newdir");   /* idempotent across runs */
        if (old) {
            if (find_child(v, old, "inside.txt")) nfsk_remove(v, old, "inside.txt");
            nfsk_remove(v, NFSK_ROOT_INO, "newdir");
        }
    }
    uint64_t dino = nfsk_create(v, NFSK_ROOT_INO, "newdir", NFSK_TYPE_DIR, &err);
    CHECK(dino != 0, "mkdir newdir (ino=%llu err=%d)", U(dino), err);
    if (dino) {
        uint64_t f2 = nfsk_create(v, dino, "inside.txt", NFSK_TYPE_FILE, &err);
        CHECK(f2 != 0, "create newdir/inside.txt (ino=%llu err=%d)", U(f2), err);
        const char *m = "nested file\n";
        if (f2) nfsk_write(v, f2, 0, m, (int64_t)strlen(m), &err);
    }

    printf("\n== EXTENDED CHECKS (rename / metadata / parentID) ==\n");
    pre_clean(v);
    test_rename_simple(v);
    test_rename_overwrite(v);
    test_rename_crossdir(v);
    test_rename_errors(v);
    test_metadata_protection(v);
    test_parent_id(v);
    test_hardlink(v);

    nfsk_sync(v);
    printf("== UNMOUNT ==\n");
    nfsk_umount(v);

    /* Remount and verify persistence. */
    printf("\n== REMOUNT to verify persistence ==\n");
    lseek(fd, 0, SEEK_SET);
    v = nfsk_mount(&tr, false, &err);
    if (!v) { fprintf(stderr, "remount failed errno=%d\n", err); return 3; }
    count = 0;
    nfsk_readdir(v, NFSK_ROOT_INO, 0, &count, dir_cb);
    printf("  root now has %d entries\n", count);

    uint64_t cino = find_child(v, NFSK_ROOT_INO, "created_by_bridge.txt");
    if (cino) {
        char buf[256]; memset(buf, 0, sizeof buf);
        int64_t n = nfsk_read(v, cino, 0, buf, sizeof(buf) - 1, &err);
        printf("  created_by_bridge.txt (%lld bytes): <<<%s>>>\n", (long long)n, buf);
    } else printf("  created_by_bridge.txt MISSING after remount!\n");

    uint64_t hino2 = find_child(v, NFSK_ROOT_INO, "hello.txt");
    if (hino2) {
        char buf[1024]; memset(buf, 0, sizeof buf);
        int64_t n = nfsk_read(v, hino2, 0, buf, sizeof(buf) - 1, &err);
        printf("  hello.txt after append (%lld bytes): <<<%s>>>\n", (long long)n, buf);
    }

    nfsk_umount(v);
    close(fd);
    printf("\n== TEST COMPLETE ==\n");
    printf("== EXTENDED CHECKS: %d passed, %d failed ==\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
