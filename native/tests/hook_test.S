// Mac-side emulation of THREE patched game functions + their hijacked stubs.
    .text
    .align 2

// body macro: `ENTRY name, stubname, imm, ret_from_original`
// The first instruction (a `b stub`) stands where the game's `sub sp, sp, #imm` was.
.macro FAKE name, stub, imm, retval
    .globl _\name
_\name:
    b       \stub
    stp     x29, x30, [sp, #(\imm - 16)]      // function body expects the frame to be allocated already
    add     x29, sp, #(\imm - 16)
    ldr     x9,  [sp, #\imm]                   // stack args (9th, 10th)
    ldr     x10, [sp, #(\imm + 8)]
    add     x0, x0, x1                         // result = x0 + x1 + x2 + ... + x7 + stack args
    add     x0, x0, x2
    add     x0, x0, x3
    add     x0, x0, x4
    add     x0, x0, x5
    add     x0, x0, x6
    add     x0, x0, x7
    add     x0, x0, x9
    add     x0, x0, x10
    add     x0, x0, #\retval                   // marks "the original body ran"
    ldp     x29, x30, [sp, #(\imm - 16)]
    add     sp, sp, #\imm
    ret
.endm
    FAKE fake_target0, _fake_stub0, 0x80, 1000
    FAKE fake_target1, _fake_stub1, 0x80, 2000
    FAKE fake_target2, _fake_stub2, 0x60, 3000
    FAKE fake_target3, _fake_stub3, 0x80, 4000

.macro STUB n
    .globl _fake_stub\n
_fake_stub\n:
    adrp    x16, _fake_slot\n@PAGE
    ldr     x16, [x16, _fake_slot\n@PAGEOFF]
    br      x16
.endm
    STUB 0
    STUB 1
    STUB 2
    STUB 3

// "real function" behind each hijacked import
    .globl _fake_real0
    .globl _fake_real1
    .globl _fake_real2
    .globl _fake_real3
_fake_real0: mov x0, #4240
    ret
_fake_real1: mov x0, #4241
    ret
_fake_real2: mov x0, #4242
    ret
_fake_real3: mov x0, #4243
    ret

// legitimate call sites: lr == the label after the bl
.macro LEGIT n
    .globl _legit_caller\n
    .globl _legit_ret\n
_legit_caller\n:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    bl      _fake_stub\n
_legit_ret\n:
    ldp     x29, x30, [sp], #16
    ret
.endm
    LEGIT 0
    LEGIT 1
    LEGIT 2
    LEGIT 3

    .globl _fake_resume_addr
_fake_resume_addr:                              // x0 = index -> address of fake_targetN + 4
    adrp    x1, _fake_target0@PAGE
    add     x1, x1, _fake_target0@PAGEOFF
    cmp     x0, #1
    b.ne    1f
    adrp    x1, _fake_target1@PAGE
    add     x1, x1, _fake_target1@PAGEOFF
1:  cmp     x0, #2
    b.ne    2f
    adrp    x1, _fake_target2@PAGE
    add     x1, x1, _fake_target2@PAGEOFF
2:  cmp     x0, #3
    b.ne    3f
    adrp    x1, _fake_target3@PAGE
    add     x1, x1, _fake_target3@PAGEOFF
3:  add     x0, x1, #4
    ret

    .data
    .align 3
    .globl _fake_slot0
    .globl _fake_slot1
    .globl _fake_slot2
    .globl _fake_slot3
_fake_slot0: .quad 0
_fake_slot1: .quad 0
_fake_slot2: .quad 0
_fake_slot3: .quad 0
