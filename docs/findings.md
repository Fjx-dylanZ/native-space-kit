# Findings

How native-space-kit drives Spaces, and what was verified.

- **Tested on:** macOS 27 RC (26A428), arm64, SIP enabled, one display,
  ordinary Desktops, unlocked GUI session. §9 adds a virtual second display.
- **Method:** private SkyLight "WMBridge" operations dispatched from a plain
  AppKit process. Results were checked against the managed-Space census
  (`SLSCopyManagedDisplaySpaces`), the per-Space window census
  (`SLSCopyWindowsWithOptionsAndTags`), window membership
  (`SLSCopySpacesForWindows`), on-screen window order, screen recordings, and
  Mission Control.
- **Reproduce:** see [Reproducing](#12-reproducing).

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
| Create unmanaged Space | `SLSBridgedSpaceCreateOperation` | same, with options `1` | sync | type 3, absent from the census (§7) |
| Destroy Desktop | `SLSBridgedSpaceDestroyOperation` | `initWithSpaceID:` (`Q`) | async | ID leaves the census |
| Show Spaces | `SLSBridgedShowSpacesOperation` | `initWithSpaces:` (`@` = `NSArray<NSNumber uint64>`) | async | part of activation (§4) |
| Hide Spaces | `SLSBridgedHideSpacesOperation` | `initWithSpaces:` (`@`) | async | part of activation |
| Set current Space | `SLSBridgedManagedDisplaySetCurrentSpaceOperation` | `initWithDisplayIdentifier:spaceID:` (`@` display identifier, `Q`) | async | census `Current Space` |
| Move windows | `SLSBridgedMoveWindowsToManagedSpaceOperation` | `initWithWindows:spaceID:` (`@` = `NSArray<NSNumber uint32>`, `Q`) | async | `SLSCopySpacesForWindows(cid, 7, [wid])` and per-Space census |
| Reorder Desktop | `SLSBridgedMoveManagedSpaceToDisplayIndexOperation` | `initWithSpaceID:displayIdentifier:index:` (`Q`, `@`, `I`) | async | exact ID order in the census |
| Add windows to Spaces (Not applied, foreign window) | `SLSBridgedAddWindowsToSpacesOperation` | `initWithWindows:spaces:` (`@`, `@`) | async | §7 |
| Remove windows from Spaces (Not applied, foreign window) | `SLSBridgedRemoveWindowsFromSpacesOperation` | `initWithWindows:spaces:` (`@`, `@`) | async | §7 |
| Add a window to a Space | `SLSBridgedSpaceAddWindowsAndRemoveFromSpacesOperation` | `initWithSpaceID:windows:options:` (`Q`, `@` = `NSArray<NSNumber uint32>`, `I`) | async | membership and per-Space census (§7) |
| Assign an app to all Spaces | `SLSBridgedProcessAssignToAllSpacesOperation` | `initWithProcess:` (`i` pid) | async | membership of every window of the process (§7) |
| Assign an app to a Space | `SLSBridgedProcessAssignToSpaceOperation` | `initWithProcess:spaceID:` (`i`, `Q`; `0` clears) | async | membership of every window of the process (§7) |
| Set Space level | `SLSBridgedSpaceSetAbsoluteLevelOperation` | `initWithSpaceID:level:` (`Q`, `i`) | async | `SLSBridgedSpaceGetAbsoluteLevelOperation`, on-screen order (§7) |
| Read Space values | `SLSBridgedSpaceCopyValuesOperation` | `initWithSpaceID:` (`Q`) | sync; result responds to `propertyListDictionary` | `nil` once the Space is destroyed |

Other operations exercised once are described in §8 and §9. Available but never
exercised (names after `SLSBridged`, without `Operation`):
`CopyAssociatedWindows`, `CopyBestManagedDisplayForPoint`,
`CopyBestManagedDisplayForRect`, `CopyManagedDisplayForSpace`,
`CopyManagedDisplayForWindow`, `CopyManagedDisplays`, `CopyManagedDisplaySpaces`,
`CopySpacesForWindows`, `CopyWindowsWithOptionsAndTags`,
`CopyWindowsWithOptionsAndTagsAndSpaceOptions`, `GetSpaceNeedsSafeAperture`,
`GetSpacePermittedResizeDirections`, `GetTileSpaceDividerDirections`,
`ManagedDisplayCurrentSpaceAllowsWindow`, `ManagedDisplayGetCurrentSpace`,
`ManagedDisplayIsAnimating`, `ManagedDisplaySetIsAnimating`,
`ManagedDisplaySetRoleWindow`, `ManagedDisplaysCopyRoleWindows`, `ResetWindows`,
`SetSpaceManagementMode`, `SpaceCanCreateTile`,
`SpaceClientDrivenMoveSpacersToPoint` (and `…Fenced`), `SpaceCopyManagedShape`,
`SpaceCopyShape`, `SpaceCopyTileSpaces`, `SpaceCreateTile`,
`SpaceFinishedResizeForRect`, `SpaceGetAlpha`, `SpaceGetInterTileSpacing`,
`SpaceGetRect`, `SpaceGetSizeForProposedTile`, `SpaceGetSpacersAtPoint`,
`SpaceGetTransform`, `SpacePreferCurrentDisplay`, `SpaceRemoveValuesForKeys`,
`SpaceResetMenuBar`, `SpaceSetAlpha`, `SpaceSetInterTileSpacing`,
`SpaceSetOrderingWeight`, `SpaceSetOwners`, `SpaceSetShape`, `SpaceSetTransform`,
`SpaceSetValues`, `SpaceTileMoveToSpaceAtIndex`,
`TileSpaceMoveSpacersForSize` (and `…Fenced`), `TileSpaceReplaceWithSnapshotWindow`,
`TileSpaceSetDividerWindow`, `TileSpaceTakeOwnership`, `WillSwitchSpaces`, and
`WindowGetTileRect`; also the C symbols `SLSSpaceCreate` and `SLSSpaceDestroy`.
`dlsym` did not resolve `SLSManagedDisplayAddSpace`,
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

`SLSBridgedMoveWindowsToManagedSpaceOperation` with an ordinary window and an
ordinary destination Desktop sets the window's membership to exactly that
Desktop, including a window that was on several Desktops (§7). The destination
is not activated and the window's frame is unchanged. Membership is read with
`SLSCopySpacesForWindows(cid, 7, [wid])` and cross-checked with the per-Space
census. For a sticky window (tag `0x800`) the move is not applied: it stays on
every Desktop. The kit therefore reads the tag through `SLSWindowQueryWindows`
and refuses sticky windows, as well as windows on fullscreen or system Spaces.

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

## 7. Sticky windows

Goal: make a window appear on every Desktop from **outside** its owning
process, as a window manager would need. The fixture is two ordinary windows,
`T` and `C`, from one process on `H`. Visibility is judged by the CG on-screen
flag together with the `0x2` census, stable across several samples; a window
in an overlay Space belongs to no Desktop, so only the on-screen flag counts.

| Attempt | Observed on | Membership | Tag `0x800` | Visibility | Result |
|---|---|---|---|---|---|
| Foreign `SLSBridgedAddWindowsToSpacesOperation` (`T` → `E`) | `E`, then a later `N`, then `H` | stayed `[H]` | unchanged | hidden on `E` and `N`, visible on `H` | **Not applied** |
| Foreign `SLSBridgedRemoveWindowsFromSpacesOperation` (`T` from `E` and `H`) | `E`, `H` | stayed `[H]` | unchanged | unchanged | **Not applied** |
| Foreign `SLSSetWindowTags(cid, T, &0x800, 64)` from a helper connection | `E`, a new `N`, `H` | stayed `[H]` | returned `CGError 0`, **bit unchanged** | unchanged | **Not applied** |
| Foreign `SLSBridgedSpaceAddWindowsAndRemoveFromSpacesOperation` (`T` → `E`, options `0`) | `E`, `H`, then a later `N` | `[E, H]`; `N` not joined | unchanged | visible on `E` and `H`, hidden on `N`; `C` stayed on `H` | **Applied** per window, existing Desktops only |
| Foreign `SLSBridgedProcessAssignToAllSpacesOperation` (fixture pid) | `E`, then a later `N` | `T` and `C` on every Desktop, including `N` | set on both | both visible everywhere | **Applied** to the whole process |
| Foreign: `T` moved into an unmanaged Space at level 20 | `H`, `E`, a later `N` | none (outside the Desktop census) | unchanged | visible everywhere; stayed in front of `C` after `C`'s owner raised it | **Applied** per window, new Desktops included |
| Owner sets `NSWindow.collectionBehavior \|= canJoinAllSpaces` (control) | `E` and a new `N` | every Desktop on the display, including `N` created afterwards | set (`…2001` → `…2801`) | visible on `E` and `N`; sibling `C` stayed on `H`, hidden | **Applied** |
| Owner clears `canJoinAllSpaces` while on `N` | `N`, then `E`, then `H` | pinned to the **current** Desktop `N`, not `H` | cleared | no longer follows to `E`; an explicit move restored `[H]` | Applied |

**Per-window join.** Options `0` adds the window to the Space and keeps its
other memberships. Values with both bits `0x1` and `0x4` set (`5`, `7`, `0xF`,
`0xFFFFFFFF`) also remove it from every other Space, which is a move; `1`, `2`,
`3`, `4`, `6`, and `8`–`256` behaved like `0`. Repeated calls add more Desktops.
The window does not follow Desktops created later and its sticky bit stays
clear. Membership held when the owning app (TextEdit) was activated.
`SLSBridgedMoveWindowsToManagedSpaceOperation`, or options `7`, returns it to
a single Desktop.

**App-wide assignment.** Every window of the process, including windows it
opens later, joins every Desktop, including new ones, and gets tag `0x800`,
like the Dock's *Assign To: All Desktops*.
`SLSBridgedProcessAssignToSpaceOperation` with a Space ID moves every window of
the process there, and new windows open there. With `0` it clears the
assignment: windows stay where they are, and sticky windows end up on the
current Desktop. Clearing does not change windows that are sticky through the
owner's `canJoinAllSpaces`. Assignments belong to the running process: nothing
was written to `com.apple.spaces` or `com.apple.dock`, and a relaunched TextEdit
started unassigned.

**Overlay Space.** `SLSBridgedSpaceCreateOperation` with options `1` creates a
Space of type 3 that is not in the managed census (options `2` created another
Desktop). After `SLSBridgedSpaceSetAbsoluteLevelOperation` and
`SLSBridgedShowSpacesOperation`, a window moved in with options `7` is visible
on every Desktop, including new ones; activation only hides managed Spaces. At
level 20 it stayed in front of other apps' windows when they were raised; at
level 0 it was still on every Desktop but stacked normally. The Space outlived
the process that created it and a Dock restart, so it must be destroyed
explicitly: move the window out with options `7`, then
`SLSBridgedHideSpacesOperation` and `SLSBridgedSpaceDestroyOperation`; its
values read back as `nil` afterwards. Raising a managed Desktop's level and
showing it next to the current one also drew its windows on top, but the next
switch hid it again.

- The owner-side control shows the method works: the tag bit, membership, and
  visibility all change, and new Desktops are followed. Sibling `C` shows the
  effect is per window, not per process. Unsticking pins the window to the
  current Desktop, so the control was not a hidden move.
- Another process can make a window sticky without injection: join it to each
  Desktop, or move it into an overlay Space (also follows new Desktops,
  optionally on top). App-wide assignment covers whole apps.
- `SLSBridgedAddWindowsToSpacesOperation`, `…RemoveWindowsFromSpaces…`, and a
  foreign tag write are still not honored.
- The kit exposes join as `add-window` (`nsk_add_window_to_space`) and app-wide
  assignment as `assign` (`nsk_assign_process_to_*`,
  `nsk_clear_process_assignment`); `probes/smoke.py` covers both. Overlay Spaces
  are probe-only. `probes/sticky.py` reruns every row.
- Untested for overlay windows: mouse and keyboard input, Dock-driven switches
  (gestures, Control-arrow), Mission Control, and multiple displays.

The observer finds windows by number in
`CGWindowListCopyWindowInfo(kCGWindowListOptionAll, …)`. On-screen state and
per-Space membership are separate: a window that is up on an inactive Space is
not necessarily visible on screen.

## 8. Other operations

Exercised once with a throwaway dispatcher; not covered by the probes.

- **Space names are UUIDs.** `SLSBridgedSpaceSetNameOperation` replaced the
  Space's `uuid` in the census and in `com.apple.spaces`.
  `SLSBridgedSpaceCopyNameOperation` returns the UUID, and
  `SLSBridgedSpaceWithNameOperation` maps a UUID to its Space ID (`0` if none).
  It is not a display label. The Dock's saved Space assignments in
  `com.apple.spaces` are keyed by this UUID, so don't write it.
- **Owners.** `SLSBridgedSpaceAddOwnerOperation` (Space ID, pid) showed up in
  `SLSBridgedSpaceCopyOwnersOperation`, but no window's membership or
  visibility changed. `SLSBridgedSpaceRemoveOwnerOperation` removed it.
- **Front process.** After `SLSBridgedSpaceSetFrontPSNOperation`, activating
  that Space with the kit did not change the frontmost app (`lsappinfo front`).
- **Edge reservation.** `SLSBridgedSpaceSetEdgeReservationOperation` on the
  current Desktop did not change `NSScreen.visibleFrame` for any edge mask.
- **Read-only queries.** `SLSBridgedGetSpaceManagementModeOperation` returned 1
  with "Displays have separate Spaces" on; `SLSBridgedSpaceGetTypeOperation`,
  `SLSBridgedSpaceGetAbsoluteLevelOperation` (0 for Desktops), and
  `SLSBridgedCopySpacesOperation` (options 7: managed Space IDs only) returned
  plausible values. The management-mode setter was not called.

## 9. Multiple displays

Exercised once with a 1280×800 `CGVirtualDisplay` created in the guest, with
"Displays have separate Spaces" on; not covered by the probes.

- `list` and `list --display` reported the second display and its Desktop.
- `move-window` to a Desktop on the other display applied. macOS shifted the
  frame so the window's center was on the destination display.
- Activation is per display: activating a Desktop on the second display left
  the first display's current Space unchanged.
- `SLSBridgedMoveManagedSpaceToDisplayIndexOperation` with the other display's
  identifier moved a Desktop to that display. The kit's `move` still refuses
  cross-display targets.
- A window can be joined to Spaces on both displays; its frame did not move.
- Removing the virtual display removed its Desktop from the census.

## 10. Limits

- Confirmation polls the main run loop in 50 ms slices for up to 2 s. This is a
  deadline for confirmation, not a timeout on every system call. The probes
  record actual operation and settle times.
- Test windows were ordinary 480×332 titled windows at level 0. Their frames
  did not change during migration, moves, or activation on one display.
- Census options: `0x2` is windows the compositor considers up on the Space;
  `0x7` also includes parked and minimized windows.

## 11. Untested

- macOS releases other than 27 RC (26A428). Reports about SkyLight/CGS Space
  APIs on other releases do not carry over, in either direction.
- Physical displays, "Displays have separate Spaces" turned off, mirrored
  displays, and display hot-plug during an operation.
- Fullscreen and tile Spaces: creating, activating, destroying, or reordering
  around them.
- Destroying the active Desktop with the raw operation; swapping the active
  Desktop with fullscreen Spaces or multiple displays present.
- Stage Manager, Universal Control, and locked or fast-user-switched sessions.
  The probes refuse to run in locked or non-console sessions.
- Keyboard focus transfer on activation, and behavior without the Dock running.
- Foreign sticky from entitled or system processes.

## 12. Reproducing

```sh
make
make probes                        # build/window-fixture and build/sticky-probe
python3 probes/smoke.py            # read-only: capabilities, census, ID validation
python3 probes/smoke.py --mutate   # lifecycle, migration, activation, moves, add-window, assign, reorder, guards
python3 probes/sticky.py --mutate  # the §7 experiment
```

The runners use only the Python 3.9 standard library. They print a JSON report
(`--report PATH` also saves it) and exit 0 on pass, 1 on failure, 2 on a missing
prerequisite, and 3 on incomplete cleanup. They only create and destroy their
own Spaces and move their own windows. Afterwards they restore each display's
current Space, compare the census with the baseline, and report every cleanup
step. Reports contain native IDs and PIDs; don't commit them.

## 13. Sources

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
