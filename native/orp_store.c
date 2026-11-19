#include "orp_store.h"
#include "orp_engine.h"
#include <sqlite3.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct orp_store {
    sqlite3 *db;
    int algo;
};

static const char *SCHEMA =
    "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);"
    "CREATE TABLE IF NOT EXISTS charts ("
    " chart_key TEXT PRIMARY KEY,"
    " title TEXT NOT NULL DEFAULT '',"
    " difficulty TEXT NOT NULL DEFAULT '',"
    " constant_d REAL);"
    "CREATE TABLE IF NOT EXISTS plays ("
    " id INTEGER PRIMARY KEY AUTOINCREMENT,"
    " chart_key TEXT NOT NULL REFERENCES charts(chart_key),"
    " score INTEGER NOT NULL,"
    " perfect INTEGER NOT NULL CHECK (perfect >= 0),"
    " good INTEGER NOT NULL CHECK (good >= 0),"
    " miss INTEGER NOT NULL CHECK (miss >= 0),"
    " bleed INTEGER NOT NULL DEFAULT 0,"
    " mirror INTEGER NOT NULL DEFAULT 0,"
    " alive INTEGER NOT NULL DEFAULT 1,"
    " played_at INTEGER NOT NULL,"
    " rating REAL);"
    "CREATE INDEX IF NOT EXISTS idx_plays_chart ON plays(chart_key);";

static int exec(sqlite3 *db, const char *sql) {
    return sqlite3_exec(db, sql, NULL, NULL, NULL) == SQLITE_OK ? 0 : -1;
}

orp_store *orp_store_open(const char *path) {
    orp_store *s = (orp_store *)calloc(1, sizeof(*s));
    if (!s) return NULL;
    if (sqlite3_open(path, &s->db) != SQLITE_OK) {
        sqlite3_close(s->db);
        free(s);
        return NULL;
    }
    sqlite3_busy_timeout(s->db, 2000);
    exec(s->db, "PRAGMA foreign_keys = ON;");
    exec(s->db, "PRAGMA journal_mode = WAL;");
    if (exec(s->db, SCHEMA) != 0) {
        sqlite3_close(s->db);
        free(s);
        return NULL;
    }
    {   // migration: older databases have no `synthetic` column
        sqlite3_stmt *ti = NULL;
        int has = 0;
        if (sqlite3_prepare_v2(s->db, "PRAGMA table_info(plays)", -1, &ti, NULL) == SQLITE_OK) {
            while (sqlite3_step(ti) == SQLITE_ROW) if (strcmp((const char *)sqlite3_column_text(ti, 1), "synthetic") == 0) has = 1;
        }
        sqlite3_finalize(ti);
        if (!has) exec(s->db, "ALTER TABLE plays ADD COLUMN synthetic INTEGER NOT NULL DEFAULT 0;");
    }
    exec(s->db, "INSERT OR IGNORE INTO meta VALUES ('schema_version','1');");
    exec(s->db, "INSERT OR IGNORE INTO meta VALUES ('algorithm','0');");
    sqlite3_stmt *st = NULL;
    s->algo = ORP_ALGO_GOODBIRD;
    if (sqlite3_prepare_v2(s->db, "SELECT value FROM meta WHERE key='algorithm'", -1, &st, NULL) == SQLITE_OK) {
        if (sqlite3_step(st) == SQLITE_ROW) {
            int a = atoi((const char *)sqlite3_column_text(st, 0));
            if (a >= 0 && a < ORP_ALGO_COUNT) s->algo = a;
        }
    }
    sqlite3_finalize(st);
    return s;
}

void orp_store_close(orp_store *s) {
    if (!s) return;
    sqlite3_close(s->db);
    free(s);
}

int orp_store_algorithm(orp_store *s) { return s->algo; }

static int constant_of(orp_store *s, const char *key, double *out) {
    sqlite3_stmt *st = NULL;
    int found = 0;
    if (sqlite3_prepare_v2(s->db, "SELECT constant_d FROM charts WHERE chart_key=?", -1, &st, NULL) != SQLITE_OK)
        return 0;
    sqlite3_bind_text(st, 1, key, -1, SQLITE_TRANSIENT);
    if (sqlite3_step(st) == SQLITE_ROW && sqlite3_column_type(st, 0) != SQLITE_NULL) {
        *out = sqlite3_column_double(st, 0);
        found = 1;
    }
    sqlite3_finalize(st);
    return found;
}

static int recalc_chart(orp_store *s, const char *key) {
    double d = 0;
    int known = constant_of(s, key, &d);
    sqlite3_stmt *sel = NULL, *upd = NULL;
    if (sqlite3_prepare_v2(s->db, "SELECT id,perfect,good,miss,alive FROM plays WHERE chart_key=?", -1, &sel, NULL) != SQLITE_OK)
        return -1;
    if (sqlite3_prepare_v2(s->db, "UPDATE plays SET rating=? WHERE id=?", -1, &upd, NULL) != SQLITE_OK) {
        sqlite3_finalize(sel);
        return -1;
    }
    sqlite3_bind_text(sel, 1, key, -1, SQLITE_TRANSIENT);
    while (sqlite3_step(sel) == SQLITE_ROW) {
        sqlite3_int64 id = sqlite3_column_int64(sel, 0);
        int alive = sqlite3_column_int(sel, 4);
        sqlite3_reset(upd);
        if (known && alive)
            sqlite3_bind_double(upd, 1, orp_chart_rating(s->algo, d, sqlite3_column_int(sel, 1), sqlite3_column_int(sel, 2), sqlite3_column_int(sel, 3)));
        else
            sqlite3_bind_null(upd, 1);
        sqlite3_bind_int64(upd, 2, id);
        sqlite3_step(upd);
    }
    sqlite3_finalize(sel);
    sqlite3_finalize(upd);
    return 0;
}

int orp_store_recalculate_all(orp_store *s) {
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(s->db, "SELECT chart_key FROM charts", -1, &st, NULL) != SQLITE_OK) return -1;
    // collect first: we must not run nested statements on the same connection while iterating charts with recalc? (allowed in SQLite, but keep simple)
    int cap = 64, n = 0;
    char **keys = (char **)malloc(sizeof(char *) * (size_t)cap);
    while (sqlite3_step(st) == SQLITE_ROW) {
        if (n == cap) { cap *= 2; keys = (char **)realloc(keys, sizeof(char *) * (size_t)cap); }
        keys[n++] = strdup((const char *)sqlite3_column_text(st, 0));
    }
    sqlite3_finalize(st);
    exec(s->db, "BEGIN;");
    for (int i = 0; i < n; i++) { recalc_chart(s, keys[i]); free(keys[i]); }
    exec(s->db, "COMMIT;");
    free(keys);
    return 0;
}

int orp_store_set_algorithm(orp_store *s, int algo) {
    if (algo < 0 || algo >= ORP_ALGO_COUNT) return -1;
    s->algo = algo;
    char sql[96];
    snprintf(sql, sizeof sql, "UPDATE meta SET value='%d' WHERE key='algorithm'", algo);
    exec(s->db, sql);
    return orp_store_recalculate_all(s);
}

int orp_store_upsert_chart(orp_store *s, const char *key, const char *title, const char *difficulty, double constant) {
    sqlite3_stmt *st = NULL;
    const char *sql =
        "INSERT INTO charts(chart_key,title,difficulty,constant_d) VALUES (?,?,?,?)"
        " ON CONFLICT(chart_key) DO UPDATE SET"
        " title=CASE WHEN excluded.title<>'' THEN excluded.title ELSE title END,"
        " difficulty=CASE WHEN excluded.difficulty<>'' THEN excluded.difficulty ELSE difficulty END,"
        " constant_d=COALESCE(excluded.constant_d, constant_d)";
    if (sqlite3_prepare_v2(s->db, sql, -1, &st, NULL) != SQLITE_OK) return -1;
    sqlite3_bind_text(st, 1, key, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, title ? title : "", -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 3, difficulty ? difficulty : "", -1, SQLITE_TRANSIENT);
    if (constant > 0) sqlite3_bind_double(st, 4, constant); else sqlite3_bind_null(st, 4);
    int rc = sqlite3_step(st);
    sqlite3_finalize(st);
    return rc == SQLITE_DONE ? 0 : -1;
}

int orp_store_set_constant(orp_store *s, const char *key, double constant) {
    if (constant <= 0) return -1;
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(s->db, "UPDATE charts SET constant_d=? WHERE chart_key=?", -1, &st, NULL) != SQLITE_OK) return -1;
    sqlite3_bind_double(st, 1, constant);
    sqlite3_bind_text(st, 2, key, -1, SQLITE_TRANSIENT);
    sqlite3_step(st);
    sqlite3_finalize(st);
    return recalc_chart(s, key);
}

static int best_rating_of(orp_store *s, const char *key, double *out) {
    sqlite3_stmt *st = NULL;
    int found = 0;
    if (sqlite3_prepare_v2(s->db, "SELECT MAX(rating) FROM plays WHERE chart_key=?", -1, &st, NULL) != SQLITE_OK) return 0;
    sqlite3_bind_text(st, 1, key, -1, SQLITE_TRANSIENT);
    if (sqlite3_step(st) == SQLITE_ROW && sqlite3_column_type(st, 0) != SQLITE_NULL) {
        *out = sqlite3_column_double(st, 0);
        found = 1;
    }
    sqlite3_finalize(st);
    return found;
}

int orp_store_record_play_ex(orp_store *s, const char *key, const char *title, const char *difficulty,
                             double constant, int score, int perfect, int good, int miss, int bleed,
                             int mirror, int alive, long long played_at, int synthetic, double *out_rating, int *out_is_best) {
    if (perfect < 0 || good < 0 || miss < 0) return -1;
    if (orp_store_upsert_chart(s, key, title, difficulty, constant) != 0) return -1;
    double prev = 0;
    int had_prev = best_rating_of(s, key, &prev);
    double d = 0;
    int known = constant_of(s, key, &d);
    double r = -1;
    if (alive && known) r = orp_chart_rating(s->algo, d, perfect, good, miss);

    sqlite3_stmt *st = NULL;
    const char *sql =
        "INSERT INTO plays(chart_key,score,perfect,good,miss,bleed,mirror,alive,played_at,rating,synthetic)"
        " VALUES (?,?,?,?,?,?,?,?,?,?,?)";
    if (sqlite3_prepare_v2(s->db, sql, -1, &st, NULL) != SQLITE_OK) return -1;
    sqlite3_bind_text(st, 1, key, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(st, 2, score);
    sqlite3_bind_int(st, 3, perfect);
    sqlite3_bind_int(st, 4, good);
    sqlite3_bind_int(st, 5, miss);
    sqlite3_bind_int(st, 6, bleed ? 1 : 0);
    sqlite3_bind_int(st, 7, mirror ? 1 : 0);
    sqlite3_bind_int(st, 8, alive ? 1 : 0);
    sqlite3_bind_int64(st, 9, played_at > 0 ? played_at : (long long)time(NULL));
    if (r >= 0) sqlite3_bind_double(st, 10, r); else sqlite3_bind_null(st, 10);
    sqlite3_bind_int(st, 11, synthetic ? 1 : 0);
    int rc = sqlite3_step(st);
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) return -1;
    if (out_rating) *out_rating = r;
    if (out_is_best) *out_is_best = (r >= 0 && (!had_prev || r > prev)) ? 1 : 0;
    return 0;
}

int orp_store_record_play(orp_store *s, const char *key, const char *title, const char *difficulty,
                          double constant, int score, int perfect, int good, int miss, int bleed,
                          int mirror, int alive, long long played_at, double *out_rating, int *out_is_best) {
    return orp_store_record_play_ex(s, key, title, difficulty, constant, score, perfect, good, miss, bleed, mirror,
                                    alive, played_at, 0, out_rating, out_is_best);
}

int orp_store_synthetic_count(orp_store *s) {
    sqlite3_stmt *st = NULL;
    int n = 0;
    if (sqlite3_prepare_v2(s->db, "SELECT COUNT(*) FROM plays WHERE synthetic=1", -1, &st, NULL) == SQLITE_OK && sqlite3_step(st) == SQLITE_ROW)
        n = sqlite3_column_int(st, 0);
    sqlite3_finalize(st);
    return n;
}

int orp_store_delete_synthetic(orp_store *s) {
    int n = orp_store_synthetic_count(s);
    exec(s->db, "DELETE FROM plays WHERE synthetic=1;");
    exec(s->db, "DELETE FROM charts WHERE chart_key NOT IN (SELECT DISTINCT chart_key FROM plays);");
    return n;
}

int orp_store_best(orp_store *s, orp_row *rows, int max) {
    const char *sql =
        "SELECT c.chart_key,c.title,c.difficulty,c.constant_d,p.score,p.perfect,p.good,p.miss,"
        "       p.bleed,p.mirror,p.rating,p.played_at"
        " FROM plays p JOIN charts c USING(chart_key)"
        " WHERE p.rating IS NOT NULL AND p.id = ("
        "   SELECT id FROM plays q WHERE q.chart_key=p.chart_key AND q.rating IS NOT NULL"
        "   ORDER BY q.rating DESC, q.score DESC, q.id ASC LIMIT 1)"
        " ORDER BY p.rating DESC, c.chart_key LIMIT ?";
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(s->db, sql, -1, &st, NULL) != SQLITE_OK) return 0;
    sqlite3_bind_int(st, 1, max);
    int n = 0;
    while (n < max && sqlite3_step(st) == SQLITE_ROW) {
        orp_row *r = &rows[n++];
        memset(r, 0, sizeof *r);
        strlcpy(r->chart_key, (const char *)sqlite3_column_text(st, 0), sizeof r->chart_key);
        strlcpy(r->title, (const char *)sqlite3_column_text(st, 1), sizeof r->title);
        strlcpy(r->difficulty, (const char *)sqlite3_column_text(st, 2), sizeof r->difficulty);
        r->constant = sqlite3_column_double(st, 3);
        r->score = sqlite3_column_int(st, 4);
        r->perfect = sqlite3_column_int(st, 5);
        r->good = sqlite3_column_int(st, 6);
        r->miss = sqlite3_column_int(st, 7);
        r->bleed = sqlite3_column_int(st, 8);
        r->mirror = sqlite3_column_int(st, 9);
        r->rating = sqlite3_column_double(st, 10);
        r->played_at = sqlite3_column_int64(st, 11);
        r->accuracy = orp_accuracy(r->perfect, r->good, r->miss);
    }
    sqlite3_finalize(st);
    return n;
}

int orp_store_overall(orp_store *s) {
    orp_row rows[20];
    double r[20];
    int n = orp_store_best(s, rows, 20);
    for (int i = 0; i < n; i++) r[i] = rows[i].rating;
    return orp_overall_rating(r, n, 20);
}

int orp_store_play_count(orp_store *s) {
    sqlite3_stmt *st = NULL;
    int n = 0;
    if (sqlite3_prepare_v2(s->db, "SELECT COUNT(*) FROM plays", -1, &st, NULL) == SQLITE_OK && sqlite3_step(st) == SQLITE_ROW)
        n = sqlite3_column_int(st, 0);
    sqlite3_finalize(st);
    return n;
}

int orp_store_integrity_ok(orp_store *s) {
    sqlite3_stmt *st = NULL;
    int ok = 0;
    if (sqlite3_prepare_v2(s->db, "PRAGMA integrity_check", -1, &st, NULL) == SQLITE_OK && sqlite3_step(st) == SQLITE_ROW)
        ok = strcmp((const char *)sqlite3_column_text(st, 0), "ok") == 0;
    sqlite3_finalize(st);
    return ok;
}

int orp_store_unrated(orp_store *s, orp_row *rows, int max) {
    const char *sql =
        "SELECT DISTINCT c.chart_key,c.title,c.difficulty FROM charts c JOIN plays p USING(chart_key)"
        " WHERE c.constant_d IS NULL AND p.alive=1 ORDER BY c.title LIMIT ?";
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(s->db, sql, -1, &st, NULL) != SQLITE_OK) return 0;
    sqlite3_bind_int(st, 1, max);
    int n = 0;
    while (n < max && sqlite3_step(st) == SQLITE_ROW) {
        orp_row *r = &rows[n++];
        memset(r, 0, sizeof *r);
        strlcpy(r->chart_key, (const char *)sqlite3_column_text(st, 0), sizeof r->chart_key);
        strlcpy(r->title, (const char *)sqlite3_column_text(st, 1), sizeof r->title);
        strlcpy(r->difficulty, (const char *)sqlite3_column_text(st, 2), sizeof r->difficulty);
        r->rating = -1;
    }
    sqlite3_finalize(st);
    return n;
}
