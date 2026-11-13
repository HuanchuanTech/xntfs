#include <stdint.h>
// Only the disposable regular file selected by dev/inode is intercepted.
int image_gate_arm(const char *path, int hold, unsigned delay_ms, int fail);
void image_gate_release(void);
void image_gate_clear(void);
unsigned image_gate_entered(void);
unsigned image_gate_reads(void);
unsigned image_gate_closes(void);
unsigned image_gate_main_reads(void);
uint64_t image_gate_requested_bytes(void);
