// Foreign-process observer and EXPERIMENTAL sticky writer for native-space-kit
// live probes. This tool is not part of the product API: nothing here is
// promised to work, and the sticky writes exist only so that the sticky
// experiment (probes/sticky.py) can be reproduced against the fixture windows.
//
// Build: xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Cocoa \
//            probes/sticky_probe.m -o build/sticky-probe
//
// Every command prints exactly one JSON object on stdout and exits 0; failures
// print {"error":...} on stderr and exit nonzero. Read-only commands:
//
//   sticky-probe session
//       GUI session facts used to guard visible tests: on_console, login_done,
//       locked (CGSessionCopyCurrentDictionary).
//   sticky-probe observe WINDOW_ID [WINDOW_ID...]
//       Per window: CG description (pid, layer, alpha, bounds, onscreen,
//       front-to-back onscreen_order), native Space memberships
//       (SLSCopySpacesForWindows selector 7), window tags (SLSWindowQuery
//       iterator) with bit 0x800 decoded as sticky_bit, and a per-Space
//       "hosting" table: whether the compositor lists the window for that
//       Space with options 0x2 ("up") and 0x7 ("including_parked"), the same
//       census yabai uses.
//   sticky-probe census SPACE_ID
//       The two window lists for one Space plus CG metadata for each entry.
//
// Experimental writes issued from THIS process, which never owns the window
// (so they are "foreign" relative to the fixture):
//
//   sticky-probe add WINDOW_ID SPACE_ID [SPACE_ID...]
//       SLSBridgedAddWindowsToSpacesOperation initWithWindows:spaces:
//   sticky-probe remove WINDOW_ID SPACE_ID [SPACE_ID...]
//       SLSBridgedRemoveWindowsFromSpacesOperation initWithWindows:spaces:
//   sticky-probe tag WINDOW_ID on|off
//       SLSSetWindowTags / SLSClearWindowTags with tag 0x800 on the main
//       connection of this process.
//   sticky-probe join WINDOW_ID SPACE_ID
//   sticky-probe place WINDOW_ID SPACE_ID
//       SLSBridgedSpaceAddWindowsAndRemoveFromSpacesOperation
//       initWithSpaceID:windows:options: with options 0 (add, keep the other
//       memberships) or 7 (add and leave every other Space).
//   sticky-probe assign PID SPACE_ID|0
//       SLSBridgedProcessAssignToSpaceOperation initWithProcess:spaceID:;
//       0 clears the process's assignment.
//   sticky-probe assign-all PID
//       SLSBridgedProcessAssignToAllSpacesOperation initWithProcess:
//   sticky-probe overlay create LEVEL
//       SLSBridgedSpaceCreateOperation with options 1 (an unmanaged Space
//       outside the Desktop census), then SLSBridgedSpaceSetAbsoluteLevel-
//       Operation and SLSBridgedShowSpacesOperation.
//   sticky-probe overlay destroy SPACE_ID
//       Hide and destroy an unmanaged Space; refuses managed Spaces.
//
// A write reports "dispatched" (the operation was submitted) plus, for window
// writes, the observation taken after briefly servicing the run loop.
// Dispatch is not application: the Python experiment decides applied /
// not_applied / inconclusive from stable compositor visibility, membership
// and tags.

#import <Cocoa/Cocoa.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define STICKY_TAG ((uint64_t)0x800)
// SLSBridgedSpaceAddWindowsAndRemoveFromSpacesOperation options observed on
// 26A428: 0 adds the window and keeps its other memberships; a value with both
// bits 0x1 and 0x4 set also removes it from every other Space.
#define ADD_KEEP_OTHERS 0u
#define ADD_LEAVE_OTHERS 7u
// SLSBridgedSpaceCreateOperation options 1 created an unmanaged type-3 Space.
#define CREATE_UNMANAGED 1u
#define UNMANAGED_SPACE_TYPE 3

static int connection;
static CFArrayRef (*copyManagedSpaces)(int);
static CFArrayRef (*copySpacesForWindows)(int, int, CFArrayRef);
static CFArrayRef (*copyWindowsWithOptionsAndTags)(int, uint32_t, CFArrayRef, uint32_t, uint64_t *, uint64_t *);
static CFTypeRef (*windowQueryWindows)(int, CFArrayRef, int);
static CFTypeRef (*windowQueryResultCopyWindows)(CFTypeRef);
static bool (*windowIteratorAdvance)(CFTypeRef);
static uint32_t (*windowIteratorGetWindowID)(CFTypeRef);
static uint64_t (*windowIteratorGetTags)(CFTypeRef);
static uint64_t (*windowIteratorGetAttributes)(CFTypeRef);
static int (*windowIteratorGetLevel)(CFTypeRef);
static CGError (*setWindowTags)(int, uint32_t, uint64_t *, int);
static CGError (*clearWindowTags)(int, uint32_t, uint64_t *, int);

static int emitJSON(FILE *stream, id object, int status) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:NULL];
    if (!data) {
        fputs("{\"error\":{\"code\":\"serialization_failed\",\"message\":\"Could not encode the result.\"}}\n", stderr);
        return 1;
    }
    fwrite(data.bytes, 1, data.length, stream);
    fputc('\n', stream);
    fflush(stream);
    return status;
}

// Same envelope as nsk, so probelib reads code/message/space_id uniformly.
static int fail(NSString *code, NSString *message) {
    return emitJSON(stderr, @{@"error": @{@"code": code, @"message": message}}, 1);
}

static BOOL parseUnsigned(const char *text, unsigned long long limit, unsigned long long *out) {
    if (!text || !*text) return NO;
    for (const char *p = text; *p; ++p) if (*p < '0' || *p > '9') return NO;
    errno = 0;
    unsigned long long value = strtoull(text, NULL, 10);
    if (errno == ERANGE || value == 0 || value > limit) return NO;
    *out = value;
    return YES;
}

static NSString *hex64(uint64_t value) {
    return [NSString stringWithFormat:@"0x%016llx", (unsigned long long)value];
}

static void serviceRunLoop(NSTimeInterval seconds) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

static BOOL methodMatches(Class cls, SEL selector, const char *result, NSArray<NSString *> *arguments) {
    if (!cls) return NO;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (signature.numberOfArguments != 2 + arguments.count || strcmp(signature.methodReturnType, result) != 0) return NO;
    for (NSUInteger i = 0; i < arguments.count; i++)
        if (strcmp([signature getArgumentTypeAtIndex:i + 2], arguments[i].UTF8String) != 0) return NO;
    return YES;
}

static SEL performSelector(void) {
    return sel_registerName("performWithWMBridgeDelegate");
}

// The class, if its initializer and perform method have the expected encodings.
static Class bridgedClass(NSString *name, SEL initializer, NSArray<NSString *> *arguments, const char *performResult) {
    Class cls = NSClassFromString(name);
    return methodMatches(cls, initializer, "@", arguments) && methodMatches(cls, performSelector(), performResult, @[])
        ? cls : Nil;
}

static void performAsync(id operation) {
    ((void (*)(id, SEL))objc_msgSend)(operation, performSelector());
}

static id performSync(id operation) {
    return ((id (*)(id, SEL))objc_msgSend)(operation, performSelector());
}

static BOOL loadSkyLight(void) {
    void *sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW);
    if (!sky) return NO;
    int (*mainConnection)(void) = dlsym(sky, "SLSMainConnectionID");
    copyManagedSpaces = dlsym(sky, "SLSCopyManagedDisplaySpaces");
    copySpacesForWindows = dlsym(sky, "SLSCopySpacesForWindows");
    copyWindowsWithOptionsAndTags = dlsym(sky, "SLSCopyWindowsWithOptionsAndTags");
    windowQueryWindows = dlsym(sky, "SLSWindowQueryWindows");
    windowQueryResultCopyWindows = dlsym(sky, "SLSWindowQueryResultCopyWindows");
    windowIteratorAdvance = dlsym(sky, "SLSWindowIteratorAdvance");
    windowIteratorGetWindowID = dlsym(sky, "SLSWindowIteratorGetWindowID");
    windowIteratorGetTags = dlsym(sky, "SLSWindowIteratorGetTags");
    windowIteratorGetAttributes = dlsym(sky, "SLSWindowIteratorGetAttributes");
    windowIteratorGetLevel = dlsym(sky, "SLSWindowIteratorGetLevel");
    setWindowTags = dlsym(sky, "SLSSetWindowTags");
    clearWindowTags = dlsym(sky, "SLSClearWindowTags");
    if (!mainConnection || !copyManagedSpaces) return NO;
    connection = mainConnection();
    return YES;
}

// Flat Space records: id, display, type, active. Mirrors the CLI census.
static NSArray *readSpaces(void) {
    CFArrayRef raw = copyManagedSpaces(connection);
    if (!raw) return nil;
    id displays = CFBridgingRelease(raw);
    if (![displays isKindOfClass:[NSArray class]]) return nil;
    NSMutableArray *spaces = [NSMutableArray array];
    for (id display in displays) {
        if (![display isKindOfClass:[NSDictionary class]] ||
            ![display[@"Spaces"] isKindOfClass:[NSArray class]] ||
            ![display[@"Display Identifier"] isKindOfClass:[NSString class]] ||
            ![display[@"Current Space"] isKindOfClass:[NSDictionary class]]) return nil;
        NSNumber *current = display[@"Current Space"][@"id64"];
        if (![current isKindOfClass:[NSNumber class]]) return nil;
        for (id space in display[@"Spaces"]) {
            if (![space isKindOfClass:[NSDictionary class]] ||
                ![space[@"id64"] isKindOfClass:[NSNumber class]] ||
                ![space[@"type"] isKindOfClass:[NSNumber class]]) return nil;
            [spaces addObject:@{@"id": space[@"id64"], @"display": display[@"Display Identifier"],
                                @"type": space[@"type"], @"active": @([space[@"id64"] isEqual:current])}];
        }
    }
    return spaces;
}

static NSDictionary *currentSpaces(NSArray *spaces) {
    NSMutableDictionary *current = [NSMutableDictionary dictionary];
    for (NSDictionary *space in spaces) if ([space[@"active"] boolValue]) current[space[@"display"]] = space[@"id"];
    return current;
}

static NSArray *windowsOnSpace(uint64_t spaceID, uint32_t options) {
    if (!copyWindowsWithOptionsAndTags) return nil;
    uint64_t setTags = 0, clearTags = 0;
    CFArrayRef raw = copyWindowsWithOptionsAndTags(connection, 0, (__bridge CFArrayRef)@[@(spaceID)], options, &setTags, &clearTags);
    return raw ? CFBridgingRelease(raw) : nil;
}

// Tags, attributes and level straight from the window server query iterator.
static NSDictionary *queryWindow(uint32_t windowID) {
    if (!windowQueryWindows || !windowQueryResultCopyWindows || !windowIteratorAdvance ||
        !windowIteratorGetWindowID || !windowIteratorGetTags) return nil;
    CFTypeRef query = windowQueryWindows(connection, (__bridge CFArrayRef)@[@(windowID)], 1);
    if (!query) return nil;
    CFTypeRef iterator = windowQueryResultCopyWindows(query);
    NSDictionary *result = nil;
    while (iterator && windowIteratorAdvance(iterator)) {
        if (windowIteratorGetWindowID(iterator) != windowID) continue;
        uint64_t tags = windowIteratorGetTags(iterator);
        NSMutableDictionary *record = [@{@"tags_hex": hex64(tags), @"sticky_bit": @((tags & STICKY_TAG) ? 1 : 0)} mutableCopy];
        if (windowIteratorGetAttributes) record[@"attributes_hex"] = hex64(windowIteratorGetAttributes(iterator));
        if (windowIteratorGetLevel) record[@"query_level"] = @(windowIteratorGetLevel(iterator));
        result = record;
        break;
    }
    if (iterator) CFRelease(iterator);
    CFRelease(query);
    return result;
}

// CGWindowListCreateDescriptionFromArray returned no descriptions at all on the
// development host (macOS 26), so metadata comes from one full on/off-screen
// scan indexed by window number. kCGWindowIsOnscreen is only present when true.
static NSDictionary *windowInfoIndex(void) {
    NSArray *all = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID));
    NSMutableDictionary *index = [NSMutableDictionary dictionaryWithCapacity:all.count];
    for (NSDictionary *info in all) {
        NSNumber *number = info[(__bridge id)kCGWindowNumber];
        if ([number isKindOfClass:[NSNumber class]]) index[number] = info;
    }
    return index;
}

// Window number -> front-to-back position among on-screen windows (all levels).
static NSDictionary *onscreenOrder(void) {
    NSArray *onscreen = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
    NSMutableDictionary *order = [NSMutableDictionary dictionaryWithCapacity:onscreen.count];
    [onscreen enumerateObjectsUsingBlock:^(NSDictionary *info, NSUInteger index, BOOL *stop) {
        (void)stop;
        NSNumber *number = info[(__bridge id)kCGWindowNumber];
        if ([number isKindOfClass:[NSNumber class]]) order[number] = @(index);
    }];
    return order;
}

static NSDictionary *describeWindow(uint32_t windowID, NSArray *spaces, NSDictionary *hostingUp,
                                    NSDictionary *hostingParked, NSDictionary *infoIndex, NSDictionary *order) {
    NSMutableDictionary *record = [@{@"id": @(windowID)} mutableCopy];
    NSDictionary *info = infoIndex[@(windowID)];
    record[@"present"] = info ? @YES : @NO;
    if (info) {
        record[@"pid"] = info[(__bridge id)kCGWindowOwnerPID] ?: [NSNull null];
        record[@"layer"] = info[(__bridge id)kCGWindowLayer] ?: [NSNull null];
        record[@"alpha"] = info[(__bridge id)kCGWindowAlpha] ?: [NSNull null];
        record[@"onscreen"] = @([info[(__bridge id)kCGWindowIsOnscreen] boolValue]);
        CGRect bounds = CGRectNull;
        if ([info[(__bridge id)kCGWindowBounds] isKindOfClass:[NSDictionary class]] &&
            CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(__bridge id)kCGWindowBounds], &bounds)) {
            record[@"bounds"] = @{@"x": @(bounds.origin.x), @"y": @(bounds.origin.y),
                                  @"w": @(bounds.size.width), @"h": @(bounds.size.height)};
        }
    } else {
        record[@"onscreen"] = @NO;
    }
    record[@"onscreen_order"] = order[@(windowID)] ?: [NSNull null];
    NSArray *memberships = nil;
    if (copySpacesForWindows) {
        CFArrayRef raw = copySpacesForWindows(connection, 7, (__bridge CFArrayRef)@[@(windowID)]);
        if (raw) memberships = CFBridgingRelease(raw);
    }
    record[@"memberships"] = memberships ? (id)memberships : (id)[NSNull null];
    NSDictionary *query = queryWindow(windowID);
    record[@"tags_hex"] = query[@"tags_hex"] ?: [NSNull null];
    record[@"sticky_bit"] = query[@"sticky_bit"] ?: [NSNull null];
    record[@"attributes_hex"] = query[@"attributes_hex"] ?: [NSNull null];
    record[@"query_level"] = query[@"query_level"] ?: [NSNull null];
    NSMutableArray *hosting = [NSMutableArray arrayWithCapacity:spaces.count];
    for (NSDictionary *space in spaces) {
        NSArray *up = hostingUp[space[@"id"]], *parked = hostingParked[space[@"id"]];
        [hosting addObject:@{@"space_id": space[@"id"], @"active": space[@"active"],
                             @"up": up ? (id)@([up containsObject:@(windowID)]) : (id)[NSNull null],
                             @"including_parked": parked ? (id)@([parked containsObject:@(windowID)]) : (id)[NSNull null]}];
    }
    record[@"hosting"] = hosting;
    return record;
}

static NSDictionary *observation(NSArray *windowIDs) {
    NSArray *spaces = readSpaces();
    if (!spaces) return nil;
    NSMutableDictionary *hostingUp = [NSMutableDictionary dictionary], *hostingParked = [NSMutableDictionary dictionary];
    for (NSDictionary *space in spaces) {
        uint64_t spaceID = [space[@"id"] unsignedLongLongValue];
        NSArray *up = windowsOnSpace(spaceID, 0x2), *parked = windowsOnSpace(spaceID, 0x7);
        if (up) hostingUp[space[@"id"]] = up;
        if (parked) hostingParked[space[@"id"]] = parked;
    }
    NSDictionary *infoIndex = windowInfoIndex(), *order = onscreenOrder();
    NSMutableArray *windows = [NSMutableArray arrayWithCapacity:windowIDs.count];
    for (NSNumber *windowID in windowIDs)
        [windows addObject:describeWindow(windowID.unsignedIntValue, spaces, hostingUp, hostingParked, infoIndex, order)];
    return @{@"spaces": spaces, @"current": currentSpaces(spaces), @"windows": windows};
}

static int commandSession(void) {
    NSDictionary *session = CFBridgingRelease(CGSessionCopyCurrentDictionary());
    return emitJSON(stdout, @{
        @"gui_session": session ? @YES : @NO,
        @"on_console": @([session[(__bridge id)kCGSessionOnConsoleKey] boolValue]),
        @"login_done": @([session[(__bridge id)kCGSessionLoginDoneKey] boolValue]),
        @"locked": @([session[@"CGSSessionScreenIsLocked"] boolValue]),
    }, 0);
}

static int commandObserve(NSArray *windowIDs) {
    NSDictionary *result = observation(windowIDs);
    if (!result) return fail(@"query_failed", @"Could not read managed Spaces.");
    return emitJSON(stdout, result, 0);
}

static int commandCensus(uint64_t spaceID) {
    NSArray *spaces = readSpaces();
    if (!spaces) return fail(@"query_failed", @"Could not read managed Spaces.");
    BOOL known = NO;
    for (NSDictionary *space in spaces) if ([space[@"id"] unsignedLongLongValue] == spaceID) known = YES;
    if (!known) return fail(@"not_found", @"No managed Space has that native ID.");
    NSArray *up = windowsOnSpace(spaceID, 0x2), *parked = windowsOnSpace(spaceID, 0x7);
    if (!up || !parked) return fail(@"query_failed", @"Could not list the windows of that Space.");
    NSMutableArray *windows = [NSMutableArray arrayWithCapacity:parked.count];
    NSDictionary *infoIndex = windowInfoIndex();
    for (NSNumber *windowID in parked) {
        NSDictionary *info = infoIndex[windowID];
        [windows addObject:@{@"id": windowID, @"up": @([up containsObject:windowID]),
                             @"present": info ? @YES : @NO,
                             @"pid": info[(__bridge id)kCGWindowOwnerPID] ?: [NSNull null],
                             @"layer": info[(__bridge id)kCGWindowLayer] ?: [NSNull null],
                             @"onscreen": @([info[(__bridge id)kCGWindowIsOnscreen] boolValue])}];
    }
    return emitJSON(stdout, @{@"space_id": @(spaceID), @"up": up, @"including_parked": parked,
                              @"windows": windows, @"current": currentSpaces(spaces)}, 0);
}

static int unsupportedOperation(NSString *className) {
    return fail(@"unsupported", [NSString stringWithFormat:@"%@ is unavailable or its ABI changed.", className]);
}

// Dispatch an asynchronous window operation and report the window before and after.
static int performObserved(id operation, uint32_t windowID, NSDictionary *details) {
    if (!operation) return fail(@"operation_failed", @"Could not initialize the operation.");
    NSDictionary *before = observation(@[@(windowID)]);
    if (!before) return fail(@"query_failed", @"Could not observe the window before the operation.");
    performAsync(operation);
    serviceRunLoop(0.5);
    NSDictionary *after = observation(@[@(windowID)]);
    NSMutableDictionary *result = [@{@"dispatched": @YES, @"window_id": @(windowID), @"before": before[@"windows"][0],
                                     @"after": after ? after[@"windows"][0] : [NSNull null]} mutableCopy];
    [result addEntriesFromDictionary:details];
    return emitJSON(stdout, result, 0);
}

static int commandWindowsSpaces(NSString *className, NSString *label, uint32_t windowID, NSArray *spaceIDs) {
    SEL initialize = sel_registerName("initWithWindows:spaces:");
    Class cls = bridgedClass(className, initialize, @[@"@", @"@"], "v");
    if (!cls) return unsupportedOperation(className);
    id operation = ((id (*)(id, SEL, id, id))objc_msgSend)([cls alloc], initialize, @[@(windowID)], spaceIDs);
    return performObserved(operation, windowID, @{@"operation": label, @"space_ids": spaceIDs});
}

static int commandAddAndRemove(NSString *label, uint32_t windowID, uint64_t spaceID, uint32_t options) {
    NSString *className = @"SLSBridgedSpaceAddWindowsAndRemoveFromSpacesOperation";
    SEL initialize = sel_registerName("initWithSpaceID:windows:options:");
    Class cls = bridgedClass(className, initialize, @[@"Q", @"@", @"I"], "v");
    if (!cls) return unsupportedOperation(className);
    id operation = ((id (*)(id, SEL, uint64_t, id, uint32_t))objc_msgSend)([cls alloc], initialize, spaceID,
                                                                          @[@(windowID)], options);
    return performObserved(operation, windowID, @{@"operation": label, @"space_id": @(spaceID), @"options": @(options)});
}

static int commandAssign(pid_t pid, uint64_t spaceID, BOOL allSpaces) {
    NSString *className = allSpaces ? @"SLSBridgedProcessAssignToAllSpacesOperation" : @"SLSBridgedProcessAssignToSpaceOperation";
    SEL initialize = sel_registerName(allSpaces ? "initWithProcess:" : "initWithProcess:spaceID:");
    Class cls = bridgedClass(className, initialize, allSpaces ? @[@"i"] : @[@"i", @"Q"], "v");
    if (!cls) return unsupportedOperation(className);
    id operation = allSpaces ? ((id (*)(id, SEL, int))objc_msgSend)([cls alloc], initialize, pid)
                             : ((id (*)(id, SEL, int, uint64_t))objc_msgSend)([cls alloc], initialize, pid, spaceID);
    if (!operation) return fail(@"operation_failed", @"Could not initialize the operation.");
    performAsync(operation);
    serviceRunLoop(0.5);
    NSMutableDictionary *result = [@{@"operation": allSpaces ? @"assign-all" : @"assign", @"dispatched": @YES,
                                     @"pid": @(pid)} mutableCopy];
    if (!allSpaces) result[@"space_id"] = @(spaceID);
    return emitJSON(stdout, result, 0);
}

static SEL spaceIDInitializer(void) {
    return sel_registerName("initWithSpaceID:");
}

static Class copyValuesClass(void) {
    return bridgedClass(@"SLSBridgedSpaceCopyValuesOperation", spaceIDInitializer(), @[@"Q"], "@");
}

// The bridge's values for a Space, or nil once it no longer exists. Callers check
// copyValuesClass() first and see non-nil values for a live Space before relying
// on nil as "gone".
static NSDictionary *spaceValues(uint64_t spaceID) {
    id operation = ((id (*)(id, SEL, uint64_t))objc_msgSend)([copyValuesClass() alloc], spaceIDInitializer(), spaceID);
    id result = operation ? performSync(operation) : nil;
    SEL getter = sel_registerName("propertyListDictionary");
    id values = [result respondsToSelector:getter] ? ((id (*)(id, SEL))objc_msgSend)(result, getter) : nil;
    return [values isKindOfClass:[NSDictionary class]] ? values : nil;
}

static BOOL isManaged(uint64_t spaceID, NSArray *spaces) {
    for (NSDictionary *space in spaces) if ([space[@"id"] unsignedLongLongValue] == spaceID) return YES;
    return NO;
}

static BOOL isOverlay(uint64_t spaceID, NSArray *spaces) {
    NSDictionary *values = spaceValues(spaceID);
    return !isManaged(spaceID, spaces) && [values[@"type"] isEqual:@(UNMANAGED_SPACE_TYPE)] && !values[@"ManagedSpaceID"];
}

static int commandOverlayCreate(int level) {
    SEL createInit = sel_registerName("initWithOptions:values:"), levelInit = sel_registerName("initWithSpaceID:level:"),
        showInit = sel_registerName("initWithSpaces:"), spaceIDGetter = sel_registerName("spaceID");
    Class create = bridgedClass(@"SLSBridgedSpaceCreateOperation", createInit, @[@"I", @"@"], "@");
    Class setLevel = bridgedClass(@"SLSBridgedSpaceSetAbsoluteLevelOperation", levelInit, @[@"Q", @"i"], "v");
    Class show = bridgedClass(@"SLSBridgedShowSpacesOperation", showInit, @[@"@"], "v");
    if (!create || !setLevel || !show || !copyValuesClass())
        return fail(@"unsupported", @"The overlay operations are unavailable or their ABI changed.");
    id operation = ((id (*)(id, SEL, uint32_t, id))objc_msgSend)([create alloc], createInit, CREATE_UNMANAGED, @{});
    id result = operation ? performSync(operation) : nil;
    uint64_t overlay = [result respondsToSelector:spaceIDGetter] ? ((uint64_t (*)(id, SEL))objc_msgSend)(result, spaceIDGetter) : 0;
    if (!overlay) return fail(@"operation_failed", @"The bridge did not return a Space ID.");
    NSArray *spaces = readSpaces();
    if (!spaces || !isOverlay(overlay, spaces))
        return emitJSON(stderr, @{@"error": @{@"code": @"unexpected_space", @"space_id": @(overlay),
                                              @"message": @"The created Space is not an unmanaged overlay; clean it up by ID."}}, 1);
    performAsync(((id (*)(id, SEL, uint64_t, int))objc_msgSend)([setLevel alloc], levelInit, overlay, level));
    performAsync(((id (*)(id, SEL, id))objc_msgSend)([show alloc], showInit, @[@(overlay)]));
    serviceRunLoop(0.3);
    return emitJSON(stdout, @{@"operation": @"overlay-create", @"overlay_id": @(overlay), @"level": @(level),
                              @"values": spaceValues(overlay) ?: (id)[NSNull null]}, 0);
}

static int commandOverlayDestroy(uint64_t overlay) {
    SEL hideInit = sel_registerName("initWithSpaces:");
    Class hide = bridgedClass(@"SLSBridgedHideSpacesOperation", hideInit, @[@"@"], "v");
    Class destroy = bridgedClass(@"SLSBridgedSpaceDestroyOperation", spaceIDInitializer(), @[@"Q"], "v");
    if (!hide || !destroy || !copyValuesClass())
        return fail(@"unsupported", @"The overlay operations are unavailable or their ABI changed.");
    NSArray *spaces = readSpaces();
    if (!spaces) return fail(@"query_failed", @"Could not read managed Spaces.");
    if (!isOverlay(overlay, spaces))
        return fail(@"refused", @"Not an unmanaged overlay Space; managed Spaces are never destroyed here.");
    performAsync(((id (*)(id, SEL, id))objc_msgSend)([hide alloc], hideInit, @[@(overlay)]));
    performAsync(((id (*)(id, SEL, uint64_t))objc_msgSend)([destroy alloc], spaceIDInitializer(), overlay));
    for (int attempt = 0; attempt < 20; attempt++) {
        serviceRunLoop(0.1);
        if (!spaceValues(overlay))
            return emitJSON(stdout, @{@"operation": @"overlay-destroy", @"overlay_id": @(overlay), @"destroyed": @YES}, 0);
    }
    return fail(@"not_confirmed", @"The overlay Space still exists after 2 seconds.");
}

static int commandTag(uint32_t windowID, BOOL on) {
    if (!setWindowTags || !clearWindowTags) return fail(@"unsupported", @"SLSSetWindowTags/SLSClearWindowTags are unavailable.");
    NSDictionary *before = queryWindow(windowID);
    if (!before) return fail(@"query_failed", @"Could not read the window's tags before writing.");
    uint64_t tags = STICKY_TAG;
    CGError status = on ? setWindowTags(connection, windowID, &tags, 64) : clearWindowTags(connection, windowID, &tags, 64);
    serviceRunLoop(0.2);
    NSDictionary *after = queryWindow(windowID);
    return emitJSON(stdout, @{@"operation": @"tag", @"mode": on ? @"on" : @"off", @"window_id": @(windowID),
                              @"tag_hex": hex64(STICKY_TAG), @"cg_error": @(status),
                              @"before": before, @"after": after ? (id)after : (id)[NSNull null]}, 0);
}

static int usage(void) {
    return fail(@"usage", @"Usage: sticky-probe session | observe WINDOW_ID... | census SPACE_ID | "
                          @"add WINDOW_ID SPACE_ID... | remove WINDOW_ID SPACE_ID... | tag WINDOW_ID on|off | "
                          @"join WINDOW_ID SPACE_ID | place WINDOW_ID SPACE_ID | assign PID SPACE_ID|0 | "
                          @"assign-all PID | overlay create LEVEL | overlay destroy SPACE_ID");
}

static int run(int argc, const char *argv[]) {
    if (argc < 2) return usage();
    const char *command = argv[1];
    BOOL session = !strcmp(command, "session") && argc == 2;
    BOOL observe = !strcmp(command, "observe") && argc >= 3;
    BOOL census = !strcmp(command, "census") && argc == 3;
    BOOL add = !strcmp(command, "add") && argc >= 4;
    BOOL remove = !strcmp(command, "remove") && argc >= 4;
    BOOL tag = !strcmp(command, "tag") && argc == 4;
    BOOL join = !strcmp(command, "join") && argc == 4;
    BOOL place = !strcmp(command, "place") && argc == 4;
    BOOL assign = !strcmp(command, "assign") && argc == 4;
    BOOL assignAll = !strcmp(command, "assign-all") && argc == 3;
    BOOL overlay = !strcmp(command, "overlay") && argc == 4;
    BOOL overlayCreate = overlay && !strcmp(argv[2], "create");
    BOOL overlayDestroy = overlay && !strcmp(argv[2], "destroy");
    if (!session && !observe && !census && !add && !remove && !tag && !join && !place && !assign && !assignAll &&
        !overlayCreate && !overlayDestroy) return usage();
    if (session) return commandSession();

    NSMutableArray *windowIDs = [NSMutableArray array];
    NSMutableArray *spaceIDs = [NSMutableArray array];
    unsigned long long value = 0, pid = 0, level = 0;
    if (observe) {
        for (int i = 2; i < argc; ++i) {
            if (!parseUnsigned(argv[i], UINT32_MAX, &value)) return fail(@"invalid_id", @"Window IDs must be positive decimal uint32 values.");
            [windowIDs addObject:@((uint32_t)value)];
        }
    } else if (census) {
        if (!parseUnsigned(argv[2], UINT64_MAX, &value)) return fail(@"invalid_id", @"Space ID must be a positive decimal uint64 value.");
        [spaceIDs addObject:@((uint64_t)value)];
    } else if (assign || assignAll) {
        if (!parseUnsigned(argv[2], INT32_MAX, &pid)) return fail(@"invalid_id", @"PID must be a positive decimal int32 value.");
        if (assign) {
            BOOL clear = !strcmp(argv[3], "0");
            if (!clear && !parseUnsigned(argv[3], UINT64_MAX, &value))
                return fail(@"invalid_id", @"Space ID must be 0 or a positive decimal uint64 value.");
            [spaceIDs addObject:@(clear ? 0 : (uint64_t)value)];
        }
    } else if (overlayCreate) {
        if (strcmp(argv[3], "0") && !parseUnsigned(argv[3], INT32_MAX, &level))
            return fail(@"invalid_level", @"Level must be a non-negative decimal int32 value.");
    } else if (overlayDestroy) {
        if (!parseUnsigned(argv[3], UINT64_MAX, &value)) return fail(@"invalid_id", @"Space ID must be a positive decimal uint64 value.");
        [spaceIDs addObject:@((uint64_t)value)];
    } else {
        if (!parseUnsigned(argv[2], UINT32_MAX, &value)) return fail(@"invalid_id", @"Window ID must be a positive decimal uint32 value.");
        [windowIDs addObject:@((uint32_t)value)];
        if (tag) {
            if (strcmp(argv[3], "on") && strcmp(argv[3], "off")) return usage();
        } else {
            for (int i = 3; i < argc; ++i) {
                if (!parseUnsigned(argv[i], UINT64_MAX, &value)) return fail(@"invalid_id", @"Space IDs must be positive decimal uint64 values.");
                [spaceIDs addObject:@((uint64_t)value)];
            }
        }
    }

    // The verified initialization order: AppKit first, then SkyLight/WMBridge.
    if (!NSApplicationLoad()) return fail(@"initialization_failed", @"AppKit could not initialize.");
    [NSApplication sharedApplication];
    if (!loadSkyLight()) return fail(@"unsupported", @"SkyLight census APIs are unavailable.");

    if (observe) return commandObserve(windowIDs);
    if (census) return commandCensus([spaceIDs[0] unsignedLongLongValue]);
    if (tag) return commandTag([windowIDs[0] unsignedIntValue], !strcmp(argv[3], "on"));
    if (add) return commandWindowsSpaces(@"SLSBridgedAddWindowsToSpacesOperation", @"add", [windowIDs[0] unsignedIntValue], spaceIDs);
    if (remove) return commandWindowsSpaces(@"SLSBridgedRemoveWindowsFromSpacesOperation", @"remove", [windowIDs[0] unsignedIntValue], spaceIDs);
    if (join || place)
        return commandAddAndRemove(join ? @"join" : @"place", [windowIDs[0] unsignedIntValue], [spaceIDs[0] unsignedLongLongValue],
                                   join ? ADD_KEEP_OTHERS : ADD_LEAVE_OTHERS);
    if (assign || assignAll) return commandAssign((pid_t)pid, assign ? [spaceIDs[0] unsignedLongLongValue] : 0, assignAll);
    if (overlayCreate) return commandOverlayCreate((int)level);
    return commandOverlayDestroy([spaceIDs[0] unsignedLongLongValue]);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        @try { return run(argc, argv); }
        @catch (NSException *exception) {
            return fail(@"native_exception", exception.reason ?: exception.name);
        }
    }
}
