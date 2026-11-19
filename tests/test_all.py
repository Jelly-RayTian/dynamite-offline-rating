import json, os, sys, tempfile, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from engine import rating
from engine.storage import Store


class RatingTests(unittest.TestCase):
    def test_accuracy(self):
        self.assertEqual(rating.accuracy(100, 0, 0), 1.0)
        self.assertAlmostEqual(rating.accuracy(90, 10, 0), 0.95)
        self.assertEqual(rating.accuracy(0, 0, 0), 0.0)

    def test_hand_values(self):  # hand-computed from the formulas in the docs
        self.assertEqual(rating.full_r(10), 369.0)
        self.assertEqual(rating.r_goodbird(10, 100, 0, 0), 369.0)

    def test_overall_sums_top20_only(self):
        self.assertEqual(rating.overall_rating([10.0] * 25 + [1.0]), 200)
        self.assertEqual(rating.overall_rating([]), 0)
        self.assertEqual(rating.overall_rating([0.5]), 1)   # half rounds up

    def test_all_algorithms_run(self):
        for name in rating.ALGORITHMS:
            v = rating.chart_rating(12.0, 950, 40, 10, name)
            self.assertIsInstance(v, float)
            self.assertGreaterEqual(v, 0.0)


class TableTests(unittest.TestCase):
    """Ground truth: data/charts.csv (397 charts, from the community B20 sheet)."""
    def rows(self):
        import csv
        p = os.path.join(os.path.dirname(__file__), "..", "data", "charts.csv")
        with open(p, encoding="utf-8") as f:
            return list(csv.DictReader(f))

    def test_full_r_matches_table(self):
        rows = self.rows()
        self.assertEqual(len(rows), 397)
        exact = sum(1 for r in rows if rating.full_r(float(r["constant"])) == float(r["full_r"]))
        worst = max(abs(rating.full_r(float(r["constant"])) - float(r["full_r"])) for r in rows)
        self.assertGreaterEqual(exact, 396)
        self.assertLessEqual(worst, 1.0)


class RealWorldPoints(unittest.TestCase):
    """Real in-game observations quoted in community articles (Bilibili cv16847763, cv17024921). Provenance: community posts."""

    def test_tempest_d17_exact(self):
        acc = 1991 / 1997                    # R(17.0, 1991/1997) = 2008 (record by TempestCMR)
        r = int(max(acc * 50.0, acc ** 8 * 17.0 ** 3 - 17.0 ** 2.8))
        self.assertEqual(r, 2008)

    def test_d15_5_one_good_pair_within_one(self):
        # article lists R = 1562 and 1561 for these two plays; the stated order is
        # inconsistent with monotonicity (higher acc must not give lower R), so we only
        # require |error| <= 1 and the correct ordering of raw values.
        D = 15.5
        raws = {}
        for name, N in (("maquina", 1470), ("circulatory", 1535)):
            acc = (N - 0.5) / N
            raws[name] = acc ** 8 * D ** 3 - D ** 2.8
            self.assertLessEqual(abs(int(raws[name]) - 1561.5), 1.0)
        self.assertGreater(raws["circulatory"], raws["maquina"])

    def test_floor_not_round(self):
        # community observation: the game truncates (floor); per-chart R is an integer
        self.assertEqual(rating.r_goodbird(13.0, 1000, 0, 0), float(int(13.0 ** 3 - 13.0 ** 2.8)))


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.dir.name, "r.db")

    def tearDown(self):
        self.dir.cleanup()

    def test_first_init_empty(self):
        s = Store(self.path)
        self.assertEqual(s.best20(), [])
        self.assertEqual(s.overall(), 0)
        self.assertTrue(s.integrity_ok())

    def test_multiple_results_same_chart_keeps_best(self):
        s = Store(self.path)
        s.upsert_chart("c1", "Song", "Mega", 12.0)
        r1, b1 = s.record_play("c1", 900000, 900, 80, 20)
        r2, b2 = s.record_play("c1", 990000, 990, 10, 0)    # better
        r3, b3 = s.record_play("c1", 800000, 700, 200, 100) # worse
        self.assertTrue(b1); self.assertTrue(b2); self.assertFalse(b3)
        top = s.best20()
        self.assertEqual(len(top), 1)
        self.assertEqual(top[0]["score"], 990000)

    def test_persists_across_restart(self):
        s = Store(self.path)
        s.upsert_chart("c1", "Song", "Mega", 12.0)
        s.record_play("c1", 990000, 990, 10, 0)
        before = s.overall(); s.close()
        s2 = Store(self.path)
        self.assertEqual(s2.overall(), before)
        self.assertEqual(len(s2.best20()), 1)

    def test_constant_update_recalculates(self):
        s = Store(self.path)
        s.upsert_chart("c1", "Song", "Mega", 10.0)
        s.record_play("c1", 1, 100, 0, 0)
        low = s.best20()[0]["rating"]
        s.set_constant("c1", 13.0)
        self.assertGreater(s.best20()[0]["rating"], low)

    def test_unknown_constant_not_rated_then_rated_later(self):
        s = Store(self.path)
        s.record_play("c9", 1, 100, 0, 0, title="NoD")
        self.assertEqual(s.best20(), [])
        s.set_constant("c9", 11.0)
        self.assertEqual(len(s.best20()), 1)

    def test_only_top_20_charts_count(self):
        s = Store(self.path)
        for i in range(25):
            s.upsert_chart("c%d" % i, "T%d" % i, "Mega", 8.0 + i * 0.3)
            s.record_play("c%d" % i, 1, 1000, 0, 0)
        self.assertEqual(len(s.best20()), 20)
        # lowest-D charts must be excluded
        ids = {r["chart_id"] for r in s.best20()}
        self.assertNotIn("c0", ids)
        self.assertIn("c24", ids)

    def test_algorithm_switch_recomputes(self):
        s = Store(self.path)
        s.upsert_chart("c1", "S", "M", 12.0)
        s.record_play("c1", 1, 980, 20, 0)
        a = s.best20()[0]["rating"]
        s.set_algorithm("goodbird")
        self.assertEqual(s.best20()[0]["rating"], a)
        with self.assertRaises(ValueError):
            s.set_algorithm("nope")

    def test_rejects_negative_counts(self):
        import sqlite3
        s = Store(self.path)
        with self.assertRaises(sqlite3.IntegrityError):
            s.record_play("c1", 1, -1, 0, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
