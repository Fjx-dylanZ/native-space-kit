// Disposable Cocoa fixture windows for native-space-kit live probes.
//
// Build: xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Cocoa \
//            probes/window_fixture.m -o build/window-fixture
//
// The process owns a few ordinary titled windows (window level 0) on the
// current Space of the main screen and never activates itself, so it does not
// steal focus. It speaks a line protocol: one JSON object per line on stdout,
// one command per line on stdin.
//
//   {"event":"ready","pid":N,"windows":[...]}    emitted once after the windows
//                                                are ordered in
//   frames                 -> {"event":"frames","windows":[...]}
//   sticky INDEX on|off    -> {"event":"sticky",...}  owner-side positive control:
//                             toggles NSWindowCollectionBehaviorCanJoinAllSpaces
//   quit                   -> {"event":"quit"} then exit 0
//
// EOF on stdin terminates the process, so a crashed runner never leaks windows.
// Frames are AppKit screen coordinates (origin bottom-left) and are compared
// only against other fixture reports, never against CoreGraphics bounds.

#import <Cocoa/Cocoa.h>
#include <string.h>
#include <unistd.h>

static NSArray<NSWindow *> *fixtureWindows;

static void emit(NSDictionary *object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:NULL];
    if (!data) {
        fputs("{\"event\":\"error\",\"message\":\"serialization failed\"}\n", stdout);
    } else {
        fwrite(data.bytes, 1, data.length, stdout);
        fputc('\n', stdout);
    }
    fflush(stdout);
}

static NSDictionary *describeWindow(NSUInteger index, NSWindow *window) {
    NSRect frame = window.frame;
    return @{
        @"index": @(index),
        @"id": @(window.windowNumber),
        @"title": window.title ?: @"",
        @"frame": @{@"x": @(frame.origin.x), @"y": @(frame.origin.y),
                    @"w": @(frame.size.width), @"h": @(frame.size.height)},
        @"visible": @(window.isVisible),
        @"on_active_space": @(window.isOnActiveSpace),
        @"occlusion_visible": (window.occlusionState & NSWindowOcclusionStateVisible) ? @YES : @NO,
        @"can_join_all_spaces": (window.collectionBehavior & NSWindowCollectionBehaviorCanJoinAllSpaces) ? @YES : @NO,
        @"collection_behavior": @((unsigned long long)window.collectionBehavior),
    };
}

static NSArray *describeAll(void) {
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:fixtureWindows.count];
    [fixtureWindows enumerateObjectsUsingBlock:^(NSWindow *window, NSUInteger index, BOOL *stop) {
        (void)stop;
        [result addObject:describeWindow(index, window)];
    }];
    return result;
}

static void quit(void) {
    emit(@{@"event": @"quit", @"windows": describeAll()});
    for (NSWindow *window in fixtureWindows) [window close];
    fixtureWindows = nil;
    [NSApp terminate:nil];
}

static void handleCommand(NSString *line) {
    NSArray<NSString *> *words = [[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                                  componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSMutableArray<NSString *> *arguments = [NSMutableArray array];
    for (NSString *word in words) if (word.length) [arguments addObject:word];
    if (arguments.count == 0) return;
    NSString *command = arguments[0];
    if ([command isEqualToString:@"frames"]) {
        emit(@{@"event": @"frames", @"windows": describeAll()});
        return;
    }
    if ([command isEqualToString:@"quit"]) {
        quit();
        return;
    }
    if ([command isEqualToString:@"sticky"]) {
        BOOL on = arguments.count == 3 && [arguments[2] isEqualToString:@"on"];
        BOOL off = arguments.count == 3 && [arguments[2] isEqualToString:@"off"];
        NSInteger index = arguments.count == 3 ? arguments[1].integerValue : -1;
        if ((!on && !off) || index < 0 || (NSUInteger)index >= fixtureWindows.count ||
            ![arguments[1] isEqualToString:[NSString stringWithFormat:@"%ld", (long)index]]) {
            emit(@{@"event": @"error", @"message": @"usage: sticky INDEX on|off"});
            return;
        }
        NSWindow *window = fixtureWindows[(NSUInteger)index];
        NSWindowCollectionBehavior behavior = window.collectionBehavior;
        if (on) behavior |= NSWindowCollectionBehaviorCanJoinAllSpaces;
        else behavior &= ~NSWindowCollectionBehaviorCanJoinAllSpaces;
        window.collectionBehavior = behavior;
        emit(@{@"event": @"sticky", @"window": describeWindow((NSUInteger)index, window)});
        return;
    }
    emit(@{@"event": @"error", @"message": [NSString stringWithFormat:@"unknown command: %@", command]});
}

static void installStandardInputReader(void) {
    NSFileHandle *input = NSFileHandle.fileHandleWithStandardInput;
    NSMutableData *pending = [NSMutableData data];
    input.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *chunk = handle.availableData;
        if (chunk.length == 0) {
            handle.readabilityHandler = nil;
            dispatch_async(dispatch_get_main_queue(), ^{ quit(); });
            return;
        }
        [pending appendData:chunk];
        for (;;) {
            NSRange newline = [pending rangeOfData:[NSData dataWithBytes:"\n" length:1]
                                           options:0
                                             range:NSMakeRange(0, pending.length)];
            if (newline.location == NSNotFound) break;
            NSString *line = [[NSString alloc] initWithData:[pending subdataWithRange:NSMakeRange(0, newline.location)]
                                                   encoding:NSUTF8StringEncoding] ?: @"";
            [pending replaceBytesInRange:NSMakeRange(0, newline.location + 1) withBytes:NULL length:0];
            dispatch_async(dispatch_get_main_queue(), ^{ handleCommand(line); });
        }
    };
}

static NSUInteger parseCount(const char *text) {
    if (!text || !*text) return 0;
    NSUInteger value = 0;
    for (const char *p = text; *p; ++p) {
        if (*p < '0' || *p > '9' || value > 6) return 0;
        value = value * 10 + (NSUInteger)(*p - '0');
    }
    return value >= 1 && value <= 6 ? value : 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSUInteger count = 2;
        NSString *title = @"nsk probe fixture";
        for (int i = 1; i < argc; ++i) {
            if (!strcmp(argv[i], "--count") && i + 1 < argc) {
                count = parseCount(argv[++i]);
                if (!count) {
                    fputs("window-fixture: --count expects 1..6\n", stderr);
                    return 2;
                }
            } else if (!strcmp(argv[i], "--title") && i + 1 < argc) {
                title = [NSString stringWithUTF8String:argv[++i]] ?: title;
            } else {
                fprintf(stderr, "usage: %s [--count 1..6] [--title PREFIX]\n", argv[0]);
                return 2;
            }
        }
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
        if (!screen) {
            fputs("{\"event\":\"error\",\"message\":\"no screen available\"}\n", stdout);
            return 1;
        }
        NSRect area = screen.visibleFrame;
        CGFloat width = MIN(480.0, area.size.width / 2.0 - 40.0);
        CGFloat height = MIN(332.0, area.size.height / 2.0 - 40.0);
        NSMutableArray<NSWindow *> *windows = [NSMutableArray arrayWithCapacity:count];
        for (NSUInteger i = 0; i < count; ++i) {
            CGFloat column = (CGFloat)(i % 2), row = (CGFloat)(i / 2);
            NSRect frame = NSMakeRect(area.origin.x + 120.0 + column * (width + 60.0),
                                      area.origin.y + area.size.height - 120.0 - (row + 1.0) * (height + 40.0),
                                      width, height);
            NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                           styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                                      NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                                                             backing:NSBackingStoreBuffered
                                                               defer:NO];
            window.releasedWhenClosed = NO;
            window.restorable = NO;
            window.excludedFromWindowsMenu = YES;
            window.title = [NSString stringWithFormat:@"%@ %lu", title, (unsigned long)i];
            window.backgroundColor = i % 2 ? NSColor.systemOrangeColor : NSColor.systemTealColor;
            NSTextField *label = [NSTextField labelWithString:[NSString stringWithFormat:@"%@ #%lu\nwindow id %ld\npid %d",
                                                              title, (unsigned long)i, (long)window.windowNumber, getpid()]];
            label.alignment = NSTextAlignmentCenter;
            label.frame = window.contentView.bounds;
            label.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            [window.contentView addSubview:label];
            [window orderFrontRegardless];
            [windows addObject:window];
        }
        fixtureWindows = windows;
        installStandardInputReader();
        // Let the window server order the windows in before reporting them.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            emit(@{@"event": @"ready", @"pid": @(getpid()), @"windows": describeAll()});
        });
        [NSApp run];
    }
    return 0;
}
