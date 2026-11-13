/* Public-bridge growth benchmark on ordinary files. Open records model the
 * macOS 15 compatibility path, not modern FSKit's native open-unlink lifetime. */
#include <errno.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include "ntfs_fskit.h"

enum { HELD = 4096, ENTRIES = 128, CALLS = 8192, LISTINGS = 512 };
static uint64_t ids[HELD], latencies[CALLS];
static uint64_t visits[2], reads, writes, flushes;
static FILE *raw;
#ifdef NFSK_REF_DIAGNOSTIC
extern size_t nfsk_ref_devctx_size(void);
extern size_t nfsk_ref_entry_size(void);
#endif
static void require(int ok, const char *what) {
    if (!ok) { fprintf(stderr, "FAIL: %s errno=%d\n", what, errno); exit(1); }
}
/* Called only by diagnostic source copies; clean binaries have no observer calls. */
void nfsk_ref_visit(int kind) { require(kind == 0 || kind == 1, "probe kind"); visits[kind]++; }
ssize_t nfsk_ref_pread(int fd, void *p, size_t n, off_t o) { reads++; return pread(fd, p, n, o); }
ssize_t nfsk_ref_pwrite(int fd, const void *p, size_t n, off_t o) { writes++; return pwrite(fd, p, n, o); }
int nfsk_ref_fsync(int fd) { flushes++; return fsync(fd); }
static uint64_t now(clockid_t clock) {
    struct timespec t; require(clock_gettime(clock, &t) == 0, "clock");
    return (uint64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}
static uint64_t create(ntfs_fskit_volume *v, uint64_t parent, const char *name, uint32_t type) {
    int error = 0; uint64_t ino = nfsk_create(v, parent, name, type, &error);
    require(ino != 0 && error == 0, "prepare create");
    if (type == NFSK_TYPE_FILE) {
        char bytes[64]; memset(bytes, 'x', sizeof bytes);
        require(nfsk_write(v, ino, 0, bytes, sizeof bytes, &error) == sizeof bytes, "prepare payload");
    }
    return ino;
}
static uint64_t lookup(ntfs_fskit_volume *v, uint64_t parent, const char *name) {
    int error = 0; uint64_t ino = nfsk_lookup(v, parent, name, &error);
    require(ino && !error, "lookup prepared item"); return ino;
}
static void prepare(ntfs_fskit_volume *v) {
    uint64_t held = create(v, NFSK_ROOT_INO, "RefHeld", NFSK_TYPE_DIR);
    uint64_t nested = create(v, NFSK_ROOT_INO, "RefNested", NFSK_TYPE_DIR);
    for (int i = 0; i < HELD; i++) {
        char name[32]; snprintf(name, sizeof name, "Held-%04d", i);
        create(v, held, name, NFSK_TYPE_FILE);
    }
    for (int i = 0; i < ENTRIES; i++) {
        char name[32]; snprintf(name, sizeof name, "Ref-%04d", i);
        create(v, NFSK_ROOT_INO, name, NFSK_TYPE_FILE);
        create(v, nested, name, NFSK_TYPE_FILE);
    }
    require(nfsk_sync(v) == 0, "prepare sync");
}
typedef struct { uint64_t hash; unsigned count, expected; uint64_t parent; } listing;
static int name_entry(void *opaque, const char *name, uint64_t ino, uint32_t type, int64_t cookie) {
    listing *l = opaque;
    require(ino && cookie > 0 && ++l->count <= 256, "bounded ordinary listing");
    require(strncmp(name, ".xntfs-open-", 12) != 0, "no retained name exposed");
    if (!strncmp(name, "Ref-", 4)) {
        char expected[32]; snprintf(expected, sizeof expected, "Ref-%04u", l->expected++);
        require(!strcmp(name, expected) && type == NFSK_TYPE_FILE, "listing names/types/order");
    }
    for (const unsigned char *p = (const unsigned char *)name; *p; p++) l->hash = l->hash * 131 + *p;
    l->hash = l->hash * 131 + ino + type + (uint64_t)cookie;
    return 0;
}
static int attr_entry(void *opaque, const char *name, const nfsk_attr_t *a, int64_t cookie) {
    listing *l = opaque;
    require(a->parent_ino == l->parent, "listing parent");
    if (!strncmp(name, "Ref-", 4)) require(a->size == 64 && a->nlink == 1, "listing attributes");
    return name_entry(opaque, name, a->ino, a->type, cookie);
}
enum { ATTR_CLOSED, ATTR_OLDEST, ATTR_NEWEST, REOPEN, LOOKUP_ROOT, NAMES_ROOT, NAMES_NESTED, ATTRS_ROOT, ATTRS_NESTED };
static const char *names[] = {"getattr.closed", "getattr.oldest", "getattr.newest", "reopen.oldest", "lookup.root",
                             "names.root", "names.nested", "attrs.root", "attrs.nested"};
static uint64_t operation(ntfs_fskit_volume *v, int kind, int opened, uint64_t closed, uint64_t nested) {
    if (kind <= ATTR_NEWEST) {
        uint64_t ino = kind == ATTR_CLOSED ? closed : kind == ATTR_OLDEST ? ids[0] : ids[opened - 1];
        nfsk_attr_t a; require(nfsk_getattr(v, ino, &a) == 0 && a.ino == ino && a.size == 64 && a.nlink == 1,
                               "getattr identity/size/links");
        return a.ino;
    }
    if (kind == REOPEN) { require(nfsk_open_item(v, ids[0]) == 0, "idempotent open"); return ids[0]; }
    if (kind == LOOKUP_ROOT) { require(lookup(v, NFSK_ROOT_INO, "Ref-0000") == closed, "lookup identity"); return closed; }
    uint64_t dir = kind == NAMES_ROOT || kind == ATTRS_ROOT ? NFSK_ROOT_INO : nested;
    listing l = {.parent = dir};
    int rc = kind >= ATTRS_ROOT ? nfsk_readdir_attributes(v, dir, 0, &l, attr_entry) : nfsk_readdir(v, dir, 0, &l, name_entry);
    require(rc == 0 && l.expected == ENTRIES, "complete listing");
    return l.hash;
}
static int compare(const void *a, const void *b) {
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b; return (x > y) - (x < y);
}
static void measure(ntfs_fskit_volume *v, int kind, int opened, uint64_t closed, uint64_t nested) {
    int count = kind >= NAMES_ROOT ? LISTINGS : CALLS;
    uint64_t expected = operation(v, kind, opened, closed, nested), warm = now(CLOCK_MONOTONIC_RAW) + 50000000;
    do { require(operation(v, kind, opened, closed, nested) == expected, "warm result"); }
    while (now(CLOCK_MONOTONIC_RAW) < warm);
    visits[0] = visits[1] = reads = writes = flushes = 0;
    uint64_t cpu = now(CLOCK_PROCESS_CPUTIME_ID), wall = now(CLOCK_MONOTONIC_RAW);
    for (int i = 0; i < count; i++) {
        uint64_t start = now(CLOCK_MONOTONIC_RAW);
        require(operation(v, kind, opened, closed, nested) == expected, "stable result");
        latencies[i] = now(CLOCK_MONOTONIC_RAW) - start;
    }
    wall = now(CLOCK_MONOTONIC_RAW) - wall; cpu = now(CLOCK_PROCESS_CPUTIME_ID) - cpu;
    for (int i = 0; i < count; i++) fprintf(raw, "%d,%s,%d,%" PRIu64 "\n", opened, names[kind], i, latencies[i]);
    qsort(latencies, count, sizeof(*latencies), compare);
    struct rusage usage; require(getrusage(RUSAGE_SELF, &usage) == 0, "rusage");
    printf("%d,%s,%d,%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%ld,%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 "\n",
           opened, names[kind], count, wall, cpu, latencies[(count*50+99)/100-1], latencies[(count*95+99)/100-1],
           latencies[(count*99+99)/100-1], usage.ru_maxrss, visits[0], visits[1], reads, writes, flushes, expected);
}
int main(int argc, char **argv) {
    require(argc == 4 && (!strcmp(argv[1], "prepare") || !strcmp(argv[1], "measure")), "arguments");
    require(pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0) == 0, "QoS");
#ifdef NFSK_REF_DIAGNOSTIC
    fprintf(stderr, "LAYOUT devctx=%zu open_ref=%zu\n", nfsk_ref_devctx_size(), nfsk_ref_entry_size());
#endif
    struct stat st; require(lstat(argv[2], &st) == 0 && S_ISREG(st.st_mode) && st.st_size <= (128 << 20), "bounded regular image");
    int preparing = !strcmp(argv[1], "prepare"), error = 0;
    void *backend = nfsk_backend_from_file(argv[2], preparing, &error);
    require(backend != NULL, "backend");
    ntfs_fskit_volume *v = nfsk_mount(backend, !preparing, &error); require(v != NULL, "mount");
    if (preparing) prepare(v);
    else {
        uint64_t held = lookup(v, NFSK_ROOT_INO, "RefHeld"), nested = lookup(v, NFSK_ROOT_INO, "RefNested");
        uint64_t closed = lookup(v, NFSK_ROOT_INO, "Ref-0000");
        for (int i = 0; i < HELD; i++) {
            char name[32]; snprintf(name, sizeof name, "Held-%04d", i); ids[i] = lookup(v, held, name);
        }
        raw = fopen(argv[3], "wx"); require(raw != NULL, "new sample output");
        fputs("opened,workload,sample,ns\n", raw);
        puts("opened,workload,operations,wall_ns,cpu_ns,p50_ns,p95_ns,p99_ns,rss_bytes,lookup_visits,retention_visits,reads,writes,flushes,checksum");
        const int levels[] = {0, 32, 512, HELD}; int opened = 0;
        for (unsigned level = 0; level < sizeof(levels)/sizeof(*levels); level++) {
            while (opened < levels[level]) require(nfsk_open_item(v, ids[opened++]) == 0, "register open item");
            char content[64];
            require(nfsk_read(v, ids[0], 0, content, sizeof content, &error) == sizeof content, "read prepared payload");
            for (size_t i = 0; i < sizeof content; i++) require(content[i] == 'x', "prepared payload bytes");
            for (int kind = ATTR_CLOSED; kind <= ATTRS_NESTED; kind++) {
                if (!opened && kind >= ATTR_OLDEST && kind <= REOPEN) continue;
                measure(v, kind, opened, closed, nested);
            }
        }
        require(fclose(raw) == 0, "sample close");
        for (int i = HELD - 1; i >= 0; i--) require(nfsk_close_item(v, ids[i]) == 0, "close all registered items");
    }
    require(nfsk_umount(v) == 0, "unmount"); nfsk_backend_free(backend);
    fputs("PASS: public bridge identity/content/lifetime, no OS mount\n", stderr);
    return 0;
}
