/* Bare-metal startup for the QEMU reader images (ci/check-qemu.py): Cortex-M4 on
 * mps2-an386 and RV32 on virt. It provides what ci/firmware/stubs.c provides, routed to
 * semihosting instead of a dummy UART. On top of that it adds startup, a fault handler that
 * exits non-zero, a stack high-water mark, and the soft-float equality compares the shared
 * float assertions need (no compiler-rt ships for these targets). Still no allocator: an
 * allocating image fails to link. Test harness only; not a BSP. */
typedef unsigned int size_t;
typedef unsigned int u32;
typedef unsigned long long u64;

#define SYS_WRITEC 0x03
#define SYS_EXIT 0x18
#define EXIT_SUCCESS_REASON 0x20026 /* ADP_Stopped_ApplicationExit: QEMU exits 0 */
#define EXIT_FAILURE_REASON 0x20023 /* ADP_Stopped_RunTimeErrorUnknown: QEMU exits 1 */
#define STACK_PAINT 0xC0DEC0DEu

extern u32 __bss_start, __bss_end, __stack_bottom, __stack_top, __capnp_input;

static int semihost(int op, const void *arg) {
#if defined(__arm__)
    register int r0 __asm__("r0") = op;
    register const void *r1 __asm__("r1") = arg;
    __asm__ volatile("bkpt 0xAB" : "+r"(r0) : "r"(r1) : "memory");
    return r0;
#elif defined(__riscv)
    /* The RISC-V semihosting trap: these three uncompressed instructions, in one page. */
    register int a0 __asm__("a0") = op;
    register const void *a1 __asm__("a1") = arg;
    __asm__ volatile(".option push\n.option norvc\n.balign 16\n"
                     "slli zero, zero, 0x1f\nebreak\nsrai zero, zero, 7\n.option pop"
                     : "+r"(a0) : "r"(a1) : "memory");
    return a0;
#else
#error "unsupported target"
#endif
}

int putchar(int c) {
    char ch = (char)c;
    semihost(SYS_WRITEC, &ch);
    return c;
}

static void put(const char *s) { while (*s) putchar(*s++); }

static void put_u32(u32 v) {
    char digits[10];
    int n = 0;
    do { digits[n++] = (char)('0' + v % 10); v /= 10; } while (v);
    while (n) putchar(digits[--n]);
}

static __attribute__((noreturn)) void exit_with(int reason) {
    /* 32-bit semihosting passes the reason itself, not a parameter block. */
    semihost(SYS_EXIT, (const void *)(size_t)reason);
    for (;;) {}
}

/* Every trap lands here: a failed precondition (udf / unimp), or any other fault. */
__attribute__((aligned(4), noreturn)) void capnp_fault(void) {
    put("\nFAULT\n");
    exit_with(EXIT_FAILURE_REASON);
}

const void *capnp_input(void) { return &__capnp_input; }

unsigned long __stack_chk_guard = 0xdeadbeef;
void __stack_chk_fail(void) { capnp_fault(); }

void *memset(void *d, int c, size_t n) {
    unsigned char *p = d; while (n--) *p++ = (unsigned char)c; return d; }
void *memcpy(void *d, const void *s, size_t n) {
    unsigned char *a = d; const unsigned char *b = s; while (n--) *a++ = *b++; return d; }

/* Soft-float equality on bit patterns: NaN equals nothing, and +0 equals -0. */
static int f64_equal(double a, double b) {
    u64 x, y;
    memcpy(&x, &a, 8);
    memcpy(&y, &b, 8);
    const u64 magnitude = 0x7fffffffffffffffull, infinity = 0x7ff0000000000000ull;
    if ((x & magnitude) > infinity || (y & magnitude) > infinity) return 0;
    return x == y || ((x | y) & magnitude) == 0;
}
static int f32_equal(float a, float b) {
    u32 x, y;
    memcpy(&x, &a, 4);
    memcpy(&y, &b, 4);
    const u32 magnitude = 0x7fffffffu, infinity = 0x7f800000u;
    if ((x & magnitude) > infinity || (y & magnitude) > infinity) return 0;
    return x == y || ((x | y) & magnitude) == 0;
}

#if defined(__arm__)
void __aeabi_memclr(void *d, size_t n) { memset(d, 0, n); }
void __aeabi_memclr4(void *d, size_t n) { memset(d, 0, n); }
void __aeabi_memclr8(void *d, size_t n) { memset(d, 0, n); }
void __aeabi_memcpy(void *d, const void *s, size_t n) { memcpy(d, s, n); }
void __aeabi_memcpy4(void *d, const void *s, size_t n) { memcpy(d, s, n); }
void __aeabi_memcpy8(void *d, const void *s, size_t n) { memcpy(d, s, n); }
int __aeabi_dcmpeq(double a, double b) { return f64_equal(a, b); }
int __aeabi_fcmpeq(float a, float b) { return f32_equal(a, b); }
#endif
/* libgcc semantics: zero when equal, nonzero when unequal or unordered. */
int __nedf2(double a, double b) { return !f64_equal(a, b); }
int __nesf2(float a, float b) { return !f32_equal(a, b); }
int __eqdf2(double a, double b) { return !f64_equal(a, b); }
int __eqsf2(float a, float b) { return !f32_equal(a, b); }

extern int main(int, char **);

/* Zero .bss, paint the unused stack, run main, and report the deepest stack use. */
__attribute__((noreturn, used)) void capnp_start(void) {
    for (u32 *p = &__bss_start; p < &__bss_end; ++p) *p = 0;
    u32 here;
    for (u32 *p = &__stack_bottom; p < &here - 64; ++p) *p = STACK_PAINT;
    main(0, 0);
    u32 *p = &__stack_bottom;
    while (p < &__stack_top && *p == STACK_PAINT) ++p;
    put("stack=");
    put_u32((u32)((char *)&__stack_top - (char *)p));
    put("\n");
    exit_with(EXIT_SUCCESS_REASON);
}

#if defined(__arm__)
/* Cortex-M vector table: initial SP, reset, then every exception to the fault handler. */
typedef void (*vector)(void);
__attribute__((section(".vectors"), used)) const vector capnp_vectors[16] = {
    (vector)&__stack_top, capnp_start, capnp_fault, capnp_fault, capnp_fault, capnp_fault,
    capnp_fault, 0, 0, 0, 0, capnp_fault, capnp_fault, 0, capnp_fault, capnp_fault,
};
#elif defined(__riscv)
/* Reset lands at the start of RAM in machine mode: set the stack and the trap vector. */
__attribute__((naked, section(".text.start"))) void _start(void) {
    __asm__ volatile("la sp, __stack_top\n"
                     "la t0, capnp_fault\n"
                     "csrw mtvec, t0\n"
                     "j capnp_start");
}
#endif
