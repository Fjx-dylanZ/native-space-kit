# native-space-kit

Native macOS Space control with SIP enabled: an Objective-C implementation, a public C API, and a JSON command-line tool.

The core uses private SkyLight WindowManager bridge operations. It does not inject into Dock, synthesize swipe gestures, disable SIP, or run a window manager. Availability and behavior may change with macOS updates.

## Verified scope

The source experiments were run on **macOS 27 Golden Gate RC, build `26A428`, Apple Silicon, with SIP enabled**, using ordinary Desktops on one display. These observations are not a compatibility guarantee for every macOS release.

| Operation | Verified behavior |
| --- | --- |
| Enumerate Spaces | Native IDs, display identity, order, type, and current Space |
| Create a Desktop | A real managed type-0 Desktop appears in the census |
| Activate a Space | Correct window visibility without a sliding transition |
| Destroy an inactive Desktop | Empty removal; opt-in migration of application windows to the active Desktop |
| Move a window | Ordinary, single-Space windows move between Desktops |
| Reorder / swap | Space identity and window membership are preserved |
| Make another app's window sticky | **Not implemented:** the tested foreign-window primitives did not apply |

See [the findings record](docs/findings.md) for exact mechanisms, controls, negative results, and untested cases.

## Build

Requires macOS and Xcode Command Line Tools or Xcode. No package-manager dependencies are required for the library or CLI.

```sh
make
make check       # read-only contract and CLI checks; no Desktop mutations
make example     # builds a pure-C API consumer
```

Outputs:

- `build/libnative-space-kit.a`
- `build/nsk`
- `build/list-spaces` from `make example`

The public header is [`include/native_space_kit.h`](include/native_space_kit.h). A deployment target is not a claim that a particular older OS supplies the private operations; runtime checks return an unsupported result when required entry points or ABIs are absent.

## JSON CLI

Start with read-only queries:

```sh
build/nsk capabilities
build/nsk list
build/nsk window-spaces WINDOW_ID
```

The following commands mutate the logged-in GUI session:

```sh
build/nsk create
build/nsk activate SPACE_ID
build/nsk move-window WINDOW_ID SPACE_ID
build/nsk move SOURCE_ID TARGET_ID
build/nsk swap ID_A ID_B
build/nsk destroy SPACE_ID
build/nsk destroy SPACE_ID --migrate
```

Replace the uppercase arguments with IDs returned by queries. **A native Space ID is not a Desktop number.** `index` is the current one-based global position; `display_index` is one-based within the owning display. Neither is a persistent identity.

### Selecting a Space on multiple displays

First run `build/nsk list` to find the opaque `display` string for the intended
screen. Use that exact string, quoted, to narrow a fresh census:

```sh
build/nsk list --display DISPLAY
build/nsk list --display DISPLAY --display-index 2
```

`--display-index` requires `--display`; a bare "Desktop 2" is ambiguous across
screens. It selects the second **Space record** on that display, which may not
be an ordinary Desktop if fullscreen Spaces are present. Check `type == 0`
before choosing a Desktop for a window move. Filters preserve the original
`index` and `display_index` values and the `{"spaces":[...]}` response shape.
An absent display or index returns `not_found` with exit 1, never a fallback to
another screen. Existing unfiltered `list` output is unchanged.

Use the selected record's native `id` in mutation commands. These read-only
selectors do not bind a later write to a topology snapshot: after unplugging a
display, reordering Spaces, or changing sessions, query again and check the
destination. Neither indices nor IDs are persistent configuration identities.

Multi-display enumeration is not a guarantee of cross-display movement:
`move-window` confirms sole Space membership, does not explicitly reposition
the frame (macOS may adjust it), and does not confirm which physical screen displays the window or
that every display's active Space stayed unchanged. Check membership, frame,
visibility, and each display's active Space separately when testing this case.
Mirroring, "Displays have separate Spaces" disabled, and hot-plug during a write
remain outside the verified scope. Reorder/swap remain same-display operations.

### Mutation behavior

- `activate` makes the target current on its display. It does not promise keyboard-focus transfer between displays.
- `move` puts the source at the target's **original position**; intervening Desktops shift.
- `swap` exchanges positions. A nonadjacent swap uses two confirmed moves and is **not atomic**.
- `destroy` refuses an active Space, the last Desktop on a display, non-Desktop targets, and normal/floating/modal application windows by default.
- `destroy --migrate` permits macOS's native window migration. It does not close application windows or implement a manual move loop. Active-Space destruction is still refused.
- Reorder/swap are currently restricted to same-display, ordinary-Desktop-only layouts. Fullscreen/sticky-window moves are outside the verified window-move contract.

Success produces one JSON object on stdout and exit status 0. Errors produce JSON on stderr and a nonzero exit status. Human-readable help is available through `build/nsk --help`.

### Requested is not applied

A private call can return successfully while doing nothing. The core confirms the corresponding modeled postcondition instead of treating dispatch as success. The live probes additionally check compositor-visible windows.

Inspect `error.request_may_have_applied` after a failure. If true, a native write was submitted: a timeout or later failure does **not** mean that nothing changed. Query the state before retrying. The CLI includes a fresh `observed_spaces` snapshot when it can obtain one. In particular, the first half of a two-operation swap may have applied; the library does not attempt a blind rollback.

`capabilities` reports **runtime entry-point/ABI availability**, not an empirical guarantee that an OS will authorize every write. Only a successful operation and its relevant observations establish applied behavior.

## C API

The header is valid C and C++. CoreFoundation is part of the public ownership contract; no Swift runtime or Objective-C syntax is required in the caller.

```c
#include <native_space_kit.h>
#include <stdio.h>

int main(void) {
    nsk_error error;
    nsk_status status = nsk_initialize(&error);
    if (status != NSK_OK) {
        fprintf(stderr, "%s: %s\n", nsk_status_name(status), error.message);
        return 1;
    }

    CFArrayRef spaces = NULL;
    status = nsk_copy_spaces(&spaces, &error);
    if (status != NSK_OK) {
        fprintf(stderr, "%s: %s\n", nsk_status_name(status), error.message);
        return 1;
    }
    CFShow(spaces);
    CFRelease(spaces);
    return 0;
}
```

### Embedding rules

- Initialize explicitly and call the API on the **process main thread**. The library does not replace the host application's delegate, menus, or activation policy.
- Keep the process's main thread alive with the application's AppKit/CF run loop. Being submitted to the main dispatch queue is not sufficient if a bare `dispatch_main()` harness has relinquished the original main thread; such calls are refused as `wrong_thread`.
- Mutations require an unlocked, logged-in GUI session. A locked session can yield restricted Accessibility data or black captures; do not interpret those as valid feature-regression observations.
- Synchronous confirmation is bounded to two seconds and services the main run loop. Account for possible **run-loop reentrancy** when embedding in an application.
- Successful CF outputs belong to the caller and must be released with `CFRelease`. Outputs are cleared on failure, except a newly returned native Space ID is retained if subsequent creation confirmation fails, so the caller can inspect it.
- Errors are caller-owned values; an error pointer may be `NULL`. The core does not print, install event taps, or alter security settings.
- The core does not request Accessibility or Screen Recording permission. An embedding app or a pixel-capture tool may have separate permission requirements.

## Opt-in live probes

Run these only in a disposable VM or a GUI session you are prepared to manipulate. They create disposable windows/Spaces, switch desktops, and restore their owned state. They do not intentionally move or delete your existing windows or desktops.

```sh
make probes
python3 probes/smoke.py            # read-only by default
python3 probes/smoke.py --mutate   # verified core-operation scenarios
python3 probes/sticky.py --mutate  # experimental sticky candidates + owner-side control
```

Keep the guest unlocked while testing. These are native GUI experiments, not ordinary headless CI tests. They restore the original Space order/current Space and clean up their own fixtures; application keyboard-focus restoration is not guaranteed. Any incomplete cleanup is reported rather than hidden.

The sticky probe distinguishes actual per-window behavior from app-wide assignment, temporary transition overlap, and a controller repeatedly moving a window. A negative result is useful evidence, not a production `sticky` implementation. No raw user-session logs, window titles, machine identifiers, or recordings are committed to this repository.

## Deliberate exclusions

- Dock injection, scripting additions, SIP changes, and synthetic gestures.
- Tiling policy, hotkeys, focus-following policy, or a background window manager.
- A fake sticky implementation that carries a window between single memberships.
- Unverified fullscreen, mixed-layout, multi-display, or OS-version guarantees.

## Provenance and license

The experiments build on private-API work documented by [yabai](https://github.com/asmvik/yabai) and [KiwiDesk's WMBridge investigation](https://github.com/KiwiCanopy/KiwiDesk/pull/990). Older third-party observations are treated as leads, not proof of behavior on the verified build; the findings record distinguishes them.

MIT licensed. See [LICENSE](LICENSE).
