#!/usr/bin/env python3
"""Prepare a modified (UNSIGNED) Dynamite app bundle for OfflineRating.

  patch_ipa.py --ipa Dynamite.ipa --dylib OfflineRating.dylib --out WORKDIR --bundle-id com.example.dynamite

What it does (every assumption is verified first; any mismatch aborts untouched):
  1. unzip the IPA into WORKDIR (must not exist / be empty)
  2. UnityFramework: verify the call site, resume instruction, hijacked stub shape,
     its lazy-pointer slot and the single legitimate caller, then replace ONE
     instruction (4 bytes) at AfterPlayUploadAsync with `b <stub>`
  3. main executable: add LC_LOAD_WEAK_DYLIB @rpath/OfflineRating.dylib into the
     existing header padding
  4. copy the dylib into Frameworks/
  5. set CFBundleIdentifier
  6. drop old signatures (re-sign with tools/sign_app.sh)
Only touches the copy inside WORKDIR. The original IPA is never modified.
"""
import argparse, os, plistlib, shutil, struct, subprocess, sys, zipfile

import re as _re
CONFIG_H = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "native", "orp_patch_config.h")
EXPECTED_BUNDLE_ID = "com.tunergames.dynamite"
EXPECTED_VERSION = ("1.0.2", "59")


def load_sites():
    """Single source of truth: the hook table in native/orp_patch_config.h."""
    txt = open(CONFIG_H).read()
    pat = _re.compile(r'\{\s*"([^"]+)",\s*(0x[0-9A-Fa-f]+)u,\s*(0x[0-9A-Fa-f]+)u,\s*(0x[0-9A-Fa-f]+|[0-9]+),\s*(0x[0-9A-Fa-f]+)u,\s*(0x[0-9A-Fa-f]+)u,'
                      r'\s*(0x[0-9A-Fa-f]+)u,\s*(0x[0-9A-Fa-f]+)u,\s*(0x[0-9A-Fa-f]+)u,\s*"([^"]+)"\s*\}')
    sites = []
    for m in pat.finditer(txt):
        n, site, orig, imm, resume, rinsn, stub, slot, fwd, sym = m.groups()
        sites.append(dict(name=n, site=int(site, 16), orig=int(orig, 16), imm=int(imm, 0), resume=int(resume, 16), resume_insn=int(rinsn, 16),
                          stub=int(stub, 16), slot=int(slot, 16), fwd=int(fwd, 16), sym=sym))
    return sites


def die(msg):
    print("ABORT:", msg, file=sys.stderr)
    sys.exit(1)


def u32(d, off):
    return struct.unpack_from("<I", d, off)[0]


def verify_and_patch_unity(path):
    sites = load_sites()
    if len(sites) != 4:
        die("expected 4 hook sites in %s, found %d" % (CONFIG_H, len(sites)))
    if len({x["stub"] for x in sites}) != len(sites) or len({x["slot"] for x in sites}) != len(sites):
        die("hook sites must use distinct stubs / slots")
    d = bytearray(open(path, "rb").read())
    if u32(d, 0) != 0xFEEDFACF:
        die("UnityFramework is not a thin 64-bit Mach-O")
    patches = []
    # verify everything first; modify nothing unless every site checks out
    for x in sites:
        site, stub = x["site"], x["stub"]
        orig = x["orig"]
        if x["imm"] and orig != (0xD10003FF | (x["imm"] << 10)):
            die("%s: orig_insn is not `sub sp, sp, #%#x`" % (x["name"], x["imm"]))
        enc = 0x14000000 | ((((stub - site) >> 2)) & 0x3FFFFFF)    # b stub
        cur = u32(d, site)
        if cur == enc:
            die("%s: already patched" % x["name"])
        if cur != orig:
            die("%s: unexpected instruction at %#x: %08x (expected %08x) - wrong Dynamite build?" % (x["name"], site, cur, orig))
        if u32(d, x["resume"]) != x["resume_insn"] or x["resume"] != site + 4:
            die("%s: unexpected resume instruction" % x["name"])
        i0, i1, i2 = struct.unpack_from("<III", d, stub)
        if (i0 & 0x9F00001F) != 0x90000010 or (i1 & 0xFFC003FF) != 0xF9400210 or i2 != 0xD61F0200:
            die("%s: hijack stub %#x has an unexpected shape" % (x["name"], stub))
        immlo, immhi = (i0 >> 29) & 3, (i0 >> 5) & 0x7FFFF
        imm = (immhi << 2) | immlo
        if imm & 0x100000:
            imm -= 0x200000
        slot = (stub & ~0xFFF) + (imm << 12) + ((i1 >> 10) & 0xFFF) * 8
        if slot != x["slot"]:
            die("%s: stub slot is %#x, expected %#x" % (x["name"], slot, x["slot"]))
        w = u32(d, x["fwd"] - 4)  # the stub's single legitimate call must be `bl stub`
        if (w >> 26) != 0x25:
            die("%s: expected a bl before %#x" % (x["name"], x["fwd"]))
        off = w & 0x3FFFFFF
        if off & 0x2000000:
            off -= 0x4000000
        if (x["fwd"] - 4) + off * 4 != stub:
            die("%s: call site at %#x does not target the stub" % (x["name"], x["fwd"] - 4))
        delta = stub - site
        if delta % 4 or abs(delta) >= (1 << 27):
            die("%s: branch out of range" % x["name"])
        patches.append((site, orig, enc, x["name"], stub))
    for site, orig, enc, name, stub in patches:
        struct.pack_into("<I", d, site, enc)
        print("UnityFramework: %-36s %#x  %08x -> %08x (b %#x)" % (name, site, orig, enc, stub))
    open(path, "wb").write(d)


def add_weak_dylib(path, name):
    d = bytearray(open(path, "rb").read())
    magic, cputype, _, _, ncmds, sizeofcmds, flags, _ = struct.unpack_from("<8I", d, 0)
    if magic != 0xFEEDFACF:
        die("main executable is not a thin 64-bit Mach-O")
    # parse commands, find the lowest section offset (= end of header padding)
    off, first_sect = 32, 1 << 62
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", d, off)
        if cmd == 0x80000018 or cmd == 0xC:  # LC_LOAD_WEAK_DYLIB / LC_LOAD_DYLIB
            nameoff = struct.unpack_from("<I", d, off + 8)[0]
            nm = bytes(d[off + nameoff:off + size]).split(b"\0")[0].decode()
            if nm == name:
                die("load command for %s already present" % name)
        if cmd == 0x19:  # LC_SEGMENT_64
            nsects = struct.unpack_from("<I", d, off + 64)[0]
            for s in range(nsects):
                so = off + 72 + s * 80
                sect_off = struct.unpack_from("<I", d, so + 48)[0]
                if sect_off:
                    first_sect = min(first_sect, sect_off)
        off += size
    enc = name.encode() + b"\0"
    size = 24 + len(enc)
    size = (size + 7) & ~7
    room = first_sect - (32 + sizeofcmds)
    if room < size:
        die("not enough header padding (%d < %d)" % (room, size))
    end = 32 + sizeofcmds
    if any(d[end:end + size]):
        die("header padding is not zero")
    lc = struct.pack("<IIIIII", 0x80000018, size, 24, 2, 0x10000, 0x10000) + enc
    lc = lc.ljust(size, b"\0")
    d[end:end + size] = lc
    struct.pack_into("<II", d, 16, ncmds + 1, sizeofcmds + size)
    open(path, "wb").write(d)
    print("main executable: added LC_LOAD_WEAK_DYLIB %s (header padding left: %d bytes)" % (name, room - size))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ipa", required=True)
    ap.add_argument("--dylib", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--bundle-id", required=True)
    ap.add_argument("--display-name", default=None, help="home-screen / Files app name")
    ap.add_argument("--debug-skip-unity-patch", action="store_true", help="bisecting aid")
    ap.add_argument("--debug-skip-dylib", action="store_true", help="bisecting aid")
    a = ap.parse_args()

    if os.path.exists(a.out) and os.listdir(a.out):
        die("output dir %s is not empty" % a.out)
    os.makedirs(a.out, exist_ok=True)
    with zipfile.ZipFile(a.ipa) as z:
        for n in z.namelist():  # zip-slip guard
            if n.startswith("/") or ".." in n.split("/"):
                die("unsafe path in IPA: %s" % n)
        z.extractall(a.out)
        # zipfile drops unix modes: restore exec bits from the archive
        for i in z.infolist():
            mode = (i.external_attr >> 16) & 0o777
            if mode:
                os.chmod(os.path.join(a.out, i.filename), mode)
    app = os.path.join(a.out, "Payload", "dynamite.app")
    if not os.path.isdir(app):
        die("Payload/dynamite.app not found")

    info_path = os.path.join(app, "Info.plist")
    info = plistlib.load(open(info_path, "rb"))
    if info.get("CFBundleIdentifier") != EXPECTED_BUNDLE_ID or \
            (info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")) != EXPECTED_VERSION:
        die("this is not Dynamite %s (%s): %s %s" % (EXPECTED_VERSION + (info.get("CFBundleIdentifier"), info.get("CFBundleVersion"))))

    if not a.debug_skip_unity_patch:
        verify_and_patch_unity(os.path.join(app, "Frameworks", "UnityFramework.framework", "UnityFramework"))
    if not a.debug_skip_dylib:
        add_weak_dylib(os.path.join(app, "dynamite"), "@rpath/OfflineRating.dylib")
        shutil.copy2(a.dylib, os.path.join(app, "Frameworks", "OfflineRating.dylib"))

    info["CFBundleIdentifier"] = a.bundle_id
    if a.display_name:
        info["CFBundleDisplayName"] = a.display_name
    with open(info_path, "wb") as f:
        plistlib.dump(info, f, fmt=plistlib.FMT_BINARY)
    print("Info.plist: CFBundleIdentifier ->", a.bundle_id)

    # strip signatures (must be re-signed)
    for p in (os.path.join(app, "dynamite"),
              os.path.join(app, "Frameworks", "UnityFramework.framework", "UnityFramework"),
              os.path.join(app, "Frameworks", "OfflineRating.dylib")):
        subprocess.run(["codesign", "--remove-signature", p], check=False, capture_output=True)
    for root, dirs, _ in os.walk(app):
        for dname in list(dirs):
            if dname == "_CodeSignature":
                shutil.rmtree(os.path.join(root, dname))
                dirs.remove(dname)
    print("done. Next: tools/sign_app.sh")


if __name__ == "__main__":
    main()
