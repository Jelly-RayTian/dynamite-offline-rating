"""Local persistence for offline Rating (SQLite).

Design: `plays` is the source of truth (every finished chart, raw judgments).
Ratings are DERIVED from plays + current chart constant + chosen algorithm,
so changing a constant or the algorithm only needs a recompute, never data loss.
Independent from any game / rendering code.
"""
import sqlite3
import time

from . import rating

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS charts (
    chart_id   TEXT PRIMARY KEY,
    title      TEXT NOT NULL DEFAULT '',
    difficulty TEXT NOT NULL DEFAULT '',
    constant_d REAL            -- NULL = unknown constant -> chart not rated
);
CREATE TABLE IF NOT EXISTS plays (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    chart_id   TEXT    NOT NULL REFERENCES charts(chart_id),
    score      INTEGER NOT NULL,
    perfect    INTEGER NOT NULL CHECK (perfect >= 0),
    good       INTEGER NOT NULL CHECK (good >= 0),
    miss       INTEGER NOT NULL CHECK (miss >= 0),
    played_at  INTEGER NOT NULL,
    rating     REAL               -- cache, recomputable
);
CREATE INDEX IF NOT EXISTS idx_plays_chart ON plays(chart_id);
"""
SCHEMA_VERSION = "1"


class Store:
    def __init__(self, path):
        self.db = sqlite3.connect(path)
        self.db.execute("PRAGMA foreign_keys = ON")
        self.db.execute("PRAGMA journal_mode = WAL")
        self.db.executescript(SCHEMA)
        self.db.execute("INSERT OR IGNORE INTO meta VALUES ('schema_version', ?)", (SCHEMA_VERSION,))
        self.db.execute("INSERT OR IGNORE INTO meta VALUES ('algorithm', ?)", (rating.DEFAULT_ALGORITHM,))
        self.db.commit()

    def close(self):
        self.db.close()

    # ----- settings -----
    @property
    def algorithm(self):
        return self.db.execute("SELECT value FROM meta WHERE key='algorithm'").fetchone()[0]

    def set_algorithm(self, name):
        if name not in rating.ALGORITHMS:
            raise ValueError("unknown algorithm: %s" % name)
        self.db.execute("UPDATE meta SET value=? WHERE key='algorithm'", (name,))
        self.recalculate_all()

    # ----- charts -----
    def upsert_chart(self, chart_id, title="", difficulty="", constant_d=None):
        self.db.execute(
            """INSERT INTO charts(chart_id,title,difficulty,constant_d) VALUES (?,?,?,?)
               ON CONFLICT(chart_id) DO UPDATE SET
                 title=CASE WHEN excluded.title<>'' THEN excluded.title ELSE title END,
                 difficulty=CASE WHEN excluded.difficulty<>'' THEN excluded.difficulty ELSE difficulty END,
                 constant_d=COALESCE(excluded.constant_d, constant_d)""",
            (chart_id, title, difficulty, constant_d))
        self.db.commit()

    def set_constant(self, chart_id, constant_d):
        """Change a chart constant, then recompute that chart's plays."""
        self.db.execute("UPDATE charts SET constant_d=? WHERE chart_id=?", (constant_d, chart_id))
        self._recalc_chart(chart_id)
        self.db.commit()

    # ----- plays -----
    def record_play(self, chart_id, score, perfect, good, miss, played_at=None, title="", difficulty=""):
        """Save one finished chart. Returns (rating_or_None, is_new_best)."""
        self.upsert_chart(chart_id, title, difficulty)
        prev = self.best_rating(chart_id)
        r = self._rate(chart_id, perfect, good, miss)
        self.db.execute(
            "INSERT INTO plays(chart_id,score,perfect,good,miss,played_at,rating) VALUES (?,?,?,?,?,?,?)",
            (chart_id, score, perfect, good, miss, int(played_at or time.time()), r))
        self.db.commit()
        is_best = r is not None and (prev is None or r > prev)
        return r, is_best

    def _rate(self, chart_id, p, g, m):
        row = self.db.execute("SELECT constant_d FROM charts WHERE chart_id=?", (chart_id,)).fetchone()
        if row is None or row[0] is None:
            return None
        return rating.chart_rating(row[0], p, g, m, self.algorithm)

    def _recalc_chart(self, chart_id):
        for pid, p, g, m in self.db.execute(
                "SELECT id,perfect,good,miss FROM plays WHERE chart_id=?", (chart_id,)).fetchall():
            self.db.execute("UPDATE plays SET rating=? WHERE id=?", (self._rate(chart_id, p, g, m), pid))

    def recalculate_all(self):
        for (cid,) in self.db.execute("SELECT chart_id FROM charts").fetchall():
            self._recalc_chart(cid)
        self.db.commit()

    # ----- queries -----
    def best_rating(self, chart_id):
        return self.db.execute(
            "SELECT MAX(rating) FROM plays WHERE chart_id=?", (chart_id,)).fetchone()[0]

    def best20(self, n=20):
        """One best play per chart (by rating), top n by rating."""
        rows = self.db.execute(
            """SELECT c.chart_id, c.title, c.difficulty, c.constant_d,
                      p.score, p.perfect, p.good, p.miss, p.rating, p.played_at
               FROM plays p JOIN charts c USING(chart_id)
               WHERE p.rating IS NOT NULL
                 AND p.id = (SELECT id FROM plays q WHERE q.chart_id=p.chart_id AND q.rating IS NOT NULL
                             ORDER BY q.rating DESC, q.score DESC, q.id ASC LIMIT 1)
               ORDER BY p.rating DESC, c.chart_id LIMIT ?""", (n,)).fetchall()
        keys = ["chart_id", "title", "difficulty", "constant", "score",
                "perfect", "good", "miss", "rating", "played_at"]
        out = []
        for r in rows:
            d = dict(zip(keys, r))
            d["accuracy"] = rating.accuracy(d["perfect"], d["good"], d["miss"])
            out.append(d)
        return out

    def overall(self):
        return rating.overall_rating([r["rating"] for r in self.best20()])

    def integrity_ok(self):
        return self.db.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
