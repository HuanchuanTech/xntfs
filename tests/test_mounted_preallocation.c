/* Diagnostic probe: use only a disposable xntfs image or an explicit APFS control directory. */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/xattr.h>
#include <unistd.h>

static int checks, failures;
static const off_t requested = 65536;
static const char *case_name;

static void require(int ok, const char *message) {
    if (!ok) { perror(message); exit(2); }
}

static void check(int ok, const char *message) {
    checks++;
    if (!ok) failures++;
    printf("%s case=%s %s\n", ok ? "PASS" : "FAIL", case_name, message);
}

static void stamp(const char *phase) {
    struct timeval now;
    require(gettimeofday(&now, NULL) == 0, "gettimeofday");
    printf("PHASE case=%s phase=%s epoch=%lld.%06d\n", case_name, phase,
           (long long)now.tv_sec, now.tv_usec);
}

static struct stat observe_stat(const char *phase, int fd, const char *path) {
    struct stat value = {0};
    errno = 0;
    int rc = fd >= 0 ? fstat(fd, &value) : stat(path, &value);
    int error = errno;
    printf("STAT case=%s phase=%s via=%s rc=%d errno=%d inode=%llu size=%lld blocks=%lld bytes=%lld\n",
           case_name, phase, fd >= 0 ? "fd" : "path", rc, error,
           (unsigned long long)value.st_ino, (long long)value.st_size,
           (long long)value.st_blocks, (long long)value.st_blocks * 512);
    require(rc == 0, "stat probe");
    return value;
}

static void observe_attr(const char *phase, int fd, const char *path, attrgroup_t bit) {
    struct attrlist request = {
        .bitmapcount = ATTR_BIT_MAP_COUNT,
        .commonattr = ATTR_CMN_RETURNED_ATTRS,
        .fileattr = bit
    };
    struct { uint32_t length; attribute_set_t returned; off_t value; } reply = {0};
    errno = 0;
    int rc = fd >= 0
        ? fgetattrlist(fd, &request, &reply, sizeof reply, FSOPT_PACK_INVAL_ATTRS)
        : getattrlist(path, &request, &reply, sizeof reply, FSOPT_PACK_INVAL_ATTRS);
    int error = errno;
    printf("ATTR case=%s phase=%s via=%s bit=0x%x rc=%d errno=%d returned=0x%x length=%u value=%lld\n",
           case_name, phase, fd >= 0 ? "fd" : "path", bit, rc, error,
           reply.returned.fileattr, reply.length, (long long)reply.value);
}

static void observe(const char *phase, int fd, const char *path) {
    stamp(phase);
    if (fd >= 0) (void)observe_stat(phase, fd, path);
    (void)observe_stat(phase, -1, path);
    observe_attr(phase, fd, path, ATTR_FILE_ALLOCSIZE);
    observe_attr(phase, fd, path, ATTR_FILE_DATAALLOCSIZE);
    if (fd >= 0) {
        observe_attr(phase, -1, path, ATTR_FILE_ALLOCSIZE);
        (void)observe_stat("after-attribute-queries", fd, path);
    }
}

static int has_payload(int fd, size_t size) {
    unsigned char data[8193] = {0};
    ssize_t n = pread(fd, data, sizeof data, 0);
    if (n != (ssize_t)size) return 0;
    for (size_t i = 0; i < size; i++)
        if (data[i] != (unsigned char)('a' + i % 26)) return 0;
    return 1;
}

struct scenario { const char *name; size_t size; int warm, metadata, keep_reader, reopen_first, write_only; };
static const struct scenario scenarios[] = {
    { "small-warm-1", 7, 1, 0, 0, 0, 0 },
    { "small-warm-2", 7, 1, 0, 0, 0, 0 },
    { "small-warm-3", 7, 1, 0, 0, 0, 0 },
    { "large-warm", 8192, 1, 0, 0, 0, 0 },
    { "small-metadata", 7, 1, 1, 0, 0, 0 },
    { "small-cold", 7, 0, 0, 0, 0, 0 },
    { "small-reader-held", 7, 1, 0, 1, 0, 0 },
    { "existing-small", 7, 1, 0, 0, 1, 0 },
    { "existing-large", 8192, 1, 0, 0, 1, 0 },
    { "ordinary-write", 8192, 1, 0, 0, 0, 1 }
};

static void run_case(const struct scenario *s) {
    case_name = s->name;
    stamp("begin");
    int fd = open(s->name, O_CREAT | O_EXCL | O_RDWR, 0600);
    require(fd >= 0, "create fixture");
    unsigned char data[8192];
    for (size_t i = 0; i < s->size; i++) data[i] = (unsigned char)('a' + i % 26);
    require(write(fd, data, s->size) == (ssize_t)s->size && fsync(fd) == 0, "write fixture");
    if (s->metadata) {
        struct attrlist request = { .bitmapcount = ATTR_BIT_MAP_COUNT, .commonattr = ATTR_CMN_CRTIME | ATTR_CMN_MODTIME };
        struct { struct timespec birth, modified; } times = { { 946684800, 0 }, { 946684801, 0 } };
        require(setattrlist(s->name, &request, &times, sizeof times, 0) == 0 &&
                chflags(s->name, UF_HIDDEN) == 0 && chflags(s->name, 0) == 0 &&
                fsetxattr(fd, "user.preallocation", "native", 6, 0, 0) == 0, "metadata fixture");
    }
    if (s->reopen_first) {
        require(close(fd) == 0, "close before allocation");
        fd = open(s->name, O_RDWR);
        require(fd >= 0, "reopen before allocation");
    }
    int reader = -1;
    if (s->keep_reader) {
        reader = open(s->name, O_RDONLY);
        require(reader >= 0, "open retained reader");
    }
    if (s->warm) observe("before-allocation", fd, s->name);
    fstore_t allocation = {
        .fst_flags = F_ALLOCATEALL | F_ALLOCATEPERSIST,
        .fst_posmode = F_PEOFPOSMODE,
        .fst_length = requested
    };
    off_t minimum = s->write_only ? (off_t)s->size : requested;
    if (!s->write_only) {
        stamp("preallocate");
        errno = 0;
        int rc = fcntl(fd, F_PREALLOCATE, &allocation), error = errno;
        printf("ALLOC case=%s rc=%d errno=%d requested=%lld allocated=%lld\n",
               case_name, rc, error, (long long)requested, (long long)allocation.fst_bytesalloc);
        check(rc == 0 && allocation.fst_bytesalloc >= requested, "preallocation return value");
    } else {
        printf("CONTROL case=%s ordinary write only, F_PREALLOCATE was not called\n", case_name);
    }
    struct stat immediate = observe_stat("immediate-before-other-queries", fd, s->name);
    check(immediate.st_size == (off_t)s->size, "immediate logical EOF preserved");
    check(immediate.st_blocks * 512 >= minimum, "immediate allocation reporting");
    observe("immediate", fd, s->name);
    check(has_payload(fd, s->size), "payload preserved");
    observe("after-read", fd, s->name);
    require(fsync(fd) == 0, "fsync preallocated file");
    observe("after-fsync", fd, s->name);
    sleep(3);
    observe("after-three-seconds", fd, s->name);

    if (reader < 0) {
        reader = open(s->name, O_RDONLY);
        require(reader >= 0, "open second reader");
    }
    observe("second-reader", reader, s->name);
    (void)observe_stat("writer-after-reader-open", fd, s->name);
    int duplicate = dup(fd);
    require(duplicate >= 0 && close(duplicate) == 0, "close dup");
    observe("after-dup-close", fd, s->name);
    if (!s->keep_reader) {
        require(close(reader) == 0, "close second reader");
        reader = -1;
        observe("after-reader-close", fd, s->name);
    }
    require(close(fd) == 0, "close writer");
    observe("after-writer-close", reader, s->name);
    if (reader >= 0) {
        check(has_payload(reader, s->size), "held reader payload after writer close");
        require(close(reader) == 0, "close retained reader");
    }
    struct stat closed = observe_stat("after-all-close", -1, s->name);
    check(closed.st_size == (off_t)s->size && closed.st_blocks * 512 >= minimum,
          "persistent allocation after final close");
    fd = open(s->name, O_RDONLY);
    require(fd >= 0, "reopen");
    observe("reopened", fd, s->name);
    check(has_payload(fd, s->size), "reopened payload preserved");
    require(close(fd) == 0, "close reopened file");
    stamp("end");
}

static void verify_directory(void) {
    for (size_t i = 0; i < sizeof scenarios / sizeof scenarios[0]; i++) {
        const struct scenario *s = &scenarios[i];
        case_name = s->name;
        struct stat attributes = observe_stat("read-only-remount", -1, s->name);
        off_t minimum = s->write_only ? (off_t)s->size : requested;
        check(attributes.st_size == (off_t)s->size && attributes.st_blocks * 512 >= minimum,
              "remounted EOF and allocation");
        int fd = open(s->name, O_RDONLY);
        require(fd >= 0, "open remounted file");
        check(has_payload(fd, s->size), "remounted payload");
        require(close(fd) == 0, "close remounted file");
    }
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc != 3) { fprintf(stderr, "Usage: %s rw|verify-ro|control DIRECTORY\n", argv[0]); return 2; }
    int verify = !strcmp(argv[1], "verify-ro"), control = !strcmp(argv[1], "control");
    if (!verify && !control && strcmp(argv[1], "rw")) return 2;
    require(geteuid() != 0, "run as an ordinary user");
    struct statfs filesystem;
    require(statfs(argv[2], &filesystem) == 0, "statfs");
    printf("MOUNT type=%s source=%s flags=%x mode=%s\n", filesystem.f_fstypename,
           filesystem.f_mntfromname, filesystem.f_flags, argv[1]);
    require(!strcmp(filesystem.f_fstypename, control ? "apfs" : "xntfs"), "unexpected filesystem");
    require(!!(filesystem.f_flags & MNT_RDONLY) == verify, "unexpected mount mode");
    require(chdir(argv[2]) == 0, "enter supplied directory");
    if (verify) {
        DIR *directory = opendir(".");
        require(directory != NULL, "open volume root");
        struct dirent *entry;
        char name[NAME_MAX + 1] = {0};
        int found = 0;
        while ((entry = readdir(directory))) {
            if (!strncmp(entry->d_name, "preallocation-probe-", 20)) {
                require(++found == 1, "ambiguous test directories");
                memcpy(name, entry->d_name, strlen(entry->d_name) + 1);
            }
        }
        require(closedir(directory) == 0 && found == 1 && chdir(name) == 0, "find previous test directory");
        verify_directory();
    } else {
        char directory[] = "preallocation-probe-XXXXXX";
        require(mkdtemp(directory) != NULL && chdir(directory) == 0, "create isolated directory");
        printf("DIRECTORY %s/%s\n", argv[2], directory);
        for (size_t i = 0; i < sizeof scenarios / sizeof scenarios[0]; i++) run_case(&scenarios[i]);
    }
    printf("SUMMARY checks=%d failures=%d\n", checks, failures);
    return failures ? 1 : 0;
}
