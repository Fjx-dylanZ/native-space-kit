#!/usr/bin/env python3
"""Live smoke probes for the nsk CLI.

Read-only by default: version/capability reporting, census consistency, and
ID validation error paths. With --mutate the runner additionally opens
disposable fixture windows and exercises the verified write operations,
always against Spaces it created itself and windows it owns:

  lifecycle    create an ordinary Desktop, confirm it in the census, destroy it
  migration    populate an own Desktop with fixture windows, confirm the
               non-empty guard, destroy --migrate, confirm ID/frame survival
  activation   activate an own Desktop and require the fixture window to be up
               in the compositor and the home control window to be off-screen
               (not just the active flag), then return home
  move_window  move a fixture window between the home Desktop and an own one
  reorder      move/swap own Desktops including one that is currently active
  guards       refusals that must not write anything

Original Desktops are never destroyed or reordered; the current Space of every
display is restored and the baseline census is compared at the end. Cleanup
failures are reported explicitly and turn the exit code into 3.

Exit codes: 0 pass, 1 failure, 2 prerequisite/usage, 3 cleanup incomplete.
"""

import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probelib as pl  # noqa: E402


class Skip(pl.ProbeError):
    """The case does not apply to this machine (reported, never silent)."""


class Context:
    def __init__(self, args, nsk, observer, fixture_path):
        self.args = args
        self.nsk = nsk
        self.observer = observer
        self.fixture_path = fixture_path
        self.baseline = None
        self.baseline_spaces = None
        self.cleanup = None
        self.owned = []            # every Space ID this run created
        self.live_owned = set()    # the ones not yet confirmed destroyed

    # -- prerequisites -------------------------------------------------------
    def need_observer(self):
        if self.observer is None:
            raise Skip("sticky-probe (observer) is not built; run `make probes`")
        return self.observer

    def need_fixture(self):
        if self.fixture_path is None:
            raise Skip("window-fixture is not built; run `make probes`")
        return self.fixture_path

    # -- fixture -------------------------------------------------------------
    def fixture(self, count):
        fx = pl.Fixture(self.need_fixture(), count=count).__enter__()
        self.cleanup.push("quit fixture pid %s" % fx.pid, fx.close, phase=pl.PHASE_FIXTURE)
        return fx

    def window(self, window_id):
        return self.need_observer().window(window_id)

    def home_of(self, window_id):
        """The single native Space an ordinary fixture window lives on."""
        record = self.window(window_id)
        memberships = record.get("memberships") or []
        if len(memberships) != 1:
            raise pl.ProbeError("fixture window %s has unexpected memberships %s" % (window_id, memberships))
        space = pl.find_space(self.nsk.list(), memberships[0])
        if space is None:
            raise pl.ProbeError("fixture window %s lives on unmanaged Space %s" % (window_id, memberships[0]))
        return space

    # -- owned Spaces --------------------------------------------------------
    def create_space(self):
        try:
            record = self.nsk.create()
        except pl.NskError as exc:
            original_ids = {entry["id"] for entry in self.baseline["order"]}
            if exc.request_may_have_applied and exc.space_id and exc.space_id not in original_ids:
                self.owned.append(exc.space_id)
                self.live_owned.add(exc.space_id)
                self.cleanup.push("destroy own Space %s" % exc.space_id,
                                  lambda sid=exc.space_id: self.destroy_owned(sid))
            raise
        sid = record["id"]
        self.owned.append(sid)
        self.live_owned.add(sid)
        self.cleanup.push("destroy own Space %s" % sid, lambda: self.destroy_owned(sid))
        return record

    def destroy_owned(self, sid):
        """Destroy one self-created Space: never a populated one, never an original one."""
        if sid not in self.owned:
            raise pl.ProbeError("refusing to destroy Space %s: not created by this run" % sid)
        spaces = self.nsk.list()
        record = pl.find_space(spaces, sid)
        if record is None:
            self.live_owned.discard(sid)
            return {"already_gone": True}
        if record["active"]:
            home = self.baseline["active"].get(record["display"])
            if home is None:
                raise pl.ProbeError("no baseline current Space for the display of %s" % sid)
            self.nsk.activate(home)
        observer = self.need_observer()
        reached, ms, _ = pl.wait_for(lambda: self._no_application_windows(observer, sid), self.args.settle)
        if not reached:
            blocking = [w["id"] for w in observer.census(sid)["windows"] if w.get("layer") in (0, 3, 8)]
            raise pl.ProbeError("own Space %s still hosts application windows %s; not destroying a populated Space"
                                % (sid, blocking))
        self.nsk.destroy(sid)
        self.live_owned.discard(sid)
        return {"destroyed": sid, "waited_ms": ms}

    @staticmethod
    def _no_application_windows(observer, sid):
        """Whether no normal/floating/modal window is parked on the test Space."""
        return not any(w.get("layer") in (0, 3, 8) for w in observer.census(sid)["windows"])

    def mark_destroyed(self, sid):
        self.live_owned.discard(sid)
        self.cleanup.discard("destroy own Space %s" % sid)

    def restore_current_spaces(self):
        """Re-activate every display's baseline current Space if something changed it."""
        changed = []
        now = pl.active_spaces(self.nsk.list())
        for display, sid in self.baseline["active"].items():
            if now.get(display) != sid:
                self.nsk.activate(sid)
                changed.append({"display": display, "from": now.get(display), "to": sid})
        return {"reactivated": changed} if changed else None

    # -- census helpers ------------------------------------------------------
    @staticmethod
    def ids_on(spaces, display):
        return [s["id"] for s in pl.display_spaces(spaces, display)]

    @staticmethod
    def identity_check(before, after):
        """Every Space keeps its display/type/uuid/active flag; nothing disappears."""
        problems = []
        after_by_id = {s["id"]: s for s in after}
        for prior in before:
            now = after_by_id.get(prior["id"])
            if now is None:
                problems.append("Space %s disappeared" % prior["id"])
                continue
            for key in ("display", "type", "uuid", "active"):
                if now.get(key) != prior.get(key):
                    problems.append("Space %s changed %s" % (prior["id"], key))
        return problems


def stable(ctx, predicate):
    return pl.settle_and_hold(predicate, ctx.args.settle, ctx.args.stable)


def ok(result):
    return bool(result["reached"] and result["held"])


# --- read-only cases ---------------------------------------------------------



def case_capabilities(ctx):
    caps = ctx.nsk.capabilities()
    entry = caps.get("runtime_entrypoints", {})
    expected = ("space_query", "window_query", "create_space", "destroy_space",
                "activate_space", "move_window", "reorder_spaces")
    missing = [k for k in expected if entry.get(k) is not True]
    details = {"runtime_entrypoints": entry, "os": caps.get("os"), "missing": missing}
    if not entry.get("space_query"):
        raise pl.CaseFailure("space_query entry point unavailable; nothing else can be verified", **details)
    if missing:
        details["status"] = "observation"
    return details


def case_list_consistency(ctx):
    spaces = ctx.nsk.list()
    problems = []
    seen = set()
    per_display = {}
    for position, s in enumerate(spaces, start=1):
        for key, kind in (("id", int), ("uuid", str), ("display", str), ("index", int),
                          ("display_index", int), ("type", int), ("active", bool)):
            if not isinstance(s.get(key), kind) or (kind is int and isinstance(s.get(key), bool)):
                problems.append("record %d: %s is not %s" % (position, key, kind.__name__))
        if not isinstance(s.get("id"), int) or s["id"] <= 0 or s["id"] in seen:
            problems.append("record %d: id %r not unique/positive" % (position, s.get("id")))
        seen.add(s.get("id"))
        if s.get("index") != position:
            problems.append("record %d: index %r is not the one-based position" % (position, s.get("index")))
        if not s.get("display"):
            problems.append("record %d: empty display identifier" % position)
        per_display.setdefault(s.get("display"), []).append(s)
    for display, records in per_display.items():
        if [r.get("display_index") for r in records] != list(range(1, len(records) + 1)):
            problems.append("display %s: display_index is not sequential" % display)
        active = [r["id"] for r in records if r.get("active") is True]
        if len(active) != 1:
            problems.append("display %s: expected exactly one active Space, got %s" % (display, active))
        if not any(r.get("type") == pl.DESKTOP_TYPE for r in records):
            problems.append("display %s: no ordinary Desktop" % display)
    details = {"count": len(spaces), "displays": len(per_display),
               "desktops": sum(1 for s in spaces if s.get("type") == pl.DESKTOP_TYPE),
               "problems": problems}
    if problems:
        raise pl.CaseFailure("census records violate the documented schema", **details)
    return details


def case_window_spaces(ctx):
    ctx.need_observer()
    fx = ctx.fixture(1)
    wid = fx.ids[0]
    reported = ctx.nsk.window_spaces(wid)
    observed = ctx.window(wid)
    home = ctx.home_of(wid)
    details = {"window_id": wid, "nsk_space_ids": reported, "observer_memberships": observed.get("memberships"),
               "home": {"id": home["id"], "active": home["active"], "type": home["type"]},
               "layer": observed.get("layer"), "onscreen": observed.get("onscreen")}
    if reported != [home["id"]]:
        raise pl.CaseFailure("window-spaces did not report the single home Space", **details)
    if not home["active"]:
        raise pl.CaseFailure("a freshly ordered-in fixture window is not on the current Space", **details)
    if observed.get("layer") != 0 or not observed.get("onscreen"):
        raise pl.CaseFailure("fixture window is not an on-screen level-0 window", **details)
    return details


def case_invalid_ids(ctx):
    trials = [
        ("activate", "0"), ("activate", "-1"), ("activate", "+1"), ("activate", " 1"), ("activate", "1x"),
        ("activate", "18446744073709551616"), ("destroy", "abc"), ("destroy", "0", "--migrate"),
        ("window-spaces", "0"), ("window-spaces", "4294967296"), ("move-window", "1", "0"),
        ("move-window", "4294967296", "1"), ("move", "0", "1"), ("swap", "1", "01x"),
    ]
    results = []
    problems = []
    for argv in trials:
        err = ctx.nsk.expect_error(*argv)
        results.append(err.summary())
        if err.code != "invalid_argument":
            problems.append("%s: expected NSK_INVALID_ARGUMENT, got %s" % (" ".join(argv), err.code))
        if err.request_may_have_applied:
            problems.append("%s: request_may_have_applied must be false for rejected input" % " ".join(argv))
    details = {"trials": results, "problems": problems}
    if problems:
        raise pl.CaseFailure("ID validation error envelope mismatch", **details)
    return details


# --- mutating cases ----------------------------------------------------------

def case_lifecycle(ctx):
    before = ctx.nsk.list()
    created = ctx.create_space()
    sid = created["id"]
    after_create = ctx.nsk.list()
    record = pl.find_space(after_create, sid)
    details = {"created": created, "appended_last": None}
    if sid in pl.space_ids(before):
        raise pl.CaseFailure("create returned an ID that already existed", **details)
    if record is None:
        raise pl.CaseFailure("created Space is absent from the census", **details)
    if record["type"] != pl.DESKTOP_TYPE or created["type"] != pl.DESKTOP_TYPE:
        raise pl.CaseFailure("created Space is not an ordinary Desktop", **details)
    if record["active"]:
        raise pl.CaseFailure("create must not activate the new Desktop", **details)
    on_display = ctx.ids_on(after_create, record["display"])
    details["appended_last"] = on_display[-1] == sid
    details["display_index"] = record["display_index"]
    problems = pl.baseline_diff(pl.snapshot_baseline(before), after_create, ignore_ids=[sid])
    if problems:
        raise pl.CaseFailure("create disturbed the existing census", problems=problems, **details)
    destroyed = ctx.nsk.destroy(sid)
    after_destroy = ctx.nsk.list()
    details["destroyed"] = destroyed
    if destroyed != sid or pl.find_space(after_destroy, sid) is not None:
        raise pl.CaseFailure("destroy did not remove the Space from the census", **details)
    ctx.mark_destroyed(sid)
    problems = pl.baseline_diff(pl.snapshot_baseline(before), after_destroy)
    if problems:
        raise pl.CaseFailure("census differs from before the lifecycle", problems=problems, **details)
    again = ctx.nsk.expect_error("destroy", sid)
    details["destroy_again"] = again.summary()
    if again.code != "not_found" or again.request_may_have_applied:
        raise pl.CaseFailure("destroying a vanished Space must fail with NSK_NOT_FOUND", **details)
    return details


def case_migration(ctx):
    observer = ctx.need_observer()
    fx = ctx.fixture(2)
    home = ctx.home_of(fx.ids[0])
    if ctx.home_of(fx.ids[1])["id"] != home["id"]:
        raise pl.ProbeError("fixture windows did not appear on the same Space")
    target = ctx.create_space()
    sid = target["id"]
    details = {"home": home["id"], "own_space": sid, "windows": fx.ids}
    if target["display"] != home["display"]:
        raise Skip("created Space landed on another display; cross-display migration is unverified")
    layout = ctx.ids_on(ctx.nsk.list(), home["display"])
    details["layout"] = {"order": layout, "home_is_first": layout[0] == home["id"],
                         "home_adjacent_to_own": abs(layout.index(home["id"]) - layout.index(sid)) == 1}
    frames_before = [w["frame"] for w in fx.frames()]
    bounds_before = [observer.window(w).get("bounds") for w in fx.ids]
    for wid in fx.ids:
        moved = ctx.nsk.move_window(wid, sid)
        if moved.get("space_ids") != [sid]:
            raise pl.CaseFailure("move-window did not report the destination as sole membership", moved=moved, **details)
    parked = stable(ctx, lambda: all(observer.window(w).get("memberships") == [sid] for w in fx.ids))
    details["parked_on_own_space"] = parked
    if not ok(parked):
        raise pl.CaseFailure("observer does not stably agree that both windows live on the own Space", **details)
    guard = ctx.nsk.expect_error("destroy", sid)
    details["not_empty_guard"] = guard.summary()
    if guard.code != "space_not_empty" or guard.request_may_have_applied:
        raise pl.CaseFailure("destroying a populated Desktop must fail with NSK_SPACE_NOT_EMPTY", **details)
    if pl.find_space(ctx.nsk.list(), sid) is None:
        raise pl.CaseFailure("the guard refused but the Space is gone", **details)
    started = time.monotonic()
    destroyed = ctx.nsk.destroy(sid, migrate=True)
    details["destroy_migrate_ms"] = round((time.monotonic() - started) * 1000.0, 1)
    if destroyed != sid or pl.find_space(ctx.nsk.list(), sid) is not None:
        raise pl.CaseFailure("destroy --migrate did not remove the Space", **details)
    ctx.mark_destroyed(sid)
    if not fx.alive():
        raise pl.CaseFailure("fixture process died during migration", **details)
    spaces = ctx.nsk.list()
    active_here = pl.active_spaces(spaces).get(home["display"])
    details["active_space"] = active_here
    landed = stable(ctx, lambda: all(observer.window(w).get("memberships") == [active_here] for w in fx.ids))
    details["landed_on_active"] = landed
    landing = []
    for wid in fx.ids:
        record = observer.window(wid)
        landing.append({"window_id": wid, "memberships": record.get("memberships"),
                        "present": record.get("present"), "bounds": record.get("bounds"),
                        "onscreen": record.get("onscreen")})
    frames_after = [w["frame"] for w in fx.frames()]
    details.update({"landing": landing, "frames_before": frames_before, "frames_after": frames_after,
                    "bounds_before": bounds_before, "destination_is_home": active_here == home["id"]})
    if not all(entry["present"] for entry in landing):
        raise pl.CaseFailure("a window did not survive migration", **details)
    if not ok(landed):
        raise pl.CaseFailure("migrated windows are not stably on the display's current Desktop", **details)
    if [entry["bounds"] for entry in landing] != bounds_before:
        raise pl.CaseFailure("window bounds changed across migration", **details)
    if frames_before != frames_after:
        raise pl.CaseFailure("owner-side frames changed across migration", **details)
    return details


def case_activation(ctx):
    observer = ctx.need_observer()
    fx = ctx.fixture(2)
    target_wid, control_wid = fx.ids
    home = ctx.home_of(target_wid)
    display = home["display"]
    own = ctx.create_space()
    sid = own["id"]
    details = {"home": home["id"], "own_space": sid, "target_window": target_wid, "control_window": control_wid}
    if own["display"] != display:
        raise Skip("created Space landed on another display; multi-display activation is unverified")
    ctx.nsk.move_window(target_wid, sid)

    def state():
        obs = observer.observe(target_wid, control_wid)
        target, control = obs["windows"]
        return {
            "current": obs["current"].get(display),
            "target_onscreen": bool(target.get("onscreen")),
            "target_up_on_own": pl.hosting(target, sid)["up"],
            "control_onscreen": bool(control.get("onscreen")),
            "control_up_on_home": pl.hosting(control, home["id"])["up"],
        }

    def parked_ok():
        s = state()
        return s if (s["current"] == home["id"] and not s["target_onscreen"] and s["control_onscreen"]) else False

    def away_ok():
        s = state()
        return s if (s["current"] == sid and s["target_onscreen"] and s["target_up_on_own"]
                     and not s["control_onscreen"]) else False

    def home_ok():
        s = state()
        return s if (s["current"] == home["id"] and s["control_onscreen"] and s["control_up_on_home"]
                     and not s["target_onscreen"]) else False

    details["before"] = stable(ctx, parked_ok)
    if not ok(details["before"]):
        raise pl.CaseFailure("precondition failed: target off-screen on the own Desktop, control on-screen at home", **details)

    started = time.monotonic()
    activated = ctx.nsk.activate(sid)
    details["activate_ms"] = round((time.monotonic() - started) * 1000.0, 1)
    details["activated"] = activated
    if not activated.get("active") or activated.get("id") != sid:
        raise pl.CaseFailure("activate did not return the target as active", **details)
    details["away"] = stable(ctx, away_ok)
    details["away_fixture_view"] = fx.frames()
    details["census_active"] = pl.active_spaces(ctx.nsk.list()).get(display)
    if not ok(details["away"]):
        raise pl.CaseFailure("target not stably visible / control not stably hidden after activation", **details)
    if details["census_active"] != sid:
        raise pl.CaseFailure("census does not report the own Desktop as current", **details)
    owner_view = {w["id"]: w for w in details["away_fixture_view"]}
    if not owner_view[target_wid]["on_active_space"] or owner_view[control_wid]["on_active_space"]:
        raise pl.CaseFailure("AppKit isOnActiveSpace disagrees with the compositor", **details)

    started = time.monotonic()
    ctx.nsk.activate(home["id"])
    details["return_ms"] = round((time.monotonic() - started) * 1000.0, 1)
    details["back"] = stable(ctx, home_ok)
    details["back_fixture_view"] = fx.frames()
    if not ok(details["back"]):
        raise pl.CaseFailure("home Desktop not stably restored after returning", **details)
    return details


def case_move_window(ctx):
    observer = ctx.need_observer()
    fx = ctx.fixture(1)
    wid = fx.ids[0]
    home = ctx.home_of(wid)
    own = ctx.create_space()
    sid = own["id"]
    details = {"home": home["id"], "own_space": sid, "window_id": wid}
    if own["display"] != home["display"]:
        raise Skip("created Space landed on another display; cross-display window moves are unverified")
    before = observer.window(wid)
    active_before = pl.active_spaces(ctx.nsk.list())
    moved = ctx.nsk.move_window(wid, sid)
    details["moved"] = moved
    if moved.get("window_id") != wid or moved.get("space_id") != sid or moved.get("space_ids") != [sid]:
        raise pl.CaseFailure("move-window response does not describe a single-Space move", **details)

    def on_own_only():
        w = observer.window(wid)
        return (w.get("memberships") == [sid] and not w.get("onscreen")
                and pl.hosting(w, sid)["including_parked"] and not pl.hosting(w, home["id"])["including_parked"])

    def home_again():
        w = observer.window(wid)
        return w.get("memberships") == [home["id"]] and bool(w.get("onscreen"))

    details["after_move"] = stable(ctx, on_own_only)
    after = observer.window(wid)
    details["bounds_before"] = before.get("bounds")
    details["bounds_after"] = after.get("bounds")
    if not ok(details["after_move"]):
        raise pl.CaseFailure("window not stably hosted by the destination only", **details)
    if after.get("bounds") != before.get("bounds"):
        raise pl.CaseFailure("window bounds changed across the move", **details)
    if pl.active_spaces(ctx.nsk.list()) != active_before:
        raise pl.CaseFailure("move-window changed the current Space", **details)
    if ctx.nsk.window_spaces(wid) != [sid]:
        raise pl.CaseFailure("window-spaces disagrees after the move", **details)
    absent = ctx.nsk.expect_error("move-window", wid, pl.NONEXISTENT_SPACE_ID)
    details["nonexistent_destination"] = absent.summary()
    if absent.code != "not_found" or absent.request_may_have_applied:
        raise pl.CaseFailure("moving to a nonexistent Space must fail with NSK_NOT_FOUND", **details)
    details["moved_back"] = ctx.nsk.move_window(wid, home["id"])
    details["after_return"] = stable(ctx, home_again)
    if not ok(details["after_return"]):
        raise pl.CaseFailure("window did not return home stably", **details)
    return details


def expect_move(order, source, target):
    """Public move semantics: source lands on target's ORIGINAL position, the rest shifts."""
    result = list(order)
    result.remove(source)
    result.insert(order.index(target), source)
    return result


def expect_swap(order, a, b):
    result = list(order)
    i, j = result.index(a), result.index(b)
    result[i], result[j] = result[j], result[i]
    return result


def case_reorder(ctx):
    baseline_spaces = ctx.nsk.list()
    probe = ctx.create_space()
    display = probe["display"]
    home = pl.active_spaces(baseline_spaces)[display]
    if any(s["type"] != pl.DESKTOP_TYPE for s in pl.display_spaces(baseline_spaces, display)):
        raise Skip("display holds non-Desktop Spaces (fullscreen/tile); reordering is limited to Desktop-only layouts")
    s1 = probe["id"]
    s2 = ctx.create_space()["id"]
    s3 = ctx.create_space()["id"]
    for sid in (s2, s3):
        if pl.find_space(ctx.nsk.list(), sid)["display"] != display:
            raise Skip("created Spaces landed on different displays; multi-display reordering is unverified")
    original = ctx.ids_on(baseline_spaces, display)
    order = ctx.ids_on(ctx.nsk.list(), display)
    details = {"display_original": original, "own": [s1, s2, s3], "home": home, "steps": []}
    if order != original + [s1, s2, s3]:
        details["note"] = "created Desktops were not appended in creation order; expectations follow the observed order"
    snapshot = {"before": ctx.nsk.list()}

    def step(label, command, a, b, expected):
        started = time.monotonic()
        response = ctx.nsk.move(a, b) if command == "move" else ctx.nsk.swap(a, b)
        elapsed = round((time.monotonic() - started) * 1000.0, 1)
        reported = [s["id"] for s in response["spaces"] if s["display"] == display]
        fresh = ctx.nsk.list()
        observed = ctx.ids_on(fresh, display)
        entry = {"label": label, "command": "%s %s %s" % (command, a, b), "expected": expected,
                 "reported": reported, "observed": observed, "ms": elapsed}
        details["steps"].append(entry)
        if command == "move" and response["moved"]["id"] != a:
            raise pl.CaseFailure("move response 'moved' is not the source", **details)
        if command == "swap" and response["swapped"] != [a, b]:
            raise pl.CaseFailure("swap response 'swapped' is not [a, b]", **details)
        if reported != expected or observed != expected:
            raise pl.CaseFailure("order after %s is not the expected permutation" % label, **details)
        problems = ctx.identity_check(snapshot["before"], fresh)
        others_before = [s["id"] for s in snapshot["before"] if s["display"] != display]
        others_after = [s["id"] for s in fresh if s["display"] != display]
        if others_before != others_after:
            problems.append("Spaces on other displays changed")
        if problems:
            raise pl.CaseFailure("identity changed during %s: %s" % (label, problems), **details)
        snapshot["before"] = fresh
        return observed

    order = step("move S3 to S1's position", "move", s3, s1, expect_move(order, s3, s1))
    order = step("nonadjacent swap S3<->S2", "swap", s3, s2, expect_swap(order, s3, s2))
    order = step("adjacent swap S2<->S1", "swap", s2, s1, expect_swap(order, s2, s1))

    activated = ctx.nsk.activate(s1)
    if not activated.get("active"):
        raise pl.CaseFailure("could not activate an own Desktop for the active-endpoint steps", **details)
    ctx.cleanup.push("restore current Space on display", ctx.restore_current_spaces, phase=pl.PHASE_RESTORE)
    snapshot["before"] = ctx.nsk.list()
    order = step("swap with active endpoint S1<->S3", "swap", s1, s3, expect_swap(order, s1, s3))
    if pl.active_spaces(ctx.nsk.list()).get(display) != s1:
        raise pl.CaseFailure("active Space did not follow its ID through the swap", **details)
    order = step("move active S1 to S3's position", "move", s1, s3, expect_move(order, s1, s3))
    if pl.active_spaces(ctx.nsk.list()).get(display) != s1:
        raise pl.CaseFailure("active Space did not follow its ID through the move", **details)
    ctx.nsk.activate(home)
    snapshot["before"] = ctx.nsk.list()
    order = step("swap back S3<->S2", "swap", s3, s2, expect_swap(order, s3, s2))
    details["final_order"] = order

    not_found = ctx.nsk.expect_error("move", s1, pl.NONEXISTENT_SPACE_ID)
    details["nonexistent_target"] = not_found.summary()
    if not_found.code != "not_found" or not_found.request_may_have_applied:
        raise pl.CaseFailure("move to a nonexistent ID must fail with NSK_NOT_FOUND", **details)
    foreign = [s["id"] for s in baseline_spaces if s["display"] != display]
    if foreign:
        cross = ctx.nsk.expect_error("move", s1, foreign[0])
        details["different_displays"] = cross.summary()
        if cross.code != "different_displays" or cross.request_may_have_applied:
            raise pl.CaseFailure("cross-display move must fail with NSK_DIFFERENT_DISPLAYS", **details)
    problems = pl.baseline_diff(pl.snapshot_baseline(baseline_spaces), ctx.nsk.list(), ignore_ids=[s1, s2, s3])
    if problems:
        raise pl.CaseFailure("original Desktops were disturbed by reordering", problems=problems, **details)
    return details


def case_guards(ctx):
    original = ctx.nsk.list()
    own = ctx.create_space()
    home = pl.active_spaces(original)[own["display"]]
    ctx.nsk.activate(own["id"])
    before = ctx.nsk.list()
    details = {"trials": []}
    problems = []
    trials = [("destroy", own["id"], "active_space"),
              ("destroy", pl.NONEXISTENT_SPACE_ID, "not_found"),
              ("activate", pl.NONEXISTENT_SPACE_ID, "not_found")]
    for trial in trials:
        argv, expected = trial[:-1], trial[-1]
        err = ctx.nsk.expect_error(*argv)
        entry = err.summary()
        entry["expected"] = expected
        details["trials"].append(entry)
        if err.code != expected:
            problems.append("%s: expected %s got %s" % (" ".join(str(a) for a in argv), expected, err.code))
        if err.request_may_have_applied:
            problems.append("%s: guard reported request_may_have_applied" % " ".join(str(a) for a in argv))
    if ctx.nsk.list() != before:
        problems.append("census changed although every request was refused")
    details["problems"] = problems
    if problems:
        raise pl.CaseFailure("guard behavior mismatch", **details)
    ctx.nsk.activate(home)
    return details


CASES = [
    ("capabilities", case_capabilities, False),
    ("list_consistency", case_list_consistency, False),
    ("window_spaces", case_window_spaces, True),
    ("invalid_ids", case_invalid_ids, False),
    ("lifecycle", case_lifecycle, True),
    ("migration", case_migration, True),
    ("activation", case_activation, True),
    ("move_window", case_move_window, True),
    ("reorder", case_reorder, True),
    ("guards", case_guards, True),
]


def run_case(ctx, report, name, func, mutating):
    if mutating and not ctx.args.mutate:
        report.record(name, "skip", error="requires --mutate")
        return True
    ctx.cleanup = pl.Cleanup()
    status, details, error = "pass", None, None
    try:
        details = func(ctx)
        if isinstance(details, dict) and details.get("status") == "observation":
            status = "observation"
    except Skip as exc:
        status, error = "skip", str(exc)
    except pl.CaseFailure as exc:
        status, error, details = "fail", str(exc), exc.details
    except pl.Prerequisite as exc:
        status, error = "skip", str(exc)
    except Exception as exc:  # any other exception is a failed verdict, never a runner crash
        status, error = "fail", pl.exception_text(exc)
    finally:
        cleanup = ctx.cleanup.run()
        if mutating:
            try:
                restored = ctx.restore_current_spaces()
                if restored:
                    cleanup.append({"label": "restore current Spaces", "ok": True, "detail": restored})
            except Exception as exc:
                cleanup.append({"label": "restore current Spaces", "ok": False, "error": pl.exception_text(exc)})
    if not all(entry["ok"] for entry in cleanup):
        report.data["cleanup"]["complete"] = False
    report.data["cleanup"]["actions"].extend(dict(entry, case=name) for entry in cleanup)
    report.record(name, status, details=details, error=error, cleanup=cleanup)
    return status in ("pass", "skip", "observation")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    pl.add_common_arguments(parser)
    parser.add_argument("--mutate", action="store_true",
                        help="consent to desktop changes: create/activate/destroy OWN Spaces and move OWN windows")
    parser.add_argument("--case", action="append", choices=[c[0] for c in CASES], metavar="NAME",
                        help="run only these cases (repeatable): %s" % ", ".join(c[0] for c in CASES))
    args = parser.parse_args(argv)
    report = pl.Report("smoke", args, "mutate" if args.mutate else "read-only")

    try:
        nsk = pl.Nsk(pl.require_executable(args.cli, "nsk"), args.timeout)
        observer = fixture_path = None
        try:
            observer = pl.Observer(pl.require_executable(args.sticky_probe, "sticky-probe"), args.timeout)
            fixture_path = pl.require_executable(args.fixture, "window-fixture")
        except pl.Prerequisite as exc:
            if args.mutate:
                raise
            report.data["environment"]["helpers"] = str(exc)
        report.data["environment"]["nsk_version"] = nsk.version()
        report.data["environment"]["os"] = nsk.capabilities().get("os")
        if args.mutate:
            report.data["environment"]["session"] = pl.guard_session(observer)
        baseline_spaces = nsk.list()
    except pl.Prerequisite as exc:
        report.record("prerequisites", "fail", error=str(exc))
        return report.finish(pl.EXIT_PREREQ)
    except pl.ProbeError as exc:
        report.record("prerequisites", "fail", error=pl.exception_text(exc))
        return report.finish(pl.EXIT_FAIL)

    ctx = Context(args, nsk, observer, fixture_path)
    ctx.baseline_spaces = baseline_spaces
    ctx.baseline = pl.snapshot_baseline(baseline_spaces)
    report.data["baseline"] = ctx.baseline

    selected = [c for c in CASES if not args.case or c[0] in args.case]
    all_ok = True
    for name, func, mutating in selected:
        if not report.data["cleanup"]["complete"]:
            report.record(name, "skip", error="an earlier cleanup failed; no further cases will run")
            continue
        all_ok = run_case(ctx, report, name, func, mutating) and all_ok

    # Final sweep: an own Space still alive is a cleanup failure unless it can be removed now.
    if ctx.live_owned:
        ctx.cleanup = pl.Cleanup()
        for sid in sorted(ctx.live_owned):
            ctx.cleanup.push("final sweep: destroy own Space %s" % sid, lambda sid=sid: ctx.destroy_owned(sid))
        sweep = ctx.cleanup.run()
        report.data["cleanup"]["actions"].extend(dict(entry, case="final") for entry in sweep)
        if not all(entry["ok"] for entry in sweep):
            report.data["cleanup"]["complete"] = False
    try:
        problems = pl.baseline_diff(ctx.baseline, nsk.list())
    except pl.ProbeError as exc:
        problems = ["could not re-read the census: %s" % pl.exception_text(exc)]
    report.data["baseline_restored"] = not problems
    report.data["baseline_problems"] = problems
    report.data["owned_spaces"] = ctx.owned

    if not report.data["cleanup"]["complete"] or problems:
        code = pl.EXIT_CLEANUP
    elif not all_ok:
        code = pl.EXIT_FAIL
    else:
        code = pl.EXIT_OK
    return report.finish(code)


if __name__ == "__main__":
    sys.exit(main())
