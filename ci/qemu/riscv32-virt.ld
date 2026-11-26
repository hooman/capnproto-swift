/* RV32 on QEMU virt with -bios none: reset jumps to the start of RAM at 0x80000000, so
 * _start comes first; the loaded input sits 4 MiB in. Used by ci/check-qemu.py. */
MEMORY { RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 4M }
__capnp_input = 0x80400000;
SECTIONS {
    .text : { KEEP(*(.text.start)) *(.text .text.*) } > RAM
    .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > RAM
    .data : { *(.data .data.* .sdata .sdata.*) } > RAM
    .bss (NOLOAD) : ALIGN(4) { __bss_start = .; *(.bss .bss.* .sbss .sbss.* COMMON) . = ALIGN(4); __bss_end = .; } > RAM
    .stack (NOLOAD) : ALIGN(16) { __stack_bottom = .; . += 256K; __stack_top = .; } > RAM
}
