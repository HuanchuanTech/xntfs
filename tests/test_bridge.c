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

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "test.ntfs";

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
    uint64_t nino = nfsk_create(v, NFSK_ROOT_INO, "created_by_bridge.txt", NFSK_TYPE_FILE, &err);
    if (nino) {
        const char *msg = "This file was created through the NTFS-3G FSKit bridge.\n";
        int64_t n = nfsk_write(v, nino, 0, msg, (int64_t)strlen(msg), &err);
        printf("  created ino=%llu, wrote %lld bytes\n", (unsigned long long)nino, (long long)n);
    } else printf("  create failed err=%d (%s)\n", err, strerror(err));

    printf("== CREATE directory 'newdir' + file inside ==\n");
    uint64_t dino = nfsk_create(v, NFSK_ROOT_INO, "newdir", NFSK_TYPE_DIR, &err);
    if (dino) {
        uint64_t f2 = nfsk_create(v, dino, "inside.txt", NFSK_TYPE_FILE, &err);
        const char *m = "nested file\n";
        if (f2) nfsk_write(v, f2, 0, m, (int64_t)strlen(m), &err);
        printf("  newdir ino=%llu, inside.txt ino=%llu\n",
               (unsigned long long)dino, (unsigned long long)f2);
    } else printf("  mkdir failed err=%d\n", err);

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
    return 0;
}
