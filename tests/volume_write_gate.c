#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <time.h>
#include <unistd.h>
#include "volume_write_gate.h"
#include <ntfs-3g/volume.h>
#include <ntfs-3g/inode.h>

static pthread_mutex_t inode_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t fail_open = UINT64_MAX, fail_close = UINT64_MAX;
static int inode_faults;
void nfsk_test_fail_inode_open(uint64_t ino) {
    pthread_mutex_lock(&inode_lock); fail_open = ino == NFSK_ROOT_INO ? FILE_root : ino; pthread_mutex_unlock(&inode_lock);
}
void nfsk_test_fail_inode_close(uint64_t ino) {
    pthread_mutex_lock(&inode_lock); fail_close = ino == NFSK_ROOT_INO ? FILE_root : ino; pthread_mutex_unlock(&inode_lock);
}
int nfsk_test_inode_faults(void) {
    pthread_mutex_lock(&inode_lock); int n = inode_faults; pthread_mutex_unlock(&inode_lock); return n;
}
static int fail_inode(uint64_t *fault, uint64_t ino) {
    pthread_mutex_lock(&inode_lock);
    int fail = *fault == ino;
    if (fail) { *fault = UINT64_MAX; inode_faults++; }
    pthread_mutex_unlock(&inode_lock);
    if (fail) errno = EIO;
    return fail;
}
ntfs_inode *nfsk_test_inode_open(ntfs_volume *v, MFT_REF ref) {
    return fail_inode(&fail_open, MREF(ref)) ? NULL : ntfs_inode_open(v, ref);
}
int nfsk_test_inode_close(ntfs_inode *ni) {
    return fail_inode(&fail_close, ni->mft_no) ? -1 : ntfs_inode_close(ni);
}
int nfsk_test_inode_real_close(ntfs_inode *ni) {
    return fail_inode(&fail_close, ni->mft_no) ? -1 : ntfs_inode_real_close(ni);
}

// Only the test copy of the file backend redirects pwrite to this function.
static pthread_mutex_t gate_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gate_changed = PTHREAD_COND_INITIALIZER;
static bool armed, entered;
static bool fail_next_sync;

void nfsk_test_fail_next_sync(void) {
    pthread_mutex_lock(&gate_lock);
    fail_next_sync = true;
    pthread_mutex_unlock(&gate_lock);
}

int nfsk_test_fsync(int fd) {
    pthread_mutex_lock(&gate_lock);
    bool fail = fail_next_sync;
    fail_next_sync = false;
    pthread_mutex_unlock(&gate_lock);
    if (fail) { errno = EIO; return -1; }
    return fsync(fd);
}

void nfsk_test_arm_write(void) {
    pthread_mutex_lock(&gate_lock);
    entered = false;
    armed = true;
    pthread_mutex_unlock(&gate_lock);
}

int nfsk_test_wait_for_write(void) {
    struct timespec until;
    clock_gettime(CLOCK_REALTIME, &until);
    until.tv_sec += 5;
    pthread_mutex_lock(&gate_lock);
    while (!entered) {
        if (pthread_cond_timedwait(&gate_changed, &gate_lock, &until) == ETIMEDOUT) break;
    }
    int result = entered;
    pthread_mutex_unlock(&gate_lock);
    return result;
}

void nfsk_test_release_write(void) {
    pthread_mutex_lock(&gate_lock);
    armed = false;
    pthread_cond_broadcast(&gate_changed);
    pthread_mutex_unlock(&gate_lock);
}

ssize_t nfsk_test_pwrite(int fd, const void *buffer, size_t count, off_t offset) {
    pthread_mutex_lock(&gate_lock);
    if (armed) {
        entered = true;
        pthread_cond_broadcast(&gate_changed);
        while (armed) pthread_cond_wait(&gate_changed, &gate_lock);
    }
    pthread_mutex_unlock(&gate_lock);
    return pwrite(fd, buffer, count, offset);
}

static pthread_mutex_t read_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t read_changed = PTHREAD_COND_INITIALIZER;
static bool read_armed, read_entered;

void nfsk_test_arm_read(void) {
    pthread_mutex_lock(&read_lock);
    read_entered = false;
    read_armed = true;
    pthread_mutex_unlock(&read_lock);
}

int nfsk_test_wait_for_read(void) {
    struct timespec until;
    clock_gettime(CLOCK_REALTIME, &until);
    until.tv_sec += 5;
    pthread_mutex_lock(&read_lock);
    while (!read_entered) {
        if (pthread_cond_timedwait(&read_changed, &read_lock, &until) == ETIMEDOUT) break;
    }
    int result = read_entered;
    pthread_mutex_unlock(&read_lock);
    return result;
}

void nfsk_test_release_read(void) {
    pthread_mutex_lock(&read_lock);
    read_armed = false;
    pthread_cond_broadcast(&read_changed);
    pthread_mutex_unlock(&read_lock);
}

ssize_t nfsk_test_pread(int fd, void *buffer, size_t count, off_t offset) {
    pthread_mutex_lock(&read_lock);
    if (read_armed) {
        read_entered = true;
        pthread_cond_broadcast(&read_changed);
        while (read_armed) pthread_cond_wait(&read_changed, &read_lock);
    }
    pthread_mutex_unlock(&read_lock);
    return pread(fd, buffer, count, offset);
}
