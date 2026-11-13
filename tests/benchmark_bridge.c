/* Ordinary-file benchmark. Link the production backend, redirecting only the
 * bridge's library calls and backend's POSIX I/O to the counters below.
 * This measures a warm host file cache, not physical FSKit device performance. */
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <ntfs-3g/volume.h>
#include <ntfs-3g/inode.h>
#include <ntfs-3g/attrib.h>
#include <ntfs-3g/index.h>
#include <ntfs-3g/unistr.h>
#include "ntfs_fskit.h"

enum { ENTRIES = 2048, SAMPLES = 32768, FILE_BYTES = 8 * 1024 * 1024, CHUNK = 65536 };
static struct {
    uint64_t reads, read_bytes, writes, write_bytes, flushes;
    uint64_t index_lookup, index_next, names, inode_open, inode_close;
    uint64_t attr_open, attr_close, allocations, allocated_bytes;
} counters;
static FILE *samples;
static uint64_t latencies[SAMPLES];
static uint64_t wall_start, cpu_start;

static void require(int ok, const char *what) {
    if (!ok) { fprintf(stderr, "FAIL: %s (errno=%d)\n", what, errno); exit(1); }
}
ssize_t nfsk_bench_pread(int fd, void *buf, size_t size, off_t offset) {
    counters.reads++;
    ssize_t n = pread(fd, buf, size, offset);
    if (n > 0) counters.read_bytes += n;
    return n;
}
ssize_t nfsk_bench_pwrite(int fd, const void *buf, size_t size, off_t offset) {
    counters.writes++;
    ssize_t n = pwrite(fd, buf, size, offset);
    if (n > 0) counters.write_bytes += n;
    return n;
}
int nfsk_bench_fsync(int fd) { counters.flushes++; return fsync(fd); }
int nfsk_bench_index_lookup(const void *key, int size, ntfs_index_context *index) {
    counters.index_lookup++;
    return ntfs_index_lookup(key, size, index);
}
INDEX_ENTRY *nfsk_bench_index_next(INDEX_ENTRY *entry, ntfs_index_context *index) {
    counters.index_next++;
    return ntfs_index_next(entry, index);
}
int nfsk_bench_ucstombs(const ntfschar *in, int size, char **out, int cap) {
    counters.names++;
    return ntfs_ucstombs(in, size, out, cap);
}
ntfs_inode *nfsk_bench_inode_open(ntfs_volume *vol, MFT_REF ref) {
    counters.inode_open++;
    return ntfs_inode_open(vol, ref);
}
int nfsk_bench_inode_real_close(ntfs_inode *inode) {
    counters.inode_close++;
    return ntfs_inode_real_close(inode);
}
ntfs_attr *nfsk_bench_attr_open(ntfs_inode *inode, ATTR_TYPES type, ntfschar *name, u32 len) {
    counters.attr_open++;
    return ntfs_attr_open(inode, type, name, len);
}
void nfsk_bench_attr_close(ntfs_attr *attr) { counters.attr_close++; ntfs_attr_close(attr); }
void *nfsk_bench_malloc(size_t size) {
    counters.allocations++; counters.allocated_bytes += size;
    return malloc(size);
}
void *nfsk_bench_calloc(size_t n, size_t size) {
    counters.allocations++; counters.allocated_bytes += n * size;
    return calloc(n, size);
}
static uint64_t clock_ns(clockid_t clock) {
    struct timespec t;
    require(clock_gettime(clock, &t) == 0, "clock");
    return (uint64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}
static void begin(void) {
    /* A much shorter optimized directory walk otherwise leaves later sub-ms
     * workloads at a different CPU power state. Apply identical CPU warm-up to
     * every phase; this does not purge caches or perform any filesystem I/O. */
    uint64_t until = clock_ns(CLOCK_MONOTONIC_RAW) + 50000000;
    volatile uint64_t warmup = 1;
    do {
        for (int i = 0; i < 1000; i++) warmup = warmup * 6364136223846793005ULL + 1;
    } while (clock_ns(CLOCK_MONOTONIC_RAW) < until);
    memset(&counters, 0, sizeof counters);
    cpu_start = clock_ns(CLOCK_PROCESS_CPUTIME_ID);
    wall_start = clock_ns(CLOCK_MONOTONIC_RAW);
}
static int compare(const void *a, const void *b) {
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return (x > y) - (x < y);
}
static void end(const char *name, int count, uint64_t bytes) {
    uint64_t wall = clock_ns(CLOCK_MONOTONIC_RAW) - wall_start;
    uint64_t cpu = clock_ns(CLOCK_PROCESS_CPUTIME_ID) - cpu_start;
    struct rusage usage;
    require(getrusage(RUSAGE_SELF, &usage) == 0, "RSS");
    require(count > 0 && count <= SAMPLES, "sample capacity");
    uint64_t call_ns = 0;
    for (int i = 0; i < count; i++) {
        call_ns += latencies[i];
        fprintf(samples, "%s,%d,%" PRIu64 "\n", name, i, latencies[i]);
    }
    qsort(latencies, count, sizeof latencies[0], compare);
    printf("%s,%d,%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%ld",
           name, count, bytes, wall, cpu, latencies[(count*50+99)/100-1], latencies[(count*95+99)/100-1],
           latencies[(count*99+99)/100-1], usage.ru_maxrss);
    printf(",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64
           ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64
           ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 "\n",
           counters.reads, counters.read_bytes, counters.writes, counters.write_bytes,
           counters.flushes, counters.index_lookup, counters.index_next, counters.names,
           counters.inode_open, counters.inode_close, counters.attr_open, counters.attr_close,
           counters.allocations, counters.allocated_bytes, call_ns);
}
static uint64_t lookup(ntfs_fskit_volume *v, uint64_t dir, const char *name) {
    int error = 0;
    uint64_t ino = nfsk_lookup(v, dir, name, &error);
    require(ino && !error, "lookup");
    return ino;
}
static uint64_t create(ntfs_fskit_volume *v, uint64_t dir, const char *name, uint32_t type) {
    int error = 0;
    uint64_t ino = nfsk_create(v, dir, name, type, &error);
    require(ino && !error, "create");
    return ino;
}
static unsigned char pattern(uint64_t offset) { return (unsigned char)((offset * 17) ^ (offset >> 8) ^ (offset >> 16)); }
static void fill(unsigned char *buf, int size, uint64_t offset) {
    for (int i = 0; i < size; i++) buf[i] = pattern(offset + i);
}
static void verify(const unsigned char *buf, int size, uint64_t offset, unsigned char salt) {
    for (int i = 0; i < size; i++) require(buf[i] == (pattern(offset + i) ^ salt), "payload checksum");
}
typedef struct { int accepted, limit, total; int64_t cookie; } page;
static int entry(void *opaque, const char *name, uint64_t ino, uint32_t type, int64_t cookie) {
    page *p = opaque;
    if (p->accepted == p->limit) return 1; /* FSKit's packer can reject an entry. */
    char expected[64];
    snprintf(expected, sizeof expected, "Entry-%05d-MiXeD.txt", p->total);
    require(!strcmp(name, expected) && ino && type == NFSK_TYPE_FILE && cookie == p->cookie + 1,
            "directory ordering/cookie/content");
    p->accepted++; p->total++; p->cookie = cookie;
    return 0;
}
static void directory(ntfs_fskit_volume *v, uint64_t dir, int limit, const char *name) {
    int calls = 0;
    int sweeps = limit > ENTRIES ? 32 : (limit == 64 ? 4 : 1);
    begin();
    for (int sweep = 0; sweep < sweeps; sweep++) {
        page p = {.limit = limit};
        do {
            p.accepted = 0;
            uint64_t t = clock_ns(CLOCK_MONOTONIC_RAW);
            int rc = nfsk_readdir(v, dir, p.cookie, &p, entry);
            latencies[calls++] = clock_ns(CLOCK_MONOTONIC_RAW) - t;
            require(rc == 0 && calls < SAMPLES, "enumeration");
        } while (p.accepted);
        require(p.total == ENTRIES, "complete directory");
    }
    end(name, calls, 0);
}
int main(int argc, char **argv) {
    if (argc != 4) return 2;
    require(pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0) == 0, "benchmark QoS");
    struct stat st;
    require(lstat(argv[2], &st) == 0 && S_ISREG(st.st_mode), "ordinary disposable image required");
    int prepare = !strcmp(argv[1], "prepare");
    require(prepare || !strcmp(argv[1], "measure"), "mode");
    int error = 0;
    void *backend = nfsk_backend_from_file(argv[2], 1, &error);
    require(backend != NULL, "file backend");
    ntfs_fskit_volume *v = nfsk_mount(backend, false, &error);
    require(v != NULL, "mount image through library only");
    unsigned char *buf = malloc(CHUNK);
    require(buf != NULL, "buffer");
    if (prepare) {
        uint64_t dir = create(v, NFSK_ROOT_INO, "PerfDirectory", NFSK_TYPE_DIR);
        for (int i = 0; i < ENTRIES; i++) {
            char name[64]; snprintf(name, sizeof name, "Entry-%05d-MiXeD.txt", i);
            create(v, dir, name, NFSK_TYPE_FILE);
        }
        uint64_t file = create(v, NFSK_ROOT_INO, "PerfData", NFSK_TYPE_FILE);
        for (int off = 0; off < FILE_BYTES; off += CHUNK) {
            fill(buf, CHUNK, off);
            require(nfsk_write(v, file, off, buf, CHUNK, &error) == CHUNK, "prepare payload");
        }
        uint64_t resident = create(v, NFSK_ROOT_INO, "PerfResident", NFSK_TYPE_FILE);
        fill(buf, 64, 0);
        require(nfsk_write(v, resident, 0, buf, 64, &error) == 64, "resident payload");
    } else {
        samples = fopen(argv[3], "w"); require(samples != NULL, "samples output");
        fputs("workload,operation,latency_ns\n", samples);
        puts("workload,operations,bytes,wall_ns,cpu_ns,p50_ns,p95_ns,p99_ns,rss_bytes,reads,read_bytes,writes,write_bytes,flushes,index_lookup,index_next,names,inode_open,inode_close,attr_open,attr_close,bridge_allocations,bridge_allocated_bytes,call_ns");
        uint64_t dir = lookup(v, NFSK_ROOT_INO, "PerfDirectory");
        uint64_t file = lookup(v, NFSK_ROOT_INO, "PerfData");
        uint64_t resident = lookup(v, NFSK_ROOT_INO, "PerfResident");
        directory(v, dir, 7, "directory_page7");
        directory(v, dir, 64, "directory_page64");
        directory(v, dir, ENTRIES + 1, "directory_all");
        begin();
        for (int i = 0; i < SAMPLES; i++) {
            nfsk_attr_t attr;
            uint64_t t = clock_ns(CLOCK_MONOTONIC_RAW);
            int rc = nfsk_getattr(v, file, &attr);
            latencies[i] = clock_ns(CLOCK_MONOTONIC_RAW) - t;
            require(!rc && attr.size == FILE_BYTES, "getattr");
        }
        end("getattr", SAMPLES, 0);
        begin();
        for (int i = 0; i < SAMPLES; i++) {
            char name[64]; snprintf(name, sizeof name, "Entry-%05d-MiXeD.txt", (i*509)%ENTRIES);
            uint64_t t = clock_ns(CLOCK_MONOTONIC_RAW);
            lookup(v, dir, name);
            latencies[i] = clock_ns(CLOCK_MONOTONIC_RAW) - t;
        }
        end("lookup", SAMPLES, 0);
        for (int mode = 0; mode < 5; mode++) {
            int size = mode == 0 ? 64 : (mode == 1 || mode == 3 ? CHUNK : 4096);
            int n = mode == 1 || mode == 3 ? 1024 : SAMPLES;
            begin();
            for (int i = 0; i < n; i++) {
                uint64_t off = mode == 0 ? 0 : ((uint64_t)i * (mode == 1 || mode == 3 ? 1 : 509) % (FILE_BYTES/size)) * size;
                if (mode >= 3) {
                    fill(buf, size, off);
                    for (int j = 0; j < size; j++) buf[j] ^= 0x5a;
                }
                uint64_t t = clock_ns(CLOCK_MONOTONIC_RAW);
                int64_t rc = mode >= 3 ? nfsk_write(v, file, off, buf, size, &error) :
                    nfsk_read(v, mode == 0 ? resident : file, off, buf, size, &error);
                latencies[i] = clock_ns(CLOCK_MONOTONIC_RAW) - t;
                require(rc == size, "read/write count");
                if (mode < 3) verify(buf, size, off, 0);
            }
            const char *names[] = {"resident_read", "sequential_read", "random_read", "sequential_write", "random_write"};
            end(names[mode], n, (uint64_t)n*size);
        }
        begin();
        for (int i = 0; i < 8; i++) {
            uint64_t t = clock_ns(CLOCK_MONOTONIC_RAW);
            int rc = nfsk_sync(v);
            latencies[i] = clock_ns(CLOCK_MONOTONIC_RAW) - t;
            require(rc == 0, "sync");
        }
        end("sync", 8, 0);
        require(fclose(samples) == 0, "close samples");
    }
    require(nfsk_umount(v) == 0, "final release");
    nfsk_backend_free(backend);
    backend = nfsk_backend_from_file(argv[2], 0, &error);
    require(backend != NULL, "reopen backend read only");
    v = nfsk_mount(backend, true, &error);
    require(v != NULL, "remount read only");
    uint64_t file = lookup(v, NFSK_ROOT_INO, "PerfData");
    for (int off = 0; off < FILE_BYTES; off += CHUNK) {
        require(nfsk_read(v, file, off, buf, CHUNK, &error) == CHUNK, "reopened read");
        verify(buf, CHUNK, off, prepare ? 0 : 0x5a);
    }
    require(nfsk_umount(v) == 0, "read-only release");
    nfsk_backend_free(backend);
    free(buf);
    fprintf(stderr, "PASS: payload verified after reopening; %d directory entries\n", ENTRIES);
    return 0;
}
