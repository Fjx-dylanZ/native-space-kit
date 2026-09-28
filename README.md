# native-space-kit

Control macOS Spaces with SIP enabled: list, create, switch, reorder, and
destroy Desktops, and move windows between them. Ships as a C library and a
JSON command-line tool, `nsk`.

It calls private SkyLight window-management operations directly. There is no
Dock injection, scripting addition, or synthetic gesture. Private APIs can
change in any macOS update.

## Compatibility

Tested on macOS 27 (build 26A428) on Apple Silicon with SIP enabled, using one
display with ordinary Desktops. Other macOS versions, multiple displays, and
fullscreen Spaces are untested.

| Operation | Command | Status |
| --- | --- | --- |
| List Spaces | `list` | Works |
| Create a Desktop | `create` | Works |
| Switch Space | `activate` | Works, without the slide animation |
| Destroy a Desktop | `destroy` | Works for inactive Desktops |
| Move a window | `move-window` | Works for ordinary single-Space windows |
| Reorder Desktops | `move`, `swap` | Works within one display |
| Make another app's window sticky | | Not supported |

[docs/findings.md](docs/findings.md) documents the private operations and how
each result was verified.

## Install

```sh
brew install Fjx-dylanZ/tap/native-space-kit
```

This builds from source and needs Xcode or the Command Line Tools. It installs
`nsk`, the header, and the static library.

To build from a checkout:

```sh
make            # build/nsk and build/libnative-space-kit.a
make check      # read-only tests
make example    # build/list-spaces, a C example
```

## Usage

```sh
nsk list                             # every Space on every display
nsk list --display DISPLAY           # Spaces on one display
nsk list --display DISPLAY --display-index 2
nsk window-spaces WINDOW_ID          # Spaces that contain a window
nsk capabilities                     # private API availability and OS build

nsk create
nsk activate SPACE_ID
nsk move-window WINDOW_ID SPACE_ID
nsk move SOURCE_ID TARGET_ID
nsk swap SPACE_A SPACE_B
nsk destroy SPACE_ID [--migrate]
```

The second group changes your desktop. Output is one JSON object on stdout
with exit status 0. Errors are JSON on stderr, with exit status 2 for invalid
arguments and 1 otherwise. See `nsk --help`.

- `SPACE_ID` is the native `id` from `list`, not a Desktop number. `WINDOW_ID`
  is a CGWindow ID. Don't store IDs or indices; they can change when displays
  or sessions change.
- `DISPLAY` is the `display` string from `list`. `--display-index N` selects
  the Nth Space on that display, which may be fullscreen; ordinary Desktops
  have `type` 0.
- `move` puts SOURCE at TARGET's position and shifts the Spaces in between.
  Swapping non-adjacent Spaces takes two moves and is not atomic. Both work
  only within one display, on layouts without fullscreen Spaces.
- `destroy` refuses the active Space, the last Desktop on a display, non-Desktop
  Spaces, and Desktops that contain windows. With `--migrate`, macOS moves those
  windows to the active Desktop.
- `activate` switches the Space on the target's display. It does not move
  keyboard focus between displays.

### Errors

The private calls can report success without doing anything, so every write is
confirmed by reading the state back for up to 2 seconds. If
`error.request_may_have_applied` is `true`, the change may still have happened:
check the error's `observed_spaces` or run `nsk list` before retrying. Nothing
is rolled back.

`capabilities` shows which private entry points exist, not whether writes will
succeed.

## C API

Include [`native_space_kit.h`](include/native_space_kit.h) and link with
`-lnative-space-kit -ObjC -lobjc -framework Cocoa`.

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

- Call `nsk_initialize` first. Call every function except `nsk_error_clear` and
  `nsk_status_name` on the main thread, with its run loop running; calls from a
  bare `dispatch_main()` process fail with `NSK_WRONG_THREAD`.
- Writes run the main run loop while waiting for confirmation, so your code may
  be re-entered.
- The caller owns returned CF objects. Any `nsk_error *` argument may be `NULL`.
- Writes need an unlocked, logged-in GUI session. The library does not request
  Accessibility or Screen Recording permission.

## Live tests

The probes change your desktop, so run them in a VM or a session you don't mind
rearranging. They only touch Spaces and windows they create, and they restore
the original Space order.

```sh
make probes
python3 probes/smoke.py             # read-only
python3 probes/smoke.py --mutate    # exercise every operation
python3 probes/sticky.py --mutate   # sticky-window experiment
```

## Non-goals

Dock injection, scripting additions, disabling SIP, synthetic gestures, and
window-manager features such as tiling, hotkeys, or focus policy.

## Acknowledgements

Builds on private-API research from [yabai](https://github.com/asmvik/yabai) and
[KiwiDesk](https://github.com/KiwiCanopy/KiwiDesk/pull/990).

## License

[MIT](LICENSE)
