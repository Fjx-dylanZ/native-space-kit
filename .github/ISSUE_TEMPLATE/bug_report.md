---
name: Bug report
about: An operation misbehaved, was refused, or reported "unsupported"
title: ''
labels: ''
assignees: ''
---

## Environment

Output of these read-only commands (use `build/nsk` if you built from source):

```sh
sw_vers
nsk --version
nsk capabilities
```

- Displays (how many; "Displays have separate Spaces" on or off):
- Fullscreen or tile Spaces present:
- Apps assigned to Desktops (Dock > Options > Assign To):
- Session (unlocked and logged in, locked, fast user switching):
- Other window managers or Space tools running (yabai, Amethyst, etc.):

## What you ran

The exact command or C API calls.

## Expected

## Actual

The JSON `nsk` printed, including `error.request_may_have_applied` and
`observed_spaces` if present. Space and window IDs are fine to include.

## Reproduction

If `python3 probes/smoke.py` (read-only) or `probes/smoke.py --mutate` (only in
a VM or a session you don't mind rearranging) reproduces it, attach the JSON
report with machine identifiers removed.
