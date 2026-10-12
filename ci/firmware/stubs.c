/* The complete platform surface a bare-metal reader image needs: output, stack
 * protector, memory helpers and 64-bit atomics (single core, no OS). Deliberately no
 * allocator: an allocating image must fail to link. Link proof only; not a BSP. */
typedef unsigned int size_t;
volatile unsigned char capnp_uart;
int putchar(int c) { capnp_uart = (unsigned char)c; return c; }
unsigned long __stack_chk_guard = 0xdeadbeef;
void __stack_chk_fail(void) { for (;;) {} }
void __aeabi_memclr(void *d, size_t n) { unsigned char *p = d; while (n--) *p++ = 0; }
void __aeabi_memclr4(void *d, size_t n) { __aeabi_memclr(d, n); }
void __aeabi_memclr8(void *d, size_t n) { __aeabi_memclr(d, n); }
void __aeabi_memcpy(void *d, const void *s, size_t n) {
    unsigned char *a = d; const unsigned char *b = s; while (n--) *a++ = *b++; }
void __aeabi_memcpy4(void *d, const void *s, size_t n) { __aeabi_memcpy(d, s, n); }
void __aeabi_memcpy8(void *d, const void *s, size_t n) { __aeabi_memcpy(d, s, n); }
unsigned long long __atomic_load_8(const volatile void *p, int order) {
    (void)order; return *(const volatile unsigned long long *)p; }
_Bool __atomic_compare_exchange_8(volatile void *p, void *expected, unsigned long long desired,
                                  _Bool weak, int success, int failure) {
    (void)weak; (void)success; (void)failure;
    volatile unsigned long long *q = p; unsigned long long *e = expected;
    if (*q == *e) { *q = desired; return 1; }
    *e = *q; return 0; }
void _start(void) { extern int main(int, char **); main(0, 0); for (;;) {} }
