/* Actual bridge/libntfs + ObjC adapter against a disposable regular file.
 * The file is the visible (volatile) view. The Python replayer constructs the
 * durable view from recorded writes/barriers; process exit alone is not a power
 * loss model. No FSKit resource is created and no device is opened. */
#import <Foundation/Foundation.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "ntfs_fskit.h"

enum { MAX_IMAGE = 128 * 1024 * 1024, MAX_PAYLOAD = 64 * 1024 * 1024,
       MAX_REQUEST = 16 * 1024 * 1024, MAX_EVENTS = 4096 };
static void require(BOOL ok, const char *message) {
    if (!ok) { fprintf(stderr, "MODEL ERROR: %s errno=%d\n", message, errno); _exit(90); }
}
static void write_all(int fd, const void *data, size_t length) {
    size_t done = 0;
    while (done < length) {
        ssize_t n = write(fd, (const char *)data + done, length - done);
        require(n > 0, "write model artifact"); done += n;
    }
}
static int regular_file(const char *path, int flags) {
    int fd = open(path, flags | O_NOFOLLOW | O_CLOEXEC, 0600);
    require(fd >= 0, "open regular model file");
    struct stat st;
    require(fstat(fd, &st) == 0 && S_ISREG(st.st_mode), "model never accepts a device");
    return fd;
}

@interface CrashResource : NSObject
@property uint64_t blockSize, physicalBlockSize, blockCount;
@property(getter=isWritable) BOOL writable;
@property int visible, log, payload;
@property uint64_t events, payloadBytes, reads, writes, flushes, serviced, rejected;
@property uint64_t disconnectWrite, failFlush;
@property BOOL disconnected;
- (void)event:(NSString *)kind values:(NSDictionary *)values;
@end
@implementation CrashResource
- (void)event:(NSString *)kind values:(NSDictionary *)values {
    require(++_events <= MAX_EVENTS, "trace event limit");
    NSMutableDictionary *row = [values mutableCopy];
    row[@"kind"] = kind; row[@"event"] = @(_events);
    NSData *data = [NSJSONSerialization dataWithJSONObject:row options:NSJSONWritingSortedKeys error:NULL];
    require(data && data.length < 4096, "bounded trace event");
    write_all(_log, data.bytes, data.length); write_all(_log, "\n", 1);
}
- (BOOL)range:(off_t)offset length:(size_t)length {
    uint64_t total = _blockSize * _blockCount;
    require(offset >= 0 && (uint64_t)offset <= total && length <= total - offset && length <= MAX_REQUEST,
            "bounded resource range");
    require(offset % _blockSize == 0 && length % _blockSize == 0, "logical block alignment");
    return YES;
}
- (size_t)readInto:(void *)buffer startingAt:(off_t)offset length:(size_t)length error:(NSError **)error {
    [self range:offset length:length]; _reads++;
    if (_disconnected) { _rejected++; *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENXIO userInfo:nil]; return 0; }
    _serviced++;
    ssize_t n = pread(_visible, buffer, length, offset);
    if (n < 0) { *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]; return 0; }
    return n;
}
- (size_t)writeFrom:(void *)buffer startingAt:(off_t)offset length:(size_t)length error:(NSError **)error {
    [self range:offset length:length]; _writes++;
    if (_disconnected) { _rejected++; *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENXIO userInfo:nil]; return 0; }
    BOOL disconnect = _disconnectWrite && _writes == _disconnectWrite;
    size_t accepted = disconnect ? MIN(length, (size_t)512) : length;
    require(length <= MAX_PAYLOAD - _payloadBytes, "trace payload limit");
    uint64_t payloadOffset = _payloadBytes;
    write_all(_payload, buffer, length); _payloadBytes += length;
    ssize_t n = pwrite(_visible, buffer, accepted, offset);
    require(n == accepted, "model visible write"); _serviced++;
    [self event:@"write" values:@{@"offset":@(offset), @"length":@(length), @"accepted":@(accepted),
        @"payload":@(payloadOffset), @"write":@(_writes), @"error":@(disconnect ? ENXIO : 0)}];
    if (disconnect) {
        _disconnected = YES;
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENXIO userInfo:nil];
    }
    return accepted;
}
- (BOOL)metadataFlushWithError:(NSError **)error {
    _flushes++;
    int code = _disconnected ? ENXIO : (_failFlush && _flushes == _failFlush ? EIO : 0);
    if (_disconnected) _rejected++;
    else _serviced++;
    [self event:@"flush" values:@{@"flush":@(_flushes), @"error":@(code)}];
    if (code) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
    // This is an abstract barrier event. Its two possible durability meanings
    // are explicitly selected by the replayer, not inferred from host fsync.
    return code == 0;
}
@end

static uint64_t child(ntfs_fskit_volume *v, uint64_t dir, const char *name) {
    int error = 0; uint64_t ino = nfsk_lookup(v, dir, name, &error);
    require(ino != 0 && error == 0, "look up seeded item"); return ino;
}
static uint64_t create(ntfs_fskit_volume *v, uint64_t dir, const char *name, uint32_t type) {
    int error = 0; uint64_t ino = nfsk_create(v, dir, name, type, &error);
    require(ino != 0 && error == 0, "create seed item"); return ino;
}
static void fill(unsigned char *bytes, size_t length, unsigned seed) {
    for (size_t i = 0; i < length; i++) bytes[i] = (seed + i * 17) % 251;
}
static void seeded_file(ntfs_fskit_volume *v, uint64_t dir, const char *name, size_t size, unsigned seed) {
    uint64_t ino = create(v, dir, name, NFSK_TYPE_FILE);
    unsigned char *data = malloc(size); require(data != NULL, "seed buffer"); fill(data, size, seed);
    int error = 0; require(nfsk_write(v, ino, 0, data, size, &error) == size && !error, "seed payload"); free(data);
}
static void prepare(const char *path, BOOL largeSeed) {
    int check = regular_file(path, O_RDWR);
    struct stat st;
    require(fstat(check, &st) == 0 && st.st_size > 0 && st.st_size <= MAX_IMAGE, "bounded seed");
    close(check);
    int error = 0; void *backend = nfsk_backend_from_file(path, 1, &error); require(backend != NULL, "seed backend");
    ntfs_fskit_volume *v = nfsk_mount(backend, false, &error); require(v != NULL, "seed mount");
    nfsk_statfs_t stats;
    require(nfsk_statfs(v, &stats) == 0 && !stats.read_only, "writable seed mount");
    int exists = 0; require(nfsk_lookup(v, NFSK_ROOT_INO, "crash-model", &exists) == 0 && exists == ENOENT, "seed namespace is new");
    uint64_t root = create(v, NFSK_ROOT_INO, "crash-model", NFSK_TYPE_DIR);
    seeded_file(v, root, "anchor", 65536, 0x20);
    seeded_file(v, root, "source", 65536, 0x31);
    seeded_file(v, root, "target", 65536, 0x42);
    seeded_file(v, root, "grow", 4096, 0x53);
    seeded_file(v, root, "attrs", 128, 0x64);
    seeded_file(v, root, "delete", 8192, 0x77);
    uint64_t left = create(v, root, "left", NFSK_TYPE_DIR);
    (void)create(v, root, "right", NFSK_TYPE_DIR);
    (void)create(v, root, "busy", NFSK_TYPE_DIR);
    seeded_file(v, left, "move", 4096, 0x88);
    if (largeSeed) seeded_file(v, root, "large", 2 * 1024 * 1024, 0x9a);
    unsigned char small[32], large[32768]; fill(small, sizeof small, 0x65); fill(large, sizeof large, 0x66);
    uint64_t attrs = child(v, root, "attrs");
    require(nfsk_setxattr(v, attrs, "crash.small", small, sizeof small, NFSK_XATTR_SET) == 0, "resident seed xattr");
    require(nfsk_setxattr(v, attrs, "crash.large", large, sizeof large, NFSK_XATTR_SET) == 0, "nonresident seed xattr");
    require(nfsk_sync(v) == 0 && nfsk_umount(v) == 0, "clean seed sync/release"); nfsk_backend_free(backend);
}

static BOOL operation(ntfs_fskit_volume *v, const char *scenario, int64_t *result, int *error) {
    if (!strncmp(scenario, "compressed-", 11)) {
        uint64_t ino = child(v, NFSK_ROOT_INO, "High");
        *error = 0;
        if (!strcmp(scenario, "compressed-grow")) {
            *result = nfsk_truncate(v, ino, 328457);
            return *result == 0;
        }
        require(!strcmp(scenario, "compressed-append"), "known compressed scenario");
        unsigned char tail[700]; memset(tail, 'R', sizeof tail);
        *result = nfsk_write(v, ino, 196731, tail, sizeof tail, error);
        return *result == sizeof tail && !*error;
    }
    uint64_t root = child(v, NFSK_ROOT_INO, "crash-model");
    unsigned char data[65536]; *error = 0; *result = 0;
    if (!strcmp(scenario, "large-overwrite") || !strcmp(scenario, "large-extend")) {
        BOOL extend = !strcmp(scenario, "large-extend");
        size_t count = 1024 * 1024;
        unsigned char *large = malloc(count); require(large != NULL, "bounded large-write input");
        fill(large, count, extend ? 0xc2 : 0xc1);
        *result = nfsk_write(v, child(v, root, extend ? "grow" : "large"), extend ? 4097 : 1, large, count, error);
        free(large);
        return *result == count && !*error;
    }
    if (!strcmp(scenario, "overwrite")) {
        fill(data, 4096, 0x90); *result = nfsk_write(v, child(v, root, "target"), 0, data, 4096, error);
        return *result == 4096 && !*error;
    }
    if (!strcmp(scenario, "create")) {
        uint64_t ino = nfsk_create(v, root, "new-file", NFSK_TYPE_FILE, error);
        if (!ino || *error) { *result = -1; return NO; }
        fill(data, 8192, 0x99); *result = nfsk_write(v, ino, 0, data, 8192, error);
        return *result == 8192 && !*error;
    }
    if (!strcmp(scenario, "extend")) {
        fill(data, 32768, 0xaa); *result = nfsk_write(v, child(v, root, "grow"), 4096, data, 32768, error);
        return *result == 32768 && !*error;
    }
    if (!strcmp(scenario, "truncate")) *result = nfsk_truncate(v, child(v, root, "target"), 2048);
    else if (!strcmp(scenario, "unlink")) *result = nfsk_remove(v, root, "delete");
    else if (!strcmp(scenario, "link")) *result = nfsk_link(v, child(v, root, "source"), root, "alias", error);
    else if (!strcmp(scenario, "rename")) *result = nfsk_rename(v, root, "source", root, "target");
    else if (!strcmp(scenario, "move")) *result = nfsk_rename(v, child(v, root, "left"), "move", child(v, root, "right"), "moved");
    else if (!strcmp(scenario, "xattr-small") || !strcmp(scenario, "xattr-large")) {
        size_t length = !strcmp(scenario, "xattr-small") ? 96 : sizeof data;
        fill(data, length, !strcmp(scenario, "xattr-small") ? 0xb1 : 0xb2);
        *result = nfsk_setxattr(v, child(v, root, "attrs"), !strcmp(scenario, "xattr-small") ? "crash.small" : "crash.large",
                              data, length, NFSK_XATTR_REPLACE);
    } else if (!strcmp(scenario, "index-growth")) {
        uint64_t dir = child(v, root, "busy");
        for (int i = 0; i < 32; i++) {
            char name[96]; snprintf(name, sizeof name, "entry-%03d-abcdefghijklmnopqrstuvwxyz-0123456789", i);
            uint64_t ino = nfsk_create(v, dir, name, NFSK_TYPE_FILE, error);
            if (!ino || *error) { *result = -1; return NO; }
        }
    } else require(NO, "known scenario");
    if (*result < 0 && !*error) *error = (int)-*result;
    return *result == 0 && !*error;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        require(argc >= 3, "mode and regular file arguments");
        if (!strcmp(argv[1], "prepare")) {
            BOOL large = argc == 4 && !strcmp(argv[3], "large");
            require(argc == 3 || large, "prepare optional large seed");
            prepare(argv[2], large); return 0;
        }
        if (!strcmp(argv[1], "probe")) {
            int fd = regular_file(argv[2], O_RDONLY); close(fd);
            int error = 0, reason = 0; void *b = nfsk_backend_from_file(argv[2], 0, &error); require(b != NULL, "probe backend");
            int quick = nfsk_quick_check(b, &reason);
            ntfs_fskit_volume *v = nfsk_mount(b, true, &error); int mounted = v != NULL;
            if (v) (void)nfsk_umount(v); nfsk_backend_free(b);
            printf("{\"quick\":%d,\"reason\":%d,\"readonly_mount\":%d,\"mount_error\":%d}\n", quick, reason, mounted, error);
            return 0;
        }
        require(!strcmp(argv[1], "trace") && argc == 9, "trace args: visible log payload scenario sector disconnect-write fail-flush");
        CrashResource *r = [CrashResource new];
        r.visible = regular_file(argv[2], O_RDWR);
        struct stat st; require(fstat(r.visible, &st) == 0 && st.st_size > 0 && st.st_size <= MAX_IMAGE && st.st_size % 512 == 0, "bounded image");
        r.log = regular_file(argv[3], O_WRONLY | O_CREAT | O_EXCL);
        r.payload = regular_file(argv[4], O_WRONLY | O_CREAT | O_EXCL);
        r.blockSize = 512; r.physicalBlockSize = strtoull(argv[6], NULL, 10); r.blockCount = st.st_size / 512; r.writable = YES;
        require(r.physicalBlockSize == 512 || r.physicalBlockSize == 4096, "model geometry");
        void *b = nfsk_backend_from_block((__bridge void *)r, 1);
        int error = 0; ntfs_fskit_volume *v = nfsk_mount(b, false, &error); require(v != NULL, "trace mount");
        nfsk_statfs_t stats;
        require(nfsk_statfs(v, &stats) == 0 && !stats.read_only, "writable trace mount");
        [r event:@"mounted" values:@{@"writes":@(r.writes), @"flushes":@(r.flushes)}];
        uint64_t failWrite = strtoull(argv[7], NULL, 10), failFlush = strtoull(argv[8], NULL, 10);
        r.disconnectWrite = failWrite ? r.writes + failWrite : 0;
        r.failFlush = failFlush ? r.flushes + failFlush : 0;
        int64_t result = 0; BOOL ok = operation(v, argv[5], &result, &error);
        [r event:@"operation" values:@{@"ok":@(ok), @"result":@(result), @"error":@(error)}];
        int sync = nfsk_sync(v);
        [r event:@"sync-result" values:@{@"result":@(sync), @"disconnected":@(r.disconnected)}];
        if (failWrite || failFlush) {
            uint64_t serviced = r.serviced;
            int retry = nfsk_sync(v);
            uint64_t beforeRelease = r.serviced;
            int release = nfsk_umount(v); nfsk_backend_free(b);
            [r event:@"survived" values:@{@"retry":@(retry), @"release":@(release), @"serviced_before_retry":@(serviced),
                @"serviced_before_release":@(beforeRelease), @"serviced_after_release":@(r.serviced), @"rejected":@(r.rejected)}];
        }
        // Do not umount or run destructors after a healthy trace's final sync.
        // Only the selected trace prefix will be materialized as durable state.
        _exit(0);
    }
}
