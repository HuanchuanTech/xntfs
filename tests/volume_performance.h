#ifndef VOLUME_PERFORMANCE_H
#define VOLUME_PERFORMANCE_H
#include "ntfs_fskit.h"
#include "directory_packer.h"
typedef struct {
    uint64_t pread_calls, pread_bytes, pread_ns;
    uint64_t inode_opens, attr_opens, statfs_calls, statfs_ns;
    uint64_t symlink_parses;
    /* Direct bridge-to-library calls. Durations are inclusive (inode open may
     * include backend reads); do not sum these as disjoint CPU categories. */
    uint64_t inode_open_ns, inode_closes, inode_close_ns;
    uint64_t attr_open_ns, attr_closes, attr_close_ns;
    uint64_t mbstoucs_calls, mbstoucs_ns;
    uint64_t reparse_validations, reparse_validation_ns;
} nfsk_perf_counters;
void nfsk_perf_reset(void);
nfsk_perf_counters nfsk_perf_snapshot(void);
#endif
