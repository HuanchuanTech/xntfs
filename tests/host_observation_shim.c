#include "host_observation_shim.h"
#include <IOKit/IOKitLib.h>
#include <assert.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>

// No real DA registration, device access or mount query escapes this executable.
// Fixed fixture bounds are test data, not limits imposed on the product.
enum { MAX_DISKS = 128, MAX_ENTRIES = 512, MAX_SESSIONS = 8,
       MEDIA_BASE = 0x70000000, ITERATOR_BASE = 0x71000000 };
struct fixture_disk {
    char bsd[32], kind[32];
    int path, writable;
    bool missing, no_description, leaf;
    uint64_t registry;
};
struct fixture_session {
    DASessionRef ref;
    dispatch_queue_t queue;
    DADiskAppearedCallback appeared;
    DADiskDisappearedCallback disappeared;
    DADiskDescriptionChangedCallback changed;
    void *context;
};
static struct fixture_disk disks[MAX_DISKS];
static struct statfs entries[MAX_ENTRIES];
static struct fixture_session sessions[MAX_SESSIONS];
static struct { bool used; uint32_t position; } iterators[MAX_SESSIONS];
static uint32_t disk_count, entry_count;
static int enumeration_failure, enumeration_limit = -1;
static bool enumeration_duplicate;
static atomic_uint enumeration_calls, media_disk_requests, iterators_live, media_live, iterators_peak, media_peak;
static bool fail_table;
static atomic_bool fail_next_table;
static atomic_uint fail_on_mount_call;
static int table_error = EIO;
static bool failure_buffer = true;
static pthread_mutex_t session_lock = PTHREAD_MUTEX_INITIALIZER;
static atomic_uint mount_calls, disk_requests, wrong_flags, session_count, registration_calls;
static atomic_ullong copied_bytes;
static dispatch_semaphore_t gate_entered, gate_release;
static dispatch_once_t gate_once;
static atomic_bool gate_active, hold_next_table, hold_next_enumeration;

static void acquired(atomic_uint *live, atomic_uint *peak) {
#ifndef OBSERVATION_CLEAN_TIMING
    unsigned count = atomic_fetch_add(live, 1) + 1, old = atomic_load(peak);
    while (count > old && !atomic_compare_exchange_weak(peak, &old, count)) {}
#else
    (void)live; (void)peak;
#endif
}
static void released(atomic_uint *live) {
#ifndef OBSERVATION_CLEAN_TIMING
    assert(atomic_fetch_sub(live, 1) > 0);
#else
    (void)live;
#endif
}

static void arm_gate(void) {
    dispatch_once(&gate_once, ^{
        gate_entered = dispatch_semaphore_create(0);
        gate_release = dispatch_semaphore_create(0);
    });
    assert(!atomic_exchange(&gate_active, true));
}
static void wait_in_gate(void) {
    dispatch_semaphore_signal(gate_entered);
    assert(dispatch_semaphore_wait(gate_release, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0);
    atomic_store(&gate_active, false);
}
void xntfs_observation_hold_next_table(void) { arm_gate(); atomic_store(&hold_next_table, true); }
void xntfs_observation_hold_next_enumeration(void) { arm_gate(); atomic_store(&hold_next_enumeration, true); }
void xntfs_observation_wait_held(void) {
    assert(dispatch_semaphore_wait(gate_entered, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0);
}

void xntfs_observation_reset_counts(void) {
    atomic_store(&mount_calls, 0); atomic_store(&disk_requests, 0);
    atomic_store(&wrong_flags, 0); atomic_store(&copied_bytes, 0);
    atomic_store(&enumeration_calls, 0); atomic_store(&media_disk_requests, 0);
}
uint32_t xntfs_observation_mount_calls(void) { return atomic_load(&mount_calls); }
uint32_t xntfs_observation_disk_requests(void) { return atomic_load(&disk_requests); }
uint32_t xntfs_observation_registration_calls(void) { return atomic_load(&registration_calls); }
uint32_t xntfs_observation_wrong_flags(void) { return atomic_load(&wrong_flags); }
uint64_t xntfs_observation_copied_bytes(void) { return atomic_load(&copied_bytes); }
uint32_t xntfs_observation_sessions(void) { return atomic_load(&session_count); }
uint32_t xntfs_observation_enumeration_calls(void) { return atomic_load(&enumeration_calls); }
uint32_t xntfs_observation_media_disk_requests(void) { return atomic_load(&media_disk_requests); }
uint32_t xntfs_observation_iterators_live(void) { return atomic_load(&iterators_live); }
uint32_t xntfs_observation_media_live(void) { return atomic_load(&media_live); }
uint32_t xntfs_observation_iterators_peak(void) { return atomic_load(&iterators_peak); }
uint32_t xntfs_observation_media_peak(void) { return atomic_load(&media_peak); }
void xntfs_observation_set_enumeration(int failure, int limit, bool duplicate) {
    assert(failure >= 0 && failure <= 3 && limit >= -1 && !atomic_load(&iterators_live));
    enumeration_failure = failure; enumeration_limit = limit; enumeration_duplicate = duplicate;
}
void xntfs_observation_reset(uint32_t count, uint32_t table_count) {
    assert(count <= MAX_DISKS && table_count >= count && table_count <= MAX_ENTRIES);
    assert(!atomic_load(&gate_active) && !atomic_load(&hold_next_table) && !atomic_load(&hold_next_enumeration));
    assert(!atomic_load(&iterators_live) && !atomic_load(&media_live));
    atomic_store(&iterators_peak, 0); atomic_store(&media_peak, 0);
    enumeration_failure = 0; enumeration_limit = -1; enumeration_duplicate = false;
    disk_count = count; entry_count = table_count; fail_table = false;
    atomic_store(&fail_next_table, false);
    atomic_store(&fail_on_mount_call, 0);
    table_error = EIO; failure_buffer = true;
    memset(disks, 0, sizeof(disks)); memset(entries, 0, sizeof(entries));
    for (uint32_t i = 0; i < table_count; ++i) {
        snprintf(entries[i].f_mntonname, sizeof(entries[i].f_mntonname), "/Volumes/Synthetic%u", i);
        snprintf(entries[i].f_mntfromname, sizeof(entries[i].f_mntfromname), "/dev/diskTest%u", i);
        strcpy(entries[i].f_fstypename, i < count ? "xntfs" : "apfs");
        entries[i].f_flags = i % 2 ? 0 : MNT_RDONLY;
        if (i < count) {
            snprintf(disks[i].bsd, sizeof(disks[i].bsd), "diskTest%u", i);
            strcpy(disks[i].kind, "msdos"); // Real mounted type must override DA's stale hint.
            disks[i].path = 1; disks[i].writable = 1;
            disks[i].registry = 1000 + i; disks[i].leaf = true;
        }
    }
    xntfs_observation_reset_counts();
}
void xntfs_observation_set_path(uint32_t disk, int path) { assert(disk < disk_count); disks[disk].path = path; }
void xntfs_observation_set_leaf(uint32_t disk, bool leaf) { assert(disk < disk_count); disks[disk].leaf = leaf; }
void xntfs_observation_set_kind(uint32_t disk, const char *kind) {
    assert(disk < disk_count && strlen(kind) < sizeof(disks[disk].kind)); strcpy(disks[disk].kind, kind);
}
void xntfs_observation_set_bsd(uint32_t disk, const char *name) {
    assert(disk < disk_count && strlen(name) < sizeof(disks[disk].bsd));
    strcpy(disks[disk].bsd, name);
}
void xntfs_observation_set_writable(uint32_t disk, int writable) {
    assert(disk < disk_count && writable >= -1 && writable <= 1);
    disks[disk].writable = writable;
}
void xntfs_observation_set_mount(uint32_t disk, const char *type, bool read_only) {
    assert(disk < disk_count && strlen(type) < sizeof(entries[disk].f_fstypename));
    strcpy(entries[disk].f_fstypename, type); entries[disk].f_flags = read_only ? MNT_RDONLY : 0;
}
void xntfs_observation_set_entry(uint32_t entry, const char *source, const char *path, const char *type) {
    assert(entry < entry_count);
    assert(strlen(source) < sizeof(entries[entry].f_mntfromname));
    assert(strlen(path) < sizeof(entries[entry].f_mntonname));
    assert(strlen(type) < sizeof(entries[entry].f_fstypename));
    strcpy(entries[entry].f_mntfromname, source);
    strcpy(entries[entry].f_mntonname, path);
    strcpy(entries[entry].f_fstypename, type);
}
void xntfs_observation_set_missing(uint32_t disk, bool missing, bool no_description) {
    assert(disk < disk_count); disks[disk].missing = missing; disks[disk].no_description = no_description;
}
void xntfs_observation_set_registry(uint32_t disk, uint64_t registry) { assert(disk < disk_count); disks[disk].registry = registry; }
void xntfs_observation_fail_table(bool fail) { fail_table = fail; }
void xntfs_observation_fail_next_table(void) { atomic_store(&fail_next_table, true); }
void xntfs_observation_fail_table_on_call(uint32_t call) { atomic_store(&fail_on_mount_call, call); }
void xntfs_observation_set_table_failure(int error, bool nonnull_buffer) {
    table_error = error; failure_buffer = nonnull_buffer;
}

static struct fixture_session *session(DASessionRef ref) {
    for (unsigned i = 0; i < MAX_SESSIONS; ++i) if (sessions[i].ref == ref) return &sessions[i];
    abort();
}
static DASessionRef synthetic_session(CFAllocatorRef allocator) {
    DASessionRef ref = (DASessionRef)CFDictionaryCreateMutable(allocator, 0, NULL, NULL);
    pthread_mutex_lock(&session_lock);
    unsigned i = 0; while (i < MAX_SESSIONS && sessions[i].ref) ++i;
    assert(i < MAX_SESSIONS); sessions[i].ref = ref;
    atomic_fetch_add(&session_count, 1); pthread_mutex_unlock(&session_lock);
    return ref;
}
static void synthetic_queue(DASessionRef ref, dispatch_queue_t queue) {
    pthread_mutex_lock(&session_lock);
    struct fixture_session *s = session(ref);
    if (s->queue) dispatch_release(s->queue);
    s->queue = queue;
    if (queue) dispatch_retain(queue);
    else { memset(s, 0, sizeof(*s)); atomic_fetch_sub(&session_count, 1); }
    pthread_mutex_unlock(&session_lock);
}
static void register_appeared(DASessionRef ref, CFDictionaryRef match, DADiskAppearedCallback callback, void *context) {
#ifndef OBSERVATION_CLEAN_TIMING
    atomic_fetch_add(&registration_calls, 1);
#endif
    (void)match; pthread_mutex_lock(&session_lock);
    session(ref)->appeared = callback; session(ref)->context = context;
    pthread_mutex_unlock(&session_lock);
}
static void register_disappeared(DASessionRef ref, CFDictionaryRef match, DADiskDisappearedCallback callback, void *context) {
#ifndef OBSERVATION_CLEAN_TIMING
    atomic_fetch_add(&registration_calls, 1);
#endif
    (void)match; pthread_mutex_lock(&session_lock);
    session(ref)->disappeared = callback; session(ref)->context = context;
    pthread_mutex_unlock(&session_lock);
}
static void register_changed(DASessionRef ref, CFDictionaryRef match, CFArrayRef watch, DADiskDescriptionChangedCallback callback, void *context) {
#ifndef OBSERVATION_CLEAN_TIMING
    atomic_fetch_add(&registration_calls, 1);
#endif
    (void)match; (void)watch; pthread_mutex_lock(&session_lock);
    session(ref)->changed = callback; session(ref)->context = context;
    pthread_mutex_unlock(&session_lock);
}
static void unregister_callback(DASessionRef ref, void *callback, void *context) {
    (void)callback; (void)context; pthread_mutex_lock(&session_lock);
    struct fixture_session *s = session(ref);
    s->appeared = NULL; s->disappeared = NULL; s->changed = NULL; s->context = NULL;
    pthread_mutex_unlock(&session_lock);
}
static dispatch_queue_t copy_queue(DASessionRef ref) {
    pthread_mutex_lock(&session_lock);
    dispatch_queue_t queue = session(ref)->queue;
    assert(queue); dispatch_retain(queue); pthread_mutex_unlock(&session_lock);
    return queue;
}
void xntfs_observation_drain(DASessionRef ref) {
    dispatch_queue_t queue = copy_queue(ref); dispatch_sync(queue, ^{}); dispatch_release(queue);
}
void xntfs_observation_hold_queue(DASessionRef ref) {
    arm_gate();
    dispatch_queue_t queue = copy_queue(ref);
    dispatch_async(queue, ^{ wait_in_gate(); });
    dispatch_release(queue);
}
void xntfs_observation_release_and_drain(DASessionRef ref) {
    // Copy before releasing: queued teardown may remove the fixture session.
    dispatch_queue_t queue = copy_queue(ref);
    dispatch_semaphore_signal(gate_release);
    dispatch_sync(queue, ^{});
    dispatch_release(queue);
}
void xntfs_observation_emit(DASessionRef ref, uint32_t disk, int event) {
    assert(disk < disk_count);
    dispatch_queue_t queue = copy_queue(ref);
    dispatch_sync(queue, ^{
        pthread_mutex_lock(&session_lock);
        struct fixture_session s = *session(ref);
        pthread_mutex_unlock(&session_lock);
        int index = (int)disk;
        DADiskRef value = (DADiskRef)CFNumberCreate(NULL, kCFNumberIntType, &index);
        if (event == 0) { assert(s.appeared); s.appeared(value, s.context); }
        else if (event == 1) {
            assert(s.changed);
            CFArrayRef keys = CFArrayCreate(NULL, NULL, 0, NULL);
            s.changed(value, keys, s.context); CFRelease(keys);
        } else { assert(event == 2 && s.disappeared); s.disappeared(value, s.context); }
        CFRelease(value);
    });
    dispatch_release(queue);
}
static unsigned disk_index(DADiskRef ref) {
    int index = -1; assert(CFGetTypeID(ref) == CFNumberGetTypeID());
    CFNumberGetValue((CFNumberRef)ref, kCFNumberIntType, &index);
    assert(index >= 0 && (unsigned)index < disk_count); return (unsigned)index;
}
static DADiskRef synthetic_disk(CFAllocatorRef allocator, DASessionRef ref, const char *name) {
    (void)ref;
#ifndef OBSERVATION_CLEAN_TIMING
    atomic_fetch_add(&disk_requests, 1);
#endif
    for (uint32_t i = 0; i < disk_count; ++i) if (!strcmp(name, disks[i].bsd) && !disks[i].missing) {
        int index = (int)i; return (DADiskRef)CFNumberCreate(allocator, kCFNumberIntType, &index);
    }
    return NULL;
}
static const char *synthetic_bsd(DADiskRef ref) { return disks[disk_index(ref)].bsd; }
static kern_return_t synthetic_matching(mach_port_t port, CFDictionaryRef matching, io_iterator_t *iterator) {
    assert(port == kIOMainPortDefault);
    CFTypeRef type = CFDictionaryGetValue(matching, CFSTR(kIOProviderClassKey));
    assert(type && CFEqual(type, CFSTR("IOMedia")));
    CFRelease(matching); // The real API consumes one reference, including on error.
#ifndef OBSERVATION_CLEAN_TIMING
    atomic_fetch_add(&enumeration_calls, 1);
#endif
    *iterator = IO_OBJECT_NULL;
    if (enumeration_failure == 1) return kIOReturnError;
    if (enumeration_failure == 3) return KERN_SUCCESS;
    pthread_mutex_lock(&session_lock);
    unsigned i = 0; while (i < MAX_SESSIONS && iterators[i].used) ++i;
    assert(i < MAX_SESSIONS);
    iterators[i].used = true; iterators[i].position = 0;
    *iterator = ITERATOR_BASE + i; acquired(&iterators_live, &iterators_peak);
    pthread_mutex_unlock(&session_lock);
#ifndef OBSERVATION_CLEAN_TIMING
    if (atomic_exchange(&hold_next_enumeration, false)) wait_in_gate();
#endif
    return enumeration_failure == 2 ? kIOReturnError : KERN_SUCCESS;
}
static io_object_t synthetic_next(io_iterator_t iterator) {
    assert(iterator >= ITERATOR_BASE && iterator < ITERATOR_BASE + MAX_SESSIONS);
    pthread_mutex_lock(&session_lock);
    unsigned i = iterator - ITERATOR_BASE;
    assert(iterators[i].used);
    unsigned position = iterators[i].position;
    if ((enumeration_limit >= 0 && position >= (unsigned)enumeration_limit) ||
        position >= disk_count * (enumeration_duplicate ? 2 : 1)) {
        pthread_mutex_unlock(&session_lock); return IO_OBJECT_NULL;
    }
    iterators[i].position += 1;
    unsigned index = position / (enumeration_duplicate ? 2 : 1);
    acquired(&media_live, &media_peak);
    pthread_mutex_unlock(&session_lock);
    return MEDIA_BASE + index;
}
static DADiskRef synthetic_media_disk(CFAllocatorRef allocator, DASessionRef ref, io_service_t media) {
    (void)ref;
    assert(media >= MEDIA_BASE && media < MEDIA_BASE + disk_count);
#ifndef OBSERVATION_CLEAN_TIMING
    atomic_fetch_add(&media_disk_requests, 1);
#endif
    int index = (int)(media - MEDIA_BASE);
    if (disks[index].missing) return NULL;
    return (DADiskRef)CFNumberCreate(allocator, kCFNumberIntType, &index);
}
static CFDictionaryRef synthetic_description(DADiskRef ref) {
    unsigned index = disk_index(ref);
    if (disks[index].no_description) return NULL;
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(d, kDADiskDescriptionMediaLeafKey, disks[index].leaf ? kCFBooleanTrue : kCFBooleanFalse);
    CFDictionarySetValue(d, kDADiskDescriptionMediaContentKey, CFSTR("Windows_NTFS"));
    CFStringRef kind = CFStringCreateWithCString(NULL, disks[index].kind, kCFStringEncodingUTF8);
    CFDictionarySetValue(d, kDADiskDescriptionVolumeKindKey, kind); CFRelease(kind);
    if (disks[index].writable >= 0) {
        CFDictionarySetValue(d, kDADiskDescriptionMediaWritableKey,
                             disks[index].writable ? kCFBooleanTrue : kCFBooleanFalse);
    }
    CFDictionarySetValue(d, kDADiskDescriptionMediaRemovableKey, kCFBooleanTrue);
    CFDictionarySetValue(d, kDADiskDescriptionVolumeNameKey, CFSTR("Synthetic"));
    if (disks[index].path) {
        char path[128];
        snprintf(path, sizeof(path), disks[index].path == 3 ? "https://synthetic.invalid/%u/" :
            (disks[index].path == 2 ? "file:///Volumes/Missing%u/" : "file:///Volumes/Synthetic%u/"), index);
        CFStringRef string = CFStringCreateWithCString(NULL, path, kCFStringEncodingUTF8);
        CFURLRef url = CFURLCreateWithString(NULL, string, NULL);
        CFDictionarySetValue(d, kDADiskDescriptionVolumePathKey, url); CFRelease(url); CFRelease(string);
    }
    return d;
}
static io_service_t synthetic_media(DADiskRef ref) {
    acquired(&media_live, &media_peak);
    return MEDIA_BASE + disk_index(ref);
}
static kern_return_t synthetic_registry(io_registry_entry_t entry, uint64_t *id) {
    if (entry >= MEDIA_BASE && entry < MEDIA_BASE + disk_count) { *id = disks[entry - MEDIA_BASE].registry; return KERN_SUCCESS; }
    return IORegistryEntryGetRegistryEntryID(entry, id);
}
static kern_return_t synthetic_release(io_object_t object) {
    if (object >= MEDIA_BASE && object < MEDIA_BASE + disk_count) {
        released(&media_live); return KERN_SUCCESS;
    }
    if (object >= ITERATOR_BASE && object < ITERATOR_BASE + MAX_SESSIONS) {
        pthread_mutex_lock(&session_lock);
        unsigned i = object - ITERATOR_BASE; assert(iterators[i].used);
        iterators[i].used = false; released(&iterators_live);
        pthread_mutex_unlock(&session_lock); return KERN_SUCCESS;
    }
    return IOObjectRelease(object);
}
static int synthetic_mounts(struct statfs **buffer, int flags) {
#ifndef OBSERVATION_CLEAN_TIMING
    unsigned call = atomic_fetch_add(&mount_calls, 1) + 1;
#endif
    if (flags != MNT_NOWAIT) { atomic_fetch_add(&wrong_flags, 1); *buffer = NULL; errno = EINVAL; return 0; }
    size_t bytes = (size_t)entry_count * sizeof(struct statfs);
    *buffer = malloc(bytes ? bytes : sizeof(struct statfs)); assert(*buffer);
    memcpy(*buffer, entries, bytes);
#ifndef OBSERVATION_CLEAN_TIMING
    atomic_fetch_add(&copied_bytes, bytes);
    if (atomic_exchange(&hold_next_table, false)) wait_in_gate();
#endif
    bool failed = fail_table;
#ifndef OBSERVATION_CLEAN_TIMING
    bool next = atomic_exchange(&fail_next_table, false);
    bool scheduled = atomic_compare_exchange_strong(&fail_on_mount_call, &call, 0);
    failed = failed || next || scheduled;
#endif
    if (failed) {
        if (!failure_buffer) { free(*buffer); *buffer = NULL; }
        errno = table_error; return 0; // Also exercise cleanup of a non-null failure buffer.
    }
    return (int)entry_count;
}

#define INTERPOSE(replacement, original) \
    __attribute__((used, section("__DATA,__interpose"))) \
    static const struct { const void *replacement; const void *original; } interpose_##replacement = \
        { (const void *)(replacement), (const void *)(original) }
INTERPOSE(synthetic_session, DASessionCreate);
INTERPOSE(synthetic_queue, DASessionSetDispatchQueue);
INTERPOSE(register_appeared, DARegisterDiskAppearedCallback);
INTERPOSE(register_disappeared, DARegisterDiskDisappearedCallback);
INTERPOSE(register_changed, DARegisterDiskDescriptionChangedCallback);
INTERPOSE(unregister_callback, DAUnregisterCallback);
INTERPOSE(synthetic_disk, DADiskCreateFromBSDName);
INTERPOSE(synthetic_matching, IOServiceGetMatchingServices);
INTERPOSE(synthetic_next, IOIteratorNext);
INTERPOSE(synthetic_media_disk, DADiskCreateFromIOMedia);
INTERPOSE(synthetic_bsd, DADiskGetBSDName);
INTERPOSE(synthetic_description, DADiskCopyDescription);
INTERPOSE(synthetic_media, DADiskCopyIOMedia);
INTERPOSE(synthetic_registry, IORegistryEntryGetRegistryEntryID);
INTERPOSE(synthetic_release, IOObjectRelease);
INTERPOSE(synthetic_mounts, getmntinfo_r_np);
