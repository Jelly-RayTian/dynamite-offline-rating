// Hook trampolines (arm64, Mach-O), table driven.
//
// tools/patch_ipa.py replaces the first instruction of each hooked game function with
// `b <stub of an unused import>`. At runtime orp_hook_install() overwrites that import's
// lazy-pointer slot with orp_entryN, so the hooked function lands here with all original
// registers intact (x0..x7 = arguments, x30 = its caller).
//
// orp_dispatch(regs, site) may modify the saved x0..x7 (they are restored) and returns
//   0 : run the original function (the displaced `sub sp, sp, #imm` is executed here, then
//       we continue at function + 4)
//   1 : skip the original and return to the caller immediately (x0 = regs[0] is the result)
//
// If the hijacked import is ever called through its single legitimate call site
// (lr == sites[n].fwd_ret) the call is forwarded to the real function untouched.
    .text
    .align 2
    .globl _orp_entry0
    .globl _orp_entry1
    .globl _orp_entry2
    .globl _orp_entry3
_orp_entry0:
    mov     w17, #0
    b       _orp_pre
_orp_entry1:
    mov     w17, #1
    b       _orp_pre
_orp_entry2:
    mov     w17, #2
    b       _orp_pre
_orp_entry3:
    mov     w17, #3
    b       _orp_pre

// struct orp_site_rt (64 bytes): +0 fwd_ret, +8 resume, +16 sub_imm, +24 real_fn
_orp_pre:
    adrp    x16, _orp_sites@PAGE
    add     x16, x16, _orp_sites@PAGEOFF
    lsl     x15, x17, #6
    add     x16, x16, x15
    ldr     x15, [x16, #0]
    cmp     x30, x15
    b.ne    1f
    ldr     x16, [x16, #24]                   // legitimate call of the hijacked import
    br      x16
1:
    sub     sp, sp, #0xa0
    stp     x29, x30, [sp, #0x90]
    add     x29, sp, #0x90
    stp     x0, x1, [sp, #0x00]
    stp     x2, x3, [sp, #0x10]
    stp     x4, x5, [sp, #0x20]
    stp     x6, x7, [sp, #0x30]
    str     x8, [sp, #0x40]
    str     x17, [sp, #0x48]
    mov     x0, sp                            // uint64_t regs[]
    mov     w1, w17                           // site index
    bl      _orp_dispatch
    mov     w9, w0
    ldr     x17, [sp, #0x48]
    ldp     x0, x1, [sp, #0x00]
    ldp     x2, x3, [sp, #0x10]
    ldp     x4, x5, [sp, #0x20]
    ldp     x6, x7, [sp, #0x30]
    ldr     x8, [sp, #0x40]
    ldp     x29, x30, [sp, #0x90]
    add     sp, sp, #0xa0
    cbnz    w9, 2f
    adrp    x16, _orp_sites@PAGE
    add     x16, x16, _orp_sites@PAGEOFF
    lsl     x15, x17, #6
    add     x16, x16, x15
    ldr     x15, [x16, #16]
    sub     sp, sp, x15                       // the displaced original instruction
    ldr     x16, [x16, #8]
    br      x16                               // continue at function + 4
2:
    ret                                       // original skipped: back to the caller
