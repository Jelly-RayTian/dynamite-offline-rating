import sys, json, struct, bisect
U, SJ = sys.argv[1], sys.argv[2]
targets = [int(x, 16) for x in sys.argv[3:]]
data = open(U, 'rb').read()
LO, HI = 0x6780, 0x11f2af4 + 0x100000
HI = min(HI, len(data))
meth = json.load(open(SJ))['ScriptMethod']
meth = sorted(((m['Address'], m['Name']) for m in meth))
addrs = [a for a, _ in meth]
def name_at(a):
    i = bisect.bisect_right(addrs, a) - 1
    return (meth[i][1], a - meth[i][0]) if i >= 0 else ("?", 0)
words = struct.unpack_from('<%dI' % ((HI - LO) // 4), data, LO)
tset = set(targets)
for idx, w in enumerate(words):
    op = w >> 26
    if op in (0x25, 0x05):                      # BL / B
        imm = w & 0x3FFFFFF
        if imm & 0x2000000: imm -= 0x4000000
        pc = LO + idx * 4
        t = pc + imm * 4
        if t in tset:
            n, off = name_at(pc)
            print("%s 0x%X -> 0x%X   in %s +0x%X" % ("BL" if op == 0x25 else "B ", pc, t, n, off))
