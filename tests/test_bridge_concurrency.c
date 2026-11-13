#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "ntfs_fskit.h"

typedef struct { int fd, index, fail_read_once; int64_t size; uint64_t symlink; ntfs_fskit_volume *volume; } device;
int64_t nfsk_block_pread(void *o, void *p, int64_t off, int64_t n) {
    device *d = o;
    if (d->fail_read_once) { d->fail_read_once = 0; errno = EIO; return -1; }
    return pread(d->fd, p, n, off);
}
int64_t nfsk_block_pwrite(void *o, const void *p, int64_t off, int64_t n) { return pwrite(((device *)o)->fd, p, n, off); }
int nfsk_block_sync(void *o) { return fsync(((device *)o)->fd) ? -errno : 0; }
uint64_t nfsk_block_total_bytes(void *o) { return ((device *)o)->size; }
uint32_t nfsk_block_sector_size(void *o) { (void)o; return 512; }
int nfsk_block_is_writable(void *o) { (void)o; return 1; }

static pthread_mutex_t gate = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static int arrived;
static char link_target[901];
static const char xattr_name[] = "user.\xc3\xa9";
static int check_xattr(ntfs_fskit_volume *v, uint64_t ino, const void *expected, size_t size) {
    void *value = NULL;
    char *names = NULL;
    int64_t bytes = nfsk_getxattr_alloc(v, ino, xattr_name, &value);
    int64_t length = nfsk_listxattr_alloc(v, ino, &names);
    int ok = bytes == (int64_t)size && value && !memcmp(value, expected, size) &&
             length == sizeof(xattr_name) && names && !memcmp(names, xattr_name, sizeof(xattr_name));
    free(value); free(names);
    return ok;
}
typedef struct { uint64_t ino; int found, invalid; } expected_entry;
static int check_entry(void *opaque, const char *name, const nfsk_attr_t *a, int64_t cookie) {
    (void)cookie;
    expected_entry *expected = opaque;
    if (!strncmp(name, ".xntfs-open-", 12)) expected->invalid++;
    if (!strcmp(name, "ConcurrentTarget")) {
        expected->found++;
        if (a->ino != expected->ino || a->parent_ino != NFSK_ROOT_INO ||
            a->type != NFSK_TYPE_FILE || a->size != 2 * sizeof(int) || a->nlink != 1) expected->invalid++;
    }
    return 0;
}
static void *worker(void *opaque) {
    device *d = opaque;
    pthread_mutex_lock(&gate);
    arrived++;
    pthread_cond_broadcast(&changed);
    while (arrived < 2) pthread_cond_wait(&changed, &gate);
    pthread_mutex_unlock(&gate);
    for (int i = 0; i < 50; i++) {
        char link_bytes[sizeof link_target]; memset(link_bytes, '!', sizeof link_bytes);
        d->fail_read_once = 1;
        if (nfsk_readlink(d->volume, d->symlink, link_bytes, sizeof link_bytes) != -EIO ||
            d->fail_read_once || link_bytes[0] != '!') return (void *)10;
        if (nfsk_readlink(d->volume, d->symlink, link_bytes, sizeof link_bytes) ||
            strcmp(link_bytes, link_target)) return (void *)11;
        int error = 0, expected[2] = {d->index, i}, actual[2] = {0};
        uint64_t previous = nfsk_lookup(d->volume, NFSK_ROOT_INO, "ConcurrentTarget", &error);
        if (!previous || nfsk_open_item(d->volume, previous)) return (void *)6;
        uint64_t ino = nfsk_create(d->volume, NFSK_ROOT_INO, "ConcurrentSource", NFSK_TYPE_FILE, &error);
        if (!ino || nfsk_write(d->volume, ino, 0, expected, sizeof expected, &error) != sizeof expected) return (void *)1;
        if (nfsk_setxattr(d->volume, ino, xattr_name, expected, sizeof expected, NFSK_XATTR_CREATE)) return (void *)4;
        if (nfsk_rename(d->volume, NFSK_ROOT_INO, "ConcurrentSource", NFSK_ROOT_INO, "ConcurrentTarget")) return (void *)2;
        uint64_t target = nfsk_lookup(d->volume, NFSK_ROOT_INO, "ConcurrentTarget", &error);
        if (target != ino || nfsk_read(d->volume, target, 0, actual, sizeof actual, &error) != sizeof actual ||
            memcmp(actual, expected, sizeof actual) || !check_xattr(d->volume, ino, expected, sizeof expected)) return (void *)3;
        expected_entry entry = {.ino = ino};
        if (nfsk_readdir_attributes(d->volume, NFSK_ROOT_INO, 0, &entry, check_entry) || entry.found != 1 || entry.invalid) return (void *)5;
        nfsk_attr_t old;
        if (nfsk_getattr(d->volume, previous, &old) || old.nlink != 0) return (void *)7;
        if (i) {
            int prior[2] = {d->index, i - 1};
            if (nfsk_read(d->volume, previous, 0, actual, sizeof actual, &error) != sizeof actual ||
                memcmp(actual, prior, sizeof actual)) return (void *)8;
        }
        if (nfsk_close_item(d->volume, previous) || nfsk_getattr(d->volume, previous, &old) != -ENOENT) return (void *)9;
    }
    return NULL;
}

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    device devices[2] = {0};
    pthread_t threads[2];
    memset(link_target, 'l', sizeof link_target - 1);
    for (int i = 0; i < 2; i++) {
        struct stat st;
        int error = 0;
        devices[i].index = i;
        devices[i].fd = open(argv[i + 1], O_RDWR);
        if (devices[i].fd < 0 || fstat(devices[i].fd, &st) || !S_ISREG(st.st_mode)) return 3;
        devices[i].size = st.st_size;
        devices[i].volume = nfsk_mount(&devices[i], false, &error);
        if (!devices[i].volume || !nfsk_create(devices[i].volume, NFSK_ROOT_INO, "ConcurrentTarget", NFSK_TYPE_FILE, &error)) return 4;
        devices[i].symlink = nfsk_symlink(devices[i].volume, NFSK_ROOT_INO, "ConcurrentSymlink", link_target, &error);
        if (!devices[i].symlink) return 4;
    }
    for (int i = 0; i < 2; i++) if (pthread_create(&threads[i], NULL, worker, &devices[i])) return 5;
    for (int i = 0; i < 2; i++) {
        void *result = NULL;
        if (pthread_join(threads[i], &result) || result) return 6;
        if (nfsk_sync(devices[i].volume) || nfsk_umount(devices[i].volume)) return 7;
        int error = 0, actual[2] = {0}, expected[2] = {i, 49};
        devices[i].volume = nfsk_mount(&devices[i], true, &error);
        if (!devices[i].volume) return 8;
        uint64_t ino = nfsk_lookup(devices[i].volume, NFSK_ROOT_INO, "ConcurrentTarget", &error);
        if (!ino || nfsk_read(devices[i].volume, ino, 0, actual, sizeof actual, &error) != sizeof actual ||
            memcmp(actual, expected, sizeof actual) || !check_xattr(devices[i].volume, ino, expected, sizeof expected)) return 9;
        if (nfsk_umount(devices[i].volume)) return 10;
        close(devices[i].fd);
    }
    puts("PASS: 100 concurrent cross-volume overwrite renames preserve retained payloads, hide anchors, reclaim on close and persist distinct xattrs/data across remount");
    puts("PASS: 100 concurrent cross-volume read errors preserve output, allow immediate retry and do not poison sync");
    return 0;
}
