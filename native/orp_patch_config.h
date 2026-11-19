// Constants describing the ONE Dynamite build this module supports
// (Dynamite 1.0.2 build 59). tools/patch_ipa.py reads THIS table, applies the byte patches and
// verifies the same facts; orp_hook_install() re-verifies them at runtime and refuses to hook
// anything if a single byte differs.
#ifndef ORP_PATCH_CONFIG_H
#define ORP_PATCH_CONFIG_H
#include <stdint.h>

// `b to` encoded at `from` (both are RVAs; __TEXT vmaddr is 0 in this image)
#define ORP_B(from, to) (0x14000000u | ((((uint32_t)(to) - (uint32_t)(from)) >> 2) & 0x3FFFFFFu))

enum { ORP_SITE_UPLOAD = 0, ORP_SITE_LOGIN = 1, ORP_SITE_REGISTER = 2, ORP_SITE_JUMPREG = 3, ORP_SITE_COUNT = 4 };

typedef struct {
    const char *name;
    uint32_t site_rva;      // function entry; its first instruction is replaced by `b stub`
    uint32_t orig_insn;     // that first instruction (the patcher verifies it)
    uint32_t sub_imm;       // != 0: the original first instruction is `sub sp, sp, #sub_imm` and the original can
                            //       still run (dispatch returns 0). 0: the original is always skipped.
    uint32_t resume_rva;    // site + 4
    uint32_t resume_insn;   // expected second instruction (sanity check)
    uint32_t stub_rva;      // stub of an (almost) unused import, used as the hijack point
    uint32_t slot_rva;      // that stub's lazy-pointer slot
    uint32_t fwd_ret_rva;   // return address of the import's single legitimate call
    const char *real_symbol;
} orp_site_cfg;

static const orp_site_cfg ORP_SITES[ORP_SITE_COUNT] = {
    { "NewMarkUpload.AfterPlayUploadAsync", 0x97C958u, 0xD10203FFu, 0x80, 0x97C95Cu, 0xA9026FFCu,
      0x11F2F14u, 0x14FC738u, 0x7A1BF4u, "MTAudioProcessingTapCreate" },
    { "UserManagement.LoginAsync", 0x9AD06Cu, 0xD10203FFu, 0x80, 0x9AD070u, 0xA90367FAu,
      0x11F2F20u, 0x14FC740u, 0x7A1FECu, "MTAudioProcessingTapGetSourceAudio" },
    { "UserManagement.RegisterAsync", 0x9AEB88u, 0xD10183FFu, 0x60, 0x9AEB8Cu, 0xA90167FAu,
      0x11F2DACu, 0x14FC648u, 0x7A0270u, "CMAudioFormatDescriptionGetRichestDecodableFormat" },
    // UI1TitleScreen.JumpRegister (opens the dead website): always skipped, so no `sub sp` needed.
    { "UI1TitleScreen.JumpRegister", 0x9AD38Cu, 0xA9BE4FF4u, 0, 0x9AD390u, 0xA9017BFDu,
      0x11F2E3Cu, 0x14FC6A8u, 0x7A0C8Cu, "CMVideoFormatDescriptionGetPresentationDimensions" },
};

#endif
