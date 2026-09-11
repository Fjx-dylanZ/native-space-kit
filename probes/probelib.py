"""Shared plumbing for the native-space-kit live probes.

Python 3.9, standard library only. Nothing here mutates the desktop by itself;
the runners decide what to call and only after explicit ``--mutate`` consent.
"""

import argparse
import datetime
import json
import os
import selectors
import subprocess
import sys
import time
import traceback

EXIT_OK = 0          # every selected case passed (observations never fail a run)
EXIT_FAIL = 1        # at least one case failed or the experiment aborted
EXIT_PREREQ = 2      # usage error, missing binary, locked/absent GUI session
EXIT_CLEANUP = 3     # cleanup incomplete or baseline not restored: needs attention

PROBES_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(PROBES_DIR)
DEFAULT_CLI = os.path.join(REPO_ROOT, "build", "nsk")
DEFAULT_FIXTURE = os.path.join(REPO_ROOT, "build", "window-fixture")
DEFAULT_STICKY_PROBE = os.path.join(REPO_ROOT, "build", "sticky-probe")

DESKTOP_TYPE = 0
NONEXISTENT_SPACE_ID = "18446744073709551615"  # valid uint64 syntax, never a managed Space


class ProbeError(Exception):
    """A step could not produce a verdict (tool failure, unexpected state)."""


class Prerequisite(ProbeError):
    """Something outside the probe's control is missing (binary, session)."""


class CaseFailure(ProbeError):
    """A verified contract did not hold; carries structured details."""

    def __init__(self, message, **details):
        super().__init__(message)
        self.details = details


class NskError(ProbeError):
    """nsk exited nonzero with its JSON error envelope."""

    def __init__(self, argv, exit_code, payload, stderr_text):
        error = payload.get("error", {}) if isinstance(payload, dict) else {}
        self.argv = argv
        self.exit_code = exit_code
        self.payload = payload
        self.code = error.get("code")
        self.message = error.get("message", "")
        self.space_id = error.get("space_id")
        self.window_id = error.get("window_id")
        self.request_may_have_applied = bool(error.get("request_may_have_applied", False))
        self.observed_spaces = payload.get("observed_spaces") if isinstance(payload, dict) else None
        self.stderr_text = stderr_text
        super().__init__("%s failed (%s): %s" % (" ".join(argv), self.code, self.message))

    def summary(self):
        return {
            "argv": self.argv,
            "exit_code": self.exit_code,
            "code": self.code,
            "message": self.message,
            "request_may_have_applied": self.request_may_have_applied,
            "space_id": self.space_id,
            "window_id": self.window_id,
        }


def add_common_arguments(parser):
    parser.add_argument("--cli", default=os.environ.get("NSK", DEFAULT_CLI),
                        help="path to the nsk binary (default: build/nsk, env NSK)")
    parser.add_argument("--fixture", default=os.environ.get("NSK_WINDOW_FIXTURE", DEFAULT_FIXTURE),
                        help="path to build/window-fixture (env NSK_WINDOW_FIXTURE)")
    parser.add_argument("--sticky-probe", default=os.environ.get("NSK_STICKY_PROBE", DEFAULT_STICKY_PROBE),
                        help="path to build/sticky-probe, the foreign observer (env NSK_STICKY_PROBE)")
    parser.add_argument("--report", metavar="PATH",
                        help="also write the JSON report to PATH (stdout always gets it)")
    parser.add_argument("--settle", type=float, default=5.0, metavar="SECONDS",
                        help="max wait for an expected compositor state (default 5)")
    parser.add_argument("--stable", type=float, default=1.0, metavar="SECONDS",
                        help="how long an observed state must hold before it counts (default 1)")
    parser.add_argument("--timeout", type=float, default=30.0, metavar="SECONDS",
                        help="per-command timeout for nsk and the helpers (default 30)")


def require_executable(path, label):
    if not (path and os.path.isfile(path) and os.access(path, os.X_OK)):
        raise Prerequisite("%s not found or not executable at %s (run `make probes`)" % (label, path))
    return path


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()


def _parse_json(text, what):
    text = text.strip()
    if not text:
        raise ProbeError("%s produced no JSON output" % what)
    try:
        return json.loads(text)
    except ValueError as exc:
        raise ProbeError("%s produced non-JSON output: %s (%s)" % (what, text[:400], exc))


class Tool:
    """One-shot JSON tool: one JSON object on stdout, JSON error on stderr."""

    def __init__(self, path, label, timeout):
        self.path = path
        self.label = label
        self.timeout = timeout

    def invoke(self, *args):
        argv = [self.path] + [str(a) for a in args]
        try:
            proc = subprocess.run(argv, capture_output=True, text=True, timeout=self.timeout)
        except subprocess.TimeoutExpired:
            raise ProbeError("%s timed out after %ss" % (" ".join(argv), self.timeout))
        except OSError as exc:
            raise Prerequisite("cannot run %s: %s" % (argv[0], exc))
        if proc.returncode != 0:
            try:
                payload = json.loads(proc.stderr.strip() or "{}")
            except ValueError:
                payload = {}
            raise NskError(argv, proc.returncode, payload, proc.stderr)
        return _parse_json(proc.stdout, " ".join(argv))


class Nsk(Tool):
    """Thin wrapper over the production CLI. IDs are passed through as strings."""

    def __init__(self, path, timeout):
        super().__init__(path, "nsk", timeout)

    def version(self):
        return self.invoke("--version")["version"]

    def capabilities(self):
        return self.invoke("capabilities")

    def list(self):
        return self.invoke("list")["spaces"]

    def create(self):
        return self.invoke("create")["created"]

    def activate(self, space_id):
        return self.invoke("activate", space_id)["activated"]

    def destroy(self, space_id, migrate=False):
        args = ["destroy", space_id] + (["--migrate"] if migrate else [])
        return self.invoke(*args)["destroyed"]

    def window_spaces(self, window_id):
        return self.invoke("window-spaces", window_id)["space_ids"]

    def move_window(self, window_id, space_id):
        return self.invoke("move-window", window_id, space_id)

    def move(self, source_id, target_id):
        return self.invoke("move", source_id, target_id)

    def swap(self, a, b):
        return self.invoke("swap", a, b)

    def expect_error(self, *args):
        """Run a command that MUST fail; return the NskError for inspection."""
        try:
            result = self.invoke(*args)
        except NskError as exc:
            return exc
        raise CaseFailure("nsk %s unexpectedly succeeded" % " ".join(str(a) for a in args), result=result)


class Observer(Tool):
    """build/sticky-probe: foreign-process observer plus experimental writers."""

    def __init__(self, path, timeout):
        super().__init__(path, "sticky-probe", timeout)

    def session(self):
        return self.invoke("session")

    def observe(self, *window_ids):
        return self.invoke("observe", *window_ids)

    def window(self, window_id):
        return self.observe(window_id)["windows"][0]

    def census(self, space_id):
        return self.invoke("census", space_id)

    def add(self, window_id, *space_ids):
        return self.invoke("add", window_id, *space_ids)

    def remove(self, window_id, *space_ids):
        return self.invoke("remove", window_id, *space_ids)

    def tag(self, window_id, on):
        return self.invoke("tag", window_id, "on" if on else "off")


def guard_session(observer):
    """Refuse visible tests unless an unlocked console GUI session is present."""
    session = observer.session()
    if not session.get("gui_session"):
        raise Prerequisite("no GUI session: run from a logged-in Aqua session")
    if not session.get("on_console") or not session.get("login_done"):
        raise Prerequisite("GUI session is not the console session or login is incomplete: %s" % json.dumps(session))
    if session.get("locked"):
        raise Prerequisite("screen is locked; unlock the session before running visible probes")
    return session


class Fixture:
    """A window-fixture process. Use as a context manager; windows die with it."""

    def __init__(self, path, count=2, title=None, timeout=10.0):
        self.path = path
        self.count = count
        self.title = title
        self.timeout = timeout
        self.proc = None
        self.pid = None
        self.windows = []
        self.ids = []
        self._buffer = b""
        self._selector = None

    def __enter__(self):
        argv = [self.path, "--count", str(self.count)]
        if self.title:
            argv += ["--title", self.title]
        try:
            self.proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=None)
        except OSError as exc:
            raise Prerequisite("cannot start window fixture %s: %s" % (self.path, exc))
        try:
            self._selector = selectors.DefaultSelector()
            self._selector.register(self.proc.stdout, selectors.EVENT_READ)
            ready = self._read_event()
            if not isinstance(ready, dict) or ready.get("event") != "ready":
                raise ProbeError("fixture did not report ready: %s" % json.dumps(ready))
            self.pid = ready["pid"]
            self.windows = ready["windows"]
            self.ids = [w["id"] for w in self.windows]
        except BaseException:
            self.close()
            raise
        return self

    def __exit__(self, exc_type, exc, tb):
        self.close()
        return False

    def _read_event(self):
        deadline = time.monotonic() + self.timeout
        while b"\n" not in self._buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ProbeError("window fixture did not respond within %ss" % self.timeout)
            if not self._selector.select(remaining):
                continue
            chunk = os.read(self.proc.stdout.fileno(), 65536)
            if not chunk:
                raise ProbeError("window fixture closed its output (exit %s)" % self.proc.poll())
            self._buffer += chunk
        line, _, self._buffer = self._buffer.partition(b"\n")
        return _parse_json(line.decode("utf-8", "replace"), "window fixture")

    def command(self, line):
        if not self.alive():
            raise ProbeError("window fixture is not running")
        self.proc.stdin.write((line + "\n").encode("utf-8"))
        self.proc.stdin.flush()
        event = self._read_event()
        if event.get("event") == "error":
            raise ProbeError("window fixture rejected %r: %s" % (line, event.get("message")))
        return event

    def frames(self):
        return self.command("frames")["windows"]

    def sticky(self, index, on):
        return self.command("sticky %d %s" % (index, "on" if on else "off"))["window"]

    def alive(self):
        return self.proc is not None and self.proc.poll() is None

    def close(self, grace=5.0):
        """Ask the fixture to quit, then kill it. Returns how it ended."""
        if self.proc is None:
            return {"exited": None, "forced": False}
        forced = False
        if self.proc.poll() is None:
            try:
                self.proc.stdin.write(b"quit\n")
                self.proc.stdin.flush()
            except (OSError, ValueError):
                pass
            try:
                self.proc.wait(timeout=grace)
            except subprocess.TimeoutExpired:
                forced = True
                self.proc.kill()
                self.proc.wait(timeout=grace)
        for stream in (self.proc.stdin, self.proc.stdout):
            try:
                stream.close()
            except (OSError, ValueError):
                pass
        if self._selector is not None:
            self._selector.close()
            self._selector = None
        result = {"exited": self.proc.returncode, "forced": forced}
        self.proc = None
        return result


PHASE_FIXTURE = 0    # terminate own windows first so own Spaces become empty
PHASE_RESTORE = 1    # re-activate baseline current Spaces
PHASE_SPACES = 2     # destroy own Spaces last


class Cleanup:
    """Ledger of cleanup actions run by phase (fixtures, restore, Spaces), LIFO
    within a phase. Every failure is recorded, never dropped."""

    def __init__(self):
        self._actions = []
        self.results = []

    def push(self, label, action, phase=PHASE_SPACES):
        self._actions.append((phase, label, action))

    def discard(self, label):
        self._actions = [entry for entry in self._actions if entry[1] != label]

    def run(self):
        ordered = []
        for phase in sorted({entry[0] for entry in self._actions}):
            ordered.extend(reversed([entry for entry in self._actions if entry[0] == phase]))
        self._actions = []
        for _, label, action in ordered:
            entry = {"label": label, "ok": True}
            try:
                detail = action()
                if detail is not None:
                    entry["detail"] = detail
            except Exception as exc:  # cleanup must keep going and report everything
                entry["ok"] = False
                entry["error"] = "%s: %s" % (type(exc).__name__, exc)
            self.results.append(entry)
        return self.results

    @property
    def complete(self):
        return all(entry["ok"] for entry in self.results)


def wait_for(predicate, timeout, interval=0.15):
    """Poll until predicate() is truthy. Returns (reached, elapsed_ms, last_value)."""
    start = time.monotonic()
    while True:
        value = predicate()
        elapsed = (time.monotonic() - start) * 1000.0
        if value:
            return True, round(elapsed, 1), value
        if time.monotonic() - start >= timeout:
            return False, round(elapsed, 1), value
        time.sleep(interval)


def hold_for(predicate, duration, interval=0.2):
    """Require predicate() to stay truthy for `duration`. Returns (held, samples, first_failure)."""
    start = time.monotonic()
    samples = 0
    while True:
        value = predicate()
        samples += 1
        if not value:
            return False, samples, value
        if time.monotonic() - start >= duration:
            return True, samples, None
        time.sleep(interval)


def settle_and_hold(predicate, settle, stable):
    """wait_for then hold_for; the shape every visibility assertion uses."""
    reached, settle_ms, last = wait_for(predicate, settle)
    if not reached:
        return {"reached": False, "settle_ms": settle_ms, "held": False, "samples": 0, "last": last}
    held, samples, failure = hold_for(predicate, stable)
    return {"reached": True, "settle_ms": settle_ms, "held": held, "samples": samples,
            "failure": failure if not held else None}


# --- Space census helpers -------------------------------------------------

def space_ids(spaces):
    return [s["id"] for s in spaces]


def find_space(spaces, space_id):
    for space in spaces:
        if space["id"] == space_id:
            return space
    return None


def active_spaces(spaces):
    """display identifier -> active Space ID"""
    return {s["display"]: s["id"] for s in spaces if s.get("active")}


def display_spaces(spaces, display):
    return [s for s in spaces if s["display"] == display]


def hosting(window, space_id):
    for entry in window.get("hosting", []):
        if entry["space_id"] == space_id:
            return entry
    return {"space_id": space_id, "up": None, "including_parked": None, "active": None}


def snapshot_baseline(spaces):
    """What must be identical after a probe: original IDs (order, display, type) and current Spaces."""
    return {
        "order": [{"id": s["id"], "display": s["display"], "type": s["type"]} for s in spaces],
        "active": active_spaces(spaces),
    }


def baseline_diff(baseline, spaces, ignore_ids=()):
    """Human-readable discrepancies between the baseline and a fresh census."""
    problems = []
    ignore = set(ignore_ids)
    now_by_id = {s["id"]: s for s in spaces}
    original_ids = [entry["id"] for entry in baseline["order"]]
    original_set = set(original_ids)
    for entry in baseline["order"]:
        now = now_by_id.get(entry["id"])
        if now is None:
            problems.append("original Space %s is missing" % entry["id"])
            continue
        if now["display"] != entry["display"]:
            problems.append("original Space %s changed display" % entry["id"])
        if now["type"] != entry["type"]:
            problems.append("original Space %s changed type %s -> %s" % (entry["id"], entry["type"], now["type"]))
    extra = [s["id"] for s in spaces if s["id"] not in original_set and s["id"] not in ignore]
    if extra:
        problems.append("unexpected extra Spaces present: %s" % extra)
    surviving = [s["id"] for s in spaces if s["id"] in original_set]
    expected = [i for i in original_ids if i in now_by_id]
    if surviving != expected:
        problems.append("relative order of original Spaces changed: %s -> %s" % (expected, surviving))
    active_now = active_spaces(spaces)
    for display, space_id in baseline["active"].items():
        if active_now.get(display) != space_id:
            problems.append("current Space on display %s changed %s -> %s" % (display, space_id, active_now.get(display)))
    return problems


def summarize_window(window):
    """Compact per-window view used in reports (IDs are local run values, not committed)."""
    return {
        "id": window.get("id"),
        "present": window.get("present"),
        "onscreen": window.get("onscreen"),
        "layer": window.get("layer"),
        "bounds": window.get("bounds"),
        "memberships": window.get("memberships"),
        "sticky_bit": window.get("sticky_bit"),
        "tags_hex": window.get("tags_hex"),
        "hosting": {str(h["space_id"]): {"up": h["up"], "including_parked": h["including_parked"], "active": h["active"]}
                    for h in window.get("hosting", [])},
    }


def exception_text(exc):
    if isinstance(exc, NskError):
        return json.dumps(exc.summary())
    return "".join(traceback.format_exception_only(type(exc), exc)).strip()


class Report:
    """Collects case outcomes; prints one JSON object on stdout and a summary on stderr."""

    def __init__(self, probe, args, mode):
        self.data = {
            "probe": probe,
            "mode": mode,
            "started": utc_now(),
            "argv": sys.argv[1:],
            "paths": {"cli": args.cli, "fixture": args.fixture, "sticky_probe": args.sticky_probe},
            "environment": {},
            "cases": [],
            "cleanup": {"complete": True, "actions": []},
            "baseline": None,
            "baseline_restored": None,
            "baseline_problems": [],
        }
        self.report_path = args.report

    def record(self, name, status, details=None, error=None, cleanup=None):
        entry = {"name": name, "status": status}
        if details:
            entry["details"] = details
        if error:
            entry["error"] = error
        if cleanup is not None:
            entry["cleanup"] = cleanup
        self.data["cases"].append(entry)
        return entry

    def finish(self, exit_code, extra=None):
        self.data["finished"] = utc_now()
        self.data["exit_code"] = exit_code
        if extra:
            self.data.update(extra)
        text = json.dumps(self.data, indent=2, sort_keys=False)
        sys.stdout.write(text + "\n")
        sys.stdout.flush()
        if self.report_path:
            with open(self.report_path, "w", encoding="utf-8") as handle:
                handle.write(text + "\n")
        counts = {}
        for case in self.data["cases"]:
            counts[case["status"]] = counts.get(case["status"], 0) + 1
        summary = ", ".join("%d %s" % (n, s) for s, n in sorted(counts.items())) or "no cases"
        sys.stderr.write("%s: %s; cleanup %s; baseline %s; exit %d\n" % (
            self.data["probe"], summary,
            "complete" if self.data["cleanup"]["complete"] else "INCOMPLETE",
            {True: "restored", False: "NOT RESTORED", None: "not checked"}[self.data["baseline_restored"]],
            exit_code))
        return exit_code
