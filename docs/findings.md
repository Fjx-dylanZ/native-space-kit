# Findings

How native-space-kit drives Spaces, and what was verified.

- **Tested on:** macOS 27 RC (26A428), arm64, SIP enabled, one display,
  ordinary Desktops, unlocked GUI session.
- **Method:** private SkyLight "WMBridge" operations dispatched from a plain
  AppKit process. Results were checked against the managed-Space census
  (`SLSCopyManagedDisplaySpaces`), the per-Space window census
  (`SLSCopyWindowsWithOptionsAndTags`), window membership
  (`SLSCopySpacesForWindows`), screen recordings, and Mission Control.
- **Reproduce:** see [Reproducing](#10-reproducing).

Status labels:

- **Verified**: exercised and confirmed by observed state, not by a successful call.
- **Available**: present in runtime introspection, never exercised.
- **Untested**: not exercised, or only in a different configuration.
- **Not applied**: the call was accepted but no state change was observed.

Labels in examples: `H` home Desktop, `E` another existing Desktop, `N` a
Desktop created during the test, `T` target window, `C` control window from the
same process.

## 1. Initialization and dispatch

- AppKit must be initialized first: `NSApplicationLoad()`, then
  `[NSApplication sharedApplication]`. SkyLight is loaded with `dlopen`; the
  census uses `SLSMainConnectionID` and `SLSCopyManagedDisplaySpaces`.
- Operations are `SLSBridged…Operation` objects dispatched with
  `performWithWMBridgeDelegate` (no colon).
- Synchronous operations (subclasses of
  `SLSSynchronousBridgedWindowManagementOperation`, e.g. create) are called as
  `id (*)(id, SEL)` and return a result object. Asynchronous ones (subclasses
  of `SLSAsynchronousBridgedWindowManagementOperation`, everything else here)
  are called as `void (*)(id, SEL)`.
- Before any call the kit checks that the class and selector exist and that
  the type encodings match the table below. Anything else is refused.

**Asynchronous operations can return before they apply.** An active-Space query
made right after dispatch still showed the old state. The kit runs the main run
loop and polls for the expected state for up to 2 s. Checking once and falling
back to a gesture can collide with a request that is still pending. Completion
time may differ between operations.

## 2. Operations

| Operation | Class | Initializer (type encodings) | Perform | Confirmed by |
|---|---|---|---|---|
| Create Desktop | `SLSBridgedSpaceCreateOperation` | `initWithOptions:values:` (`I`, `@`) with `0` and an empty dictionary | sync; result responds to `spaceID` (`Q`) | new `type 0` ID in the census |
| Destroy Desktop | `SLSBridgedSpaceDestroyOperation` | `initWithSpaceID:` (`Q`) | async | ID leaves the census |
| Show Spaces | `SLSBridgedShowSpacesOperation` | `initWithSpaces:` (`@` = `NSArray<NSNumber uint64>`) | async | part of activation (§4) |
| Hide Spaces | `SLSBridgedHideSpacesOperation` | `initWithSpaces:` (`@`) | async | part of activation |
| Set current Space | `SLSBridgedManagedDisplaySetCurrentSpaceOperation` | `initWithDisplayIdentifier:spaceID:` (`@` display identifier, `Q`) | async | census `Current Space` |
| Move windows | `SLSBridgedMoveWindowsToManagedSpaceOperation` | `initWithWindows:spaceID:` (`@` = `NSArray<NSNumber uint32>`, `Q`) | async | `SLSCopySpacesForWindows(cid, 7, [wid])` and per-Space census |
| Reorder Desktop | `SLSBridgedMoveManagedSpaceToDisplayIndexOperation` | `initWithSpaceID:displayIdentifier:index:` (`Q`, `@`, `I`) | async | exact ID order in the census |
| Add windows to Spaces (Not applied, foreign window) | `SLSBridgedAddWindowsToSpacesOperation` | `initWithWindows:spaces:` (`@`, `@`) | async | §7 |
| Remove windows from Spaces (Not applied, foreign window) | `SLSBridgedRemoveWindowsFromSpacesOperation` | `initWithWindows:spaces:` (`@`, `@`) | async | §7 |

Available but never exercised: `SLSBridgedProcessAssignToAllSpacesOperation`
(`initWithProcess:`), `SLSBridgedProcessAssignToSpaceOperation`
(`initWithProcess:spaceID:`), `SLSBridgedSpaceSetNameOperation`,
`SLSBridgedSpaceSetOrderingWeightOperation`,
`SLSBridgedSpacePreferCurrentDisplayOperation`,
`SLSBridgedSpaceCreateTileOperation`, `SLSBridgedSpaceSetFrontPSNOperation`,
the tile/spacer operations, and the C symbols `SLSSpaceCreate` and
`SLSSpaceDestroy`. `dlsym` did not resolve `SLSManagedDisplayAddSpace`,
`SLSManagedDisplayRemoveSpace`, or
`SLSPerformAsynchronousBridgedWindowManagementOperation` by name.

## 3. Create and destroy

- **Create (Verified).** Creates an ordinary Desktop (`type 0`) on the bridge's
  default display, appended after the existing Desktops in every trial. No
  placement or name options are passed. The returned ID is the one that
  appears in the census.
- **Destroy an empty inactive Desktop (Verified).** The ID disappears, the other
  IDs keep their order, and the current Space is unchanged.
- **Destroy a populated inactive Desktop (Verified).** With six Desktops and the
  third current, destroying the fifth (two ordinary windows) moved both windows
  to the **active** Desktop, not the first or an adjacent one. Window IDs and
  frames were unchanged. Closing the same kind of Desktop in Mission Control
  gave the same result.
- **Kit guards.** The kit refuses the active Space, a display's last Desktop,
  non-Desktop Spaces, and Desktops holding windows at level 0, 3, or 8 (normal,
  floating, modal). Unknown window metadata counts as non-empty.
  `NSK_DESTROY_MIGRATE_WINDOWS` lifts only the non-empty guard and checks
  afterwards that the sampled windows still exist. It does not move windows
  itself.
- **Untested:** destroying the active Desktop, fullscreen or tile Spaces,
  Desktops holding minimized, sticky, or fullscreen windows, and multiple
  displays.

## 4. Activation (Verified)

Setting the current Space alone updates the census, but the previous Desktop's
windows stay on screen. Activation takes three operations on the target's
display:

1. `SLSBridgedShowSpacesOperation initWithSpaces:@[target]`
2. `SLSBridgedHideSpacesOperation initWithSpaces:<every other Space on the display>`
3. `SLSBridgedManagedDisplaySetCurrentSpaceOperation initWithDisplayIdentifier:spaceID:`

With the yabai daemon stopped, four consecutive activations (Desktops holding 4,
1, 0, and 4 windows) each showed exactly the expected on-screen windows
(`CGWindowListCopyWindowInfo`, on-screen only, application window levels), and
a screen recording showed no slide animation. The probe also checks the
per-Space `0x2` census.

Activation is per display, does not move keyboard focus between displays
(untested), and must be confirmed by polling (§1).

## 5. Window moves (Verified)

`SLSBridgedMoveWindowsToManagedSpaceOperation` with an ordinary single-Space
window and an ordinary destination Desktop sets the window's membership to
exactly that Desktop. The destination is not activated and the window's frame
is unchanged. Membership is read with `SLSCopySpacesForWindows(cid, 7, [wid])`
and cross-checked with the per-Space census. The kit refuses fullscreen,
sticky, and multi-Space windows when it can identify them.

## 6. Reordering (Verified)

- The `index` argument of `SLSBridgedMoveManagedSpaceToDisplayIndexOperation`
  is the **zero-based final position within the display**. On a seven-Desktop
  display, index 6 put the Space last, 5 sixth, and 3 fourth.
- `move SOURCE TARGET` therefore places SOURCE at TARGET's **original**
  position and shifts the Desktops in between. On seven Desktops (three
  existing, four created): swapping the fourth and seventh produced the exact
  exchanged order; moving the fourth to the sixth position produced
  `[…, fifth, sixth, fourth, seventh]`; moving it back restored the order; an
  adjacent swap applied and reverted cleanly.
- Swapping the active Desktop works (one trial): with the fourth Desktop
  current, swapping it with the seventh kept it current. `probes/smoke.py`
  repeats this with its own Desktops.
- UUIDs, window membership, the current Space, and Mission Control's thumbnail
  order matched the census after every reorder.
- `swap` orders its arguments by position, moves the earlier Space to the later
  position, and, unless they were adjacent, moves the other Space to the
  earlier position. Each step is confirmed. A non-adjacent swap is **not
  atomic**: if the second move fails, the first stays applied and the kit
  reports the observed state instead of rolling back.
- Only same-display, Desktop-only layouts were tested. The kit refuses layouts
  with fullscreen or tile Spaces and moves across displays.

## 7. Sticky windows (Not applied)

Goal: make a window appear on every Desktop from **outside** its owning
process, as a window manager would need. The fixture is two ordinary windows,
`T` and `C`, from one process on `H`. Visibility is judged by the CG on-screen
flag together with the `0x2` census, stable across several samples.

| Attempt | Observed on | Membership | Tag `0x800` | Visibility | Result |
|---|---|---|---|---|---|
| Foreign `SLSBridgedAddWindowsToSpacesOperation` (`T` → `E`) | `E`, then a later `N`, then `H` | stayed `[H]` | unchanged | hidden on `E` and `N`, visible on `H` | **Not applied** |
| Foreign `SLSBridgedRemoveWindowsFromSpacesOperation` (`T` from `E` and `H`) | `E`, `H` | stayed `[H]` | unchanged | unchanged | **Not applied** |
| Foreign `SLSSetWindowTags(cid, T, &0x800, 64)` from a helper connection | `E`, a new `N`, `H` | stayed `[H]` | returned `CGError 0`, **bit unchanged** | unchanged | **Not applied** |
| Owner sets `NSWindow.collectionBehavior \|= canJoinAllSpaces` (control) | `E` and a new `N` | every Desktop on the display, including `N` created afterwards | set (`…2001` → `…2801`) | visible on `E` and `N`; sibling `C` stayed on `H`, hidden | **Applied** |
| Owner clears `canJoinAllSpaces` while on `N` | `N`, then `E`, then `H` | pinned to the **current** Desktop `N`, not `H` | cleared | no longer follows to `E`; an explicit move restored `[H]` | Applied |

- The owner-side control shows the method works: the tag bit, membership, and
  visibility all change, and new Desktops are followed. Sibling `C` shows the
  effect is per window, not per process.
- None of the foreign attempts had that effect. Unsticking pins the window to
  the current Desktop, so the control was not a hidden move or an app-wide
  assignment.
- The API therefore has **no sticky operation**. `probes/sticky.py` reruns the
  experiment; a positive result on a newer build would be new information.
- This does not show that the tag or add operations are inert in general, only
  that foreign calls were not honored for another process's window on this
  build. Entitled or system processes were not tested.

The observer finds windows by number in
`CGWindowListCopyWindowInfo(kCGWindowListOptionAll, …)`. On-screen state and
per-Space membership are separate: a window that is up on an inactive Space is
not necessarily visible on screen.

## 8. Limits

- Confirmation polls the main run loop in 50 ms slices for up to 2 s. This is a
  deadline for confirmation, not a timeout on every system call. The probes
  record actual operation and settle times.
- Test windows were ordinary 480×332 titled windows at level 0. Their frames
  did not change during migration, moves, or activation.
- Census options: `0x2` is windows the compositor considers up on the Space;
  `0x7` also includes parked and minimized windows.

## 9. Untested

- macOS releases other than 27 RC (26A428). Reports about SkyLight/CGS Space
  APIs on other releases do not carry over, in either direction.
- Multiple displays, "Displays have separate Spaces" turned off, mirrored
  displays, and display hot-plug during an operation.
- Fullscreen and tile Spaces: creating, activating, destroying, or reordering
  around them.
- Destroying the active Desktop with the raw operation; swapping the active
  Desktop with fullscreen Spaces or multiple displays present.
- Stage Manager, Universal Control, and locked or fast-user-switched sessions.
  The probes refuse to run in locked or non-console sessions.
- Keyboard focus transfer on activation, and behavior without the Dock running.
- Foreign sticky from entitled or system processes, and
  `SLSBridgedProcessAssignToAllSpacesOperation`.

## 10. Reproducing

```sh
make
make probes                        # build/window-fixture and build/sticky-probe
python3 probes/smoke.py            # read-only: capabilities, census, ID validation
python3 probes/smoke.py --mutate   # lifecycle, migration, activation, moves, reorder, guards
python3 probes/sticky.py --mutate  # the §7 experiment
```

The runners use only the Python 3.9 standard library. They print a JSON report
(`--report PATH` also saves it) and exit 0 on pass, 1 on failure, 2 on a missing
prerequisite, and 3 on incomplete cleanup. They only create and destroy their
own Spaces and move their own windows. Afterwards they restore each display's
current Space, compare the census with the baseline, and report every cleanup
step. Reports contain native IDs and PIDs; don't commit them.

## 11. Sources

- The operation table (§2) comes from runtime introspection of
  `SkyLight.framework` on 26A428: class list, method type encodings, and symbol
  lookup.
- The `performWithWMBridgeDelegate` dispatch pattern came from
  [KiwiDesk pull request 990](https://github.com/KiwiCanopy/KiwiDesk/pull/990).
  It was used as a lead only; the results here come from the tests above.
- Census option bits and the level 0/3/8 window classification follow
  [yabai `src/space.c`](https://github.com/asmvik/yabai/blob/master/src/space.c).
  They are conventions, not Apple documentation.
- Public APIs used by the probes:
  [`NSWindowCollectionBehaviorCanJoinAllSpaces`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior/canjoinallspaces),
  [`CGSessionCopyCurrentDictionary`](https://developer.apple.com/documentation/coregraphics/1454780-cgsessioncopycurrentdictionary),
  [`CGWindowListCopyWindowInfo`](https://developer.apple.com/documentation/coregraphics/1455137-cgwindowlistcopywindowinfo).
