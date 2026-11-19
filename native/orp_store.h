// Local persistence (SQLite). Mirrors engine/storage.py.
// `plays` is the source of truth; ratings are derived and cached, so changing a
// chart constant or the algorithm only needs a recompute.
#ifndef ORP_STORE_H
#define ORP_STORE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct orp_store orp_store;

typedef struct {
    char chart_key[256];
    char title[200];
    char difficulty[16];
    double constant;     // chart constant D
    int score, perfect, good, miss;
    int bleed, mirror;
    double rating;       // per-chart R of this (best) play
    double accuracy;     // 0..1
    long long played_at; // unix seconds
} orp_row;

// Opens (creating if needed) the database. Returns NULL on failure.
orp_store *orp_store_open(const char *path);
void orp_store_close(orp_store *s);

int orp_store_algorithm(orp_store *s);               // current algorithm id
int orp_store_set_algorithm(orp_store *s, int algo); // recomputes everything; 0 = ok

// Insert/update chart metadata. constant <= 0 means "unknown, keep existing".
int orp_store_upsert_chart(orp_store *s, const char *key, const char *title,
                           const char *difficulty, double constant);
// Change a constant (> 0) and recompute that chart's plays.
int orp_store_set_constant(orp_store *s, const char *key, double constant);

// Record one finished play. alive=0 plays are stored but never rated.
// out_rating receives the rating (or -1 when the chart has no known constant or
// alive == 0). out_is_best is 1 when this play beats every earlier rated play.
// Returns 0 on success.
int orp_store_record_play(orp_store *s, const char *key, const char *title,
                          const char *difficulty, double constant, int score,
                          int perfect, int good, int miss, int bleed, int mirror,
                          int alive, long long played_at, double *out_rating,
                          int *out_is_best);

// Same as orp_store_record_play, with a flag marking the play as synthetic (imported from a seed file, not played).
int orp_store_record_play_ex(orp_store *s, const char *key, const char *title,
                             const char *difficulty, double constant, int score,
                             int perfect, int good, int miss, int bleed, int mirror,
                             int alive, long long played_at, int synthetic,
                             double *out_rating, int *out_is_best);
// Number of synthetic plays / delete them all (returns how many were removed).
int orp_store_synthetic_count(orp_store *s);
int orp_store_delete_synthetic(orp_store *s);

// Fills rows with the best play per chart (by rating), top `max` descending.
// Returns the number of rows written.
int orp_store_best(orp_store *s, orp_row *rows, int max);
// Overall rating from the best 20 charts.
int orp_store_overall(orp_store *s);
// Charts with at least one finished play but no known constant (so unrated).
// Fills chart_key/title/difficulty only. Returns the number written.
int orp_store_unrated(orp_store *s, orp_row *rows, int max);
// Number of stored plays.
int orp_store_play_count(orp_store *s);
int orp_store_recalculate_all(orp_store *s);
int orp_store_integrity_ok(orp_store *s);  // 1 = ok

#ifdef __cplusplus
}
#endif
#endif
