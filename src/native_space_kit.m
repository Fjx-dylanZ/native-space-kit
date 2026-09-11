// Implementation of include/native_space_kit.h.
//
// Bridges the private SkyLight WMBridge operations (SLSBridged*Operation classes)
// into a C-callable, main-thread-only library. Every native ABI is validated at
// runtime through the Objective-C method signatures before it is used, and every
// mutation is confirmed against the managed-Space census for at most two seconds.
// Behavior and operation sequences were verified on macOS 27 RC (26A428, arm64)
// with SIP enabled; see docs/ for the findings behind each guard.
//
// The core never writes to stdout/stderr, never installs event taps, synthesizes
// input, injects code, or changes SIP/TCC state.
#import <Cocoa/Cocoa.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "../include/native_space_kit.h"

static bool g_initialized;
static int g_connection;
static SEL g_perform;
static CFArrayRef (*g_copyManagedSpaces)(int);
static CFArrayRef (*g_copyWindows)(int, uint32_t, CFArrayRef, uint32_t, uint64_t *, uint64_t *);
static CFArrayRef (*g_copySpacesForWindows)(int, int, CFArrayRef);

// Verified WMBridge operation ABIs. init_arguments holds one Objective-C type code per
// argument; perform_result is "v" for asynchronous and "@" for synchronous operations.
typedef struct {
    const char *class_name;
    const char *init_selector;
    const char *init_arguments;
    const char *perform_result;
} nsk_operation;

static const nsk_operation kCreate = {"SLSBridgedSpaceCreateOperation", "initWithOptions:values:", "I@", "@"};
static const nsk_operation kDestroy = {"SLSBridgedSpaceDestroyOperation", "initWithSpaceID:", "Q", "v"};
static const nsk_operation kShow = {"SLSBridgedShowSpacesOperation", "initWithSpaces:", "@", "v"};
static const nsk_operation kHide = {"SLSBridgedHideSpacesOperation", "initWithSpaces:", "@", "v"};
static const nsk_operation kSetCurrent = {"SLSBridgedManagedDisplaySetCurrentSpaceOperation",
                                          "initWithDisplayIdentifier:spaceID:", "@Q", "v"};
static const nsk_operation kMoveWindows = {"SLSBridgedMoveWindowsToManagedSpaceOperation", "initWithWindows:spaceID:", "@Q", "v"};
static const nsk_operation kReorder = {"SLSBridgedMoveManagedSpaceToDisplayIndexOperation",
                                       "initWithSpaceID:displayIdentifier:index:", "Q@I", "v"};

// MARK: - Errors and preconditions

// Sets status, IDs, and message. request_may_have_applied is deliberately left alone so a
// write submitted earlier in the call stays reported on every later failure.
__attribute__((format(printf, 5, 6)))
static nsk_status fail(nsk_error *error, nsk_status status, nsk_space_id space, nsk_window_id window, const char *format, ...) {
    if (error) {
        error->status = status;
        error->space_id = space;
        error->window_id = window;
        va_list arguments;
        va_start(arguments, format);
        vsnprintf(error->message, sizeof error->message, format, arguments);
        va_end(arguments);
    }
    return status;
}

static nsk_status succeed(nsk_error *error) {
    if (error) {
        error->status = NSK_OK;
        error->space_id = 0;
        error->window_id = 0;
        error->message[0] = '\0';
    }
    return NSK_OK;
}

static nsk_status begin(nsk_error *error) {
    nsk_error_clear(error);
    if (!pthread_main_np()) return fail(error, NSK_WRONG_THREAD, 0, 0, "This API must be called on the process main thread.");
    return NSK_OK;
}

static nsk_status require_initialized(nsk_error *error) {
    if (!g_initialized) return fail(error, NSK_NOT_INITIALIZED, 0, 0, "Call nsk_initialize before using this API.");
    return NSK_OK;
}

static bool session_flag(CFDictionaryRef session, CFStringRef key) {
    CFTypeRef value = CFDictionaryGetValue(session, key);
    if (!value) return false;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) return CFBooleanGetValue(value);
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        int64_t number = 0;
        return CFNumberGetValue(value, kCFNumberSInt64Type, &number) && number != 0;
    }
    return false;
}

static nsk_status require_session(bool unlocked, nsk_error *error) {
    CFDictionaryRef session = CGSessionCopyCurrentDictionary();
    if (!session) return fail(error, NSK_NO_GUI_SESSION, 0, 0, "No graphical login session is available to this process.");
    bool loggedIn = session_flag(session, kCGSessionOnConsoleKey) && session_flag(session, kCGSessionLoginDoneKey);
    CFTypeRef lockState = CFDictionaryGetValue(session, CFSTR("CGSSessionScreenIsLocked"));
    if (lockState && CFGetTypeID(lockState) != CFBooleanGetTypeID() && CFGetTypeID(lockState) != CFNumberGetTypeID()) {
        CFRelease(session);
        return fail(error, NSK_QUERY_FAILED, 0, 0, "The graphical session's lock state has an unexpected representation.");
    }
    bool locked = session_flag(session, CFSTR("CGSSessionScreenIsLocked"));
    CFRelease(session);
    if (!loggedIn) return fail(error, NSK_NO_GUI_SESSION, 0, 0, "The current session is not a logged-in console GUI session.");
    if (unlocked && locked) return fail(error, NSK_SESSION_LOCKED, 0, 0, "The screen is locked; unlock the session before mutating Spaces.");
    return NSK_OK;
}

static nsk_status require_mutation(nsk_error *error) {
    nsk_status status = require_initialized(error);
    return status ? status : require_session(true, error);
}

// Runs body inside an autorelease pool (C callers may have none) and converts native
// exceptions into NSK_INTERNAL_ERROR instead of unwinding through C frames.
static nsk_status guarded(nsk_error *error, nsk_status (^body)(void)) {
    @autoreleasepool {
        @try {
            return body();
        } @catch (NSException *exception) {
            const char *reason = exception.reason.UTF8String ?: exception.name.UTF8String;
            return fail(error, NSK_INTERNAL_ERROR, 0, 0, "Unexpected native exception: %s", reason ?: "unknown");
        }
    }
}

// MARK: - Runtime ABI validation and dispatch

static bool method_matches(Class cls, SEL selector, const char *result, const char *arguments) {
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    NSMethodSignature *signature = encoding ? [NSMethodSignature signatureWithObjCTypes:encoding] : nil;
    size_t count = strlen(arguments);
    if (!signature || signature.numberOfArguments != count + 2 || strcmp(signature.methodReturnType, result) != 0) return false;
    for (size_t i = 0; i < count; ++i) {
        const char *type = [signature getArgumentTypeAtIndex:i + 2];
        if (type[0] != arguments[i] || type[1] != '\0') return false;
    }
    return true;
}

// Returns the operation class only when both its initializer and perform selector match the verified ABI.
static Class resolve_operation(const nsk_operation *operation) {
    Class cls = objc_getClass(operation->class_name);
    if (!method_matches(cls, sel_registerName(operation->init_selector), "@", operation->init_arguments) ||
        !method_matches(cls, g_perform, operation->perform_result, "")) return Nil;
    return cls;
}

// Ownership is handed to the initializer explicitly (init consumes self and may return nil),
// which plain objc_msgSend casts cannot express under ARC.
static CFTypeRef allocate(Class cls) {
    return (__bridge_retained CFTypeRef)[cls alloc];
}

static void perform_async(id operation, nsk_error *error) {
    if (error) error->request_may_have_applied = true;
    ((void (*)(id, SEL))objc_msgSend)(operation, g_perform);
}

static id perform_sync(id operation, nsk_error *error) {
    if (error) error->request_may_have_applied = true;
    return ((id (*)(id, SEL))objc_msgSend)(operation, g_perform);
}

// MARK: - Confirmation

static void service_run_loop(void) {
    if (CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false) == kCFRunLoopRunFinished) usleep(50000);
}

// Polls probe until it returns anything other than NSK_NOT_CONFIRMED, servicing the main
// run loop between polls, for at most two seconds.
static nsk_status confirm(nsk_status (^probe)(void)) {
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 2.0;
    for (;;) {
        nsk_status status = probe();
        if (status != NSK_NOT_CONFIRMED || NSProcessInfo.processInfo.systemUptime >= deadline) return status;
        service_run_loop();
    }
}

static bool integer_number(id value) {
    return value && CFGetTypeID((__bridge CFTypeRef)value) == CFNumberGetTypeID() &&
           !CFNumberIsFloatType((__bridge CFNumberRef)value);
}

// MARK: - Census model

// Flattens SLSCopyManagedDisplaySpaces into the public record schema. Any structural
// surprise yields nil so callers fail closed instead of acting on a partial model.
static NSArray *read_spaces(void) {
    id displays = CFBridgingRelease(g_copyManagedSpaces(g_connection));
    if (![displays isKindOfClass:[NSArray class]] || [displays count] == 0) return nil;
    NSMutableArray *spaces = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (id display in displays) {
        if (![display isKindOfClass:[NSDictionary class]]) return nil;
        NSString *identifier = display[@"Display Identifier"];
        NSArray *members = display[@"Spaces"];
        NSDictionary *current = display[@"Current Space"];
        if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0 ||
            ![members isKindOfClass:[NSArray class]] || members.count == 0 ||
            ![current isKindOfClass:[NSDictionary class]]) return nil;
        NSNumber *currentID = current[@"id64"];
        if (!integer_number(currentID) || currentID.unsignedLongLongValue == 0) return nil;
        NSUInteger local = 0;
        bool foundCurrent = false;
        for (id space in members) {
            if (![space isKindOfClass:[NSDictionary class]]) return nil;
            NSNumber *spaceID = space[@"id64"], *type = space[@"type"];
            NSString *uuid = space[@"uuid"];
            if (!integer_number(spaceID) || !integer_number(type) || ![uuid isKindOfClass:[NSString class]]) return nil;
            NSNumber *normalizedID = @(spaceID.unsignedLongLongValue);
            if (normalizedID.unsignedLongLongValue == 0 || [seen containsObject:normalizedID]) return nil;
            [seen addObject:normalizedID];
            bool active = normalizedID.unsignedLongLongValue == currentID.unsignedLongLongValue;
            foundCurrent |= active;
            [spaces addObject:@{@"id":normalizedID, @"uuid":uuid,
                                @"display":identifier, @"index":@(spaces.count + 1), @"display_index":@(++local),
                                @"type":type, @"active":@(active)}];
        }
        if (!foundCurrent) return nil;
    }
    return spaces;
}

static NSDictionary *find_space(NSArray *spaces, nsk_space_id space) {
    for (NSDictionary *record in spaces)
        if ([record[@"id"] unsignedLongLongValue] == space) return record;
    return nil;
}

static int space_type(NSDictionary *record) { return [record[@"type"] intValue]; }
static bool space_active(NSDictionary *record) { return [record[@"active"] boolValue]; }
static bool same_display(NSDictionary *a, NSDictionary *b) { return [a[@"display"] isEqual:b[@"display"]]; }

static bool ids_match(NSArray *spaces, NSArray *expected) {
    if (spaces.count != expected.count) return false;
    for (NSUInteger i = 0; i < expected.count; ++i) {
        NSDictionary *record = spaces[i];
        if (![record[@"id"] isEqual:expected[i]]) return false;
    }
    return true;
}

// MARK: - Window model

// SkyLight window lists are queried with SInt32 window numbers, matching the verified callers.
static NSArray *window_list(nsk_window_id window) {
    return @[CFBridgingRelease(CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &window))];
}

// Space IDs the window is a member of (mask 7), normalized to uint64 NSNumbers; nil on query failure.
static NSMutableArray *window_memberships(nsk_window_id window) {
    NSArray *native = CFBridgingRelease(g_copySpacesForWindows(g_connection, 7, (__bridge CFArrayRef)window_list(window)));
    if (!native) return nil;
    NSMutableArray *memberships = [NSMutableArray arrayWithCapacity:native.count];
    for (id member in native) {
        if (![member isKindOfClass:[NSNumber class]]) return nil;
        [memberships addObject:@([member unsignedLongLongValue])];
    }
    return memberships;
}

static NSNumber *window_layer(NSArray *metadata, NSNumber *windowID) {
    for (NSDictionary *info in metadata) {
        if (![info[(id)kCGWindowNumber] isEqual:windowID]) continue;
        NSNumber *layer = info[(id)kCGWindowLayer];
        return [layer isKindOfClass:[NSNumber class]] ? layer : nil;
    }
    return nil;
}

// Normal, floating, and modal application window levels (yabai's classification).
static bool application_layer(NSNumber *layer) {
    int level = layer.intValue;
    return level == 0 || level == 3 || level == 8;
}

// Application windows on a Space, minimized included. Missing metadata fails closed
// rather than treating an unclassifiable Space as empty.
static nsk_status copy_application_windows(nsk_space_id space, NSArray **out, nsk_error *error) {
    if (!g_copyWindows) return fail(error, NSK_UNSUPPORTED, space, 0, "Cannot inspect the windows on the requested Space.");
    uint64_t setTags = 0, clearTags = 0;
    NSArray *ids = CFBridgingRelease(g_copyWindows(g_connection, 0, (__bridge CFArrayRef)@[@(space)], 7, &setTags, &clearTags));
    NSArray *metadata = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID));
    if (!ids || !metadata) return fail(error, NSK_QUERY_FAILED, space, 0, "Could not inspect the windows on the Space.");
    NSMutableArray *windows = [NSMutableArray array];
    for (id windowID in ids) {
        NSNumber *layer = [windowID isKindOfClass:[NSNumber class]] ? window_layer(metadata, windowID) : nil;
        if (!layer) return fail(error, NSK_QUERY_FAILED, space, 0, "Some window metadata is unavailable; refusing to classify the Space.");
        if (application_layer(layer)) [windows addObject:windowID];
    }
    *out = windows;
    return NSK_OK;
}

// MARK: - Operations

static nsk_status initialize(nsk_error *error) {
    nsk_status status = begin(error);
    if (status) return status;
    if (g_initialized) return succeed(error);
    status = require_session(false, error);
    if (status) return status;
    if (!NSApplicationLoad()) return fail(error, NSK_INTERNAL_ERROR, 0, 0, "AppKit could not initialize.");
    [NSApplication sharedApplication];
    void *skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW);
    if (!skylight) return fail(error, NSK_UNSUPPORTED, 0, 0, "SkyLight could not be loaded.");
    int (*mainConnection)(void) = dlsym(skylight, "SLSMainConnectionID");
    g_copyManagedSpaces = dlsym(skylight, "SLSCopyManagedDisplaySpaces");
    g_copyWindows = dlsym(skylight, "SLSCopyWindowsWithOptionsAndTags");
    g_copySpacesForWindows = dlsym(skylight, "SLSCopySpacesForWindows");
    if (!mainConnection || !g_copyManagedSpaces) return fail(error, NSK_UNSUPPORTED, 0, 0, "The native Space census APIs are unavailable.");
    g_connection = mainConnection();
    if (!g_connection) return fail(error, NSK_NO_GUI_SESSION, 0, 0, "No window server connection is available.");
    g_perform = sel_registerName("performWithWMBridgeDelegate");
    g_initialized = true;
    return succeed(error);
}

static nsk_status get_capabilities(nsk_capabilities *out, nsk_error *error) {
    nsk_status status = begin(error);
    if (status) return status;
    if (!out) return fail(error, NSK_INVALID_ARGUMENT, 0, 0, "out must not be NULL.");
    if ((status = require_initialized(error))) return status;
    out->space_query = true;
    out->window_query = g_copySpacesForWindows != NULL;
    out->create_space = resolve_operation(&kCreate) != Nil;
    out->destroy_space = resolve_operation(&kDestroy) != Nil && g_copyWindows != NULL;
    out->activate_space = resolve_operation(&kShow) != Nil && resolve_operation(&kHide) != Nil &&
                          resolve_operation(&kSetCurrent) != Nil;
    out->move_window = resolve_operation(&kMoveWindows) != Nil && g_copySpacesForWindows != NULL;
    out->reorder_spaces = resolve_operation(&kReorder) != Nil;
    return succeed(error);
}

static nsk_status copy_spaces(CFArrayRef *out, nsk_error *error) {
    nsk_status status = begin(error);
    if (status) return status;
    if (!out) return fail(error, NSK_INVALID_ARGUMENT, 0, 0, "out must not be NULL.");
    if ((status = require_initialized(error))) return status;
    NSArray *spaces = read_spaces();
    if (!spaces) return fail(error, NSK_QUERY_FAILED, 0, 0, "Could not read managed Spaces.");
    *out = CFBridgingRetain([spaces copy]);
    return succeed(error);
}

static nsk_status copy_window_spaces(nsk_window_id window, CFArrayRef *out, nsk_error *error) {
    nsk_status status = begin(error);
    if (status) return status;
    if (!out) return fail(error, NSK_INVALID_ARGUMENT, 0, window, "out must not be NULL.");
    if (!window) return fail(error, NSK_INVALID_ARGUMENT, 0, 0, "Window ID must be nonzero.");
    if ((status = require_initialized(error))) return status;
    if (!g_copySpacesForWindows) return fail(error, NSK_UNSUPPORTED, 0, window, "Window membership queries are unavailable.");
    NSArray *memberships = window_memberships(window);
    if (!memberships) return fail(error, NSK_QUERY_FAILED, 0, window, "Could not read the window's Space memberships.");
    *out = CFBridgingRetain([memberships copy]);
    return succeed(error);
}

static nsk_status create_space(nsk_space_id *out, nsk_error *error) {
    nsk_status status = begin(error);
    if (status) return status;
    if (!out) return fail(error, NSK_INVALID_ARGUMENT, 0, 0, "out must not be NULL.");
    if ((status = require_mutation(error))) return status;
    NSArray *before = read_spaces();
    if (!before) return fail(error, NSK_QUERY_FAILED, 0, 0, "Could not read managed Spaces.");
    Class cls = resolve_operation(&kCreate);
    if (!cls) return fail(error, NSK_UNSUPPORTED, 0, 0, "Native Space creation is unavailable or its ABI changed.");
    id operation = (__bridge_transfer id)((CFTypeRef (*)(CFTypeRef, SEL, uint32_t, id))objc_msgSend)(
        allocate(cls), sel_registerName(kCreate.init_selector), 0, @{});
    if (!operation) return fail(error, NSK_OPERATION_FAILED, 0, 0, "Could not initialize the native create operation.");
    id result = perform_sync(operation, error);
    SEL getID = sel_registerName("spaceID");
    if (!result || !method_matches(object_getClass(result), getID, "Q", ""))
        return fail(error, NSK_OPERATION_FAILED, 0, 0, "The create operation returned no usable Space ID.");
    nsk_space_id space = ((uint64_t (*)(id, SEL))objc_msgSend)(result, getID);
    if (!space || find_space(before, space))
        return fail(error, NSK_OPERATION_FAILED, space, 0, "The create operation did not return a new Space ID.");
    *out = space;
    status = confirm(^nsk_status(void) {
        NSArray *spaces = read_spaces();
        if (!spaces) return fail(error, NSK_QUERY_FAILED, space, 0, "Creation was requested, but the resulting state could not be read.");
        NSDictionary *created = find_space(spaces, space);
        if (!created) return NSK_NOT_CONFIRMED;
        if (space_type(created) != 0) return fail(error, NSK_STATE_CHANGED, space, 0, "The created Space is not an ordinary Desktop.");
        return NSK_OK;
    });
    if (status == NSK_NOT_CONFIRMED)
        return fail(error, NSK_NOT_CONFIRMED, space, 0,
                    "Creation was not observed within 2 seconds; the Space may still appear later. Check the list before retrying.");
    return status ? status : succeed(error);
}

static nsk_status activate_space(nsk_space_id space, nsk_error *error) {
    nsk_status status = begin(error);
    if (status) return status;
    if (!space) return fail(error, NSK_INVALID_ARGUMENT, 0, 0, "Space ID must be nonzero.");
    if ((status = require_mutation(error))) return status;
    NSArray *before = read_spaces();
    if (!before) return fail(error, NSK_QUERY_FAILED, space, 0, "Could not read managed Spaces.");
    NSDictionary *target = find_space(before, space);
    if (!target) return fail(error, NSK_NOT_FOUND, space, 0, "No managed Space has that native ID; Desktop numbers are not IDs.");
    Class showClass = resolve_operation(&kShow), hideClass = resolve_operation(&kHide), currentClass = resolve_operation(&kSetCurrent);
    if (!showClass || !hideClass || !currentClass)
        return fail(error, NSK_UNSUPPORTED, space, 0, "Native Space activation is unavailable or its ABI changed.");
    NSMutableArray *hidden = [NSMutableArray array];
    for (NSDictionary *record in before)
        if (same_display(record, target) && [record[@"id"] unsignedLongLongValue] != space) [hidden addObject:record[@"id"]];
    id show = (__bridge_transfer id)((CFTypeRef (*)(CFTypeRef, SEL, id))objc_msgSend)(
        allocate(showClass), sel_registerName(kShow.init_selector), @[@(space)]);
    id hide = (__bridge_transfer id)((CFTypeRef (*)(CFTypeRef, SEL, id))objc_msgSend)(
        allocate(hideClass), sel_registerName(kHide.init_selector), hidden);
    id current = (__bridge_transfer id)((CFTypeRef (*)(CFTypeRef, SEL, id, uint64_t))objc_msgSend)(
        allocate(currentClass), sel_registerName(kSetCurrent.init_selector), target[@"display"], space);
    if (!show || !hide || !current) return fail(error, NSK_OPERATION_FAILED, space, 0, "Could not initialize the native activation operations.");
    // Verified sequence: show the target, hide its display siblings, then set the current Space.
    perform_async(show, error);
    perform_async(hide, error);
    perform_async(current, error);
    status = confirm(^nsk_status(void) {
        NSArray *spaces = read_spaces();
        if (!spaces) return fail(error, NSK_QUERY_FAILED, space, 0, "Activation was requested, but the resulting state could not be read.");
        return space_active(find_space(spaces, space)) ? NSK_OK : NSK_NOT_CONFIRMED;
    });
    if (status == NSK_NOT_CONFIRMED) return fail(error, NSK_NOT_CONFIRMED, space, 0, "Activation was not observed within 2 seconds.");
    return status ? status : succeed(error);
}

static nsk_status destroy_space(nsk_space_id space, uint32_t options, nsk_error *error) {
    nsk_status status = begin(error);
    if (status) return status;
    if (!space) return fail(error, NSK_INVALID_ARGUMENT, 0, 0, "Space ID must be nonzero.");
    if (options & ~(uint32_t)NSK_DESTROY_MIGRATE_WINDOWS) return fail(error, NSK_INVALID_ARGUMENT, space, 0, "Unknown destroy option bits.");
    if ((status = require_mutation(error))) return status;
    NSArray *before = read_spaces();
    if (!before) return fail(error, NSK_QUERY_FAILED, space, 0, "Could not read managed Spaces.");
    NSDictionary *target = find_space(before, space);
    if (!target) return fail(error, NSK_NOT_FOUND, space, 0, "No managed Space has that native ID; Desktop numbers are not IDs.");
    if (space_type(target) != 0) return fail(error, NSK_NOT_DESKTOP, space, 0, "Only ordinary Desktops may be destroyed.");
    NSUInteger desktops = 0;
    for (NSDictionary *record in before)
        if (same_display(record, target) && space_type(record) == 0) ++desktops;
    if (desktops < 2) return fail(error, NSK_LAST_DESKTOP, space, 0, "Refusing to remove the display's last ordinary Desktop.");
    if (space_active(target)) return fail(error, NSK_ACTIVE_SPACE, space, 0, "Switch to another Desktop before destroying this one.");
    Class cls = resolve_operation(&kDestroy);
    if (!cls) return fail(error, NSK_UNSUPPORTED, space, 0, "Native Space destruction is unavailable or its ABI changed.");
    NSArray *windows = nil;
    if ((status = copy_application_windows(space, &windows, error))) return status;
    bool migrate = options & NSK_DESTROY_MIGRATE_WINDOWS;
    if (!migrate && windows.count)
        return fail(error, NSK_SPACE_NOT_EMPTY, space, [windows[0] unsignedIntValue],
                    "Move the Space's normal, floating, and modal windows elsewhere, or request window migration.");
    if (migrate && windows.count && !g_copySpacesForWindows)
        return fail(error, NSK_UNSUPPORTED, space, 0, "Window membership queries are unavailable; cannot verify that migrated windows survive.");
    id operation = (__bridge_transfer id)((CFTypeRef (*)(CFTypeRef, SEL, uint64_t))objc_msgSend)(
        allocate(cls), sel_registerName(kDestroy.init_selector), space);
    if (!operation) return fail(error, NSK_OPERATION_FAILED, space, 0, "Could not initialize the native destroy operation.");
    perform_async(operation, error);
    // macOS migrates the windows itself; we only verify that each sampled window still has a
    // membership that no longer includes the destroyed Space.
    __block nsk_window_id pending = 0;
    status = confirm(^nsk_status(void) {
        NSArray *spaces = read_spaces();
        if (!spaces) return fail(error, NSK_QUERY_FAILED, space, 0, "Destruction was requested, but the resulting state could not be read.");
        pending = 0;
        if (find_space(spaces, space)) return NSK_NOT_CONFIRMED;
        for (NSNumber *windowID in windows) {
            nsk_window_id window = windowID.unsignedIntValue;
            NSArray *memberships = window_memberships(window);
            if (!memberships)
                return fail(error, NSK_QUERY_FAILED, space, window, "The Space was removed, but window memberships could not be read.");
            if (!memberships.count || [memberships containsObject:@(space)]) {
                pending = window;
                return NSK_NOT_CONFIRMED;
            }
        }
        return NSK_OK;
    });
    if (status == NSK_NOT_CONFIRMED) {
        if (pending)
            return fail(error, NSK_NOT_CONFIRMED, space, pending,
                        "The Space was removed, but window %" PRIu32 " was not observed on another Space within 2 seconds.", pending);
        return fail(error, NSK_NOT_CONFIRMED, space, 0, "Destruction was not observed within 2 seconds. Check the list before retrying.");
    }
    return status ? status : succeed(error);
}

static nsk_status move_window(nsk_window_id window, nsk_space_id destination, nsk_error *error) {
    nsk_status status = begin(error);
    if (status) return status;
    if (!window || !destination) return fail(error, NSK_INVALID_ARGUMENT, 0, 0, "Window and Space IDs must be nonzero.");
    if ((status = require_mutation(error))) return status;
    if (!g_copySpacesForWindows)
        return fail(error, NSK_UNSUPPORTED, destination, window, "Window membership queries are unavailable; window moves cannot be verified.");
    Class cls = resolve_operation(&kMoveWindows);
    if (!cls) return fail(error, NSK_UNSUPPORTED, destination, window, "Native window moves are unavailable or their ABI changed.");
    NSArray *before = read_spaces();
    if (!before) return fail(error, NSK_QUERY_FAILED, destination, window, "Could not read managed Spaces.");
    NSDictionary *target = find_space(before, destination);
    if (!target) return fail(error, NSK_NOT_FOUND, destination, window, "No managed Space has that native ID; Desktop numbers are not IDs.");
    if (space_type(target) != 0) return fail(error, NSK_NOT_DESKTOP, destination, window, "Windows can only be moved to ordinary Desktops.");
    NSArray *memberships = window_memberships(window);
    if (!memberships) return fail(error, NSK_QUERY_FAILED, destination, window, "Could not read the window's Space memberships.");
    if (!memberships.count) return fail(error, NSK_NOT_FOUND, destination, window, "The window has no managed Space membership; it may not exist.");
    if (memberships.count != 1)
        return fail(error, NSK_UNSUPPORTED_WINDOW, destination, window,
                    "The window belongs to %lu Spaces; sticky and multi-Space windows are outside the verified contract.",
                    (unsigned long)memberships.count);
    NSDictionary *source = find_space(before, [memberships[0] unsignedLongLongValue]);
    if (!source || space_type(source) != 0)
        return fail(error, NSK_UNSUPPORTED_WINDOW, destination, window, "The window's current Space is not an ordinary Desktop (fullscreen or system Space).");
    NSArray *metadata = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID));
    NSNumber *layer = metadata ? window_layer(metadata, @(window)) : nil;
    if (!layer) return fail(error, NSK_QUERY_FAILED, destination, window, "Window metadata is unavailable; refusing to move an unclassified window.");
    if (!application_layer(layer))
        return fail(error, NSK_UNSUPPORTED_WINDOW, destination, window, "Only normal, floating, and modal application windows (levels 0, 3, 8) can be moved.");
    if ([source[@"id"] unsignedLongLongValue] == destination) return succeed(error);
    id operation = (__bridge_transfer id)((CFTypeRef (*)(CFTypeRef, SEL, id, uint64_t))objc_msgSend)(
        allocate(cls), sel_registerName(kMoveWindows.init_selector), window_list(window), destination);
    if (!operation) return fail(error, NSK_OPERATION_FAILED, destination, window, "Could not initialize the native window move operation.");
    perform_async(operation, error);
    status = confirm(^nsk_status(void) {
        NSArray *now = window_memberships(window);
        if (!now) return fail(error, NSK_QUERY_FAILED, destination, window, "The move was requested, but the window's memberships could not be read.");
        return now.count == 1 && [now[0] unsignedLongLongValue] == destination ? NSK_OK : NSK_NOT_CONFIRMED;
    });
    if (status == NSK_NOT_CONFIRMED)
        return fail(error, NSK_NOT_CONFIRMED, destination, window,
                    "The window was not observed on the destination Space within 2 seconds. Check its memberships before retrying.");
    return status ? status : succeed(error);
}

// One native reorder: position is the zero-based, display-local FINAL index; expected is the
// exact global ID order that must be observed. Display, type, and active state must be
// unchanged for every Space relative to before. stage labels the step in messages.
static nsk_status move_to_position(NSArray *before, nsk_space_id space, uint32_t position, NSArray *expected,
                                   const char *stage, nsk_error *error) {
    Class cls = resolve_operation(&kReorder);
    if (!cls) return fail(error, NSK_UNSUPPORTED, space, 0, "Native Space reordering is unavailable or its ABI changed (%s).", stage);
    NSDictionary *target = find_space(before, space);
    id operation = (__bridge_transfer id)((CFTypeRef (*)(CFTypeRef, SEL, uint64_t, id, uint32_t))objc_msgSend)(
        allocate(cls), sel_registerName(kReorder.init_selector), space, target[@"display"], position);
    if (!operation) return fail(error, NSK_OPERATION_FAILED, space, 0, "Could not initialize the native reorder operation (%s).", stage);
    perform_async(operation, error);
    nsk_status status = confirm(^nsk_status(void) {
        NSArray *spaces = read_spaces();
        if (!spaces) return fail(error, NSK_QUERY_FAILED, space, 0, "The reorder was requested, but the resulting state could not be read (%s).", stage);
        if (!ids_match(spaces, expected)) return NSK_NOT_CONFIRMED;
        for (NSDictionary *prior in before) {
            NSDictionary *now = find_space(spaces, [prior[@"id"] unsignedLongLongValue]);
            if (!same_display(prior, now) || space_type(prior) != space_type(now) || space_active(prior) != space_active(now))
                return fail(error, NSK_STATE_CHANGED, space, 0,
                            "The order changed, but display, type, or active-Space state also changed (%s).", stage);
        }
        return NSK_OK;
    });
    if (status == NSK_NOT_CONFIRMED)
        return fail(error, NSK_NOT_CONFIRMED, space, 0,
                    "The requested order was not observed within 2 seconds (%s). State may be partially changed; inspect the list before retrying.",
                    stage);
    return status;
}

static nsk_status reorder_spaces(nsk_space_id source, nsk_space_id target, bool exchange, nsk_error *error) {
    nsk_status status = begin(error);
    if (status) return status;
    if (!source || !target) return fail(error, NSK_INVALID_ARGUMENT, 0, 0, "Space IDs must be nonzero.");
    if ((status = require_mutation(error))) return status;
    NSArray *before = read_spaces();
    if (!before) return fail(error, NSK_QUERY_FAILED, source, 0, "Could not read managed Spaces.");
    NSDictionary *sourceRecord = find_space(before, source), *targetRecord = find_space(before, target);
    if (!sourceRecord || !targetRecord)
        return fail(error, NSK_NOT_FOUND, sourceRecord ? target : source, 0, "Both arguments must be existing native Space IDs.");
    if (!same_display(sourceRecord, targetRecord))
        return fail(error, NSK_DIFFERENT_DISPLAYS, source, 0, "Move and swap require both Spaces to belong to the same display.");
    NSMutableArray *originalIDs = [NSMutableArray arrayWithCapacity:before.count];
    NSMutableArray *displayIDs = [NSMutableArray array];
    NSUInteger sourceLocal = 0, targetLocal = 0, sourceGlobal = 0, targetGlobal = 0;
    for (NSDictionary *record in before) {
        [originalIDs addObject:record[@"id"]];
        if (!same_display(record, sourceRecord)) continue;
        if (space_type(record) != 0)
            return fail(error, NSK_UNSUPPORTED_LAYOUT, source, 0, "Reordering is limited to displays containing ordinary Desktops only.");
        nsk_space_id space = [record[@"id"] unsignedLongLongValue];
        if (space == source) { sourceLocal = displayIDs.count; sourceGlobal = originalIDs.count - 1; }
        if (space == target) { targetLocal = displayIDs.count; targetGlobal = originalIDs.count - 1; }
        [displayIDs addObject:record[@"id"]];
    }
    if (displayIDs.count > UINT32_MAX) return fail(error, NSK_UNSUPPORTED_LAYOUT, source, 0, "The Desktop index exceeds the native API range.");
    if (source == target) return succeed(error);
    if (!exchange) {
        // Source lands on the target's original position; entries in between shift.
        NSMutableArray *expected = [originalIDs mutableCopy];
        [expected removeObjectAtIndex:sourceGlobal];
        [expected insertObject:originalIDs[sourceGlobal] atIndex:targetGlobal];
        status = move_to_position(before, source, (uint32_t)targetLocal, expected, "move", error);
        return status ? status : succeed(error);
    }
    // Swap: move the earlier Space onto the later one's final position first; that already is
    // the swap for adjacent Spaces. Otherwise move the saved later Space back to the earlier
    // position. Each step is confirmed exactly; a second-step failure is reported, not rolled back.
    NSUInteger low = MIN(sourceLocal, targetLocal), high = MAX(sourceLocal, targetLocal);
    NSUInteger lowGlobal = MIN(sourceGlobal, targetGlobal), highGlobal = MAX(sourceGlobal, targetGlobal);
    NSNumber *earlier = displayIDs[low], *later = displayIDs[high];
    NSMutableArray *intermediate = [originalIDs mutableCopy];
    [intermediate removeObjectAtIndex:lowGlobal];
    [intermediate insertObject:earlier atIndex:highGlobal];
    status = move_to_position(before, earlier.unsignedLongLongValue, (uint32_t)high, intermediate, "first swap move", error);
    if (status || high == low + 1) return status ? status : succeed(error);
    NSMutableArray *expected = [originalIDs mutableCopy];
    [expected exchangeObjectAtIndex:lowGlobal withObjectAtIndex:highGlobal];
    status = move_to_position(before, later.unsignedLongLongValue, (uint32_t)low, expected,
                              "second swap move; the first move is already applied", error);
    return status ? status : succeed(error);
}

// MARK: - Public API

nsk_status nsk_initialize(nsk_error *error) {
    return guarded(error, ^nsk_status(void) { return initialize(error); });
}

void nsk_error_clear(nsk_error *error) {
    if (error) memset(error, 0, sizeof *error);
}

const char *nsk_status_name(nsk_status status) {
    switch (status) {
        case NSK_OK: return "ok";
        case NSK_INVALID_ARGUMENT: return "invalid_argument";
        case NSK_WRONG_THREAD: return "wrong_thread";
        case NSK_NOT_INITIALIZED: return "not_initialized";
        case NSK_NO_GUI_SESSION: return "no_gui_session";
        case NSK_SESSION_LOCKED: return "session_locked";
        case NSK_UNSUPPORTED: return "unsupported";
        case NSK_QUERY_FAILED: return "query_failed";
        case NSK_NOT_FOUND: return "not_found";
        case NSK_NOT_DESKTOP: return "not_desktop";
        case NSK_ACTIVE_SPACE: return "active_space";
        case NSK_LAST_DESKTOP: return "last_desktop";
        case NSK_SPACE_NOT_EMPTY: return "space_not_empty";
        case NSK_UNSUPPORTED_WINDOW: return "unsupported_window";
        case NSK_DIFFERENT_DISPLAYS: return "different_displays";
        case NSK_UNSUPPORTED_LAYOUT: return "unsupported_layout";
        case NSK_OPERATION_FAILED: return "operation_failed";
        case NSK_NOT_CONFIRMED: return "not_confirmed";
        case NSK_STATE_CHANGED: return "state_changed";
        case NSK_INTERNAL_ERROR: return "internal_error";
    }
    return "unknown";
}

nsk_status nsk_get_capabilities(nsk_capabilities *out, nsk_error *error) {
    if (out) memset(out, 0, sizeof *out);
    return guarded(error, ^nsk_status(void) { return get_capabilities(out, error); });
}

nsk_status nsk_copy_spaces(CFArrayRef *out, nsk_error *error) {
    if (out) *out = NULL;
    return guarded(error, ^nsk_status(void) { return copy_spaces(out, error); });
}

nsk_status nsk_copy_window_spaces(nsk_window_id window, CFArrayRef *out, nsk_error *error) {
    if (out) *out = NULL;
    return guarded(error, ^nsk_status(void) { return copy_window_spaces(window, out, error); });
}

nsk_status nsk_create_space(nsk_space_id *out, nsk_error *error) {
    if (out) *out = 0;
    return guarded(error, ^nsk_status(void) { return create_space(out, error); });
}

nsk_status nsk_activate_space(nsk_space_id space, nsk_error *error) {
    return guarded(error, ^nsk_status(void) { return activate_space(space, error); });
}

nsk_status nsk_destroy_space(nsk_space_id space, uint32_t options, nsk_error *error) {
    return guarded(error, ^nsk_status(void) { return destroy_space(space, options, error); });
}

nsk_status nsk_move_window(nsk_window_id window, nsk_space_id destination, nsk_error *error) {
    return guarded(error, ^nsk_status(void) { return move_window(window, destination, error); });
}

nsk_status nsk_move_space(nsk_space_id source, nsk_space_id target, nsk_error *error) {
    return guarded(error, ^nsk_status(void) { return reorder_spaces(source, target, false, error); });
}

nsk_status nsk_swap_spaces(nsk_space_id a, nsk_space_id b, nsk_error *error) {
    return guarded(error, ^nsk_status(void) { return reorder_spaces(a, b, true, error); });
}
