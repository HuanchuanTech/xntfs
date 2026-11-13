#import "directory_packer.h"
@interface NFSKTestDirectoryPacker : NSObject
@property(copy) NFSKTestPackEntry entry;
@end
@implementation NFSKTestDirectoryPacker
- (BOOL)packEntryWithName:(FSFileName *)name itemType:(FSItemType)type
                  itemID:(FSItemID)ino nextCookie:(FSDirectoryCookie)cookie
              attributes:(FSItemAttributes *)attributes {
    return self.entry(name, type, ino, cookie, attributes);
}
@end
FSDirectoryEntryPacker *nfsk_test_packer(NFSKTestPackEntry entry) {
    NFSKTestDirectoryPacker *packer = [NFSKTestDirectoryPacker new];
    packer.entry = entry;
    return (FSDirectoryEntryPacker *)packer;
}
