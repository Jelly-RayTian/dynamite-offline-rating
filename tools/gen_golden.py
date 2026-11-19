"""Golden vectors: Python engine (verified) -> text file consumed by the C test."""
import os, sys, random, csv
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from engine import rating
random.seed(20261118)
out = []
consts = [float(r["constant"]) for r in csv.DictReader(open(os.path.join(os.path.dirname(__file__), "..", "data", "charts.csv"), encoding="utf-8"))]
for algo, name in ((0, "goodbird"),):
    for _ in range(2000):
        d = random.choice(consts) if random.random() < 0.6 else round(random.uniform(5.7, 17.0), 2)
        n = random.randint(100, 3000)
        miss = random.choice([0, 0, 0, random.randint(0, 8)])
        good = random.choice([0, random.randint(0, max(1, n // 20)), random.randint(0, max(1, n // 5))])
        perfect = max(0, n - good - miss)
        v = rating.chart_rating(d, perfect, good, miss, name)
        out.append("%d %.4f %d %d %d %.12f" % (algo, d, perfect, good, miss, v))
# overall rating cases
rs = [random.randint(0, 2100) for _ in range(30)]
open(os.path.join(os.path.dirname(__file__), "..", "native", "tests", "golden_engine.txt"), "w").write("\n".join(out) + "\n")
print(len(out), "vectors")
