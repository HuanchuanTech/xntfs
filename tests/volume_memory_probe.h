#ifndef NFSK_VOLUME_MEMORY_PROBE_H
#define NFSK_VOLUME_MEMORY_PROBE_H
#include <stddef.h>
#include <stdint.h>
#include "ntfs_fskit.h"
typedef struct {
    uint64_t live, peak, created, destroyed;
} nfsk_memory_stats;
void nfsk_memory_emit(size_t bytes);
nfsk_memory_stats nfsk_memory_sample(void);
void nfsk_memory_reset(void);
#endif
