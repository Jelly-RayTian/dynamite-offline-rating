// Reader for the game's song index (Documents/__rena_index_2, plain text).
// Used to turn NewMarkUpload.lastChartId (a possibly truncated chart path) into the
// real title, difficulty class, level and chart UUID.
#ifndef ORP_INDEX_H
#define ORP_INDEX_H
#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    char title[200];
    char cls[16];     // CASUAL / NORMAL / HARD / MEGA / GIGA / TERA (upper-cased from the index)
    int level;        // displayed level, e.g. 15 (0 if absent)
    char uuid[40];    // chart id used by the game for score records
    int ranked;
} orp_index_hit;

// Sets the index file path (re-read automatically when the file changes).
void orp_index_set_path(const char *path);
// Finds the chart whose map path starts with `chart_id_prefix`.
// Returns 1 on a unique match, 0 if none, -1 if ambiguous (different charts match).
int orp_index_lookup(const char *chart_id_prefix, orp_index_hit *hit);
int orp_index_count(void);
// Cover image path (relative to Documents, e.g. "Song(Charter)/Song.jpg.rnx") of the chart with this uuid. 1 = found.
// First cover path in the index (used by the one-time self-test). 1 = found.
int orp_index_any_cover(char *out, size_t cap);
int orp_index_cover_for_uuid(const char *uuid, char *out, size_t cap);

#ifdef __cplusplus
}
#endif
#endif
