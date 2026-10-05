#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <ntfs-3g/volume.h>
#include <ntfs-3g/inode.h>
#include <ntfs-3g/attrib.h>
#include <ntfs-3g/dir.h>
#include <ntfs-3g/unistr.h>
#include <ntfs-3g/logging.h>
#include "ntfs_fskit.h"

static int checks, failures;
#define CHECK(ok, message) do { checks++; if (!(ok)) { failures++; \
    fprintf(stderr, "FAIL: %s\n", message); } else printf("PASS: %s\n", message); } while (0)

static void require(int ok, const char *message) {
    if (!ok) { fprintf(stderr, "Fixture failure: %s (errno=%d)\n", message, errno); exit(2); }
}

static ntfs_inode *create(ntfs_inode *root, const char *name) {
    ntfschar *wide = NULL;
    int length = ntfs_mbstoucs(name, &wide);
    require(length > 0, "convert fixture name");
    ntfs_inode *item = ntfs_create(root, const_cpu_to_le32(0), wide, length, S_IFREG);
    free(wide);
    require(item != NULL, "create fixture item");
    return item;
}

/* Reproduce a bitmap-free, zero-filled record without changing any live file.
 * Allocate and delete placeholders first so the slots are within initialized MFT
 * data. A normal mkntfs image has formatted free slots and misses this regression. */
static uint64_t prepare(const char *path, uint64_t slots[3]) {
    ntfs_volume *v = ntfs_mount(path, NTFS_MNT_NONE);
    require(v && !NVolReadOnly(v), "open writable fixture copy");
    require(ntfs_volume_get_free_space(v) == 0, "initialize free space");
    ntfs_inode *root = ntfs_inode_open(v, FILE_root);
    require(root != NULL, "open root");
    ntfs_inode *existing = create(root, "Issue7Existing.txt");
    uint64_t existing_ino = existing->mft_no;
    require(ntfs_inode_close(existing) == 0, "close existing file");
    const char *names[] = { "Issue7SlotA", "Issue7SlotB", "Issue7SlotC" };
    for (int i = 0; i < 3; i++) {
        ntfs_inode *item = create(root, names[i]);
        slots[i] = item->mft_no;
        require(slots[i] >= 64 && (i == 0 || slots[i] > slots[i - 1]), "ordered user records");
        require(ntfs_inode_close(item) == 0, "close placeholder");
    }
    require(ntfs_inode_close(root) == 0, "close root");
    for (int i = 0; i < 3; i++) {
        root = ntfs_inode_open(v, FILE_root);
        ntfs_inode *item = ntfs_inode_open(v, slots[i]);
        require(root && item, "open placeholder for deletion");
        ntfschar *wide = NULL;
        int length = ntfs_mbstoucs(names[i], &wide);
        require(length > 0, "convert deleted name");
        /* ntfs_delete consumes both inodes. */
        require(ntfs_delete(v, NULL, item, root, wide, length) == 0, "delete placeholder");
        free(wide);
    }
    void *zero = calloc(1, v->mft_record_size);
    require(zero != NULL, "allocate zero record");
    for (int i = 0; i < 3; i++) {
        unsigned char bitmap;
        require(ntfs_attr_pread(v->mftbmp_na, slots[i] / 8, 1, &bitmap) == 1 &&
                !(bitmap & (1u << (slots[i] % 8))), "slot must be bitmap-free before zeroing");
        s64 offset = (s64)slots[i] * v->mft_record_size;
        require(offset + v->mft_record_size <= v->mft_na->initialized_size, "slot is initialized MFT data");
        require(ntfs_attr_pwrite(v->mft_na, offset, v->mft_record_size, zero) == v->mft_record_size,
                "zero only a free MFT record");
    }
    free(zero);
    printf("Fixture: sector=%u cluster=%u record=%u zeroed free records=%llu,%llu,%llu\n",
           v->sector_size, v->cluster_size, v->mft_record_size,
           (unsigned long long)slots[0], (unsigned long long)slots[1], (unsigned long long)slots[2]);
    require(ntfs_umount(v, FALSE) == 0, "unmount prepared fixture");
    return existing_ino;
}

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "Usage: %s <disposable-NTFS-image>\n", argv[0]); return 2; }
    struct stat st;
    require(lstat(argv[1], &st) == 0 && S_ISREG(st.st_mode), "regular disposable image required");
    ntfs_log_set_handler(ntfs_log_handler_outerr);
    require(ntfs_set_char_encoding("UTF-8") == 0, "set encoding");
    uint64_t slots[3];
    uint64_t existing = prepare(argv[1], slots);

    int error = 0;
    void *backend = nfsk_backend_from_file(argv[1], 1, &error);
    require(backend != NULL, "open production image backend");
    ntfs_fskit_volume *v = nfsk_mount(backend, false, &error);
    require(v != NULL, "bridge mount");
    nfsk_statfs_t stats;
    CHECK(nfsk_statfs(v, &stats) == 0 && !stats.read_only, "volume is writable");
    char payload[8192]; memset(payload, 'x', sizeof payload);
    CHECK(nfsk_write(v, existing, 0, "seed", 4, &error) == 4, "write existing resident file");
    CHECK(nfsk_write(v, existing, 4, payload, sizeof payload, &error) == sizeof payload,
          "append beyond resident size despite zero-filled free records");
    const char *names[] = { "Issue7NewFile.txt", "Issue7NewDirectory", "Issue7SecondFile.txt" };
    const uint32_t types[] = { NFSK_TYPE_FILE, NFSK_TYPE_DIR, NFSK_TYPE_FILE };
    uint64_t created[3];
    for (int i = 0; i < 3; i++) {
        error = 0;
        created[i] = nfsk_create(v, NFSK_ROOT_INO, names[i], types[i], &error);
        printf("create %s: inode=%llu errno=%d\n", names[i], (unsigned long long)created[i], error);
        CHECK(created[i] == slots[i], "create reinitializes the expected zero-filled free record");
        if (created[i]) {
            nfsk_attr_t attributes;
            CHECK(nfsk_getattr(v, created[i], &attributes) == 0 && attributes.type == types[i],
                  "new item attributes have the requested type");
        }
    }
    uint64_t child = 0;
    if (created[0]) CHECK(nfsk_write(v, created[0], 0, payload, sizeof payload, &error) == sizeof payload,
                          "write newly created file");
    if (created[1]) {
        child = nfsk_create(v, created[1], "Child.txt", NFSK_TYPE_FILE, &error);
        CHECK(child != 0, "create inside newly created directory");
    }
    CHECK(nfsk_sync(v) == 0, "sync after allocation");
    nfsk_umount(v);
    v = nfsk_mount(backend, false, &error);
    require(v != NULL, "remount");
    char readback[sizeof payload];
    CHECK(nfsk_read(v, existing, 4, readback, sizeof readback, &error) == sizeof readback &&
          !memcmp(payload, readback, sizeof payload), "existing file survives sync and remount");
    for (int i = 0; i < 3; i++) {
        CHECK(nfsk_lookup(v, NFSK_ROOT_INO, names[i], &error) == slots[i], "new item persists after remount");
    }
    if (created[0]) CHECK(nfsk_read(v, created[0], 0, readback, sizeof readback, &error) == sizeof readback &&
                          !memcmp(payload, readback, sizeof payload), "new file data persists after remount");
    if (child) CHECK(nfsk_remove(v, created[1], "Child.txt") == 0, "remove nested child");
    for (int i = 0; i < 3; i++) {
        if (created[i]) CHECK(nfsk_remove(v, NFSK_ROOT_INO, names[i]) == 0, "remove new item");
    }
    nfsk_umount(v);
    nfsk_backend_free(backend);
    printf("%d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
