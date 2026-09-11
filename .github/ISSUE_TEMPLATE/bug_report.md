---
name: Bug report
about: An operation misbehaved, was refused, or reported "unsupported"
title: ''
labels: ''
assignees: ''
---

## Environment

Paste the output of these two commands. They are read-only.

```sh
sw_vers
build/nsk capabilities
```

- Display layout (one display, several, "Displays have separate Spaces" on/off):
- Any fullscreen or tile Spaces present:
- Session state (unlocked, logged-in GUI session; not a locked or fast-user-switched session):
- Other window managers or Space tools running (yabai, Amethyst, etc.):

## What you ran

The exact command, or the C API call sequence.

## What you expected

## What happened

Paste the JSON that `nsk` printed, including `error.request_may_have_applied`
and the `observed_spaces` snapshot if present. Redact anything you consider
sensitive; native Space IDs and window IDs are fine to include.

## Reproduction

If `python3 probes/smoke.py` (read-only) or `probes/smoke.py --mutate` (only in a
disposable VM or a session you are prepared to manipulate) reproduces the
problem, attach the JSON report with machine identifiers removed.
