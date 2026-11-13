#ifndef NFSK_TEST_DIRECTORY_PACKER_H
#define NFSK_TEST_DIRECTORY_PACKER_H
#include "ntfs_fskit.h"
#ifdef __OBJC__
#import <FSKit/FSKit.h>
NS_ASSUME_NONNULL_BEGIN
/* Test-only selector mock. This does not instantiate the system's packer or
 * exercise its buffer serialization/reference-count protocol. */
typedef BOOL (^NFSKTestPackEntry)(FSFileName *, FSItemType, FSItemID,
                                 FSDirectoryCookie, FSItemAttributes * _Nullable);
FSDirectoryEntryPacker *nfsk_test_packer(NFSKTestPackEntry entry);
NS_ASSUME_NONNULL_END
#endif
#endif
