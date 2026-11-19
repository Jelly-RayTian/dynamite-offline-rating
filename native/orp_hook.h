#ifndef ORP_HOOK_H
#define ORP_HOOK_H
#include <stdint.h>
// Returns 1 = installed, 0 = UnityFramework not loaded yet (try again),
// -1 = this binary is not the expected build / not patched (do not retry).
int orp_hook_install(void);
// Load address of UnityFramework (valid after a successful install).
uintptr_t orp_game_base(void);
// Implemented in orp_core.m, runs on the game thread. See orp_hook.S for the contract.
int orp_dispatch(uint64_t *regs, int site);
#endif
