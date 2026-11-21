/* The complete platform surface a bare-metal reader image needs: output, stack
 * protector, and freestanding memory helpers (no 64-bit atomic stubs needed: ReadState
 * uses word-sized Atomic<UInt>). Deliberately no allocator: an allocating image must fail
 * to link. Link proof only; not a BSP. */
typedef unsigned int size_t;
volatile unsigned char capnp_uart;
int putchar(int c) { capnp_uart = (unsigned char)c; return c; }
unsigned long __stack_chk_guard = 0xdeadbeef;
void __stack_chk_fail(void) { for (;;) {} }
void *memset(void *d, int c, size_t n) {
    unsigned char *p = d; while (n--) *p++ = (unsigned char)c; return d; }
void *memcpy(void *d, const void *s, size_t n) {
    unsigned char *a = d; const unsigned char *b = s; while (n--) *a++ = *b++; return d; }
void __aeabi_memclr(void *d, size_t n) { memset(d, 0, n); }
void __aeabi_memclr4(void *d, size_t n) { memset(d, 0, n); }
void __aeabi_memclr8(void *d, size_t n) { memset(d, 0, n); }
void __aeabi_memcpy(void *d, const void *s, size_t n) { memcpy(d, s, n); }
void __aeabi_memcpy4(void *d, const void *s, size_t n) { memcpy(d, s, n); }
void __aeabi_memcpy8(void *d, const void *s, size_t n) { memcpy(d, s, n); }
void _start(void) { extern int main(int, char **); main(0, 0); for (;;) {} }
