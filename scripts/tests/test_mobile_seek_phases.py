import runpy
from pathlib import Path
import unittest

MODULE = runpy.run_path(str(Path(__file__).resolve().parents[1] / "summarize-mobile-seek-phases.py"))
summarize = MODULE["summarize"]

class MobileSeekPhasesTests(unittest.TestCase):
    def test_order_and_bound(self):
        self.assertEqual(summarize("HARC_SEEK_PHASE:recent-start\n" * 100 + "HARC_SEEK_PHASE:recent-complete"), ["recent-start", "recent-complete"])
    def test_rejects_arbitrary_payloads(self):
        self.assertEqual(summarize("private text\nHARC_SEEK_PHASE:unknown\nHARC_SEEK_PHASE:recent-start private\nx HARC_SEEK_PHASE:launch-start"), [])
    def test_missing_is_not_success(self):
        self.assertEqual(summarize(""), [])
    def test_all_closed_phases(self):
        phases = sorted(MODULE["PHASES"])
        self.assertEqual(summarize("\n".join(MODULE["PREFIX"] + p for p in phases)), phases)
