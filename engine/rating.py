"""Offline Rating engine for Dynamite.

The per-chart rating is the closed form

    R = trunc( max( acc * 50 , acc^8 * D^3 - D^2.8 ) ),   acc = (Perfect + Good/2) / (Perfect + Good + Miss)

It is NOT an official formula (the original lived on the server). The evidence for it is recorded in docs/FINDINGS.md:
it reproduces 396 of the 397 full-R values of the community chart table exactly (max error 1) and several real in-game results.
The expression was published by the Dynamite community (it appears in the ExplodeX private-server project).
"""
import math

# ---------- shared ----------

def accuracy(perfect, good, miss):
    """acc = (P + G/2) / (P + G + M); 0 if no notes."""
    n = perfect + good + miss
    if n <= 0:
        return 0.0
    return (perfect + good / 2.0) / n


def full_r(d):
    """R of a perfect (100% acc) play. Verified against data/charts.csv (D 11..17)."""
    return float(int(d ** 3 - d ** 2.8))


def r_goodbird(d, p, g, m):
    acc = accuracy(p, g, m)
    return float(int(max(acc * 50.0, acc ** 8 * d ** 3 - d ** 2.8)))   # truncation, like the original int cast


ALGORITHMS = {
    "goodbird": r_goodbird,
}
DEFAULT_ALGORITHM = "goodbird"


def chart_rating(d, perfect, good, miss, algorithm=DEFAULT_ALGORITHM):
    return ALGORITHMS[algorithm](d, perfect, good, miss)


def overall_rating(chart_ratings, top_n=20):
    """Best-N rule: one best value per chart, take the top N, SUM (not average), round half up."""
    best = sorted(chart_ratings, reverse=True)[:top_n]
    return int(math.floor(sum(best) + 0.5))
