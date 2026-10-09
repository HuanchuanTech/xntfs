/* Run only on a disposable, writable xntfs test volume. */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>

static int checks, failures;
#define CHECK(ok, message) do { checks++; if (!(ok)) { failures++; \
    fprintf(stderr, "FAIL: %s (errno=%d: %s)\n", message, errno, strerror(errno)); } \
    else printf("PASS: %s\n", message); } while (0)
static void require(int ok, const char *message) {
    if (!ok) { perror(message); exit(2); }
}
static int payload(int fd, const char *expected) {
    char buffer[64] = {0};
    return pread(fd, buffer, sizeof buffer, 0) == (ssize_t)strlen(expected) && !strcmp(buffer, expected);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc != 2 && argc != 3) return 2;
    struct statfs filesystem;
    require(statfs(argv[1], &filesystem) == 0, "statfs");
    printf("Mounted type=%s source=%s flags=%x\n", filesystem.f_fstypename, filesystem.f_mntfromname, filesystem.f_flags);
    require(!strcmp(filesystem.f_fstypename, "xntfs") && !(filesystem.f_flags & MNT_RDONLY), "writable xntfs volume required");
    if (argc == 3) {
        struct attrlist request = { .bitmapcount = ATTR_BIT_MAP_COUNT, .volattr = ATTR_VOL_INFO | ATTR_VOL_NAME };
        struct { attrreference_t reference; char name[128]; } value = {0};
        require(strlen(argv[2]) < sizeof value.name, "test label length");
        strcpy(value.name, argv[2]);
        value.reference.attr_dataoffset = sizeof value.reference;
        value.reference.attr_length = (uint32_t)strlen(value.name) + 1;
        CHECK(setattrlist(argv[1], &request, &value, sizeof value, 0) == 0, "volume label rename through setattrlist");
        return failures ? 1 : 0;
    }
    char directory[PATH_MAX];
    require(snprintf(directory, sizeof directory, "%s/alignment-XXXXXX", argv[1]) < (int)sizeof directory &&
            mkdtemp(directory) && chdir(directory) == 0, "new isolated test directory");
    printf("Test directory=%s\n", directory);
    struct stat attributes = {0};

    int fd = open("open-unlink", O_CREAT | O_EXCL | O_RDWR, 0666);
    require(fd >= 0 && write(fd, "old", 3) == 3 && fsync(fd) == 0, "open-unlink fixture");
    (void)fcntl(fd, F_NOCACHE, 1);
    CHECK(unlink("open-unlink") == 0 && access("open-unlink", F_OK) == -1 && errno == ENOENT, "unlink removes pathname");
    CHECK(payload(fd, "old") && fstat(fd, &attributes) == 0,
          "open descriptor remains readable and stat-able");
    printf("Observed open-unlink st_nlink=%u (macOS 26+ uses FSKit emulation)\n", attributes.st_nlink);
    CHECK(pwrite(fd, "new", 3, 0) == 3 && fsync(fd) == 0 && payload(fd, "new"), "unlinked open descriptor remains writable");
    require(close(fd) == 0, "close unlinked descriptor");

    fd = open("destination", O_CREAT | O_EXCL | O_RDWR, 0666);
    int source = open("source", O_CREAT | O_EXCL | O_RDWR, 0666);
    require(fd >= 0 && source >= 0 && write(fd, "old", 3) == 3 && write(source, "source", 6) == 6 &&
            fsync(fd) == 0 && fsync(source) == 0 && close(source) == 0, "overwrite fixtures");
    (void)fcntl(fd, F_NOCACHE, 1);
    CHECK(rename("source", "destination") == 0 && payload(fd, "old"), "rename replacement preserves the old open descriptor");
    source = open("destination", O_RDONLY);
    CHECK(source >= 0 && payload(source, "source"), "replacement pathname reads the new contents");
    if (source >= 0) close(source);
    require(close(fd) == 0, "close overwritten descriptor");

    fd = open("metadata", O_CREAT | O_EXCL | O_RDWR, 0666);
    require(fd >= 0 && write(fd, "payload", 7) == 7 && fsync(fd) == 0, "metadata fixture");
    struct attrlist request = { .bitmapcount = ATTR_BIT_MAP_COUNT, .commonattr = ATTR_CMN_CRTIME | ATTR_CMN_MODTIME };
    struct { struct timespec birth, modified; } times = { { 946684800, 123456700 }, { 946684801, 0 } };
    CHECK(setattrlist("metadata", &request, &times, sizeof times, 0) == 0 && stat("metadata", &attributes) == 0 &&
          attributes.st_birthtimespec.tv_sec == times.birth.tv_sec && attributes.st_birthtimespec.tv_nsec == times.birth.tv_nsec &&
          attributes.st_mtimespec.tv_sec == times.modified.tv_sec, "native creation/modification timestamps round-trip through syscalls");
    CHECK(chflags("metadata", UF_HIDDEN) == 0 && stat("metadata", &attributes) == 0 && (attributes.st_flags & UF_HIDDEN),
          "UF_HIDDEN is visible through stat");
    CHECK(chflags("metadata", 0) == 0 && stat("metadata", &attributes) == 0 && !(attributes.st_flags & UF_HIDDEN), "hidden flag can be cleared");
    CHECK(fsetxattr(fd, "user.alignment", "native", 6, 0, 0) == 0, "native xattrs still work");
    CHECK(symlink("metadata", "relative-link") == 0 && symlink("/some/target", "absolute-link") == 0, "symlink creation works through the kernel");
    char target[128] = {0};
    CHECK(readlink("relative-link", target, sizeof target) == 8 && !memcmp(target, "metadata", 8), "relative symlink target preserved");
    CHECK(readlink("absolute-link", target, sizeof target) == 12 && !memcmp(target, "/some/target", 12), "absolute symlink target preserved");
    CHECK(stat("relative-link", &attributes) == 0 && attributes.st_size == 7, "relative symlink follows to its target");

    fstore_t allocation = { .fst_flags = F_ALLOCATEALL | F_ALLOCATEPERSIST, .fst_posmode = F_PEOFPOSMODE, .fst_length = 65536 };
    CHECK(fcntl(fd, F_PREALLOCATE, &allocation) == 0 && allocation.fst_bytesalloc >= 65536,
          "F_PREALLOCATE reserves persistent storage");
    errno = 0;
    int stat_result = fstat(fd, &attributes), stat_error = errno;
    char allocated_contents[64] = {0};
    errno = 0;
    ssize_t allocated_read = pread(fd, allocated_contents, sizeof allocated_contents, 0);
    int read_error = errno;
    printf("Immediate preallocation: allocated=%lld stat=%d errno=%d size=%lld blocks=%lld read=%lld errno=%d payload=%d\n",
           (long long)allocation.fst_bytesalloc, stat_result, stat_error,
           (long long)attributes.st_size, (long long)attributes.st_blocks,
           (long long)allocated_read, read_error, allocated_read == 7 && !memcmp(allocated_contents, "payload", 7));
    CHECK(stat_result == 0 && attributes.st_size == 7 && attributes.st_blocks * 512 >= 65536 &&
          allocated_read == 7 && !memcmp(allocated_contents, "payload", 7),
          "preallocation preserves EOF and contents and reports actual storage");
    struct stat after_read = {0};
    int after_read_result = fstat(fd, &after_read);
    printf("After read: stat=%d size=%lld blocks=%lld\n", after_read_result,
           (long long)after_read.st_size, (long long)after_read.st_blocks);
    int sync_result = fsync(fd);
    struct stat after_sync = {0};
    int after_sync_result = fstat(fd, &after_sync);
    printf("After fsync: sync=%d stat=%d size=%lld blocks=%lld\n", sync_result, after_sync_result,
           (long long)after_sync.st_size, (long long)after_sync.st_blocks);
    require(close(fd) == 0, "close preallocated descriptor");
    CHECK(stat("metadata", &attributes) == 0 && attributes.st_size == 7 && attributes.st_blocks * 512 >= 65536,
          "persistent preallocation survives close");

    fd = open("sparse", O_CREAT | O_EXCL | O_RDWR, 0666);
    require(fd >= 0 && ftruncate(fd, 3 * 1024 * 1024) == 0 && pwrite(fd, "data", 4, 1024 * 1024) == 4 && fsync(fd) == 0, "sparse fixture");
    if (__builtin_available(macOS 27.0, *)) {
        CHECK(lseek(fd, 0, SEEK_DATA) == 1024 * 1024, "SEEK_DATA skips leading sparse hole");
        CHECK(lseek(fd, 0, SEEK_HOLE) == 0, "SEEK_HOLE recognizes current hole");
        require(fstat(fd, &attributes) == 0, "sparse allocation size");
        off_t hole = lseek(fd, 1024 * 1024, SEEK_HOLE);
        printf("Observed sparse allocation=%lld hole=%lld\n", (long long)attributes.st_blocks * 512, (long long)hole);
        CHECK(hole == 1024 * 1024 + attributes.st_blocks * 512, "SEEK_HOLE finds end of actual data run");
        CHECK(lseek(fd, 2 * 1024 * 1024, SEEK_DATA) == -1 && errno == ENXIO, "SEEK_DATA beyond final data returns ENXIO");
    } else {
        printf("SKIP: native sparse-region queries require macOS 27\n");
    }
    require(close(fd) == 0, "close sparse descriptor");
    printf("%d mounted checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
