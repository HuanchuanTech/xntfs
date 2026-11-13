/* Test-only MRC objects exercise the actual queues' autorelease boundary.
 * Their payload is synthetic and is never presented as real FSKit allocation. */
#import <Foundation/Foundation.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include "volume_memory_probe.h"

static _Atomic uint64_t live, peak, created, destroyed;
@interface NFSKMemoryTemporary : NSObject {
    void *bytes;
    size_t length;
}
- (instancetype)initWithBytes:(size_t)count;
@end
@implementation NFSKMemoryTemporary
- (instancetype)initWithBytes:(size_t)count {
    self = [super init];
    if (self) {
        assert(count && count <= 65536);
        bytes = malloc(count); assert(bytes); memset(bytes, 0xa5, count); length = count;
        uint64_t value = atomic_fetch_add(&live, count) + count, previous = atomic_load(&peak);
        while (value > previous && !atomic_compare_exchange_weak(&peak, &previous, value)) {}
        atomic_fetch_add(&created, 1);
    }
    return self;
}
- (void)dealloc {
    free(bytes); atomic_fetch_sub(&live, length); atomic_fetch_add(&destroyed, 1);
    [super dealloc];
}
@end
void nfsk_memory_emit(size_t bytes) { [[[NFSKMemoryTemporary alloc] initWithBytes:bytes] autorelease]; }
nfsk_memory_stats nfsk_memory_sample(void) {
    return (nfsk_memory_stats){atomic_load(&live), atomic_load(&peak), atomic_load(&created), atomic_load(&destroyed)};
}
void nfsk_memory_reset(void) {
    assert(atomic_load(&live) == 0 && atomic_load(&created) == atomic_load(&destroyed));
    atomic_store(&peak, 0); atomic_store(&created, 0); atomic_store(&destroyed, 0);
}
