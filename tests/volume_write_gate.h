#include "ntfs_fskit.h"
#include "directory_packer.h"

void nfsk_test_arm_write(void);
int nfsk_test_wait_for_write(void);
void nfsk_test_release_write(void);
void nfsk_test_arm_read(void);
int nfsk_test_wait_for_read(void);
void nfsk_test_release_read(void);
void nfsk_test_fail_next_sync(void);
void nfsk_test_fail_inode_open(uint64_t ino);
void nfsk_test_fail_inode_close(uint64_t ino);
int nfsk_test_inode_faults(void);
