import sys, json, re, subprocess, bisect
U, SJ, start, stop = sys.argv[1], sys.argv[2], int(sys.argv[3],16), int(sys.argv[4],16)
m = sorted((x['Address'], x['Name']) for x in json.load(open(SJ))['ScriptMethod'])
addrs=[a for a,_ in m]
def nm(a):
    i=bisect.bisect_right(addrs,a)-1
    return m[i][1] if i>=0 and a-m[i][0]<0x4000 and a==m[i][0] else None
out=subprocess.run(["xcrun","llvm-objdump","-d","--no-show-raw-insn","--start-address=0x%x"%start,"--stop-address=0x%x"%stop,U],capture_output=True,text=True).stdout
for line in out.splitlines():
    mm=re.search(r'\b(bl|b)\s+0x([0-9a-f]+)',line)
    if mm:
        n=nm(int(mm.group(2),16))
        line+="    ; "+(n if n else "?")
    print(line)
