/* Read-only ABI contract test for include/native_space_kit.h.
 *
 * Never submits a native write. Mutation entry points are exercised only with
 * arguments the library must refuse before touching the bridge: NULL outputs,
 * zero IDs, unknown option bits, the wrong thread, the uninitialized state, and
 * IDs that cannot exist (UINT64_MAX / UINT32_MAX). Initialization and snapshot
 * queries run when a GUI session is available; otherwise they are skipped.
 *
 * Built and run by `make check`.
 */

#include <CoreFoundation/CoreFoundation.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "native_space_kit.h"

static int failures;

static bool check(bool condition, const char *label) {
    if (!condition) {
        ++failures;
        printf("FAIL %s\n", label);
    }
    return condition;
}

static void check_status(const char *label, nsk_status returned, nsk_status expected, const nsk_error *error) {
    char text[256];
    snprintf(text, sizeof text, "%s: returned %s, expected %s", label, nsk_status_name(returned), nsk_status_name(expected));
    check(returned == expected, text);
    snprintf(text, sizeof text, "%s: error.status %s does not match return value", label, nsk_status_name(error->status));
    check(error->status == returned, text);
    snprintf(text, sizeof text, "%s: empty message", label);
    check(error->message[0] != '\0', text);
    snprintf(text, sizeof text, "%s: message not terminated within %zu bytes", label, sizeof error->message);
    check(memchr(error->message, '\0', sizeof error->message) != NULL, text);
    snprintf(text, sizeof text, "%s: request_may_have_applied must be false before any write", label);
    check(!error->request_may_have_applied, text);
}

/* Runs one call with a poisoned error and asserts the refusal shape. */
#define EXPECT(label, expected, call)                       \
    do {                                                    \
        nsk_error e;                                        \
        memset(&e, 0xA5, sizeof e);                         \
        nsk_status s = (call);                              \
        check_status(label, s, (expected), &e);             \
    } while (0)

static void test_status_names(void) {
    const char *names[NSK_INTERNAL_ERROR + 1];
    for (int i = 0; i <= NSK_INTERNAL_ERROR; ++i) {
        names[i] = nsk_status_name((nsk_status)i);
        check(names[i] != NULL && names[i][0] != '\0', "status_name: NULL or empty for a defined status");
    }
    for (int i = 0; i <= NSK_INTERNAL_ERROR; ++i) {
        for (int j = i + 1; j <= NSK_INTERNAL_ERROR; ++j) {
            if (names[i] && names[j]) check(strcmp(names[i], names[j]) != 0, "status_name: two statuses share a name");
        }
    }
    const char *unknown = nsk_status_name((nsk_status)(NSK_INTERNAL_ERROR + 1));
    check(unknown != NULL && unknown[0] != '\0', "status_name: out-of-range must still yield a string");
    check(!unknown || !names[NSK_OK] || strcmp(unknown, names[NSK_OK]) != 0, "status_name: out-of-range must not read as ok");
}

static void test_error_clear(void) {
    nsk_error e;
    memset(&e, 0xFF, sizeof e);
    nsk_error_clear(&e);
    check(e.status == NSK_OK, "error_clear: status");
    check(e.space_id == 0 && e.window_id == 0, "error_clear: ids");
    check(!e.request_may_have_applied, "error_clear: request_may_have_applied");
    check(e.message[0] == '\0', "error_clear: message");
}

/* Argument validation precedes the initialization check, and valid out
 * pointers are cleared on every failure. */
static void test_before_initialize(void) {
    CFArrayRef array = (CFArrayRef)(uintptr_t)1;
    nsk_space_id created = 42;
    nsk_capabilities caps;

    EXPECT("copy_spaces NULL out", NSK_INVALID_ARGUMENT, nsk_copy_spaces(NULL, &e));
    EXPECT("copy_spaces uninitialized", NSK_NOT_INITIALIZED, nsk_copy_spaces(&array, &e));
    check(array == NULL, "copy_spaces uninitialized: out must be NULL");
    check(nsk_copy_spaces(&array, NULL) == NSK_NOT_INITIALIZED, "copy_spaces: NULL error must be accepted");

    EXPECT("get_capabilities NULL out", NSK_INVALID_ARGUMENT, nsk_get_capabilities(NULL, &e));
    EXPECT("get_capabilities uninitialized", NSK_NOT_INITIALIZED, nsk_get_capabilities(&caps, &e));
    check(nsk_get_capabilities(&caps, NULL) == NSK_NOT_INITIALIZED, "get_capabilities: NULL error must be accepted");

    array = (CFArrayRef)(uintptr_t)1;
    EXPECT("copy_window_spaces zero window", NSK_INVALID_ARGUMENT, nsk_copy_window_spaces(0, &array, &e));
    check(array == NULL, "copy_window_spaces zero window: out must be NULL");
    EXPECT("copy_window_spaces NULL out", NSK_INVALID_ARGUMENT, nsk_copy_window_spaces(UINT32_MAX, NULL, &e));
    array = (CFArrayRef)(uintptr_t)1;
    EXPECT("copy_window_spaces uninitialized", NSK_NOT_INITIALIZED, nsk_copy_window_spaces(UINT32_MAX, &array, &e));
    check(array == NULL, "copy_window_spaces uninitialized: out must be NULL");

    EXPECT("create_space NULL out", NSK_INVALID_ARGUMENT, nsk_create_space(NULL, &e));
    EXPECT("create_space uninitialized", NSK_NOT_INITIALIZED, nsk_create_space(&created, &e));
    check(created == 0, "create_space uninitialized: out must be 0");
    created = 42;
    check(nsk_create_space(&created, NULL) == NSK_NOT_INITIALIZED && created == 0, "create_space: NULL error must be accepted");

    EXPECT("activate_space zero", NSK_INVALID_ARGUMENT, nsk_activate_space(0, &e));
    EXPECT("activate_space uninitialized", NSK_NOT_INITIALIZED, nsk_activate_space(UINT64_MAX, &e));
    check(nsk_activate_space(UINT64_MAX, NULL) == NSK_NOT_INITIALIZED, "activate_space: NULL error must be accepted");

    EXPECT("destroy_space zero", NSK_INVALID_ARGUMENT, nsk_destroy_space(0, NSK_DESTROY_DEFAULT, &e));
    EXPECT("destroy_space unknown option bits", NSK_INVALID_ARGUMENT,
           nsk_destroy_space(UINT64_MAX, ~(uint32_t)NSK_DESTROY_MIGRATE_WINDOWS, &e));
    EXPECT("destroy_space uninitialized", NSK_NOT_INITIALIZED, nsk_destroy_space(UINT64_MAX, NSK_DESTROY_DEFAULT, &e));
    EXPECT("destroy_space --migrate uninitialized", NSK_NOT_INITIALIZED,
           nsk_destroy_space(UINT64_MAX, NSK_DESTROY_MIGRATE_WINDOWS, &e));

    EXPECT("move_window zero window", NSK_INVALID_ARGUMENT, nsk_move_window(0, UINT64_MAX, &e));
    EXPECT("move_window zero space", NSK_INVALID_ARGUMENT, nsk_move_window(UINT32_MAX, 0, &e));
    EXPECT("move_window uninitialized", NSK_NOT_INITIALIZED, nsk_move_window(UINT32_MAX, UINT64_MAX, &e));

    EXPECT("move_space zero source", NSK_INVALID_ARGUMENT, nsk_move_space(0, UINT64_MAX, &e));
    EXPECT("move_space zero target", NSK_INVALID_ARGUMENT, nsk_move_space(UINT64_MAX, 0, &e));
    EXPECT("move_space uninitialized", NSK_NOT_INITIALIZED, nsk_move_space(UINT64_MAX, UINT64_MAX - 1, &e));

    EXPECT("swap_spaces zero a", NSK_INVALID_ARGUMENT, nsk_swap_spaces(0, UINT64_MAX, &e));
    EXPECT("swap_spaces zero b", NSK_INVALID_ARGUMENT, nsk_swap_spaces(UINT64_MAX, 0, &e));
    EXPECT("swap_spaces uninitialized", NSK_NOT_INITIALIZED, nsk_swap_spaces(UINT64_MAX, UINT64_MAX - 1, &e));
}

typedef struct {
    bool initialized;
    nsk_status initialize;
    nsk_status copy_spaces;
    CFArrayRef spaces;
    nsk_status copy_spaces_null_out;
    nsk_status activate;
    nsk_error activate_error;
} thread_results;

static void *thread_main(void *argument) {
    thread_results *r = argument;
    nsk_error e;
    nsk_error_clear(&e);
    r->spaces = (CFArrayRef)(uintptr_t)1;
    r->copy_spaces = nsk_copy_spaces(&r->spaces, &e);
    r->copy_spaces_null_out = nsk_copy_spaces(NULL, &e);
    nsk_error_clear(&r->activate_error);
    r->activate = nsk_activate_space(UINT64_MAX, &r->activate_error);
    r->initialize = r->initialized ? NSK_OK : nsk_initialize(&e);
    return NULL;
}

/* Wrong thread wins over every other check, initialized or not. */
static void test_wrong_thread(bool initialized) {
    thread_results r;
    memset(&r, 0, sizeof r);
    r.initialized = initialized;
    pthread_t thread;
    if (!check(pthread_create(&thread, NULL, thread_main, &r) == 0, "wrong thread: pthread_create")) return;
    pthread_join(thread, NULL);
    const char *phase = initialized ? " (initialized)" : " (uninitialized)";
    char label[128];
    snprintf(label, sizeof label, "wrong thread%s: copy_spaces", phase);
    check(r.copy_spaces == NSK_WRONG_THREAD, label);
    snprintf(label, sizeof label, "wrong thread%s: copy_spaces out must be NULL", phase);
    check(r.spaces == NULL, label);
    snprintf(label, sizeof label, "wrong thread%s: copy_spaces NULL out still reports the thread", phase);
    check(r.copy_spaces_null_out == NSK_WRONG_THREAD, label);
    snprintf(label, sizeof label, "wrong thread%s: activate_space", phase);
    check_status(label, r.activate, NSK_WRONG_THREAD, &r.activate_error);
    if (!initialized) check(r.initialize == NSK_WRONG_THREAD, "wrong thread: initialize");
}

static CFTypeRef field(CFDictionaryRef record, const char *key, CFTypeID type) {
    CFStringRef name = CFStringCreateWithCStringNoCopy(NULL, key, kCFStringEncodingUTF8, kCFAllocatorNull);
    CFTypeRef value = CFDictionaryGetValue(record, name);
    CFRelease(name);
    return value && CFGetTypeID(value) == type ? value : NULL;
}

static int64_t integer(CFDictionaryRef record, const char *key) {
    CFNumberRef value = field(record, key, CFNumberGetTypeID());
    int64_t out = -1;
    if (value) CFNumberGetValue(value, kCFNumberSInt64Type, &out);
    return out;
}

static void validate_snapshot(CFArrayRef spaces) {
    char label[160];
    CFIndex count = CFArrayGetCount(spaces);
    if (!check(count > 0, "snapshot: no records")) return;
    for (CFIndex i = 0; i < count; ++i) {
        CFTypeRef entry = CFArrayGetValueAtIndex(spaces, i);
        snprintf(label, sizeof label, "snapshot: record %ld is not a dictionary", (long)i);
        if (!check(CFGetTypeID(entry) == CFDictionaryGetTypeID(), label)) continue;
        CFDictionaryRef record = entry;
        snprintf(label, sizeof label, "snapshot: record %ld id must be a nonzero number", (long)i);
        check(integer(record, "id") > 0, label);
        snprintf(label, sizeof label, "snapshot: record %ld index must equal its position", (long)i);
        check(integer(record, "index") == (int64_t)i + 1, label);
        snprintf(label, sizeof label, "snapshot: record %ld display_index must be positive", (long)i);
        check(integer(record, "display_index") > 0, label);
        snprintf(label, sizeof label, "snapshot: record %ld type must be a number", (long)i);
        check(field(record, "type", CFNumberGetTypeID()) != NULL, label);
        snprintf(label, sizeof label, "snapshot: record %ld uuid must be a string", (long)i);
        check(field(record, "uuid", CFStringGetTypeID()) != NULL, label);
        snprintf(label, sizeof label, "snapshot: record %ld display must be a non-empty string", (long)i);
        CFStringRef display = field(record, "display", CFStringGetTypeID());
        check(display && CFStringGetLength(display) > 0, label);
        snprintf(label, sizeof label, "snapshot: record %ld active must be a boolean", (long)i);
        check(field(record, "active", CFBooleanGetTypeID()) != NULL, label);

        /* Unique IDs, per-display 1..k local indices, exactly one active per display. */
        for (CFIndex j = 0; j < i; ++j) {
            CFDictionaryRef other = CFArrayGetValueAtIndex(spaces, j);
            if (CFGetTypeID(other) != CFDictionaryGetTypeID()) continue;
            snprintf(label, sizeof label, "snapshot: records %ld and %ld share an id", (long)j, (long)i);
            check(integer(other, "id") != integer(record, "id"), label);
        }
    }
    CFIndex previous_local = 0;
    CFStringRef previous_display = NULL;
    CFIndex active_on_display = 0;
    for (CFIndex i = 0; i <= count; ++i) {
        CFDictionaryRef record = i < count ? CFArrayGetValueAtIndex(spaces, i) : NULL;
        CFStringRef display = record ? field(record, "display", CFStringGetTypeID()) : NULL;
        bool same = previous_display && display && CFStringCompare(previous_display, display, 0) == kCFCompareEqualTo;
        if (!same) {
            if (previous_display) {
                snprintf(label, sizeof label, "snapshot: display ending at record %ld has %ld active records, expected 1",
                         (long)i - 1, (long)active_on_display);
                check(active_on_display == 1, label);
            }
            previous_local = 0;
            active_on_display = 0;
        }
        if (!record) break;
        snprintf(label, sizeof label, "snapshot: record %ld display_index %" PRId64 " breaks the per-display sequence",
                 (long)i, integer(record, "display_index"));
        check(integer(record, "display_index") == previous_local + 1, label);
        previous_local = integer(record, "display_index");
        CFBooleanRef active = field(record, "active", CFBooleanGetTypeID());
        if (active && CFBooleanGetValue(active)) ++active_on_display;
        previous_display = display;
    }
}

/* Read-only checks against the live session: idempotent initialize, ownership
 * of every snapshot, and argument validation that survives initialization. */
static void test_initialized(void) {
    nsk_error err;
    nsk_error_clear(&err);
    check(nsk_initialize(&err) == NSK_OK && err.status == NSK_OK, "initialize: second call must be idempotent");

    nsk_capabilities caps;
    memset(&caps, 0xFF, sizeof caps);
    check(nsk_get_capabilities(&caps, &err) == NSK_OK, "get_capabilities: initialized");

    CFArrayRef first = (CFArrayRef)(uintptr_t)1;
    CFArrayRef second = (CFArrayRef)(uintptr_t)1;
    if (caps.space_query) {
        check(nsk_copy_spaces(&first, &err) == NSK_OK && first != NULL, "copy_spaces: initialized");
        check(nsk_copy_spaces(&second, &err) == NSK_OK && second != NULL, "copy_spaces: repeated");
        if (first) validate_snapshot(first);
        if (first) CFRelease(first);
        if (second) CFRelease(second);
    } else {
        EXPECT("copy_spaces without space_query", NSK_UNSUPPORTED, nsk_copy_spaces(&first, &e));
        check(first == NULL, "copy_spaces without space_query: out must be NULL");
        printf("SKIP snapshot checks: space_query unavailable\n");
    }

    if (caps.window_query) {
        /* SkyLight reports an unknown window either as no membership or as a failed query. */
        CFArrayRef membership = (CFArrayRef)(uintptr_t)1;
        nsk_status s = nsk_copy_window_spaces(UINT32_MAX, &membership, &err);
        check(s == NSK_OK ? membership != NULL && CFArrayGetCount(membership) == 0 : membership == NULL,
              "copy_window_spaces unknown window: empty array on success, NULL on failure");
        check(s == NSK_OK || s == NSK_QUERY_FAILED, "copy_window_spaces unknown window: status");
        check(!err.request_may_have_applied, "copy_window_spaces unknown window: no write");
        if (s == NSK_OK && membership) CFRelease(membership);
    }

    EXPECT("activate_space zero (initialized)", NSK_INVALID_ARGUMENT, nsk_activate_space(0, &e));
    EXPECT("destroy_space zero (initialized)", NSK_INVALID_ARGUMENT, nsk_destroy_space(0, NSK_DESTROY_DEFAULT, &e));
    EXPECT("move_window zero (initialized)", NSK_INVALID_ARGUMENT, nsk_move_window(0, UINT64_MAX, &e));
    EXPECT("move_space zero (initialized)", NSK_INVALID_ARGUMENT, nsk_move_space(0, UINT64_MAX, &e));
    EXPECT("swap_spaces zero (initialized)", NSK_INVALID_ARGUMENT, nsk_swap_spaces(UINT64_MAX, 0, &e));
}

static nsk_status refuse_activate(nsk_error *e) { return nsk_activate_space(UINT64_MAX, e); }
static nsk_status refuse_destroy(nsk_error *e) { return nsk_destroy_space(UINT64_MAX, NSK_DESTROY_DEFAULT, e); }
static nsk_status refuse_destroy_migrate(nsk_error *e) { return nsk_destroy_space(UINT64_MAX, NSK_DESTROY_MIGRATE_WINDOWS, e); }
static nsk_status refuse_move_window(nsk_error *e) { return nsk_move_window(UINT32_MAX, UINT64_MAX, e); }
static nsk_status refuse_move_space(nsk_error *e) { return nsk_move_space(UINT64_MAX, UINT64_MAX - 1, e); }
static nsk_status refuse_swap(nsk_error *e) { return nsk_swap_spaces(UINT64_MAX, UINT64_MAX - 1, e); }

/* Impossible IDs must be refused before any write: not_found (or a locked
 * session, which is checked earlier). An unknown window may additionally
 * surface as a failed membership query. */
static void test_nonexistent_targets(void) {
    static const struct {
        const char *label;
        nsk_status (*call)(nsk_error *);
        bool query_may_fail;
    } cases[] = {
        {"activate_space nonexistent", refuse_activate, false},
        {"destroy_space nonexistent", refuse_destroy, false},
        {"destroy_space --migrate nonexistent", refuse_destroy_migrate, false},
        {"move_window nonexistent", refuse_move_window, true},
        {"move_space nonexistent", refuse_move_space, false},
        {"swap_spaces nonexistent", refuse_swap, false},
    };
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; ++i) {
        nsk_error e;
        memset(&e, 0xA5, sizeof e);
        nsk_status s = cases[i].call(&e);
        bool refused = s == NSK_NOT_FOUND || s == NSK_SESSION_LOCKED || s == NSK_NO_GUI_SESSION ||
                       (cases[i].query_may_fail && s == NSK_QUERY_FAILED);
        char text[256];
        snprintf(text, sizeof text, "%s: returned %s, expected not_found or a session refusal", cases[i].label, nsk_status_name(s));
        check(refused, text);
        snprintf(text, sizeof text, "%s: error.status %s does not match return value", cases[i].label, nsk_status_name(e.status));
        check(e.status == s, text);
        snprintf(text, sizeof text, "%s: empty message", cases[i].label);
        check(e.message[0] != '\0', text);
        snprintf(text, sizeof text, "%s: a refused target must never count as a submitted write", cases[i].label);
        check(!e.request_may_have_applied, text);
    }
}

int main(void) {
    test_status_names();
    test_error_clear();
    test_before_initialize();
    test_wrong_thread(false);

    nsk_error e;
    nsk_error_clear(&e);
    nsk_status s = nsk_initialize(&e);
    if (s == NSK_NO_GUI_SESSION) {
        printf("SKIP live checks: %s: %s\n", nsk_status_name(s), e.message);
    } else if (check(s == NSK_OK && e.status == NSK_OK, "initialize")) {
        test_initialized();
        test_wrong_thread(true);
        test_nonexistent_targets();
    } else {
        printf("initialize: %s: %s\n", nsk_status_name(s), e.message);
    }

    if (failures) {
        printf("contract: %d failure(s)\n", failures);
        return EXIT_FAILURE;
    }
    printf("contract: ok\n");
    return EXIT_SUCCESS;
}
