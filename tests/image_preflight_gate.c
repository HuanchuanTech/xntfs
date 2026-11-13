#include "image_preflight_gate.h"
#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t condition = PTHREAD_COND_INITIALIZER;
static dev_t device;
static ino_t inode;
static bool armed, entered, released, hold, fail;
static unsigned delay_ms, reads, closes, main_reads;
static uint64_t requested_bytes;

int image_gate_arm(const char *path, int should_hold, unsigned delay, int should_fail) {
    struct stat st;
    if (stat(path, &st) || !S_ISREG(st.st_mode)) return -1;
    pthread_mutex_lock(&lock);
    device = st.st_dev; inode = st.st_ino;
    armed = true; entered = released = false;
    hold = should_hold; fail = should_fail; delay_ms = delay;
    reads = closes = main_reads = 0; requested_bytes = 0;
    pthread_mutex_unlock(&lock);
    return 0;
}
void image_gate_release(void) {
    pthread_mutex_lock(&lock); released = true;
    pthread_cond_broadcast(&condition); pthread_mutex_unlock(&lock);
}
void image_gate_clear(void) {
    pthread_mutex_lock(&lock); armed = false; released = true;
    pthread_cond_broadcast(&condition); pthread_mutex_unlock(&lock);
}
#define COUNTER(name, type, value) type name(void) { \
    pthread_mutex_lock(&lock); type result = value; pthread_mutex_unlock(&lock); return result; }
COUNTER(image_gate_entered, unsigned, entered)
COUNTER(image_gate_reads, unsigned, reads)
COUNTER(image_gate_closes, unsigned, closes)
COUNTER(image_gate_main_reads, unsigned, main_reads)
COUNTER(image_gate_requested_bytes, uint64_t, requested_bytes)

static bool matches(const struct stat *st) { return armed && st->st_dev == device && st->st_ino == inode; }
static bool before_read(int fd, size_t count) {
    struct stat st;
    if (fstat(fd, &st)) return false;
    pthread_mutex_lock(&lock);
    if (!matches(&st)) { pthread_mutex_unlock(&lock); return false; }
    reads++; requested_bytes += count; main_reads += pthread_main_np() != 0;
    if (!entered) {
        entered = true;
        if (hold) {
            while (!released) pthread_cond_wait(&condition, &lock);
        } else if (delay_ms) {
            struct timespec end;
            clock_gettime(CLOCK_REALTIME, &end);
            end.tv_sec += delay_ms / 1000;
            end.tv_nsec += (delay_ms % 1000) * 1000000L;
            if (end.tv_nsec >= 1000000000L) { end.tv_sec++; end.tv_nsec -= 1000000000L; }
            while (!released && pthread_cond_timedwait(&condition, &lock, &end) == 0) {}
        }
    }
    bool result = fail;
    pthread_mutex_unlock(&lock);
    if (result) errno = EIO;
    return result;
}
static void before_close(int fd) {
    struct stat st;
    if (fstat(fd, &st)) return;
    pthread_mutex_lock(&lock); if (matches(&st)) closes++; pthread_mutex_unlock(&lock);
}
extern ssize_t read_nocancel(int, void *, size_t) __asm("_read$NOCANCEL");
extern int close_nocancel(int) __asm("_close$NOCANCEL");
static ssize_t gated_read(int fd, void *buffer, size_t count) { return before_read(fd, count) ? -1 : read(fd, buffer, count); }
static ssize_t gated_read_nocancel(int fd, void *buffer, size_t count) { return before_read(fd, count) ? -1 : read_nocancel(fd, buffer, count); }
static ssize_t gated_pread(int fd, void *buffer, size_t count, off_t offset) { return before_read(fd, count) ? -1 : pread(fd, buffer, count, offset); }
static int gated_close(int fd) { before_close(fd); return close(fd); }
static int gated_close_nocancel(int fd) { before_close(fd); return close_nocancel(fd); }
#define INTERPOSE(replacement, original) \
    __attribute__((used, section("__DATA,__interpose"))) \
    static const struct { const void *replace; const void *original; } interpose_##replacement = \
        { (const void *)(replacement), (const void *)(original) }
INTERPOSE(gated_read, read);
INTERPOSE(gated_read_nocancel, read_nocancel);
INTERPOSE(gated_pread, pread);
INTERPOSE(gated_close, close);
INTERPOSE(gated_close_nocancel, close_nocancel);
