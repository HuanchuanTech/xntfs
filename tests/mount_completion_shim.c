#include "mount_completion_shim.h"
#include <assert.h>
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <string.h>

enum { MAX_PENDING = 4 };
static struct request {
    DADiskRef disk;
    DADiskMountCallback callback;
    void *context;
} pending[MAX_PENDING];
static bool read_only[MAX_PENDING];
static uint32_t submissions, completions;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

void xntfs_mount_fixture_reset(void) {
    pthread_mutex_lock(&lock);
    for (unsigned i = 0; i < MAX_PENDING; ++i) assert(!pending[i].disk);
    submissions = completions = 0;
    memset(read_only, 0, sizeof(read_only));
    pthread_mutex_unlock(&lock);
}
uint32_t xntfs_mount_submissions(void) {
    pthread_mutex_lock(&lock); uint32_t n = submissions; pthread_mutex_unlock(&lock); return n;
}
uint32_t xntfs_mount_completions(void) {
    pthread_mutex_lock(&lock); uint32_t n = completions; pthread_mutex_unlock(&lock); return n;
}
uint32_t xntfs_mount_pending(void) {
    pthread_mutex_lock(&lock);
    uint32_t n = 0; for (unsigned i = 0; i < MAX_PENDING; ++i) n += pending[i].disk != NULL;
    pthread_mutex_unlock(&lock); return n;
}
bool xntfs_mount_requested_read_only(uint32_t disk) {
    assert(disk < MAX_PENDING);
    pthread_mutex_lock(&lock); bool value = read_only[disk]; pthread_mutex_unlock(&lock); return value;
}
static void synthetic_mount(DADiskRef disk, CFURLRef path, DADiskMountOptions options,
                            DADiskMountCallback callback, void *context, CFStringRef arguments[]) {
    // host_observation_shim uses CFNumber as a fake DADisk. Never accept a real
    // disk, and never forward any mount submission to DiskArbitration.
    assert(disk && CFGetTypeID(disk) == CFNumberGetTypeID());
    int index = -1;
    assert(CFNumberGetValue((CFNumberRef)disk, kCFNumberIntType, &index));
    assert(index >= 0 && index < MAX_PENDING && !path && options == kDADiskMountOptionDefault);
    assert(callback && context && arguments && arguments[0] && !arguments[1]);
    bool ro = CFEqual(arguments[0], CFSTR("rdonly"));
    assert(ro || CFEqual(arguments[0], CFSTR("rw")));
    pthread_mutex_lock(&lock);
    assert(!pending[index].disk);
    pending[index] = (struct request){ (DADiskRef)CFRetain(disk), callback, context };
    read_only[index] = ro; submissions += 1;
    pthread_mutex_unlock(&lock);
}
void xntfs_mount_finish(uint32_t index, DAReturn status) {
    assert(index < MAX_PENDING);
    pthread_mutex_lock(&lock);
    struct request request = pending[index]; assert(request.disk);
    pending[index] = (struct request){0};
    pthread_mutex_unlock(&lock);
    // Deliver from a non-main serial queue, as the actual continuation bridge
    // must work when the native callback is not running on its caller's executor.
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("test.mount.completion", DISPATCH_QUEUE_SERIAL); });
    dispatch_sync(queue, ^{
        DADissenterRef dissenter = status ? DADissenterCreate(NULL, status, CFSTR("fixture refusal")) : NULL;
        request.callback(request.disk, dissenter, request.context);
        if (dissenter) CFRelease(dissenter);
        CFRelease(request.disk);
    });
    pthread_mutex_lock(&lock); completions += 1; pthread_mutex_unlock(&lock);
}
static void forbidden_mount(DADiskRef disk, CFURLRef path, DADiskMountOptions options,
                            DADiskMountCallback callback, void *context) {
    (void)disk; (void)path; (void)options; (void)callback; (void)context;
    assert(!"Unexpected native mount API in fixture");
}
static void forbidden_unmount(DADiskRef disk, DADiskUnmountOptions options,
                              DADiskUnmountCallback callback, void *context) {
    (void)disk; (void)options; (void)callback; (void)context;
    assert(!"Unexpected native unmount API in fixture");
}
#define INTERPOSE(replacement, original) \
    __attribute__((used, section("__DATA,__interpose"))) \
    static const struct { const void *replacement; const void *original; } interpose_##replacement = \
        { (const void *)(replacement), (const void *)(original) }
INTERPOSE(synthetic_mount, DADiskMountWithArguments);
INTERPOSE(forbidden_mount, DADiskMount);
INTERPOSE(forbidden_unmount, DADiskUnmount);
