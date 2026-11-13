#include "host_observation_shim.h"

// Synthetic submissions only, at most four distinct fixture disks in flight.
void xntfs_mount_fixture_reset(void);
uint32_t xntfs_mount_submissions(void);
uint32_t xntfs_mount_completions(void);
uint32_t xntfs_mount_pending(void);
bool xntfs_mount_requested_read_only(uint32_t disk);
void xntfs_mount_finish(uint32_t disk, DAReturn status);
