#include <DiskArbitration/DiskArbitration.h>
#include <stdbool.h>
#include <stdint.h>
#include "host_query_guard.h"

// Test-only synthetic DA source. Configure only while all monitor queues are idle.
void xntfs_observation_reset(uint32_t disks, uint32_t table_entries);
void xntfs_observation_set_path(uint32_t disk, int path); // 0 absent, 1 mounted, 2 stale, 3 non-file
void xntfs_observation_set_kind(uint32_t disk, const char *kind);
void xntfs_observation_set_bsd(uint32_t disk, const char *name);
// -1 omits DAMediaWritable; 0/1 supplies explicit false/true.
void xntfs_observation_set_writable(uint32_t disk, int writable);
void xntfs_observation_set_leaf(uint32_t disk, bool leaf);
void xntfs_observation_set_mount(uint32_t disk, const char *type, bool read_only);
void xntfs_observation_set_entry(uint32_t entry, const char *source, const char *path, const char *type);
void xntfs_observation_set_missing(uint32_t disk, bool disk_missing, bool description_missing);
void xntfs_observation_set_registry(uint32_t disk, uint64_t registry);
void xntfs_observation_fail_table(bool fail);
void xntfs_observation_fail_next_table(void);
// A one-shot numbered call, configured after reset_counts while all queues are idle.
void xntfs_observation_fail_table_on_call(uint32_t call);
void xntfs_observation_set_table_failure(int error, bool nonnull_buffer);
void xntfs_observation_reset_counts(void);
uint32_t xntfs_observation_mount_calls(void);
uint32_t xntfs_observation_disk_requests(void);
uint32_t xntfs_observation_registration_calls(void);
uint32_t xntfs_observation_wrong_flags(void);
uint64_t xntfs_observation_copied_bytes(void);
uint32_t xntfs_observation_sessions(void);
// Test-only registered-media traversal: 0 normal, 1 error/null, 2 error/iterator,
// 3 success/null; limit >= 0 invalidates after that many entries, -1 visits all.
void xntfs_observation_set_enumeration(int failure, int limit, bool duplicate);
uint32_t xntfs_observation_enumeration_calls(void);
uint32_t xntfs_observation_media_disk_requests(void);
uint32_t xntfs_observation_iterators_live(void);
uint32_t xntfs_observation_media_live(void);
uint32_t xntfs_observation_iterators_peak(void);
uint32_t xntfs_observation_media_peak(void);
void xntfs_observation_drain(DASessionRef session);
// One test gate at a time; always release it, including the queued-teardown case.
void xntfs_observation_hold_queue(DASessionRef session);
void xntfs_observation_hold_next_table(void); // Pause after copying the table.
void xntfs_observation_hold_next_enumeration(void); // Pause with an owned iterator.
void xntfs_observation_wait_held(void);
void xntfs_observation_release_and_drain(DASessionRef session);
void xntfs_observation_emit(DASessionRef session, uint32_t disk, int event); // 0 appear, 1 change, 2 disappear
