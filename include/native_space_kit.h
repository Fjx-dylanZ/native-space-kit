#ifndef NATIVE_SPACE_KIT_H
#define NATIVE_SPACE_KIT_H

#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NSK_VERSION "0.3.0"
#define NSK_EXPORT __attribute__((visibility("default")))

typedef uint64_t nsk_space_id;
typedef uint32_t nsk_window_id;

typedef enum {
    NSK_OK = 0,
    NSK_INVALID_ARGUMENT,
    NSK_WRONG_THREAD,
    NSK_NOT_INITIALIZED,
    NSK_NO_GUI_SESSION,
    NSK_SESSION_LOCKED,
    NSK_UNSUPPORTED,
    NSK_QUERY_FAILED,
    NSK_NOT_FOUND,
    NSK_NOT_DESKTOP,
    NSK_ACTIVE_SPACE,
    NSK_LAST_DESKTOP,
    NSK_SPACE_NOT_EMPTY,
    NSK_UNSUPPORTED_WINDOW,
    NSK_DIFFERENT_DISPLAYS,
    NSK_UNSUPPORTED_LAYOUT,
    NSK_OPERATION_FAILED,
    NSK_NOT_CONFIRMED,
    NSK_STATE_CHANGED,
    NSK_INTERNAL_ERROR
} nsk_status;

typedef struct {
    nsk_status status;
    nsk_space_id space_id;
    nsk_window_id window_id;
    /* A native write was submitted. Failure does not imply that nothing changed. */
    bool request_may_have_applied;
    char message[256];
} nsk_error;

typedef struct {
    /* Entry-point and ABI availability, not a promise that every write is authorized. */
    bool space_query;
    bool window_query;
    bool create_space;
    bool destroy_space;
    bool activate_space;
    bool move_window;
    bool reorder_spaces;
    bool add_window;
    bool assign_process;
} nsk_capabilities;

typedef enum {
    NSK_DESTROY_DEFAULT = 0,
    /* Let macOS migrate application windows; the target must still be inactive. */
    NSK_DESTROY_MIGRATE_WINDOWS = 1u << 0
} nsk_destroy_options;

/* All APIs except error_clear/status_name must be called on the process main thread.
 * Initialize once before using the other APIs. Initialization loads AppKit/SkyLight
 * but does not replace the application's delegate, menus, or activation policy.
 * Mutations require an unlocked, logged-in GUI session. No SIP changes or injection.
 * Synchronous mutation confirmation is bounded to 2 seconds and services the main
 * run loop; embedded applications must account for possible run-loop reentrancy.
 */
NSK_EXPORT nsk_status nsk_initialize(nsk_error *error);
NSK_EXPORT void nsk_error_clear(nsk_error *error);
NSK_EXPORT const char *nsk_status_name(nsk_status status);
NSK_EXPORT nsk_status nsk_get_capabilities(nsk_capabilities *out, nsk_error *error);

/* Caller owns successful CF outputs and must CFRelease them. Outputs are set to
 * NULL before any failure. error may be NULL for every API.
 *
 * Space records are immutable CFDictionary values with keys:
 *   id            CFNumber: native uint64 Space ID, NOT a Desktop number
 *   uuid          CFString: native UUID (may be empty)
 *   display       CFString: opaque native display identifier; do not assume UUID
 *   index         CFNumber: one-based position across all display records
 *   display_index CFNumber: one-based position within the owning display
 *   type          CFNumber: native type; 0 is an ordinary Desktop
 *   active        CFBoolean: current Space on its display
 * IDs/indices must not be used as persistent identities across topology/session changes.
 */
NSK_EXPORT nsk_status nsk_copy_spaces(CFArrayRef *out, nsk_error *error);
NSK_EXPORT nsk_status nsk_copy_window_spaces(nsk_window_id window, CFArrayRef *out, nsk_error *error);

/* Create on the native bridge's default display; query the returned ID's actual
 * display rather than assuming placement. out is set to 0 before failure, except
 * that a returned native ID is preserved if later confirmation fails.
 */
NSK_EXPORT nsk_status nsk_create_space(nsk_space_id *out, nsk_error *error);

/* Show target, hide the other Spaces on that display, and set the current Space.
 * This is per-display activation, not a promise to transfer keyboard focus between displays.
 */
NSK_EXPORT nsk_status nsk_activate_space(nsk_space_id space, nsk_error *error);

/* Refuses active, last, or non-Desktop targets. The default additionally refuses
 * normal/floating/modal application windows (window levels 0, 3, and 8); this is
 * not an exhaustive classification of arbitrary custom overlay windows.
 * MIGRATE_WINDOWS delegates migration to macOS and verifies the sampled application
 * windows survive. It does not implement a manual move/close loop.
 */
NSK_EXPORT nsk_status nsk_destroy_space(nsk_space_id space, uint32_t options, nsk_error *error);

/* Ordinary application windows on one or more ordinary Desktops, and ordinary destination
 * Desktops only. A window on several Desktops (see nsk_add_window_to_space) ends up on the
 * destination alone. Does not deliberately activate the destination. Sticky windows
 * (canJoinAllSpaces or an app assignment) and windows on fullscreen or system Spaces are
 * refused.
 */
NSK_EXPORT nsk_status nsk_move_window(nsk_window_id window, nsk_space_id destination, nsk_error *error);

/* Also show an ordinary application window on another ordinary Desktop of the same
 * display, keeping its current Desktops. Repeat per Desktop; the window does not join
 * Desktops created later. nsk_move_window returns it to a single Desktop. Sticky windows
 * are refused.
 */
NSK_EXPORT nsk_status nsk_add_window_to_space(nsk_window_id window, nsk_space_id space, nsk_error *error);

/* Process-wide assignment, like the Dock's "Assign To" menu, for every current and
 * future window of pid. Not saved: it ends when the process exits. Confirmed against
 * the process's application windows on ordinary Desktops; a process without such a
 * window is refused with NSK_NOT_FOUND.
 *   to_all_spaces: every Desktop, including Desktops created later.
 *   to_space:      one ordinary Desktop; existing windows move there, new windows open
 *                  there. Every window must be on that Desktop's display.
 *   clear:         no assignment. Windows stay where they are, except that windows on
 *                  every Desktop of their display stay only on its current Desktop. A
 *                  window that is sticky through its app's own setting stays on every
 *                  Desktop, and the call reports NSK_NOT_CONFIRMED.
 */
NSK_EXPORT nsk_status nsk_assign_process_to_all_spaces(pid_t pid, nsk_error *error);
NSK_EXPORT nsk_status nsk_assign_process_to_space(pid_t pid, nsk_space_id space, nsk_error *error);
NSK_EXPORT nsk_status nsk_clear_process_assignment(pid_t pid, nsk_error *error);

/* Same-display, ordinary-Desktop-only layouts. Move places source at target's
 * ORIGINAL position; intervening entries shift. Swap preserves other positions.
 * A nonadjacent swap uses two confirmed moves, so it is NOT atomic. A failure may
 * leave the first move applied; inspect state before retrying. No blind rollback.
 */
NSK_EXPORT nsk_status nsk_move_space(nsk_space_id source, nsk_space_id target, nsk_error *error);
NSK_EXPORT nsk_status nsk_swap_spaces(nsk_space_id a, nsk_space_id b, nsk_error *error);

#ifdef __cplusplus
}
#endif
#endif
