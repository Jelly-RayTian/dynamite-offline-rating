// Offline Rating engine (C port of engine/rating.py). Pure C, no platform dependencies.
// The formula is a community reconstruction, not the official one; see docs/FINDINGS.md for the evidence.
#ifndef ORP_ENGINE_H
#define ORP_ENGINE_H

#ifdef __cplusplus
extern "C" {
#endif

enum {
    ORP_ALGO_GOODBIRD = 0,  // trunc(max(acc*50, acc^8*D^3 - D^2.8))
    ORP_ALGO_COUNT
};

// acc = (P + G/2) / (P + G + M); 0 when there are no notes.
double orp_accuracy(int perfect, int good, int miss);
// R of a perfect play: trunc(D^3 - D^2.8).
double orp_full_r(double d);
// Per-chart rating. Returns a non-negative integer-valued double.
double orp_chart_rating(int algo, double d, int perfect, int good, int miss);
// Best-N rule: sum of the N largest values, rounded half up.
// `ratings` need not be sorted. Returns the overall rating.
int orp_overall_rating(const double *ratings, int count, int top_n);

#ifdef __cplusplus
}
#endif
#endif
