#!/usr/bin/env python3
"""Read-only contract test for the nsk CLI.

Usage: cli_test.py PATH_TO_NSK

Covers the argument grammar, the stdout/stderr JSON split, structured error
shape, and the snapshot schema. Every mutating command invoked here must be
rejected while parsing arguments (exit 2, nothing initialized); well-formed IDs
are only ever passed to read-only commands and are chosen so they cannot exist.
Live checks are skipped when no GUI session is available.

Python 3.9 / standard library only.
"""

import json
import subprocess
import sys

U64_MAX = "18446744073709551615"
U32_MAX = "4294967295"
SNAPSHOT_KEYS = {"id", "uuid", "display", "index", "display_index", "type", "active"}
ENTRYPOINTS = {
    "space_query", "window_query", "create_space", "destroy_space",
    "activate_space", "move_window", "reorder_spaces",
}

failures = []


def check(condition, label):
    if not condition:
        failures.append(label)
        print("FAIL " + label)
    return condition


def run(nsk, args):
    completed = subprocess.run([nsk] + list(args), capture_output=True, text=True, timeout=60)
    return completed.returncode, completed.stdout, completed.stderr


def one_object(text, label):
    """The whole stream must be exactly one JSON object."""
    try:
        value = json.loads(text)
    except ValueError:
        check(False, label + ": stream is not JSON: " + repr(text[:200]))
        return None
    if not check(isinstance(value, dict), label + ": JSON is not an object"):
        return None
    return value


def expect_rejected(nsk, args):
    label = "reject " + " ".join(repr(a) for a in args)
    code, out, err = run(nsk, args)
    check(code == 2, label + ": exit %d, expected 2" % code)
    check(out == "", label + ": stdout must be empty")
    payload = one_object(err, label)
    if payload is None:
        return
    error = payload.get("error")
    if not check(isinstance(error, dict), label + ": missing error object"):
        return
    check(error.get("code") == "invalid_argument", label + ": code %r" % error.get("code"))
    check(isinstance(error.get("message"), str) and error["message"], label + ": message missing")
    check(error.get("request_may_have_applied") is False, label + ": request_may_have_applied must be false")
    check("space_id" not in error and "window_id" not in error, label + ": no IDs before parsing succeeds")
    check("observed_spaces" not in payload, label + ": no observed_spaces without a write")


def expect_window_spaces_unknown(nsk):
    """A well-formed window ID that no compositor assigns must reach the library
    (never exit 2). SkyLight reports unknown windows either as no membership
    (exit 0, empty space_ids) or as a failed query (exit 1); both are contract-clean."""
    label = "window-spaces " + U32_MAX
    code, out, err = run(nsk, ["window-spaces", U32_MAX])
    if code == 0:
        check(err == "", label + ": stderr must be empty on success")
        payload = one_object(out, label)
        if payload is None:
            return
        check(set(payload) == {"window_id", "space_ids"}, label + ": keys %r" % sorted(payload))
        check(payload.get("window_id") == int(U32_MAX), label + ": window_id %r" % (payload.get("window_id"),))
        check(payload.get("space_ids") == [], label + ": space_ids %r for an unknown window" % (payload.get("space_ids"),))
        return
    check(code == 1, label + ": exit %d, expected 0 or 1" % code)
    check(out == "", label + ": stdout must be empty on failure")
    payload = one_object(err, label)
    if payload is None:
        return
    error = payload.get("error")
    if not check(isinstance(error, dict), label + ": missing error object"):
        return
    check(error.get("code") == "query_failed", label + ": code %r" % error.get("code"))
    check(error.get("window_id", int(U32_MAX)) == int(U32_MAX), label + ": window_id %r" % (error.get("window_id"),))
    check(isinstance(error.get("message"), str) and error["message"], label + ": message missing")
    check(error.get("request_may_have_applied") is False, label + ": read-only command cannot have applied")
    check("observed_spaces" not in payload, label + ": no observed_spaces without a write")


def expect_success(nsk, args):
    label = " ".join(args)
    code, out, err = run(nsk, args)
    check(code == 0, label + ": exit %d, stderr %r" % (code, err[:200]))
    check(err == "", label + ": stderr must be empty on success")
    return one_object(out, label)


def test_grammar(nsk):
    version = expect_success(nsk, ["--version"])
    if version is not None:
        check(set(version) == {"version"}, "--version: keys %r" % sorted(version))
        check(isinstance(version.get("version"), str) and version["version"], "--version: value")


    rejected = [
        [],
        ["bogus"],
        ["--version", "extra"],
        ["list", "extra"],
        ["list", "--display"],
        ["list", "--display", ""],
        ["list", "--display", "a", "--display", "b"],
        ["list", "--display-index", "1"],
        ["list", "--display", "a", "--display-index"],
        ["list", "--display", "a", "--display-index", "0"],
        ["list", "--display", "a", "--display-index", "+1"],
        ["list", "--display", "a", "--display-index", " 1"],
        ["list", "--display", "a", "--display-index", "1.0"],
        ["list", "--display", "a", "--display-index", "18446744073709551616"],
        ["list", "--display", "a", "--display-index", "1", "--display-index", "2"],
        ["list", "--display", "--display-index", "1"],
        ["activate", U64_MAX, "--display", "a"],
        ["move-window", U32_MAX, U64_MAX, "--display-index", "1"],
        ["capabilities", "--migrate"],
        ["activate"],
        ["activate", U64_MAX, U64_MAX],
        ["activate", "0"],
        ["activate", "-1"],
        ["activate", "+1"],
        ["activate", " 1"],
        ["activate", "1 "],
        ["activate", "1x"],
        ["activate", "0x10"],
        ["activate", "1.0"],
        ["activate", "1e3"],
        ["activate", ""],
        ["activate", "\u0661"],  # Arabic-Indic digit one: not ASCII
        ["activate", "18446744073709551616"],  # UINT64_MAX + 1
        ["activate", U64_MAX, "--migrate"],
        ["destroy"],
        ["destroy", "--migrate"],
        ["destroy", U64_MAX, "--bogus"],
        ["destroy", U64_MAX, "-m"],
        ["destroy", "0", "--migrate"],
        ["window-spaces"],
        ["window-spaces", "0"],
        ["window-spaces", "4294967296"],  # UINT32_MAX + 1
        ["window-spaces", U32_MAX, U32_MAX],
        ["move-window"],
        ["move-window", U32_MAX],
        ["move-window", U32_MAX, "0"],
        ["move-window", "0", U64_MAX],
        ["move-window", "4294967296", U64_MAX],
        ["move-window", U32_MAX, U64_MAX, U64_MAX],
        ["move"],
        ["move", U64_MAX],
        ["move", U64_MAX, "-2"],
        ["move", U64_MAX, U64_MAX, U64_MAX],
        ["swap"],
        ["swap", U64_MAX],
        ["swap", "1a", U64_MAX],
        ["swap", U64_MAX, U64_MAX, U64_MAX],
    ]
    for args in rejected:
        expect_rejected(nsk, args)


def validate_snapshot(spaces, label):
    if not check(isinstance(spaces, list) and spaces, label + ": spaces must be a non-empty list"):
        return
    ids = []
    per_display = {}
    for position, record in enumerate(spaces, start=1):
        where = "%s: record %d" % (label, position)
        if not check(isinstance(record, dict), where + " is not an object"):
            continue
        check(SNAPSHOT_KEYS.issubset(record), where + ": missing required snapshot keys")
        space_id = record.get("id")
        check(isinstance(space_id, int) and not isinstance(space_id, bool) and space_id > 0, where + ": id %r" % (space_id,))
        check(isinstance(record.get("uuid"), str), where + ": uuid must be a string")
        check(isinstance(record.get("display"), str) and record["display"], where + ": display must be a non-empty string")
        check(record.get("index") == position, where + ": index %r, expected %d" % (record.get("index"), position))
        check(isinstance(record.get("type"), int) and not isinstance(record["type"], bool), where + ": type %r" % (record.get("type"),))
        check(isinstance(record.get("active"), bool), where + ": active must be a bool")
        ids.append(space_id)
        per_display.setdefault(record.get("display"), []).append(record)
    check(len(set(ids)) == len(ids), label + ": ids must be unique")
    for display, records in per_display.items():
        local = [r.get("display_index") for r in records]
        check(local == list(range(1, len(records) + 1)), "%s: display %r local indices %r" % (label, display, local))
        active = [r for r in records if r.get("active") is True]
        check(len(active) == 1, "%s: display %r has %d active records, expected 1" % (label, display, len(active)))


def test_display_filters(nsk, spaces):
    """Compare selectors with the unfiltered census, including original indices."""
    for display in dict.fromkeys(record["display"] for record in spaces):
        expected = [record for record in spaces if record["display"] == display]
        selected = expect_success(nsk, ["list", "--display", display])
        check(selected == {"spaces": expected}, "display filter preserves records and indices")
        for record in expected:
            # Options need not be in a particular order.
            selected = expect_success(nsk, ["list", "--display-index", str(record["display_index"]),
                                            "--display", display])
            check(selected == {"spaces": [record]}, "display-local selection returns exact record")

    for args in (["list", "--display", "nsk-test-nonexistent-display"],
                 ["list", "--display", spaces[0]["display"], "--display-index", U64_MAX]):
        code, out, err = run(nsk, args)
        check(code == 1 and out == "", "unmatched selector fails without stdout")
        payload = one_object(err, "unmatched selector")
        if payload:
            check(payload.get("error", {}).get("code") == "not_found", "unmatched selector: not_found")
            check(payload.get("error", {}).get("request_may_have_applied") is False,
                  "unmatched selector cannot have written")
            check("observed_spaces" not in payload, "unmatched selector has no write snapshot")


def test_live(nsk):
    """Read-only commands against the running session; skipped without a GUI."""
    code, out, err = run(nsk, ["capabilities"])
    if code != 0:
        payload = one_object(err, "capabilities")
        error = payload.get("error") if payload else None
        if isinstance(error, dict) and error.get("code") == "no_gui_session":
            print("SKIP live checks: %s: %s" % (error.get("code"), error.get("message")))
            return
        check(False, "capabilities: exit %d, stderr %r" % (code, err[:300]))
        return
    check(err == "", "capabilities: stderr must be empty on success")
    caps = one_object(out, "capabilities")
    if caps is None:
        return
    check(set(caps) == {"runtime_entrypoints", "os"}, "capabilities: keys %r" % sorted(caps))
    entrypoints = caps.get("runtime_entrypoints")
    if check(isinstance(entrypoints, dict), "capabilities: runtime_entrypoints must be an object"):
        check(set(entrypoints) == ENTRYPOINTS, "capabilities: entry points %r" % sorted(entrypoints))
        check(all(isinstance(v, bool) for v in entrypoints.values()), "capabilities: entry points must be bools")
    os_info = caps.get("os")
    if check(isinstance(os_info, dict), "capabilities: os must be an object"):
        check(set(os_info) == {"version", "build"}, "capabilities: os keys %r" % sorted(os_info))
        check(isinstance(os_info.get("version"), str) and os_info["version"], "capabilities: os.version")
        check(isinstance(os_info.get("build"), str), "capabilities: os.build must be a string")

    if not isinstance(entrypoints, dict):
        return
    if entrypoints.get("space_query"):
        listing = expect_success(nsk, ["list"])
        if listing is not None:
            check(set(listing) == {"spaces"}, "list: keys %r" % sorted(listing))
            validate_snapshot(listing.get("spaces"), "list")
            if listing.get("spaces"):
                test_display_filters(nsk, listing["spaces"])
    else:
        print("SKIP list: space_query unavailable")

    if entrypoints.get("window_query"):
        expect_window_spaces_unknown(nsk)
    else:
        print("SKIP window-spaces: window_query unavailable")


def main(argv):
    if len(argv) != 2:
        print("usage: cli_test.py PATH_TO_NSK", file=sys.stderr)
        return 2
    nsk = argv[1]
    test_grammar(nsk)
    test_live(nsk)
    if failures:
        print("cli_test: %d failure(s)" % len(failures))
        return 1
    print("cli_test: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
