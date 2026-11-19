// Native tests (run on macOS): engine golden vectors from Python + store scenarios.
#include "../orp_engine.h"
#include "../orp_store.h"
#include <math.h>
#include <sqlite3.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int fails = 0, checks = 0;
#define CHECK(cond, ...) do { checks++; if (!(cond)) { fails++; printf("FAIL %s:%d ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static void test_golden(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) { printf("cannot open %s\n", path); exit(2); }
    int algo, p, g, m, n = 0;
    double d, exp;
    int bad = 0;
    while (fscanf(f, "%d %lf %d %d %d %lf", &algo, &d, &p, &g, &m, &exp) == 6) {
        double got = orp_chart_rating(algo, d, p, g, m);
        double tol = 0.0;
        if (fabs(got - exp) > tol) { if (bad++ < 5) printf("  mismatch algo=%d d=%.4f %d/%d/%d got %.9f exp %.9f\n", algo, d, p, g, m, got, exp); }
        n++;
    }
    fclose(f);
    CHECK(n == 2000, "read %d vectors", n);
    CHECK(bad == 0, "%d golden mismatches", bad);
    printf("golden: %d vectors, %d mismatches\n", n, bad);
}

static void test_engine_misc(void) {
    CHECK(orp_accuracy(100, 0, 0) == 1.0, "acc 1");
    CHECK(fabs(orp_accuracy(90, 10, 0) - 0.95) < 1e-12, "acc .95");
    CHECK(orp_accuracy(0, 0, 0) == 0.0, "acc empty");
    CHECK(orp_full_r(17.0) == 2125.0, "full r 17");
    CHECK(orp_full_r(10.0) == 369.0, "full r 10");
    // real-world point: R(17.0, 1991/1997) = 2008 (acc given directly via counts)
    CHECK(orp_chart_rating(ORP_ALGO_GOODBIRD, 17.0, 1991 * 2, 0, 0) == 2125.0, "perfect D17");
    // overall: sum top 20 only, half rounds up
    double a[26]; for (int i = 0; i < 25; i++) a[i] = 10.0; a[25] = 1.0;
    CHECK(orp_overall_rating(a, 26, 20) == 200, "top20 sum");
    double h[1] = {0.5};
    CHECK(orp_overall_rating(h, 1, 20) == 1, "half up");
    CHECK(orp_overall_rating(NULL, 0, 20) == 0, "empty");
}

static void tmpdb(char *buf, size_t n, const char *tag) { const char *d = getenv("ORP_TEST_DIR"); snprintf(buf, n, "%s/orp_test_%s_%d.db", d ? d : "/tmp", tag, (int)getpid()); }
static void rmdb(const char *p) { char b[300]; unlink(p); snprintf(b, sizeof b, "%s-wal", p); unlink(b); snprintf(b, sizeof b, "%s-shm", p); unlink(b); }

static void test_store(void) {
    char path[200]; tmpdb(path, sizeof path, "a");
    orp_store *s = orp_store_open(path);
    CHECK(s != NULL, "open");
    orp_row rows[20];
    CHECK(orp_store_best(s, rows, 20) == 0, "empty best");
    CHECK(orp_store_overall(s) == 0, "empty overall");
    CHECK(orp_store_integrity_ok(s), "integrity");

    // multiple results same chart keeps the best
    double r1, r2, r3; int b1, b2, b3;
    CHECK(orp_store_record_play(s, "c1", "Song", "GIGA", 12.0, 900000, 900, 80, 20, 0, 0, 1, 1000, &r1, &b1) == 0, "rec1");
    CHECK(orp_store_record_play(s, "c1", "Song", "GIGA", 0, 990000, 990, 10, 0, 0, 0, 1, 1001, &r2, &b2) == 0, "rec2");
    CHECK(orp_store_record_play(s, "c1", "Song", "GIGA", 0, 800000, 700, 200, 100, 0, 0, 1, 1002, &r3, &b3) == 0, "rec3");
    CHECK(b1 == 1 && b2 == 1 && b3 == 0, "best flags %d %d %d", b1, b2, b3);
    CHECK(r2 > r1 && r1 > r3, "ordering %f %f %f", r1, r2, r3);
    CHECK(orp_store_best(s, rows, 20) == 1 && rows[0].score == 990000, "best play kept");

    // failed play (alive=0) is stored but never rated
    double rf; int bf;
    CHECK(orp_store_record_play(s, "c1", "Song", "GIGA", 0, 1, 1000, 0, 0, 0, 0, 0, 1003, &rf, &bf) == 0 && rf < 0 && bf == 0, "dead play");
    CHECK(orp_store_play_count(s) == 4, "4 plays stored");
    CHECK(orp_store_best(s, rows, 20) == 1 && rows[0].score == 990000, "dead play ignored");

    // unknown constant -> not rated, later rated once constant known
    double ru; int bu;
    CHECK(orp_store_record_play(s, "c9", "NoD", "MEGA", 0, 1, 100, 0, 0, 0, 0, 1, 1004, &ru, &bu) == 0 && ru < 0, "unrated");
    CHECK(orp_store_best(s, rows, 20) == 1, "unrated excluded");
    orp_row un[8];
    CHECK(orp_store_unrated(s, un, 8) == 1 && !strcmp(un[0].title, "NoD") && !strcmp(un[0].difficulty, "MEGA"), "unrated listed");
    CHECK(orp_store_set_constant(s, "c9", 11.0) == 0, "set const");
    CHECK(orp_store_best(s, rows, 20) == 2, "now rated");
    CHECK(orp_store_unrated(s, un, 8) == 0, "no longer unrated");

    // restart persistence
    int ov = orp_store_overall(s);
    orp_store_close(s);
    s = orp_store_open(path);
    CHECK(s && orp_store_overall(s) == ov && orp_store_best(s, rows, 20) == 2, "persist across restart");

    // constant update recalculates
    double before = 0; orp_store_best(s, rows, 20); for (int i = 0; i < 2; i++) if (!strcmp(rows[i].chart_key, "c1")) before = rows[i].rating;
    orp_store_set_constant(s, "c1", 13.0);
    double after = 0; orp_store_best(s, rows, 20); for (int i = 0; i < 2; i++) if (!strcmp(rows[i].chart_key, "c1")) after = rows[i].rating;
    CHECK(after > before, "recalc on constant change %f -> %f", before, after);

    // algorithm switch recomputes; invalid rejected
    CHECK(orp_store_set_algorithm(s, ORP_ALGO_GOODBIRD) == 0, "set algo");
    CHECK(orp_store_algorithm(s) == ORP_ALGO_GOODBIRD, "algo stored");
    CHECK(orp_store_set_algorithm(s, 99) != 0, "bad algo");
    orp_store_close(s);
    s = orp_store_open(path);
    CHECK(orp_store_algorithm(s) == ORP_ALGO_GOODBIRD, "algo persists");

    // negative counts rejected
    CHECK(orp_store_record_play(s, "c1", "", "", 0, 1, -1, 0, 0, 0, 0, 1, 1, NULL, NULL) != 0, "neg rejected");
    CHECK(orp_store_integrity_ok(s), "integrity end");
    orp_store_close(s);
    rmdb(path);
}

static void test_synthetic(void) {
    char path[200]; tmpdb(path, sizeof path, "c");
    orp_store *s = orp_store_open(path);
    double r; int best;
    CHECK(orp_store_record_play(s, "real", "Real", "GIGA 15", 15.0, 900000, 1000, 10, 2, 0, 0, 1, 10, &r, &best) == 0, "real play");
    CHECK(orp_store_record_play_ex(s, "fake", "Fake", "GIGA 15", 16.0, 990000, 1500, 2, 0, 0, 0, 1, 11, 1, &r, &best) == 0, "synthetic play");
    CHECK(orp_store_synthetic_count(s) == 1, "synthetic count");
    orp_row rows[20];
    CHECK(orp_store_best(s, rows, 20) == 2, "both rated");
    CHECK(orp_store_delete_synthetic(s) == 1, "delete returns 1");
    CHECK(orp_store_synthetic_count(s) == 0 && orp_store_best(s, rows, 20) == 1 && !strcmp(rows[0].chart_key, "real"), "only the real play remains");
    orp_store_close(s);
    rmdb(path);

    // migration: a database created by an older version (no synthetic column) opens and works
    char old[200]; tmpdb(old, sizeof old, "old");
    {   // build a database with the OLD schema (no `synthetic` column) using the SQLite API directly
        sqlite3 *db = NULL;
        CHECK(sqlite3_open(old, &db) == SQLITE_OK, "create legacy db");
        const char *sql =
            "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);"
            "CREATE TABLE charts (chart_key TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', difficulty TEXT NOT NULL DEFAULT '', constant_d REAL);"
            "CREATE TABLE plays (id INTEGER PRIMARY KEY AUTOINCREMENT, chart_key TEXT NOT NULL REFERENCES charts(chart_key), score INTEGER NOT NULL,"
            " perfect INTEGER NOT NULL, good INTEGER NOT NULL, miss INTEGER NOT NULL, bleed INTEGER NOT NULL DEFAULT 0, mirror INTEGER NOT NULL DEFAULT 0,"
            " alive INTEGER NOT NULL DEFAULT 1, played_at INTEGER NOT NULL, rating REAL);"
            "INSERT INTO charts VALUES ('k','T','MEGA 14',14.0);"
            "INSERT INTO plays(chart_key,score,perfect,good,miss,played_at,rating) VALUES ('k',1,100,0,0,5,500);";
        CHECK(sqlite3_exec(db, sql, NULL, NULL, NULL) == SQLITE_OK, "legacy schema");
        sqlite3_close(db);
    }
    orp_store *o = orp_store_open(old);
    CHECK(o != NULL && orp_store_play_count(o) == 1 && orp_store_synthetic_count(o) == 0, "legacy db migrated");
    CHECK(orp_store_record_play_ex(o, "k", "T", "MEGA 14", 0, 1, 100, 0, 0, 0, 0, 1, 6, 1, &r, &best) == 0 && orp_store_synthetic_count(o) == 1, "insert after migration");
    orp_store_close(o);
    rmdb(old);
}

static void test_top20(void) {
    char path[200]; tmpdb(path, sizeof path, "b");
    orp_store *s = orp_store_open(path);
    char key[32];
    for (int i = 0; i < 25; i++) {
        snprintf(key, sizeof key, "c%d", i);
        orp_store_record_play(s, key, key, "MEGA", 8.0 + i * 0.3, 1, 1000, 0, 0, 0, 0, 1, 1, NULL, NULL);
    }
    orp_row rows[20];
    int n = orp_store_best(s, rows, 20);
    CHECK(n == 20, "20 rows");
    int has24 = 0, has0 = 0;
    for (int i = 0; i < n; i++) { if (!strcmp(rows[i].chart_key, "c24")) has24 = 1; if (!strcmp(rows[i].chart_key, "c0")) has0 = 1; }
    CHECK(has24 && !has0, "top20 membership");
    for (int i = 1; i < n; i++) CHECK(rows[i - 1].rating >= rows[i].rating, "descending");
    orp_store_close(s);
    rmdb(path);
}

int main(int argc, char **argv) {
    test_golden(argc > 1 ? argv[1] : "golden_engine.txt");
    test_engine_misc();
    test_store();
    test_top20();
    test_synthetic();
    printf("%d checks, %d failures\n", checks, fails);
    return fails ? 1 : 0;
}
