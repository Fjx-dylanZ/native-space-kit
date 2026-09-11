# Native Space operations: verified findings

| | |
|---|---|
| OS | macOS 27 RC, build 26A428, arm64 |
| System Integrity Protection | enabled; native library operations use no injection or synthetic input (the separate Mission Control comparison used UI interaction) |
| Layout | one display, ordinary Desktops only, unlocked logged-in GUI session |
| Method | private SkyLight "WMBridge" operations dispatched from a plain AppKit process, confirmed against the managed-Space census (`SLSCopyManagedDisplaySpaces`), the per-Space compositor window census (`SLSCopyWindowsWithOptionsAndTags`), per-window membership (`SLSCopySpacesForWindows`), screen recordings, and Mission Control behavior |
| Reproduction | `probes/smoke.py --mutate` and `probes/sticky.py --mutate` (see "Reproducing") |

Everything below is tagged with one of four confidence levels:

- **Verified**: exercised on the build above and confirmed by observed state, not by a successful dispatch.
- **Apparently available**: class/selector/symbol present in runtime introspection on that build, never exercised. No behavioral claim.
- **Unverified**: not exercised at all, or exercised only in a different configuration. Treat as unknown.
- **Not applied**: exercised; the write was accepted but no corresponding state change was observed.

IDs in this document are labels (`H` home Desktop, `E` an existing other Desktop, `N` a Desktop created during the trial, `T` target window, `C` same-process control window). Native IDs, UUIDs, display identifiers, PIDs and paths from the trial machine are deliberately not reproduced.

## 1. Initialization and dispatch (Verified)

- AppKit must genuinely initialize before any bridged operation: `NSApplicationLoad()` followed by `[NSApplication sharedApplication]`. SkyLight is loaded with `dlopen` and the census uses `SLSMainConnectionID` / `SLSCopyManagedDisplaySpaces`.
- Operations are Objective-C objects of the form `SLSBridged…Operation`; the dispatch selector is **`performWithWMBridgeDelegate`** with **no colon**.
- Synchronous operations (`SLSSynchronousBridgedWindowManagementOperation` subclasses, e.g. create) perform as `id (*)(id, SEL)` and return a result object. Asynchronous operations (`SLSAsynchronousBridgedWindowManagementOperation` subclasses, everything else here) perform as `void (*)(id, SEL)`.
- ABI is checked at runtime from the method type encodings before any call (class exists, selector exists, argument and return encodings match the table below). Unknown or changed encodings are refused, not guessed.

### The asynchronous dispatch trap

Asynchronous dispatch **may** return before the window server applies the operation. In the guest integration, an immediate same-stack active-Space query still showed the old state. Confirmation must observe the requested postcondition rather than assume that dispatch applied it; this kit services the main run loop and polls within a 2 s bound. A caller that checks once and injects a fallback gesture can interfere with a native request that is still pending. These observations do not establish identical completion timing for every operation.

## 2. Operation table (Verified unless marked)

| Operation | Class | Initializer (type encodings) | Perform | Confirmation used |
|---|---|---|---|---|
| Create Desktop | `SLSBridgedSpaceCreateOperation` | `initWithOptions:values:` (`I`, `@`) with `0` and an empty dictionary | sync, result responds to `spaceID` (`Q`) | new `type 0` ID appears in the managed census |
| Destroy Desktop | `SLSBridgedSpaceDestroyOperation` | `initWithSpaceID:` (`Q`) | async | ID disappears from the census |
| Show Spaces | `SLSBridgedShowSpacesOperation` | `initWithSpaces:` (`@` = `NSArray<NSNumber uint64>`) | async | part of activation, see §4 |
| Hide Spaces | `SLSBridgedHideSpacesOperation` | `initWithSpaces:` (`@`) | async | part of activation |
| Set current Space | `SLSBridgedManagedDisplaySetCurrentSpaceOperation` | `initWithDisplayIdentifier:spaceID:` (`@` display identifier string, `Q`) | async | census `Current Space` |
| Move windows | `SLSBridgedMoveWindowsToManagedSpaceOperation` | `initWithWindows:spaceID:` (`@` = `NSArray<NSNumber uint32>`, `Q`) | async | `SLSCopySpacesForWindows(cid, 7, [wid])` and per-Space census |
| Reorder Desktop | `SLSBridgedMoveManagedSpaceToDisplayIndexOperation` | `initWithSpaceID:displayIdentifier:index:` (`Q`, `@`, `I`) | async | exact ID permutation in the census |
| Add windows to Spaces (Not applied, foreign) | `SLSBridgedAddWindowsToSpacesOperation` | `initWithWindows:spaces:` (`@`, `@`) | async | see §7 |
| Remove windows from Spaces (Not applied, foreign) | `SLSBridgedRemoveWindowsFromSpacesOperation` | `initWithWindows:spaces:` (`@`, `@`) | async | see §7 |

Apparently available, never exercised: `SLSBridgedProcessAssignToAllSpacesOperation` (`initWithProcess:`), `SLSBridgedProcessAssignToSpaceOperation` (`initWithProcess:spaceID:`), `SLSBridgedSpaceSetNameOperation`, `SLSBridgedSpaceSetOrderingWeightOperation`, `SLSBridgedSpacePreferCurrentDisplayOperation`, `SLSBridgedSpaceCreateTileOperation`, `SLSBridgedSpaceSetFrontPSNOperation`, the tile/spacer operations, and the C symbols `SLSSpaceCreate` / `SLSSpaceDestroy`. Literal-name `dlsym` lookups did not resolve `SLSManagedDisplayAddSpace`, `SLSManagedDisplayRemoveSpace` or `SLSPerformAsynchronousBridgedWindowManagementOperation`. That is not proof that no non-exported or mangled symbol exists; the kit uses Objective-C bridge dispatch instead.

## 3. Create and destroy

- **Create (Verified).** The new Space is an ordinary Desktop (`type 0`) on the bridge's default display and was appended after the display's existing Desktops in every trial. No placement or naming keys were passed; none were invented. The returned ID is the ID that later appears in the census.
- **Destroy, empty inactive Desktop (Verified).** The ID disappears; the remaining IDs keep their relative order and the current Space is unchanged.
- **Destroy, populated inactive Desktop (Verified: native migration semantics).** In a six-Desktop layout with the *third* Desktop current, destroying the *fifth* Desktop, which held two ordinary windows, moved both windows to the **currently active Desktop** (third): not to the first Desktop and not to an adjacent one. Window IDs and frames were identical before and after. Removing the same kind of populated Desktop with the Mission Control close button produced the same destination, IDs and frames.
- **Kit defaults.** The library refuses to destroy the active Space, a display's last Desktop, non-Desktop Spaces, and Desktops that host normal/floating/modal windows (window levels 0, 3, 8; unknown window metadata is treated as non-empty). `NSK_DESTROY_MIGRATE_WINDOWS` only lifts the non-empty guard and verifies that the sampled windows still exist afterwards; it does not move windows itself.
- **Unverified:** destroying the active Desktop; destroying fullscreen/tile Spaces; migration when the Desktop holds minimized, sticky or fullscreen windows; anything with more than one display.

## 4. Activation: the full sequence (Verified)

Setting the current Space alone (`SLSBridgedManagedDisplaySetCurrentSpaceOperation`) updates the census, yet the previous Desktop's windows stay on screen: the compositor keeps showing the old Space. The verified activation is a three-step sequence on the target's display:

1. `SLSBridgedShowSpacesOperation initWithSpaces:@[target]`
2. `SLSBridgedHideSpacesOperation initWithSpaces:<every other Space on the same display>`
3. `SLSBridgedManagedDisplaySetCurrentSpaceOperation initWithDisplayIdentifier:spaceID:`

With the yabai daemon stopped, four consecutive activations (Desktops holding 4, 1, 0 and 4 ordinary windows) each produced an on-screen window census (`CGWindowListCopyWindowInfo` with the on-screen-only option, filtered to application-window levels) matching the expected window set, and a recording showed no sliding transition. The packaged probe additionally cross-checks the per-Space option-`0x2` census. After guest integration, ordinary `space --focus` and cross-Space `window --focus` commands worked without gesture instrumentation.

Activation is per display. It is not a promise about keyboard focus between displays (unverified) and it must be confirmed by polling, never by an immediate check (§1).

## 5. Window moves (Verified)

`SLSBridgedMoveWindowsToManagedSpaceOperation` with one ordinary, single-Space window and an ordinary destination Desktop changes the window's membership to exactly the destination; the destination is not activated; the window's bounds are unchanged. Membership is read back with `SLSCopySpacesForWindows(cid, 7, [wid])` and cross-checked with the per-Space census. Fullscreen, sticky and multi-Space windows are outside the verified contract and are refused by the kit when identifiable.

## 6. Reordering (Verified)

- The `index` argument of `SLSBridgedMoveManagedSpaceToDisplayIndexOperation` is a **zero-based, display-local final position**. Calibration on a seven-Desktop display: index 6 placed the Space last, index 5 sixth, index 3 fourth.
- Public `move SOURCE TARGET` therefore places SOURCE at TARGET's **original** position and shifts the entries in between. Trials on the seven-Desktop display (three original Desktops followed by four created ones): a nonadjacent `swap` of the fourth and seventh Desktops produced the exact exchanged permutation; `move` of the fourth to the sixth position produced `[…, fifth, sixth, fourth, seventh]`; moving it back to the fourth position restored the order; an adjacent `swap` applied and reverted cleanly.
- **Active endpoint (Verified, one trial).** With the fourth Desktop current, a nonadjacent `swap` of the fourth and seventh Desktops applied and the swapped Desktop remained the current Space; swapping back with the first Desktop current restored the order. `probes/smoke.py` repeats this with own Desktops.
- UUIDs, window memberships, the current Space and the Mission Control thumbnail order were consistent with the census after every reorder.
- Swap is normalized to `i < j`: move the earlier ID to the later final position (adjacent pairs are done), otherwise move the saved later ID to the earlier position. Each intermediate permutation is confirmed before the next move. A nonadjacent swap is **not atomic**: a failure after the first move leaves that move applied, and the kit reports the observed state instead of attempting a blind rollback.
- Only same-display, Desktop-only layouts were exercised. Displays containing fullscreen/tile Spaces and multi-display moves are unverified and refused.

## 7. Per-window "sticky": honest negative findings

Goal: make a window appear on every Desktop from **outside** its owning process (what a window manager would need). Fixture: two ordinary windows `T` and `C` from one disposable process on home Desktop `H`; visibility judged by the CG on-screen flag together with the option-`0x2` census, held stable across samples, never by dispatch alone.

| Attempt | Where observed | Membership | Tag `0x800` | Stable visibility | Verdict |
|---|---|---|---|---|---|
| Foreign `SLSBridgedAddWindowsToSpacesOperation` (`T` → `E`) | `E`, then a Desktop `N` created afterwards, then `H` | stayed `[H]` | unchanged | hidden on `E` and `N`, visible at `H` | **Not applied** |
| Foreign `SLSBridgedRemoveWindowsFromSpacesOperation` (`T` from `E` and `H`) | `E`, `H` | stayed `[H]` | unchanged | unchanged | **Not applied** |
| Foreign `SLSSetWindowTags(cid, T, &0x800, 64)` from a helper connection | `E`, a new `N`, `H` | stayed `[H]` | `CGError 0` returned, **bit unchanged** | unchanged | **Not applied** |
| Owner-side `NSWindow.collectionBehavior |= canJoinAllSpaces` (positive control) | `E` and a new `N` | every Desktop on the display, including `N` created afterwards | bit set (`…2001` → `…2801`) | visible on `E` and `N`; sibling `C` stayed `[H]` and hidden | **Applied** |
| Owner clears `canJoinAllSpaces` while on `N` | `N`, then `E`, then `H` | pinned to the **current** Desktop `N`, not home | cleared | no longer follows to `E`; explicit native move restored `[H]` | Applied (owner) |

Conclusions:

- The positive control proves the observation method: when the owner sets the collection behavior, the tag bit, the memberships and the compositor visibility all change, and future Desktops are followed. The same-process sibling proves the effect is per window, not per process.
- No foreign mechanism tried here produced the same effect. There is also no hidden carry-by-move or app-wide assignment masquerading as per-window sticky: unsticking pins the window to the current Desktop and only an explicit move returns it home.
- Therefore the production API has **no sticky operation**. `probes/sticky.py` keeps the experiment reproducible; a repeated negative result on a newer build is an observation, and a positive one would be news, not a bug.
- These findings do not say the tag or add operations are inert in general (the owner path clearly sets the same bit). They say the foreign paths tried here were not honored for a window of another process on this build. Whether an entitled or system process would be honored was not tested.

The observer scans `CGWindowListCopyWindowInfo(kCGWindowListOptionAll, …)` by window number. On-screen state and per-Space hosting are separate observations: a window being “up” on an inactive Space is not proof that it is visible on the current screen.

## 8. Measured limits

- Confirmation is bounded to 2 s of run-loop polling in 50 ms slices. This is a confirmation deadline, not a hard timeout around every system call or a claim about animation duration. The original experiments did not establish finer universal timing guarantees. The packaged probes record operation and settle times as local run evidence.
- Fixture windows in the trials were ordinary 480×332 titled windows at window level 0; frames were unchanged across migration, moves and activations.
- Census options used throughout: `0x2` = windows the compositor considers up on the Space; `0x7` = including parked/minimized. Window level classification for the "empty" guard: 0 (normal), 3 (floating), 8 (modal), following the guest window manager's rules.

## 9. Not verified (do not assume)

- Any macOS release other than 27 RC 26A428; older reports about SkyLight/CGS space APIs are not evidence for this build and vice versa.
- Multiple displays, "Displays have separate Spaces" turned off, mirrored displays, display hot-plug during an operation.
- Fullscreen and tile Spaces (creation, activation, destruction, reordering around them).
- Destroying the active Desktop through the raw operation. Active-endpoint reordering has been exercised on the single-display ordinary-Desktop setup, but not with fullscreen or multi-display layouts.
- Stage Manager, Universal Control, locked or fast-user-switched sessions (probes refuse to run when the session is locked or not on the console).
- Keyboard focus transfer as part of activation; behavior when the Dock is not running.
- Foreign sticky through entitled or system processes; `SLSBridgedProcessAssignToAllSpacesOperation`.

## 10. Reproducing

```
make            # library, nsk CLI
make probes     # build/window-fixture and build/sticky-probe
python3 probes/smoke.py                 # read-only: capabilities, census, ID validation
python3 probes/smoke.py --mutate        # lifecycle, migration, activation, move, reorder, guards
python3 probes/sticky.py --mutate       # the §7 experiment
```

Both runners are Python 3.9 standard library, print one JSON report on stdout (`--report PATH` also writes it), and exit 0/1/2/3 for pass / failure / prerequisite / incomplete cleanup. They only create and destroy Spaces they created, only move windows they own, restore every display's current Space, compare the final census with the baseline, and list every cleanup step with its outcome so a partial cleanup is never silent. Reports contain the run's native IDs and PIDs; they are local evidence and are not meant to be committed.

## 11. Provenance

- Runtime introspection of `SkyLight.framework` on build 26A428 (class list, method type encodings, symbol resolution) is the source of §2. The raw listing is machine-specific and not committed.
- The guest-side reference implementation cited [KiwiCanopy/KiwiDesk pull request 990](https://github.com/KiwiCanopy/KiwiDesk/pull/990) for the `performWithWMBridgeDelegate` dispatch pattern. It is a lead, not evidence: nothing in that report was re-checked here and it must not be read as proving behavior on this build.
- Census option bits and the level 0/3/8 window classification follow [yabai `src/space.c`](https://github.com/asmvik/yabai/blob/master/src/space.c); they are conventions adopted for comparability, not Apple documentation.
- Public API used by the probes: [`NSWindowCollectionBehaviorCanJoinAllSpaces`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior/canjoinallspaces), [`CGSessionCopyCurrentDictionary`](https://developer.apple.com/documentation/coregraphics/1454780-cgsessioncopycurrentdictionary), [`CGWindowListCopyWindowInfo`](https://developer.apple.com/documentation/coregraphics/1455137-cgwindowlistcopywindowinfo).
- Historical findings came from the original isolated guest experiments. The repository's packaged implementation and probes were subsequently revalidated as described below; raw machine-specific reports remain outside the repository.

## 12. Packaged implementation revalidation

The library, CLI and probes in this repository were built and exercised in the following environments:

| Environment | Checks | Result |
|---|---|---|
| macOS 26.6.2 (`25G83`), arm64 development host | Library/CLI build, pure-C consumer build, C ABI/error checks, CLI checks, probe-safety regression checks, default read-only smoke | Passed; no host Desktop mutations |
| macOS 27 RC (`26A428`), arm64 guest, SIP enabled | Same build and read-only checks | Passed |
| Same guest | Packaged `smoke.py --mutate`: queries, fixture membership, ID refusals, lifecycle, populated migration, activation visibility, window move, reorder/swap, active-Space guard | All 10 case groups passed; cleanup complete and baseline restored |
| Same guest | Packaged `sticky.py --mutate` | Foreign ADD, REMOVE and tag writes not applied; owner positive control applied on existing and future Desktops; unsticky pinned to current; cleanup complete and baseline restored |
| Same guest | C API create/destroy plus a later query from main-queue callbacks under AppKit's main run loop | Passed; the created test Desktop was removed |

The embedding harness also demonstrated why the API requires the **actual process main thread**, not just a queue label: with a bare `dispatch_main()` harness, a later main-queue callback ran off the original main thread and was correctly refused as `wrong_thread`. Keeping AppKit's main run loop running made all callbacks pass.

The packaged smoke runner's default is genuinely read-only. Fixture creation and every GUI mutation require `--mutate`. Cleanup tracks IDs returned even by an unconfirmed create, refuses populated cleanup targets, never adopts an original Desktop from an error, and stops subsequent cases after an incomplete cleanup. Those safety boundaries have read-only regression checks.
