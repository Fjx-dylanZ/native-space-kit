// Pure model checks: no GUI initialization, window-server queries, or native writes.
// Include the implementation to exercise the private guard without expanding the C API.
#import "../src/native_space_kit.m"
#include <assert.h>

static NSArray *census;

static CFArrayRef copy_census(int connection) {
    (void)connection;
    return census ? CFBridgingRetain(census) : NULL;
}

static NSMutableDictionary *fullscreen(void) {
    return [@{@"id64": @10, @"type": @4, @"fs_wid": @100,
              @"TileLayoutManager": @{@"TileSpaces": @[@{@"fs_wid": @100, @"TileWindowID": @100}]}}
            mutableCopy];
}

int main(void) {
    @autoreleasepool {
        NSMutableDictionary *space = fullscreen();
        assert(fullscreen_guest(space, 200)); // Siri shares another app's fullscreen Space.
        assert(!fullscreen_guest(space, 100)); // Never detach the fullscreen owner.
        assert(!fullscreen_guest(nil, 200));
        assert(!fullscreen_guest((id)@[], 200));

        for (id type in @[@0, @3, @5, @6, @"4", @4.0, [NSNull null]]) {
            space[@"type"] = type;
            assert(!fullscreen_guest(space, 200));
        }
        space = fullscreen();
        for (id owner in @[@0, @-1, @((uint64_t)UINT32_MAX + 1), @"100", @100.0, @YES, [NSNull null]]) {
            space[@"fs_wid"] = owner;
            assert(!fullscreen_guest(space, 200));
        }
        space = fullscreen();
        [space removeObjectForKey:@"fs_wid"];
        assert(!fullscreen_guest(space, 200));
        for (id layout in @[@{}, @[], [NSNull null]]) {
            space = fullscreen();
            space[@"TileLayoutManager"] = layout;
            assert(!fullscreen_guest(space, 200));
        }
        for (id tiles in @[@[], @{}, @[@100], @[@{}],
                           @[@{@"fs_wid": @100, @"TileWindowID": @200}],
                           @[@{@"fs_wid": @200, @"TileWindowID": @100}],
                           @[@{@"fs_wid": @100.0, @"TileWindowID": @100}],
                           @[@{@"fs_wid": @100, @"TileWindowID": @100.0}],
                           @[@{@"fs_wid": @100, @"TileWindowID": @100},
                             @{@"fs_wid": @200, @"TileWindowID": @200}]]) {
            space = fullscreen();
            space[@"TileLayoutManager"] = @{@"TileSpaces": tiles};
            assert(!fullscreen_guest(space, 200)); // Incomplete, conflicting, or Split View owners.
        }

        // Re-read the native owner metadata, on the same display as the source snapshot.
        g_copyManagedSpaces = copy_census;
        NSDictionary *source = @{@"id": @10, @"type": @4, @"display": @"test"};
        census = @[@{@"Display Identifier": @"test", @"Spaces": @[fullscreen()]}];
        assert(can_leave_fullscreen(source, 200));
        assert(!can_leave_fullscreen(source, 100));
        assert(!can_leave_fullscreen(nil, 200));
        assert(!can_leave_fullscreen(@{@"id": @10, @"type": @0}, 200));
        assert(!can_leave_fullscreen(@{@"id": @11, @"type": @4, @"display": @"test"}, 200));
        assert(!can_leave_fullscreen(@{@"id": @10, @"type": @4, @"display": @"other"}, 200));
        for (id spaces in @[@[], @[@{}], @[@100], @[@{@"id64": @10, @"type": @0}], [NSNull null]]) {
            census = @[@{@"Display Identifier": @"test", @"Spaces": spaces}];
            assert(!can_leave_fullscreen(source, 200));
        }
        census = nil;
        assert(!can_leave_fullscreen(source, 200));
        puts("window_source_test: ok");
    }
    return 0;
}
