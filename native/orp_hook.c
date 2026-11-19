#include "orp_hook.h"
#include "orp_patch_config.h"
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

extern void orp_entry0(void);
extern void orp_entry1(void);
extern void orp_entry2(void);
extern void orp_entry3(void);
extern void orp_log(const char *fmt, ...);

typedef struct {   // 64 bytes: read by orp_hook.S
    uintptr_t fwd_ret, resume, sub_imm, real_fn, pad[4];
} orp_site_rt;
__attribute__((visibility("hidden"))) orp_site_rt orp_sites[ORP_SITE_COUNT];

static int g_installed;
static uintptr_t g_base;

uintptr_t orp_game_base(void) { return g_base; }

int orp_hook_install(void) {
    if (g_installed) return 1;
    const struct mach_header *hdr = NULL;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (nm && strstr(nm, "UnityFramework.framework/UnityFramework")) { hdr = _dyld_get_image_header(i); break; }
    }
    if (!hdr) return 0;
    uintptr_t base = (uintptr_t)hdr;  // __TEXT vmaddr is 0 in this image

    // 1) verify EVERYTHING first; touch nothing if any site is not exactly as expected
    void *real[ORP_SITE_COUNT];
    for (int i = 0; i < ORP_SITE_COUNT; i++) {
        const orp_site_cfg *c = &ORP_SITES[i];
        uint32_t site = *(volatile uint32_t *)(base + c->site_rva);
        uint32_t next = *(volatile uint32_t *)(base + c->resume_rva);
        if (site != ORP_B(c->site_rva, c->stub_rva) || next != c->resume_insn) {
            orp_log("hook: %s: unexpected code (%08x, %08x) - wrong build or IPA not patched", c->name, site, next);
            return -1;
        }
        real[i] = dlsym(RTLD_DEFAULT, c->real_symbol);
        if (!real[i]) { orp_log("hook: cannot resolve %s", c->real_symbol); return -1; }
    }

    // 2) fill the runtime table, then publish the entry points
    void (*entries[ORP_SITE_COUNT])(void) = { orp_entry0, orp_entry1, orp_entry2, orp_entry3 };
    for (int i = 0; i < ORP_SITE_COUNT; i++) {
        const orp_site_cfg *c = &ORP_SITES[i];
        orp_sites[i].fwd_ret = base + c->fwd_ret_rva;
        orp_sites[i].resume = base + c->resume_rva;
        orp_sites[i].sub_imm = c->sub_imm;
        orp_sites[i].real_fn = (uintptr_t)real[i];
    }
    __sync_synchronize();
    for (int i = 0; i < ORP_SITE_COUNT; i++) {
        void **slot = (void **)(base + ORP_SITES[i].slot_rva);
        uintptr_t page = (uintptr_t)slot & ~((uintptr_t)getpagesize() - 1);
        mprotect((void *)page, (size_t)getpagesize(), PROT_READ | PROT_WRITE);  // data page; best effort
        *slot = (void *)entries[i];
    }
    __sync_synchronize();
    g_base = base;
    g_installed = 1;
    orp_log("hook: installed %d sites (base %p)", ORP_SITE_COUNT, (void *)base);
    return 1;
}
