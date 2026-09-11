#!/usr/bin/env python3
"""Reproducible per-window "sticky" experiment (NOT a product test).

The production kit has no sticky command because foreign per-window sticky
writes were observed not to apply. This runner reproduces that observation
with disposable fixture windows and reports each attempt as
applied / not_applied / inconclusive. A negative result is an observation
about this OS build, not a failure, and is never assumed to hold forever.

Stages (target T and same-process sibling control C, both owned by the fixture):

  foreign ADD      SLSBridgedAddWindowsToSpacesOperation from another process,
                   observed on an existing Desktop, on a Desktop created
                   AFTERWARDS, and back home
  foreign REMOVE   SLSBridgedRemoveWindowsFromSpacesOperation against the
                   never-joined Desktop and against T's home
  foreign tag      SLSSetWindowTags 0x800 from another process, observed on an
                   existing Desktop, a newly created one, and home; cleared after
  owner control    NSWindow.collectionBehavior canJoinAllSpaces set by the owner
                   process (positive control): existing Desktop, newly created
                   Desktop, sibling stays home; then cleared to show where the
                   window is pinned, that it no longer follows, and an explicit
                   move back home

Every verdict requires STABLE compositor visibility (CG on-screen flag plus the
Space census with option 0x2) held for --stable seconds, not merely a dispatch
or a membership count. Requires --mutate: it activates other Desktops
temporarily and creates Desktops of its own. Original Desktops are never
destroyed or reordered; current Spaces are restored; own Spaces are removed in
a final block that reports every failure.

Exit codes: 0 experiment completed (whatever the verdicts), 1 aborted,
2 prerequisite/usage, 3 cleanup incomplete or baseline not restored.
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probelib as pl  # noqa: E402

STICKY_TAG_HEX = "0x0000000000000800"


class Experiment:
    def __init__(self, args, nsk, observer, report):
        self.args = args
        self.nsk = nsk
        self.observer = observer
        self.report = report
        self.baseline_spaces = nsk.list()
        self.baseline = pl.snapshot_baseline(self.baseline_spaces)
        self.cleanup = pl.Cleanup()
        self.owned = []
        self.stages = []
        self.verdicts = {}
        self.fixture = None
        self.target = None
        self.control = None
        self.display = None
        self.home = None

    # -- infrastructure ------------------------------------------------------
    def start_fixture(self):
        self.fixture = pl.Fixture(self.args.fixture, count=2, title="nsk sticky experiment").__enter__()
        self.cleanup.push("quit fixture pid %s" % self.fixture.pid, self.fixture.close, phase=pl.PHASE_FIXTURE)
        self.target, self.control = self.fixture.ids
        record = self.observer.window(self.target)
        memberships = record.get("memberships") or []
        if len(memberships) != 1:
            raise pl.ProbeError("target window has unexpected memberships %s" % memberships)
        home = pl.find_space(self.nsk.list(), memberships[0])
        if home is None or not home["active"]:
            raise pl.ProbeError("target window is not on a current managed Space")
        if (self.observer.window(self.control).get("memberships") or []) != [home["id"]]:
            raise pl.ProbeError("control window is not on the same home Space as the target")
        self.home = home["id"]
        self.display = home["display"]
        self.cleanup.push("restore current Spaces", self.restore_current, phase=pl.PHASE_RESTORE)

    def create_space(self, purpose):
        try:
            record = self.nsk.create()
        except pl.NskError as exc:
            original_ids = {entry["id"] for entry in self.baseline["order"]}
            if exc.request_may_have_applied and exc.space_id and exc.space_id not in original_ids:
                self.owned.append(exc.space_id)
                self.cleanup.push("destroy own Space %s" % exc.space_id,
                                  lambda sid=exc.space_id: self.destroy_owned(sid))
            raise
        sid = record["id"]
        if record["display"] != self.display:
            self.owned.append(sid)
            self.cleanup.push("destroy own Space %s" % sid, lambda: self.destroy_owned(sid))
            raise pl.ProbeError("created Desktop %s landed on another display; multi-display sticky is unverified" % sid)
        self.owned.append(sid)
        self.cleanup.push("destroy own Space %s (%s)" % (sid, purpose), lambda: self.destroy_owned(sid))
        return sid

    def destroy_owned(self, sid):
        if sid not in self.owned:
            raise pl.ProbeError("refusing to destroy Space %s: not created by this run" % sid)
        record = pl.find_space(self.nsk.list(), sid)
        if record is None:
            return {"already_gone": True}
        if record["active"]:
            self.nsk.activate(self.baseline["active"][record["display"]])

        def no_application_windows():
            return not any(w.get("layer") in (0, 3, 8) for w in self.observer.census(sid)["windows"])

        reached, ms, _ = pl.wait_for(no_application_windows, self.args.settle)
        if not reached:
            blocking = [w["id"] for w in self.observer.census(sid)["windows"] if w.get("layer") in (0, 3, 8)]
            raise pl.ProbeError("own Space %s still hosts application windows %s" % (sid, blocking))
        self.nsk.destroy(sid)
        return {"destroyed": sid, "waited_ms": ms}

    def restore_current(self):
        changed = []
        now = pl.active_spaces(self.nsk.list())
        for display, sid in self.baseline["active"].items():
            if now.get(display) != sid:
                self.nsk.activate(sid)
                changed.append({"display": display, "from": now.get(display), "to": sid})
        return {"reactivated": changed} if changed else None

    def activate(self, sid):
        record = self.nsk.activate(sid)
        if not record.get("active"):
            raise pl.ProbeError("activation of %s did not confirm" % sid)
        reached, ms, _ = pl.wait_for(lambda: pl.active_spaces(self.nsk.list()).get(self.display) == sid,
                                     self.args.settle)
        if not reached:
            raise pl.ProbeError("census never showed %s as current" % sid)
        return ms

    def existing_desktop(self):
        """An ORIGINAL other Desktop on the display if there is one, else an own one."""
        for space in pl.display_spaces(self.baseline_spaces, self.display):
            if space["type"] == pl.DESKTOP_TYPE and space["id"] != self.home:
                return space["id"], "original"
        return self.create_space("existing-desktop stand-in"), "created"

    # -- measurement ---------------------------------------------------------
    def visibility(self, wid, sid):
        """Stable compositor visibility of wid while sid is current: stable_visible / stable_hidden / flapping."""
        def visible():
            w = self.observer.window(wid)
            return bool(w.get("onscreen") and pl.hosting(w, sid)["up"])
        reached, settle_ms, _ = pl.wait_for(visible, self.args.settle)
        if reached:
            held, samples, _ = pl.hold_for(visible, self.args.stable)
            return {"visibility": "stable_visible" if held else "flapping", "settle_ms": settle_ms, "samples": samples}
        held, samples, _ = pl.hold_for(lambda: not visible(), self.args.stable)
        return {"visibility": "stable_hidden" if held else "flapping", "settle_ms": settle_ms, "samples": samples}

    def observe(self, stage, focus_space=None, measure=True):
        """Record one stage: current Space, target/control views, and (optionally) target visibility on focus_space."""
        entry = {"stage": stage, "current": pl.active_spaces(self.nsk.list()).get(self.display)}
        if measure:
            focus = focus_space if focus_space is not None else entry["current"]
            entry["target_visibility"] = self.visibility(self.target, focus)
            entry["control_visibility"] = self.visibility(self.control, focus)
            entry["focus_space"] = focus
        obs = self.observer.observe(self.target, self.control)
        entry["target"] = pl.summarize_window(obs["windows"][0])
        entry["control"] = pl.summarize_window(obs["windows"][1])
        entry["owner_view"] = [{k: w[k] for k in ("id", "on_active_space", "occlusion_visible", "can_join_all_spaces")}
                               for w in self.fixture.frames()]
        self.stages.append(entry)
        return entry

    def verdict_join(self, entry, sid, tag_expected_unchanged=None):
        """Did the target become a member of sid and stably visible there?"""
        target = entry["target"]
        member = sid in (target.get("memberships") or [])
        visibility = entry["target_visibility"]["visibility"]
        tag_changed = tag_expected_unchanged is not None and target.get("sticky_bit") != tag_expected_unchanged
        if member and visibility == "stable_visible":
            verdict = "applied"
        elif not member and visibility == "stable_hidden" and not tag_changed:
            verdict = "not_applied"
        else:
            verdict = "inconclusive"
        sibling_isolated = (entry["control_visibility"]["visibility"] == "stable_hidden"
                            and (entry["control"].get("memberships") or []) == [self.home])
        if sid != self.home and not sibling_isolated:
            verdict = "inconclusive"
        return {"verdict": verdict, "member": member, "visibility": visibility,
                "sticky_bit": target.get("sticky_bit"), "space_id": sid,
                "sibling_isolated": sibling_isolated if sid != self.home else None}

    @staticmethod
    def verdict_leave(entry, sid):
        """Did the target stop being a member of sid (and vanish from it)?"""
        target = entry["target"]
        member = sid in (target.get("memberships") or [])
        visibility = entry["target_visibility"]["visibility"]
        if not member and visibility == "stable_hidden":
            verdict = "applied"
        elif member and visibility == "stable_visible":
            verdict = "not_applied"
        else:
            verdict = "inconclusive"
        return {"verdict": verdict, "member": member, "visibility": visibility, "space_id": sid}

    def reset_target_home(self):
        """Use the cooperating owner only to reset between independent candidates."""
        self.fixture.sticky(0, True)
        self.fixture.sticky(0, False)
        self.nsk.move_window(self.target, self.home)
        self.activate(self.home)
        record = self.observer.window(self.target)
        if record.get("memberships") != [self.home] or record.get("sticky_bit"):
            raise pl.ProbeError("could not restore the target's non-sticky home baseline")
        return pl.summarize_window(record)

    # -- the experiment ------------------------------------------------------
    def run(self):
        self.start_fixture()
        home = self.home
        base = self.observe("baseline home", focus_space=home)
        baseline_bit = base["target"].get("sticky_bit")
        if base["target_visibility"]["visibility"] != "stable_visible":
            raise pl.ProbeError("target is not stably visible at home before the experiment")
        if (baseline_bit or base["control_visibility"]["visibility"] != "stable_visible" or
                (base["target"].get("memberships") or []) != [home]):
            raise pl.ProbeError("fixture baseline is not two ordinary, non-sticky home windows")

        existing, existing_kind = self.existing_desktop()
        self.report["existing_desktop"] = {"id": existing, "kind": existing_kind}
        self.activate(existing)
        other = self.observe("baseline other desktop", focus_space=existing)
        if other["target_visibility"]["visibility"] != "stable_hidden":
            raise pl.ProbeError("target is visible on another Desktop before any sticky attempt; cannot measure")
        self.activate(home)

        # ---- foreign ADD ----------------------------------------------------
        self.report["foreign_add_dispatch"] = self.observer.add(self.target, existing)
        self.activate(existing)
        entry = self.observe("after foreign ADD, existing desktop", focus_space=existing)
        self.verdicts["foreign_add_existing_desktop"] = self.verdict_join(entry, existing, baseline_bit)
        future1 = self.create_space("created after foreign ADD")
        self.activate(future1)
        entry = self.observe("after foreign ADD, newly created desktop", focus_space=future1)
        self.verdicts["foreign_add_future_desktop"] = self.verdict_join(entry, future1, baseline_bit)
        self.activate(home)
        entry = self.observe("after foreign ADD, home", focus_space=home)
        self.verdicts["foreign_add_home_intact"] = self.verdict_join(entry, home)

        # ---- foreign REMOVE -------------------------------------------------
        member_before_remove = existing in (self.observer.window(self.target).get("memberships") or [])
        self.report["foreign_remove_dispatch"] = [self.observer.remove(self.target, existing)]
        self.activate(existing)
        entry = self.observe("after foreign REMOVE from never-joined desktop", focus_space=existing)
        self.verdicts["foreign_remove_never_joined"] = dict(self.verdict_leave(entry, existing),
                                                           note="window was never a member; hidden is the no-op outcome")
        if not member_before_remove and self.verdicts["foreign_remove_never_joined"]["verdict"] == "applied":
            self.verdicts["foreign_remove_never_joined"]["verdict"] = "not_applied"
        self.activate(home)
        self.report["foreign_remove_dispatch"].append(self.observer.remove(self.target, home))
        entry = self.observe("after foreign REMOVE from home", focus_space=home)
        self.verdicts["foreign_remove_home"] = self.verdict_leave(entry, home)
        self.report["baseline_reset_after_remove"] = self.reset_target_home()

        # ---- foreign tag 0x800 ----------------------------------------------
        tag_on = self.observer.tag(self.target, True)
        self.report["foreign_tag_on"] = tag_on
        self.activate(existing)
        entry = self.observe("after foreign sticky-tag write, existing desktop", focus_space=existing)
        self.verdicts["foreign_tag_existing_desktop"] = dict(
            self.verdict_join(entry, existing, baseline_bit),
            cg_error=tag_on.get("cg_error"), bit_after_write=(tag_on.get("after") or {}).get("sticky_bit"))
        future2 = self.create_space("created after foreign tag write")
        self.activate(future2)
        entry = self.observe("foreign sticky tag, newly created desktop", focus_space=future2)
        self.verdicts["foreign_tag_future_desktop"] = self.verdict_join(entry, future2, baseline_bit)
        self.activate(home)
        entry = self.observe("foreign sticky tag, home", focus_space=home)
        self.verdicts["foreign_tag_home_intact"] = self.verdict_join(entry, home)
        self.report["foreign_tag_off"] = self.observer.tag(self.target, False)
        self.report["baseline_reset_after_tag"] = self.reset_target_home()

        # ---- owner-side positive control -----------------------------------
        self.report["owner_control_on"] = self.fixture.sticky(0, True)
        self.activate(existing)
        entry = self.observe("owner canJoinAllSpaces, existing desktop", focus_space=existing)
        control_existing = self.verdict_join(entry, existing)
        control_existing["sibling"] = {
            "memberships": entry["control"].get("memberships"),
            "visibility": entry["control_visibility"]["visibility"],
            "isolated": entry["control_visibility"]["visibility"] == "stable_hidden"
            and (entry["control"].get("memberships") or []) == [home],
        }
        control_existing["all_desktops_joined"] = all(
            s["id"] in (entry["target"].get("memberships") or [])
            for s in pl.display_spaces(self.nsk.list(), self.display) if s["type"] == pl.DESKTOP_TYPE)
        self.verdicts["owner_control_existing_desktop"] = control_existing
        future3 = self.create_space("created after owner control")
        self.activate(future3)
        entry = self.observe("owner canJoinAllSpaces, newly created desktop", focus_space=future3)
        control_future = self.verdict_join(entry, future3)
        control_future["sibling_isolated"] = (entry["control_visibility"]["visibility"] == "stable_hidden"
                                              and (entry["control"].get("memberships") or []) == [home])
        self.verdicts["owner_control_future_desktop"] = control_future

        self.report["owner_control_off"] = self.fixture.sticky(0, False)
        entry = self.observe("owner control cleared while on new desktop", focus_space=future3)
        memberships = entry["target"].get("memberships") or []
        self.verdicts["owner_unsticky_pins_to"] = {
            "memberships": memberships,
            "pinned_to": "current" if memberships == [future3] else ("home" if memberships == [home] else "other"),
            "visibility": entry["target_visibility"]["visibility"],
            "sticky_bit": entry["target"].get("sticky_bit"),
        }
        self.activate(existing)
        entry = self.observe("unsticky no longer follows to another desktop", focus_space=existing)
        follows = self.verdict_join(entry, existing)
        follows["follows"] = follows["verdict"] == "applied"
        self.verdicts["owner_unsticky_follows"] = follows
        self.report["explicit_move_home"] = self.nsk.move_window(self.target, home)
        self.activate(home)
        entry = self.observe("unsticky explicitly restored to original home", focus_space=home)
        self.verdicts["explicit_move_restores_home"] = self.verdict_join(entry, home)

        # ---- summary -------------------------------------------------------
        control_ok = (self.verdicts["owner_control_existing_desktop"]["verdict"] == "applied"
                      and self.verdicts["owner_control_existing_desktop"]["sibling"]["isolated"]
                      and self.verdicts["owner_control_future_desktop"]["verdict"] == "applied"
                      and self.verdicts["owner_control_future_desktop"]["sibling_isolated"])
        self.report["positive_control_valid"] = control_ok
        if not control_ok:
            for key, verdict in self.verdicts.items():
                if key.startswith("foreign_") and verdict.get("verdict") == "not_applied":
                    verdict["verdict"] = "inconclusive"
                    verdict["note"] = "positive control did not behave; this environment cannot validate sticky"
        self.report["summary"] = {
            "foreign_add": self._combine("foreign_add_existing_desktop", "foreign_add_future_desktop"),
            "foreign_remove": self.verdicts["foreign_remove_home"]["verdict"],
            "foreign_tag": self._combine("foreign_tag_existing_desktop", "foreign_tag_future_desktop"),
            "owner_control": self._combine("owner_control_existing_desktop", "owner_control_future_desktop"),
            "owner_unsticky_pins_to": self.verdicts["owner_unsticky_pins_to"]["pinned_to"],
        }
        for candidate in ("foreign_add", "foreign_tag"):
            if self.verdicts[candidate + "_home_intact"]["verdict"] != "applied":
                self.report["summary"][candidate] = "inconclusive"

    def _combine(self, *keys):
        values = {self.verdicts[k]["verdict"] for k in keys}
        if values == {"applied"}:
            return "applied"
        if values == {"not_applied"}:
            return "not_applied"
        return "inconclusive"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    pl.add_common_arguments(parser)
    parser.add_argument("--mutate", action="store_true",
                        help="consent to desktop changes: activates other Desktops, creates/destroys OWN Desktops")
    args = parser.parse_args(argv)
    report = pl.Report("sticky", args, "experiment")
    if not args.mutate:
        report.record("prerequisites", "fail", error="the sticky experiment changes the current Desktop; pass --mutate")
        return report.finish(pl.EXIT_PREREQ)

    try:
        nsk = pl.Nsk(pl.require_executable(args.cli, "nsk"), args.timeout)
        observer = pl.Observer(pl.require_executable(args.sticky_probe, "sticky-probe"), args.timeout)
        pl.require_executable(args.fixture, "window-fixture")
        report.data["environment"]["nsk_version"] = nsk.version()
        report.data["environment"]["os"] = nsk.capabilities().get("os")
        report.data["environment"]["session"] = pl.guard_session(observer)
        experiment = Experiment(args, nsk, observer, report.data)
    except pl.Prerequisite as exc:
        report.record("prerequisites", "fail", error=str(exc))
        return report.finish(pl.EXIT_PREREQ)
    except pl.ProbeError as exc:
        report.record("prerequisites", "fail", error=pl.exception_text(exc))
        return report.finish(pl.EXIT_FAIL)

    report.data["baseline"] = experiment.baseline
    report.data["sticky_tag_hex"] = STICKY_TAG_HEX
    completed = False
    try:
        experiment.run()
        completed = True
        report.record("experiment", "observation", details={"summary": report.data.get("summary")})
    except pl.ProbeError as exc:
        report.record("experiment", "fail", error=pl.exception_text(exc))
    except Exception as exc:  # report, then still clean up
        report.record("experiment", "fail", error=pl.exception_text(exc))
    finally:
        actions = experiment.cleanup.run()
        report.data["cleanup"] = {"complete": all(a["ok"] for a in actions), "actions": actions}
        report.data["stages"] = experiment.stages
        report.data["verdicts"] = experiment.verdicts
        report.data["owned_spaces"] = experiment.owned
        try:
            problems = pl.baseline_diff(experiment.baseline, nsk.list())
        except pl.ProbeError as exc:
            problems = ["could not re-read the census: %s" % pl.exception_text(exc)]
        report.data["baseline_restored"] = not problems
        report.data["baseline_problems"] = problems

    if not report.data["cleanup"]["complete"] or report.data["baseline_problems"]:
        code = pl.EXIT_CLEANUP
    elif not completed:
        code = pl.EXIT_FAIL
    else:
        code = pl.EXIT_OK
    return report.finish(code)


if __name__ == "__main__":
    sys.exit(main())
