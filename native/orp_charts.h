// Chart-constant lookup: (title, difficulty) -> D.
// Built-in table (397 charts, D 11..17) + optional user overrides loaded from a
// CSV file the user can edit through the Files app.
#ifndef ORP_CHARTS_H
#define ORP_CHARTS_H

#ifdef __cplusplus
extern "C" {
#endif

// ChartInfoManager.Difficulties: B=0 N=1 H=2 M=3 G=4 T=5
const char *orp_difficulty_class(int difficulty_enum);   // "CASUAL","NORMAL","HARD","MEGA","GIGA","TERA", or "?"

// Inverse of orp_difficulty_class (case-insensitive); -1 if unknown.
int orp_class_index(const char *cls);

// Constant D for a chart, or 0 when unknown. Overrides win over the built-in table.
double orp_chart_constant(const char *title_utf8, int difficulty_enum);

// Load overrides: one chart per line "title,CLASS,constant" (title may contain
// commas; the last two comma-separated fields are CLASS and the number). Lines
// starting with '#' are ignored. Returns the number of entries loaded.
int orp_charts_load_overrides(const char *path);

// Number of built-in entries (for tests).
int orp_charts_builtin_count(void);

#ifdef __cplusplus
}
#endif
#endif
