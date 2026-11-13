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
static int checks, failures, reads, writes, fail_reads, fail_serial;
static int malloc_countdown, malloc_hits, conversion_error, conversion_hits, partial_frees;
static int lookup_error, lookup_hits, context_error, context_hits, live_contexts;
static void *partial;
#define CHECK(ok, message) do { checks++; if (!(ok)) { failures++; \
    fprintf(stderr, "FAIL: %s\n", message); } else printf("PASS: %s\n", message); } while (0)

int64_t nfsk_block_pread(void *p, void *buf, int64_t off, int64_t count) {
    reads++;
    if (fail_reads || (fail_serial && off == 0x48 && count == 8)) { errno = ENXIO; return -1; }
    return pread(((test_device *)p)->fd, buf, count, off);
}
int64_t nfsk_block_pwrite(void *p, const void *buf, int64_t off, int64_t count) {
    writes++;
    return pwrite(((test_device *)p)->fd, buf, count, off);
}
int nfsk_block_sync(void *p) { return fsync(((test_device *)p)->fd) ? -errno : 0; }
uint64_t nfsk_block_total_bytes(void *p) { return ((test_device *)p)->size; }
uint32_t nfsk_block_sector_size(void *p) { (void)p; return 512; }
int nfsk_block_is_writable(void *p) { (void)p; return 1; }

void *nfsk_test_malloc(size_t size) {
    if (malloc_countdown > 0 && --malloc_countdown == 0) { malloc_hits++; errno = ENOMEM; return NULL; }
    return malloc(size);
}
void nfsk_test_free(void *pointer) {
    if (pointer && pointer == partial) { partial = NULL; partial_frees++; }
    free(pointer);
}
int nfsk_test_ucstombs(const ntfschar *name, int length, char **output, int capacity) {
    if (conversion_error) {
        *output = malloc(8); if (!*output) abort(); partial = *output;
        conversion_hits++; errno = conversion_error; return -1;
    }
    return ntfs_ucstombs(name, length, output, capacity);
}
int nfsk_test_attr_lookup(ATTR_TYPES type, const ntfschar *name, u32 length,
        IGNORE_CASE_BOOL ic, VCN lowest, const u8 *value, u32 bytes, ntfs_attr_search_ctx *ctx) {
    if (type == AT_VOLUME_NAME && lookup_error) { lookup_hits++; errno = lookup_error; return -1; }
    return ntfs_attr_lookup(type, name, length, ic, lowest, value, bytes, ctx);
}
ntfs_attr_search_ctx *nfsk_test_attr_get_search_ctx(ntfs_inode *ni, MFT_RECORD *record) {
    if (ni && ni->mft_no == FILE_Volume && context_error) {
        context_hits++; errno = context_error; return NULL;
    }
    ntfs_attr_search_ctx *ctx = ntfs_attr_get_search_ctx(ni, record);
    if (ctx) live_contexts++;
    return ctx;
}
void nfsk_test_attr_put_search_ctx(ntfs_attr_search_ctx *ctx) {
    if (ctx) live_contexts--;
    ntfs_attr_put_search_ctx(ctx);
}

typedef struct { char input[1600], output[1600]; ntfschar literal[129]; int length; } label_case;
static label_case make_label(int index) {
    label_case label = {0};
    int boms = index == 3 || index == 5 ? 2 : index == 9 ? 127 :
               index == 2 || index == 4 || index == 6 || index == 8;
    for (int i = 0; i < boms; i++) {
        strcat(label.input, "\xef\xbb\xbf"); strcat(label.output, "\xef\xbb\xbf");
        label.literal[label.length++] = const_cpu_to_le16(0xfeff);
    }
    if (index == 0 || index == 4 || index == 5) {
        strcat(label.input, "Alpha"); strcat(label.output, "Alpha");
        for (const char *p = "Alpha"; *p; p++) label.literal[label.length++] = cpu_to_le16(*p);
    }
    if (index == 1) {
        strcpy(label.input, "\xe6\xb5\x8b\xe8\xaf\x95 \xf0\x9f\x92\xbe"); strcpy(label.output, label.input);
        const ntfschar units[] = { cpu_to_le16(0x6d4b), cpu_to_le16(0x8bd5), cpu_to_le16(' '),
                                  cpu_to_le16(0xd83d), cpu_to_le16(0xdcbe) };
        memcpy(label.literal, units, sizeof units); label.length = 5;
    }
    if (index == 6) {
        strcat(label.input, "e\xcc\x81"); strcat(label.output, "e\xcc\x81");
        label.literal[label.length++] = const_cpu_to_le16(0xe9);
    }
    if (index == 7 || index == 8 || index == 10) {
        int units = index == 10 ? 128 : 127;
        while (label.length < units) {
            strcat(label.input, "\xea\xb0\x81"); strcat(label.output, "\xe1\x84\x80\xe1\x85\xa1\xe1\x86\xa8");
            label.literal[label.length++] = const_cpu_to_le16(0xac01);
        }
    }
    return label;
}

static void require(int ok, const char *message) {
    if (!ok) { fprintf(stderr, "Fixture failure: %s errno=%d\n", message, errno); exit(2); }
}

static void native_label(const char *path, const label_case *label, int write_label) {
    ntfs_volume *volume = ntfs_mount(path, write_label ? 0 : NTFS_MNT_RDONLY | NTFS_MNT_FORENSIC);
    require(volume != NULL, "native literal label mount");
    if (write_label) require(ntfs_volume_rename(volume, label->literal, label->length) == 0, "native literal label write");
    ntfs_attr *attr = ntfs_attr_open(volume->vol_ni, AT_VOLUME_NAME, AT_UNNAMED, 0);
    require(attr != NULL, "native label attribute");
    ntfschar units[129] = {0};
    s64 expected = (s64)label->length * sizeof(ntfschar);
    CHECK(attr->data_size == expected, "persisted volume label excludes the terminator");
    CHECK(ntfs_attr_pread(attr, 0, expected, units) == expected && !memcmp(units, label->literal, (size_t)expected),
          "native observer matches independent literal UTF16 label units");
    ntfs_attr_close(attr);
    require(ntfs_umount(volume, FALSE) == 0, "native label close");
}

static void check_published_label(test_device *device, const label_case *label, uint64_t expected_serial) {
    char probe[1600], small[3] = {'!', '!', '!'};
    uint64_t serial = 0;
    writes = 0;
    CHECK(nfsk_probe(device, probe, sizeof probe, &serial) == 1 && !strcmp(probe, label->output) && serial == expected_serial,
          "legacy probe with sufficient capacity returns complete normalized label and stable serial");
    CHECK(nfsk_probe(device, small, sizeof small, NULL) == 1 && small[2] == 0 &&
          !memcmp(small, label->output, 2), "legacy bounded probe retains its caller-capacity contract");
    char *first = NULL, *second = NULL;
    CHECK(nfsk_probe_name_alloc(device, &first, &serial) == 1 && first && !strcmp(first, label->output) && serial == expected_serial,
          "owned probe transfers the full name after releasing its native volume");
    CHECK(nfsk_probe_name_alloc(device, &second, NULL) == 1 && second && first != second &&
          !strcmp(second, label->output) && first && !strcmp(first, label->output),
          "separate owned probes retain independent buffers");
    nfsk_test_free(second);
    second = NULL; fail_serial = 1;
    CHECK(nfsk_probe_name_alloc(device, &second, &serial) == 1 && second && !strcmp(second, label->output) && serial == 0,
          "optional serial-read failure preserves recognition and complete owned name");
    fail_serial = 0; nfsk_test_free(second);
    int error = 0;
    ntfs_fskit_volume *v = nfsk_mount(device, true, &error);
    require(v != NULL, "read-only literal label mount");
    nfsk_statfs_t stats;
    reads = 0; fail_reads = 1;
    CHECK(nfsk_statfs(v, &stats) == 0 && nfsk_volume_name(v) && !strcmp(nfsk_volume_name(v), label->output) &&
          stats.volume_serial == expected_serial && reads == 0,
          "statfs and complete cached name perform no backend read, including after remount");
    fail_reads = 0;
    CHECK(nfsk_rename_volume(v, "ReadOnly") == -EROFS && writes == 0,
          "probe/reopen and rejected read-only label mutation perform no writes");
    CHECK(nfsk_umount(v) == 0 && first && !strcmp(first, label->output),
          "owned probe name outlives subsequent volume mounts and releases");
    nfsk_test_free(first);
}

static void check_label(test_device *device, const char *path, const label_case *label, int index) {
    int error = 0;
    ntfs_fskit_volume *v = nfsk_mount(device, false, &error);
    require(v != NULL, "writable label mount");
    CHECK(nfsk_rename_volume(v, label->input) == 0, "rename literal label through the bridge");
    nfsk_statfs_t stats;
    reads = 0; fail_reads = 1;
    CHECK(nfsk_statfs(v, &stats) == 0 && nfsk_volume_name(v) && !strcmp(nfsk_volume_name(v), label->output) && reads == 0,
          "live complete label and statistics stay memory-only");
    fail_reads = 0;
    size_t legacy_length = strlen(label->output);
    if (legacy_length >= sizeof stats.volume_name) legacy_length = sizeof stats.volume_name - 1;
    CHECK(strlen(stats.volume_name) == legacy_length && !memcmp(stats.volume_name, label->output, legacy_length),
          "legacy statistics keep their documented bounded spelling without enlarging the snapshot");
    CHECK(nfsk_umount(v) == 0, "renamed label volume releases cleanly");
    native_label(path, label, 0);
    check_published_label(device, label, stats.volume_serial);
    printf("LABEL C CASE: index=%d units=%d bytes=%zu\n", index, label->length, strlen(label->output));
}

#ifdef NFSK_TEST_LABEL_FAULTS
static void label_faults(test_device *device, const char *path) {
    label_case label = make_label(4);
    native_label(path, &label, 1);
    int error = 0;
    ntfs_fskit_volume *v = nfsk_mount(device, false, &error);
    require(v != NULL, "label fault mount");
    for (int allocation = 1; allocation <= 2; allocation++) {
        malloc_countdown = allocation; malloc_hits = writes = 0;
        int result = nfsk_rename_volume(v, "\xef\xbb\xbf" "New");
        malloc_countdown = 0;
        CHECK(result == -ENOMEM && malloc_hits == 1 && writes == 0 && !strcmp(nfsk_volume_name(v), label.output),
              "input/cache allocation failure precedes label writes and preserves the old cache");
    }
    for (int i = 0; i < 2; i++) {
        conversion_error = i ? EILSEQ : ENOMEM; conversion_hits = partial_frees = writes = 0;
        int result = nfsk_rename_volume(v, "\xef\xbb\xbf" "New");
        CHECK(result == -conversion_error && conversion_hits == 1 && partial_frees == 1 && !partial && !writes &&
              !strcmp(nfsk_volume_name(v), label.output), "setter suffix failure frees partial output without modifying cached or disk label");
        conversion_error = 0;
    }
    char oversized[131] = "\xef\xbb\xbf"; memset(oversized + 3, 'L', 127); oversized[130] = 0;
    writes = 0;
    CHECK(nfsk_rename_volume(v, oversized) == -ENAMETOOLONG &&
          nfsk_rename_volume(v, "\xef\xbb\xbf\xff") == -EILSEQ && !writes && !strcmp(nfsk_volume_name(v), label.output),
          "literal prefix counts toward label units and malformed suffix never writes");
    require(nfsk_umount(v) == 0, "label fault close");
    native_label(path, &label, 0);
    for (int operation = 0; operation < 2; operation++) for (int fault = 0; fault < 4; fault++) {
        int expected = fault == 0 ? ENXIO : ENOMEM;
        lookup_hits = context_hits = malloc_hits = conversion_hits = partial_frees = writes = 0;
        if (fault == 0) lookup_error = expected;
        if (fault == 1) context_error = expected;
        if (fault == 2) malloc_countdown = 1;
        if (fault == 3) conversion_error = expected;
        char *owned = NULL;
        if (operation) {
            CHECK(nfsk_probe_name_alloc(device, &owned, NULL) == 0 && !owned,
                  "failed probe name production leaves no transferred result");
        } else {
            v = nfsk_mount(device, true, &error);
            CHECK(!v && error == expected, "mount preserves label correction error");
            if (v) nfsk_umount(v);
        }
        int hits = lookup_hits + context_hits + malloc_hits + conversion_hits;
        CHECK(hits == 1 && !live_contexts && !writes && !partial && (fault != 3 || partial_frees == 1),
              "label fault is reached once and releases search/partial ownership without writes");
        lookup_error = context_error = malloc_countdown = conversion_error = 0;
        CHECK(nfsk_probe_name_alloc(device, &owned, NULL) == 1 && owned && !strcmp(owned, label.output),
              "probe retry after correction failure returns the full literal label");
        nfsk_test_free(owned);
    }
    /* EILSEQ keeps native mount's compatibility fallback. Other production
     * failures above are not mistaken for a successful corrected name. */
    ntfs_volume *native = ntfs_mount(path, NTFS_MNT_RDONLY | NTFS_MNT_FORENSIC);
    require(native != NULL, "native label fallback observer");
    char *fallback = strdup(native->vol_name);
    require(fallback && ntfs_umount(native, FALSE) == 0, "retain native fallback");
    conversion_error = EILSEQ; conversion_hits = partial_frees = 0;
    char *owned = NULL;
    CHECK(nfsk_probe_name_alloc(device, &owned, NULL) == 1 && owned && !strcmp(owned, fallback) &&
          conversion_hits == 1 && partial_frees == 1 && !partial,
          "unrepresentable label retains native cached fallback and releases failed conversion");
    conversion_error = 0; nfsk_test_free(owned); free(fallback);
    lookup_error = ENXIO; lookup_hits = 0;
    CHECK(nfsk_probe(device, NULL, 0, NULL) == 1 && lookup_hits == 0,
          "recognition-only legacy probe does not perform unused label correction");
    lookup_error = 0;
}
#endif

static void empty_label_tests(test_device *device, const char *path) {
    for (int absent = 0; absent < 2; absent++) {
        ntfs_volume *native = ntfs_mount(path, 0);
        require(native != NULL, "empty label fixture mount");
        ntfschar empty = 0;
        require(ntfs_volume_rename(native, &empty, 0) == 0, "empty native label");
        if (absent) require(ntfs_attr_remove(native->vol_ni, AT_VOLUME_NAME, AT_UNNAMED, 0) == 0, "remove native label attribute");
        require(ntfs_umount(native, FALSE) == 0, "empty label fixture close");
        char *name = NULL; writes = 0;
        CHECK(nfsk_probe_name_alloc(device, &name, NULL) == 1 && name && !*name && !writes,
              "empty or absent native labels remain recognized with an owned empty string");
        nfsk_test_free(name);
        int error = 0;
        ntfs_fskit_volume *v = nfsk_mount(device, true, &error);
        CHECK(v && nfsk_volume_name(v) && !*nfsk_volume_name(v), "empty or absent native label has a complete empty cache");
        if (v) CHECK(nfsk_umount(v) == 0, "empty label mount releases");
    }
}

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "Usage: %s <disposable-NTFS-image>\n", argv[0]); return 2; }
    test_device device = { .fd = open(argv[1], O_RDWR) };
    struct stat st;
    if (device.fd < 0 || fstat(device.fd, &st) || !S_ISREG(st.st_mode)) return 2;
    device.size = st.st_size;
    for (int index = 0; index < 10; index++) {
        label_case label = make_label(index);
        check_label(&device, argv[1], &label, index);
    }
    label_case external = make_label(10);
    native_label(argv[1], &external, 1);
    int error = 0;
    ntfs_fskit_volume *v = nfsk_mount(&device, true, &error);
    nfsk_statfs_t stats;
    require(v && nfsk_statfs(v, &stats) == 0 && nfsk_umount(v) == 0, "external128-unit label fixture");
    check_published_label(&device, &external, stats.volume_serial);
#ifdef NFSK_TEST_LABEL_FAULTS
    label_faults(&device, argv[1]);
#endif
    empty_label_tests(&device, argv[1]);
    reads = 0;
    CHECK(!nfsk_volume_name(NULL) && !nfsk_probe_name_alloc(&device, NULL, NULL) && !reads,
          "invalid cached/owned-name requests fail before backend access");
    char *name = NULL; fail_reads = 1; writes = 0;
    CHECK(nfsk_probe_name_alloc(&device, &name, NULL) == 0 && !name && !writes,
          "actual backend read failure keeps probe unrecognized with no owned output or writes");
    fail_reads = 0;
    CHECK(!live_contexts && !partial, "label tests retain no search context or partial conversion");
    close(device.fd);
    printf("%d label checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
