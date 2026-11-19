#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct { uintptr_t fwd_ret, resume, sub_imm, real_fn, pad[4]; } orp_site_rt;
orp_site_rt orp_sites[4];   // defined in orp_hook.c in the real dylib
extern void orp_entry0(void), orp_entry1(void), orp_entry2(void), orp_entry3(void);
extern int64_t fake_target0(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
extern int64_t fake_target1(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
extern int64_t fake_target2(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
extern int64_t fake_target3(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
extern int64_t legit_caller0(void), legit_caller1(void), legit_caller2(void), legit_caller3(void);
extern void legit_ret0(void), legit_ret1(void), legit_ret2(void), legit_ret3(void);
extern void fake_real0(void), fake_real1(void), fake_real2(void), fake_real3(void);
extern uintptr_t fake_resume_addr(int64_t idx);
extern void *fake_slot0, *fake_slot1, *fake_slot2, *fake_slot3;

static int calls[4];
static uint64_t seen[4][8];

int orp_dispatch(uint64_t *regs, int site) {
    calls[site]++;
    memcpy(seen[site], regs, sizeof seen[site]);
    // stress: stack alignment + trash every caller-saved register
    volatile double v[4] __attribute__((aligned(16))) = {1, 2, 3, 4};
    char buf[64]; snprintf(buf, sizeof buf, "%d %f", site, v[1]);
    int action = 0;
    if (site == 1) regs[1] += 1000;            // modify an argument; original must see it
    if (site == 2) { regs[0] = 777; action = 1; }   // skip the original, return 777
    if (site == 3) { regs[0] = 555; action = 1; }   // always-skip site (like JumpRegister)
    __asm__ volatile("mov x1,#0\n mov x2,#0\n mov x3,#0\n mov x4,#0\n mov x5,#0\n mov x6,#0\n mov x7,#0\n mov x8,#0\n"
                     "mov x9,#0\n mov x10,#0\n mov x11,#0\n mov x12,#0\n mov x13,#0\n mov x14,#0\n mov x15,#0\n mov x17,#0\n"
                     ::: "x1","x2","x3","x4","x5","x6","x7","x8","x9","x10","x11","x12","x13","x14","x15","x17","memory");
    return action;
}

int main(void) {
    int fails = 0;
#define EXPECT(cond, ...) do { if (!(cond)) { printf("FAIL: " __VA_ARGS__); printf("\n"); fails++; } } while (0)
    uintptr_t fwd[4] = {(uintptr_t)legit_ret0, (uintptr_t)legit_ret1, (uintptr_t)legit_ret2, (uintptr_t)legit_ret3};
    uintptr_t real[4] = {(uintptr_t)fake_real0, (uintptr_t)fake_real1, (uintptr_t)fake_real2, (uintptr_t)fake_real3};
    uintptr_t imm[4] = {0x80, 0x80, 0x60, 0};
    for (int i = 0; i < 4; i++) {
        orp_sites[i].fwd_ret = fwd[i];
        orp_sites[i].real_fn = real[i];
        orp_sites[i].resume = fake_resume_addr(i);
        orp_sites[i].sub_imm = imm[i];
    }
    fake_slot0 = (void *)orp_entry0; fake_slot1 = (void *)orp_entry1; fake_slot2 = (void *)orp_entry2; fake_slot3 = (void *)orp_entry3;

    // site 0: observe only. result = sum(args) + stack args + 1000 (original ran)
    int64_t r = fake_target0(1, 2, 3, 4, 5, 6, 7, 8, 9, 10);
    EXPECT(r == 55 + 1000, "site0 result %lld", (long long)r);
    EXPECT(calls[0] == 1 && seen[0][0] == 1 && seen[0][6] == 7 && seen[0][7] == 8, "site0 captured args");

    // site 1: argument modified by the handler (x1 += 1000) must reach the original body
    r = fake_target1(1, 2, 3, 4, 5, 6, 7, 8, 9, 10);
    EXPECT(r == 55 + 1000 + 2000, "site1 result %lld", (long long)r);
    EXPECT(seen[1][1] == 2, "site1 handler saw the ORIGINAL x1");

    // site 2 (different frame size 0x60): handler skips the original and returns 777
    r = fake_target2(1, 2, 3, 4, 5, 6, 7, 8, 9, 10);
    EXPECT(r == 777, "site2 skip result %lld (3000+ would mean the original body ran)", (long long)r);

    // site 3 (frame size irrelevant, original always skipped): handler result comes back untouched
    r = fake_target3(1, 2, 3, 4, 5, 6, 7, 8, 9, 10);
    EXPECT(r == 555, "site3 skip result %lld (4000+ would mean the original body ran)", (long long)r);

    // stability / register & stack preservation
    for (int i = 0; i < 2000; i++) {
        int64_t a = fake_target0(i, 2, 3, 4, 5, 6, 7, 8, 9, 10);
        int64_t b = fake_target1(i, 2, 3, 4, 5, 6, 7, 8, 9, 10);
        int64_t c = fake_target2(i, 2, 3, 4, 5, 6, 7, 8, 9, 10);
        int64_t e = fake_target3(i, 2, 3, 4, 5, 6, 7, 8, 9, 10);
        if (a != i + 54 + 1000 || b != i + 54 + 1000 + 2000 || c != 777 || e != 555) { printf("FAIL loop %d: %lld %lld %lld\n", i, (long long)a, (long long)b, (long long)c); fails++; break; }
    }
    EXPECT(calls[0] == 2001 && calls[1] == 2001 && calls[2] == 2001 && calls[3] == 2001, "call counts %d %d %d %d", calls[0], calls[1], calls[2], calls[3]);

    // forwarding of the hijacked imports' legitimate calls: real function runs, handler does NOT
    int before[4] = {calls[0], calls[1], calls[2], calls[3]};
    r = legit_caller0(); EXPECT(r == 4240, "forward0 %lld", (long long)r);
    r = legit_caller1(); EXPECT(r == 4241, "forward1 %lld", (long long)r);
    r = legit_caller2(); EXPECT(r == 4242, "forward2 %lld", (long long)r);
    r = legit_caller3(); EXPECT(r == 4243, "forward3 %lld", (long long)r);
    EXPECT(calls[0] == before[0] && calls[1] == before[1] && calls[2] == before[2] && calls[3] == before[3], "handler must not run for legitimate calls");

    printf("hook trampoline test (4 sites): %d failures\n", fails);
    return fails ? 1 : 0;
}
