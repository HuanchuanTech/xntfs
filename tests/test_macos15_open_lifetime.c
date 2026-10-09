/* Only run on a disposable xntfs volume. No app or registration changes. */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
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

static unsigned long long free_bytes(const char *path) {
    struct statfs info;
    require(statfs(path, &info) == 0, "free space");
    return (unsigned long long)info.f_bfree * info.f_bsize;
}

static void verify_remount(const char *root) {
    DIR *dir = opendir(root);
    require(dir != NULL, "open remounted root");
    int retained = 0, metadata = 0, persisted = 0;
    struct dirent *entry;
    while ((entry = readdir(dir))) {
        if (!strncmp(entry->d_name, ".xntfs-open-", 12)) retained++;
        if (!strncmp(entry->d_name, "alignment-", 10)) {
            char path[PATH_MAX], bytes[32] = {0};
            require(snprintf(path, sizeof path, "%s/%s/metadata", root, entry->d_name) < (int)sizeof path,
                    "metadata path");
            int fd = open(path, O_RDONLY | O_NOFOLLOW);
            struct stat info;
            require(fd >= 0, "open persisted metadata");
            CHECK(read(fd, bytes, sizeof bytes) == 7 && !memcmp(bytes, "payload", 7) &&
                  fstat(fd, &info) == 0 && info.st_birthtimespec.tv_sec == 946684800 &&
                  info.st_blocks * 512 >= 65536, "contents, creation time and preallocation survive remount");
            CHECK(fgetxattr(fd, "user.alignment", bytes, sizeof bytes, 0, 0) == 6 && !memcmp(bytes, "native", 6),
                  "native xattr survives remount");
            require(close(fd) == 0, "close persisted metadata");
            metadata++;
        }
        if (!strncmp(entry->d_name, "lifetime-", 9)) {
            char path[PATH_MAX], bytes[16] = {0};
            require(snprintf(path, sizeof path, "%s/%s/persistent", root, entry->d_name) < (int)sizeof path,
                    "persistent path");
            int fd = open(path, O_RDONLY | O_NOFOLLOW);
            require(fd >= 0, "open persistent file");
            CHECK(read(fd, bytes, sizeof bytes) == 7 && !memcmp(bytes, "persist", 7),
                  "normal file survives lifecycle tests and remount");
            require(close(fd) == 0, "close persistent file");
            persisted++;
        }
    }
    require(closedir(dir) == 0, "close remounted root");
    CHECK(metadata == 1 && persisted == 1, "both isolated test directories survive remount");
    CHECK(retained == 0, "final close leaves no on-disk retention links after remount");
}

int main(int argc, char **argv) {
    if (argc != 3 || (strcmp(argv[1], "rw") && strcmp(argv[1], "verify"))) return 2;
    if (__builtin_available(macOS 26.0, *)) {
        fprintf(stderr, "This suite requires the macOS 15 native lifecycle branch.\n");
        return 2;
    }
    struct statfs filesystem;
    require(statfs(argv[2], &filesystem) == 0 && !strcmp(filesystem.f_fstypename, "xntfs"), "xntfs mount required");
    if (!strcmp(argv[1], "verify")) {
        require(filesystem.f_flags & MNT_RDONLY, "read-only verification mount required");
        verify_remount(argv[2]);
    } else {
        require(!(filesystem.f_flags & MNT_RDONLY), "writable test mount required");
        char directory[PATH_MAX];
        require(snprintf(directory, sizeof directory, "%s/lifetime-XXXXXX", argv[2]) < (int)sizeof directory &&
                mkdtemp(directory) && chdir(directory) == 0, "isolated test directory");
        int writer = open("multi-open", O_CREAT | O_EXCL | O_RDWR, 0600);
        require(writer >= 0, "open multi-handle fixture");
        char block[65536];
        memset(block, 'a', sizeof block);
        for (int i = 0; i < 128; i++) require(write(writer, block, sizeof block) == sizeof block, "write 8 MiB fixture");
        require(fsync(writer) == 0, "flush fixture");
        int reader = open("multi-open", O_RDONLY);
        require(reader >= 0 && fcntl(reader, F_NOCACHE, 1) == 0, "open independent uncached reader");
        unsigned long long allocated = free_bytes(argv[2]);
        CHECK(unlink("multi-open") == 0, "unlink while two descriptors are open");
        struct stat info;
        CHECK(fstat(reader, &info) == 0 && info.st_nlink == 0 && info.st_size == 8 * 1024 * 1024,
              "native open-unlink reports zero links and preserves size");
        CHECK(pwrite(writer, "z", 1, 0) == 1 && fsync(writer) == 0, "unlinked writer still flushes data");
        require(close(writer) == 0, "close only writer");
        char byte = 0;
        CHECK(pread(reader, &byte, 1, 0) == 1 && byte == 'z', "closing writer preserves remaining reader");
        require(close(reader) == 0, "final close");
        unsigned long long released = 0;
        for (int attempt = 0; attempt < 100; attempt++) {
            unsigned long long now = free_bytes(argv[2]);
            released = now > allocated ? now - allocated : 0;
            if (released >= 7 * 1024 * 1024) break;
            usleep(100000);
        }
        CHECK(released >= 7 * 1024 * 1024, "final close releases allocated clusters (within 10 seconds)");

        int fd = open("mapped", O_CREAT | O_EXCL | O_RDWR, 0600);
        require(fd >= 0 && ftruncate(fd, 65536) == 0 && pwrite(fd, "m", 1, 65535) == 1 && fsync(fd) == 0,
                "prepare mmap fixture");
        unsigned char *mapping = mmap(NULL, 65536, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        require(mapping != MAP_FAILED && close(fd) == 0, "retain mapping after descriptor close");
        CHECK(unlink("mapped") == 0 && mapping[65535] == 'm', "mmap survives descriptor close and unlink");
        mapping[0] = 'n';
        CHECK(msync(mapping, 65536, MS_SYNC) == 0, "unlinked shared mapping remains writable");
        require(munmap(mapping, 65536) == 0, "release final mapping");

        require(mkdir("parent", 0700) == 0, "create removable parent");
        fd = open("parent/child", O_CREAT | O_EXCL | O_RDWR, 0600);
        require(fd >= 0 && write(fd, "c", 1) == 1 && fsync(fd) == 0, "create held child");
        CHECK(unlink("parent/child") == 0 && rmdir("parent") == 0 && pread(fd, &byte, 1, 0) == 1 && byte == 'c',
              "open child does not prevent removing its old parent directory");
        require(close(fd) == 0, "close held child");

        fd = open("persistent", O_CREAT | O_EXCL | O_RDWR, 0600);
        require(fd >= 0 && write(fd, "persist", 7) == 7 && fsync(fd) == 0 && close(fd) == 0,
                "persistent control file");
    }
    printf("%d macOS 15 lifetime checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
