#!/usr/bin/env python3
"""Read-only regression checks for destructive-probe bookkeeping and verdicts."""
import copy
import pathlib
import sys
import types
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "probes"))
import probelib as pl
import smoke
import sticky


class Model:
    def __init__(self):
        self.spaces = [{"id": 1, "display": "test", "type": 0, "active": True},
                       {"id": 2, "display": "test", "type": 0, "active": False}]
        self.create_error_id = None

    def list(self):
        return copy.deepcopy(self.spaces)

    def destroy(self, sid):
        self.spaces = [space for space in self.spaces if space["id"] != sid]
        return sid

    def create(self):
        payload = {"error": {"code": "not_confirmed", "message": "confirmation interrupted",
                             "space_id": self.create_error_id, "request_may_have_applied": True}}
        raise pl.NskError(["nsk", "create"], 1, payload, "")


class Observer:
    def __init__(self, populated):
        self.populated = populated

    def census(self, sid):
        return {"windows": [{"id": 99, "layer": 0}] if self.populated else []}


def context(model, populated=False):
    ctx = smoke.Context(types.SimpleNamespace(settle=0), model, Observer(populated), None)
    ctx.baseline = {"order": [{"id": 1, "display": "test", "type": 0}], "active": {"test": 1}}
    ctx.cleanup = pl.Cleanup()
    return ctx


class ProbeSafety(unittest.TestCase):
    def test_populated_cleanup_keeps_the_desktop(self):
        model = Model()
        ctx = context(model, populated=True)
        ctx.owned = [2]
        ctx.live_owned = {2}
        with self.assertRaises(pl.ProbeError):
            ctx.destroy_owned(2)
        self.assertEqual([s["id"] for s in model.spaces], [1, 2])

    def test_unconfirmed_create_id_is_cleaned_up(self):
        model = Model()
        model.create_error_id = 2
        ctx = context(model)
        with self.assertRaises(pl.NskError):
            ctx.create_space()
        ctx.cleanup.run()
        self.assertTrue(ctx.cleanup.complete)
        self.assertEqual([s["id"] for s in model.spaces], [1])

    def test_create_error_never_adopts_an_original_desktop(self):
        model = Model()
        model.create_error_id = 1
        ctx = context(model)
        with self.assertRaises(pl.NskError):
            ctx.create_space()
        ctx.cleanup.run()
        self.assertEqual([s["id"] for s in model.spaces], [1, 2])
        self.assertEqual(ctx.owned, [])

    def test_app_wide_visibility_is_not_per_window_sticky(self):
        experiment = sticky.Experiment.__new__(sticky.Experiment)
        experiment.home = 1
        entry = {"target": {"memberships": [1, 2], "sticky_bit": True},
                 "control": {"memberships": [1, 2]},
                 "target_visibility": {"visibility": "stable_visible"},
                 "control_visibility": {"visibility": "stable_visible"}}
        verdict = experiment.verdict_join(entry, 2, False)
        self.assertEqual(verdict["verdict"], "inconclusive")


if __name__ == "__main__":
    unittest.main()
