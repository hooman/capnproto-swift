/* Cortex-M4 on QEMU mps2-an386: code in SSRAM1 at 0 (the vector table must be first), data,
 * stack and the loaded input in SSRAM2/3 at 0x20000000. Used by ci/check-qemu.py. */
MEMORY {
    CODE (rx) : ORIGIN = 0x00000000, LENGTH = 4M
    RAM (rwx) : ORIGIN = 0x20000000, LENGTH = 3M
}
__capnp_input = 0x20300000;
SECTIONS {
    .text : { KEEP(*(.vectors)) *(.text .text.*) *(.rodata .rodata.*) } > CODE
    .ARM.exidx : { *(.ARM.exidx*) } > CODE
    .data : { *(.data .data.*) } > RAM
    .bss (NOLOAD) : ALIGN(4) { __bss_start = .; *(.bss .bss.* COMMON) . = ALIGN(4); __bss_end = .; } > RAM
    .stack (NOLOAD) : ALIGN(8) { __stack_bottom = .; . += 256K; __stack_top = .; } > RAM
}
