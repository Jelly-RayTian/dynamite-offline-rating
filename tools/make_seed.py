#!/usr/bin/env python3
"""Generate a seed.csv of SYNTHETIC plays that adds up to an exact total Rating.

    make_seed.py <__rena_index_2> <account> <target_rating> [--extra N] [--seed S] > seed.csv

These plays are NOT real. They are written into the local offline Rating database only (flagged `synthetic`;
the app shows how many there are and `seed_clear.txt` removes them). Nothing is uploaded anywhere.

How it works
  * picks the 20 distinct charts with the highest full-R among the charts that are in YOUR index and have a known constant
  * scales a per-chart target R so that the best-20 total hits <target>, converts each target into judgments
    (perfect/good/miss) with the verified formula, and finally nudges the note counts of single charts until the
    total is EXACTLY <target>
  * adds a few weaker plays (never entering the top 20) so the list looks natural
"""
import csv, os, random, sys, time, unicodedata

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from engine import rating as R


def norm(t):
    return unicodedata.normalize("NFKC", t).lower().strip()


def load_table():
    t = {}
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data", "charts.csv")
    for row in csv.DictReader(open(path, encoding="utf-8")):
        t[(norm(row["title"]), row["grade"].split()[0])] = float(row["constant"])
    return t


def load_candidates(index_path):
    table = load_table()
    txt = open(index_path, encoding="utf-8", errors="replace").read()
    entries, cur = [], None
    for line in txt.splitlines():
        line = line.rstrip("\r")
        if line.startswith("B."):
            cur = {"id": line[2:]}
        elif line == "E." and cur is not None:
            entries.append(cur)
            cur = None
        elif cur is not None and len(line) > 2 and line[1] == "?":
            cur[line[0]] = line[2:]
    best = {}
    for e in entries:
        for diff in (e.get("H") or "").split(";"):
            if not diff:
                continue
            cls, _, lvl = diff.partition(",")
            cls = cls.strip().upper()
            d = table.get((norm(e.get("N", "")), cls))
            if not d:
                continue
            c = dict(title=e["N"], cls=cls, level=int(lvl or 0), uuid=e["id"], ranked=e.get("R") == "1", D=d, full=R.full_r(d))
            k = (norm(c["title"]), cls)
            if k not in best or (c["ranked"] and not best[k]["ranked"]):   # one entry per song+difficulty, ranked preferred
                best[k] = c
    return sorted(best.values(), key=lambda c: (-c["full"], c["title"]))


def goodbird(D, P, G, M):
    return int(R.chart_rating(D, P, G, M, "goodbird"))


def judgments_for(D, target, N, M):
    """(P, G, M) with total notes N whose rating is closest to `target`."""
    bestv = None
    for G in range(0, int(N * 0.12)):
        P = N - G - M
        if P < 0:
            break
        err = abs(goodbird(D, P, G, M) - target)
        if bestv is None or err < bestv[0]:
            bestv = (err, P, G, M)
    return bestv[1], bestv[2], bestv[3]


def cosmetic_score(P, G, M):
    N = P + G + M
    acc = (P + G / 2.0) / N
    s = 1_000_000 * acc
    if M:
        s -= 15_000 + 1_500 * M
    s -= 80 * G
    return int(max(0, min(1_000_000, round(s))))


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    opts = dict(a.split("=", 1) for a in sys.argv[1:] if a.startswith("--") and "=" in a)
    if len(args) != 3:
        sys.exit(__doc__)
    index_path, account, target = args[0], args[1], int(args[2])
    n_extra = int(opts.get("--extra", 6))
    rng = random.Random(int(opts.get("--seed", 20261118)))

    cands = load_candidates(index_path)
    if len(cands) < 20:
        sys.exit("need at least 20 charts with a known constant, found %d" % len(cands))
    top = cands[:20]
    cap = sum(c["full"] for c in top)
    if target > cap:
        sys.exit("target %d is above the best possible %d for the charts on this device" % (target, int(cap)))

    # per-chart target proportional to the full-R, then judgments
    plans = []
    for c in top:
        tgt = min(c["full"], round(target * c["full"] / cap))
        N = rng.randint(1100, 2300)
        M = rng.choice([0, 0, 1, 1, 2, 3])
        P, G, M = judgments_for(c["D"], tgt, N, M)
        plans.append(dict(c=c, N=N, P=P, G=G, M=M, r=goodbird(c["D"], P, G, M)))

    # nudge single charts' note counts (fine control: ~0.15 R per note) until the total is exactly the target
    for _ in range(40):
        delta = target - sum(p["r"] for p in plans)
        if delta == 0:
            break
        best = None
        for i, p in enumerate(plans):
            for dn in range(-150, 151):
                if dn == 0:
                    continue
                P2 = p["P"] + dn
                if P2 < 0:
                    continue
                r2 = goodbird(p["c"]["D"], P2, p["G"], p["M"])
                err = abs(delta - (r2 - p["r"]))
                if best is None or err < best[0]:
                    best = (err, i, P2, r2)
        _, i, P2, r2 = best
        plans[i]["P"], plans[i]["r"] = P2, r2
        plans[i]["N"] = P2 + plans[i]["G"] + plans[i]["M"]
    total = sum(p["r"] for p in plans)
    assert total == target, "could not hit the target exactly (%d != %d)" % (total, target)

    # weaker extras that stay below the 20th best play
    floor_r = min(p["r"] for p in plans)
    extras = []
    for c in cands[20:20 + n_extra * 3]:
        if len(extras) >= n_extra:
            break
        tgt = min(int(c["full"] * 0.82), floor_r - 40)
        if tgt < 60:
            continue
        N = rng.randint(900, 2000)
        M = rng.choice([0, 1, 2, 4])
        P, G, M = judgments_for(c["D"], tgt, N, M)
        r = goodbird(c["D"], P, G, M)
        if r < floor_r:
            extras.append(dict(c=c, N=N, P=P, G=G, M=M, r=r))

    # self-check with the same rules as the app (best per chart, top 20, summed)
    allp = plans + extras
    per_chart = {}
    for p in allp:
        k = (p["c"]["uuid"], p["c"]["cls"])
        per_chart[k] = max(per_chart.get(k, 0), p["r"])
    overall = R.overall_rating(list(per_chart.values()))
    assert overall == target, "self-check failed: %d != %d" % (overall, target)

    now = int(time.time())
    rows = sorted(allp, key=lambda p: p["c"]["title"])
    print("# SYNTHETIC plays generated by tools/make_seed.py - not actually played. target total Rating = %d" % target)
    print("# account\tuuid\tCLASS\tlabel\ttitle\tperfect\tgood\tmiss\tscore\tbleed\tmirror\tplayed_at")
    for i, p in enumerate(rows):
        c = p["c"]
        label = "%s %d" % (c["cls"], c["level"]) if c["level"] else c["cls"]
        at = now - rng.randint(1, 30) * 86400 - rng.randint(0, 80000)
        print("\t".join(str(x) for x in (account, c["uuid"], c["cls"], label, c["title"], p["P"], p["G"], p["M"],
                                         cosmetic_score(p["P"], p["G"], p["M"]), 0, 0, at)))
    sys.stderr.write("plays: %d (top 20 + %d weaker), best-20 total = %d (target %d)\n" % (len(allp), len(extras), overall, target))
    for p in sorted(plans, key=lambda p: -p["r"]):
        c = p["c"]
        sys.stderr.write("  %5d  D%-5.2f %-4s %-34s P%d G%d M%d  acc %.2f%%\n" % (
            p["r"], c["D"], c["cls"], c["title"][:34], p["P"], p["G"], p["M"], R.accuracy(p["P"], p["G"], p["M"]) * 100))


if __name__ == "__main__":
    main()
