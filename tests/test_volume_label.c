/* SPDX-License-Identifier: GPL-2.0-or-later */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <ntfs-3g/volume.h>
#include <ntfs-3g/inode.h>
#include <ntfs-3g/attrib.h>
#include <ntfs-3g/unistr.h>
#include "ntfs_fskit.h"

typedef struct { int fd; int64_t size; } test_device;
static int checks, failures;
#define CHECK(ok, message) do { checks++; if (!(ok)) { failures++; \
    fprintf(stderr, "FAIL: %s\n", message); } else printf("PASS: %s\n", message); } while (0)

int64_t nfsk_block_pread(void *p, void *buf, int64_t off, int64_t count) {
    return pread(((test_device *)p)->fd, buf, count, off);
}
int64_t nfsk_block_pwrite(void *p, const void *buf, int64_t off, int64_t count) {
    return pwrite(((test_device *)p)->fd, buf, count, off);
}
int nfsk_block_sync(void *p) { return fsync(((test_device *)p)->fd) ? -errno : 0; }
uint64_t nfsk_block_total_bytes(void *p) { return ((test_device *)p)->size; }
uint32_t nfsk_block_sector_size(void *p) { (void)p; return 512; }
int nfsk_block_is_writable(void *p) { (void)p; return 1; }

static int check_label(test_device *device, const char *path, const char *label) {
    int error = 0;
    ntfs_fskit_volume *v = nfsk_mount(device, false, &error);
    if (!v) return 2;
    CHECK(nfsk_rename_volume(v, label) == 0, "rename label through the bridge");
    nfsk_statfs_t stats;
    CHECK(nfsk_statfs(v, &stats) == 0 && !strcmp(stats.volume_name, label),
          "bridge statistics return the requested label");
    nfsk_umount(v);

    /* Inspect the persisted attribute independently of the bridge's UTF-8 cache. */
    ntfs_volume *vol = ntfs_mount(path, NTFS_MNT_RDONLY);
    if (!vol) return 2;
    ntfs_inode *ni = ntfs_inode_open(vol, FILE_Volume);
    if (!ni) { ntfs_umount(vol, FALSE); return 2; }
    ntfs_attr *attr = ntfs_attr_open(ni, AT_VOLUME_NAME, AT_UNNAMED, 0);
    ntfschar *unicode = NULL;
    int length = ntfs_mbstoucs(label, &unicode);
    if (!attr || length < 0) {
        if (attr) ntfs_attr_close(attr);
        free(unicode); ntfs_inode_close(ni); ntfs_umount(vol, FALSE); return 2;
    }
    unsigned char bytes[256];
    s64 expected = length * (s64)sizeof(ntfschar);
    CHECK(attr->data_size == expected, "on-disk label excludes the UTF-16 terminator");
    CHECK(ntfs_attr_pread(attr, 0, expected, bytes) == expected &&
          !memcmp(bytes, unicode, (size_t)expected), "on-disk label matches every requested UTF-16 code unit");
    ntfs_attr_close(attr); free(unicode);
    if (ntfs_inode_close(ni) || ntfs_umount(vol, FALSE)) return 2;
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "Usage: %s <disposable-NTFS-image>\n", argv[0]); return 2; }
    test_device device = { .fd = open(argv[1], O_RDWR) };
    struct stat st;
    if (device.fd < 0 || fstat(device.fd, &st) || !S_ISREG(st.st_mode)) return 2;
    device.size = st.st_size;
    if (check_label(&device, argv[1], "Renamed NTFS") ||
        check_label(&device, argv[1], "\xe6\xb5\x8b\xe8\xaf\x95 \xf0\x9f\x92\xbe")) return 2;
    char longest[382];
    for (int i = 0; i < 127; i++) memcpy(longest + i * 3, "\xe6\xb5\x8b", 3);
    longest[381] = 0;
    if (check_label(&device, argv[1], longest)) return 2;
    close(device.fd);
    printf("%d label checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
