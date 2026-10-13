import os, sys, unittest
from unittest import mock
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
os.environ.setdefault("FSX_CACHE_DIR", "/tmp/fsx-test-cache")
import fsx


class Parse(unittest.TestCase):
    def test_explicit(self):
        ex = fsx.parse_explicit("ext:md grep:turbopuffer in:~/Projects/estate-kg-live/docs")
        self.assertEqual((ex["ext"], ex["grep"]), ("md", "turbopuffer"))
        self.assertTrue(ex["in"].startswith("~/"))

    def test_plain_is_not_explicit(self):
        self.assertIsNone(fsx.parse_explicit("where do we decide model routing"))

    def test_filters(self):
        self.assertEqual(fsx.extract_filters("notes in ~/Projects/x/docs markdown")["ext"], "md")
        self.assertEqual(fsx.extract_filters("budget.pdf")["ext"], "pdf")

    def test_keywords(self):
        self.assertEqual(fsx.keywords("where do we decide model routing"), ["decide", "model", "routing"])

    def test_collapse_keeps_newest(self):
        hs = [{"kind": "file", "path": "/a/x.md", "mtime": 1, "source": "n"}, {"kind": "file", "path": "/b/x.md", "mtime": 9, "source": "n"}]
        out = fsx.collapse_copies(hs)
        self.assertEqual((len(out), out[0]["path"], out[0]["copies"]), (1, "/b/x.md", 2))


class Paths(unittest.TestCase):
    def test_fast_path_makes_no_typesafe_call(self):
        with mock.patch.object(fsx, "_ask", side_effect=AssertionError("typesafe called")):
            r = fsx.run_query("ext:md grep:turbopuffer in:~/Projects/estate-kg-live/docs")
        self.assertEqual((r["path"], r["mode"], r["typesafe_calls"]), ("fast", "content", 0))
        self.assertTrue(all(h["path"].endswith(".md") for h in r["hits"]))

    def test_semantic_stub_without_jg(self):
        with mock.patch("shutil.which", return_value=None):
            h = fsx.be_semantic("anything")
        self.assertIn("not installed", h[0]["text"])

    def test_low_confidence_falls_back_to_name(self):
        with mock.patch.object(fsx, "_ask", return_value={"mode": {"choice": "estate", "confidence": 0.1}}), \
             mock.patch.dict(os.environ, {"FSX_CACHE_DIR": "/tmp/fsx-test-cache2"}):
            fsx.CACHE_DIR = fsx.Path("/tmp/fsx-test-cache2-" + str(os.getpid()))
            self.assertEqual(fsx.route("zzz unique query 1")[0], "name")

    def test_rerank_orders_by_score(self):
        hits = [{"path": f"/p/{i}", "text": "", "kind": "file", "source": "n"} for i in range(3)]
        fsx.CACHE_DIR = fsx.Path("/tmp/fsx-test-cache3-" + str(os.getpid()))
        with mock.patch.object(fsx, "_ask", return_value={"c0": {"noul": .1}, "c1": {"noul": .9}, "c2": {"noul": .5}}):
            out = fsx.rerank("q", hits)
        self.assertEqual([h["path"] for h in out], ["/p/1", "/p/2", "/p/0"])


if __name__ == "__main__":
    unittest.main()
