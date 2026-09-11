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
//       Per window: CG description (pid, layer, alpha, bounds, onscreen),
//       native Space memberships (SLSCopySpacesForWindows selector 7), window
//       tags (SLSWindowQuery iterator) with bit 0x800 decoded as sticky_bit,
//       and a per-Space "hosting" table: whether the compositor lists the
//       window for that Space with options 0x2 ("up") and 0x7
//       ("including_parked"), the same census yabai uses.
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
//
// A write reports "dispatched" (the operation was submitted) plus the
// observation taken after briefly servicing the run loop. Dispatch is not
// application: the Python experiment decides applied / not_applied /
// inconclusive from stable compositor visibility, membership and tags.

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
        fputs("{\"error\":\"serialization_failed\"}\n", stderr);
        return 1;
    }
    fwrite(data.bytes, 1, data.length, stream);
    fputc('\n', stream);
    fflush(stream);
    return status;
}

static int fail(NSString *code, NSString *message) {
    return emitJSON(stderr, @{@"error": code, @"message": message}, 1);
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

static BOOL methodMatches(Class cls, SEL selector, const char *result, const char *argument2, const char *argument3) {
    if (!cls) return NO;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    NSUInteger count = 2 + (argument2 != NULL) + (argument3 != NULL);
    return signature.numberOfArguments == count && strcmp(signature.methodReturnType, result) == 0 &&
           (!argument2 || strcmp([signature getArgumentTypeAtIndex:2], argument2) == 0) &&
           (!argument3 || strcmp([signature getArgumentTypeAtIndex:3], argument3) == 0);
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

static NSDictionary *describeWindow(uint32_t windowID, NSArray *spaces, NSDictionary *hostingUp,
                                    NSDictionary *hostingParked, NSDictionary *infoIndex) {
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
    NSDictionary *infoIndex = windowInfoIndex();
    NSMutableArray *windows = [NSMutableArray arrayWithCapacity:windowIDs.count];
    for (NSNumber *windowID in windowIDs)
        [windows addObject:describeWindow(windowID.unsignedIntValue, spaces, hostingUp, hostingParked, infoIndex)];
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

static int commandWindowsSpaces(NSString *className, NSString *label, uint32_t windowID, NSArray *spaceIDs) {
    Class cls = NSClassFromString(className);
    SEL initialize = sel_registerName("initWithWindows:spaces:");
    SEL perform = sel_registerName("performWithWMBridgeDelegate");
    if (!methodMatches(cls, initialize, "@", "@", "@") || !methodMatches(cls, perform, "v", NULL, NULL))
        return fail(@"unsupported", [NSString stringWithFormat:@"%@ is unavailable or its ABI changed.", className]);
    NSDictionary *before = observation(@[@(windowID)]);
    if (!before) return fail(@"query_failed", @"Could not observe the window before the operation.");
    id operation = ((id (*)(id, SEL, id, id))objc_msgSend)([cls alloc], initialize, @[@(windowID)], spaceIDs);
    if (!operation) return fail(@"operation_failed", @"Could not initialize the operation.");
    ((void (*)(id, SEL))objc_msgSend)(operation, perform);
    serviceRunLoop(0.5);
    NSDictionary *after = observation(@[@(windowID)]);
    return emitJSON(stdout, @{@"operation": label, @"dispatched": @YES, @"window_id": @(windowID), @"space_ids": spaceIDs,
                              @"before": before[@"windows"][0], @"after": after ? after[@"windows"][0] : [NSNull null]}, 0);
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
                          @"add WINDOW_ID SPACE_ID... | remove WINDOW_ID SPACE_ID... | tag WINDOW_ID on|off");
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
    if (!session && !observe && !census && !add && !remove && !tag) return usage();
    if (session) return commandSession();

    NSMutableArray *windowIDs = [NSMutableArray array];
    NSMutableArray *spaceIDs = [NSMutableArray array];
    unsigned long long value = 0;
    if (observe) {
        for (int i = 2; i < argc; ++i) {
            if (!parseUnsigned(argv[i], UINT32_MAX, &value)) return fail(@"invalid_id", @"Window IDs must be positive decimal uint32 values.");
            [windowIDs addObject:@((uint32_t)value)];
        }
    } else if (census) {
        if (!parseUnsigned(argv[2], UINT64_MAX, &value)) return fail(@"invalid_id", @"Space ID must be a positive decimal uint64 value.");
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
    return commandWindowsSpaces(@"SLSBridgedRemoveWindowsFromSpacesOperation", @"remove", [windowIDs[0] unsignedIntValue], spaceIDs);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        @try { return run(argc, argv); }
        @catch (NSException *exception) {
            return fail(@"native_exception", exception.reason ?: exception.name);
        }
    }
}
