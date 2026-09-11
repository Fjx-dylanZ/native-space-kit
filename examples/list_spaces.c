/* Pure C consumer of include/native_space_kit.h: initialize, report runtime
 * capabilities, and print every managed Space. Read-only; nothing is mutated.
 *
 * Build:  make example        (or: xcrun clang -std=c11 -Iinclude examples/list_spaces.c
 *                               build/libnative-space-kit.a -ObjC -lobjc -framework Cocoa)
 * Run:    build/list-spaces
 */

#include <CoreFoundation/CoreFoundation.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>

#include "native_space_kit.h"

static int fail(const char *step, const nsk_error *error) {
    fprintf(stderr, "%s failed: %s: %s", step, nsk_status_name(error->status), error->message);
    if (error->space_id) fprintf(stderr, " (space %" PRIu64 ")", error->space_id);
    if (error->request_may_have_applied) fputs(" [a native write may have applied]", stderr);
    fputc('\n', stderr);
    return EXIT_FAILURE;
}

static uint64_t number(CFDictionaryRef record, const char *key) {
    CFStringRef name = CFStringCreateWithCStringNoCopy(NULL, key, kCFStringEncodingUTF8, kCFAllocatorNull);
    CFNumberRef value = CFDictionaryGetValue(record, name);
    CFRelease(name);
    int64_t out = 0;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue(value, kCFNumberSInt64Type, &out);
    return (uint64_t)out;
}

static bool flag(CFDictionaryRef record, const char *key) {
    CFStringRef name = CFStringCreateWithCStringNoCopy(NULL, key, kCFStringEncodingUTF8, kCFAllocatorNull);
    CFBooleanRef value = CFDictionaryGetValue(record, name);
    CFRelease(name);
    return value && CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue(value);
}

/* Copies the string value into buffer; empty when missing or not representable. */
static void text(CFDictionaryRef record, const char *key, char *buffer, size_t size) {
    CFStringRef name = CFStringCreateWithCStringNoCopy(NULL, key, kCFStringEncodingUTF8, kCFAllocatorNull);
    CFStringRef value = CFDictionaryGetValue(record, name);
    CFRelease(name);
    if (!value || CFGetTypeID(value) != CFStringGetTypeID() ||
        !CFStringGetCString(value, buffer, (CFIndex)size, kCFStringEncodingUTF8)) {
        buffer[0] = '\0';
    }
}

int main(void) {
    nsk_error error;
    nsk_error_clear(&error);

    if (nsk_initialize(&error) != NSK_OK) return fail("nsk_initialize", &error);

    nsk_capabilities caps;
    if (nsk_get_capabilities(&caps, &error) != NSK_OK) return fail("nsk_get_capabilities", &error);
    printf("native-space-kit %s: query=%d window_query=%d create=%d destroy=%d activate=%d move_window=%d reorder=%d\n",
           NSK_VERSION, caps.space_query, caps.window_query, caps.create_space, caps.destroy_space,
           caps.activate_space, caps.move_window, caps.reorder_spaces);

    CFArrayRef spaces = NULL;
    if (nsk_copy_spaces(&spaces, &error) != NSK_OK) return fail("nsk_copy_spaces", &error);

    printf("%-5s %-5s %-6s %-4s %-6s %-20s %s\n", "index", "local", "active", "type", "id", "display", "uuid");
    CFIndex count = CFArrayGetCount(spaces);
    for (CFIndex i = 0; i < count; ++i) {
        CFDictionaryRef record = CFArrayGetValueAtIndex(spaces, i);
        char display[128], uuid[64];
        text(record, "display", display, sizeof display);
        text(record, "uuid", uuid, sizeof uuid);
        printf("%-5" PRIu64 " %-5" PRIu64 " %-6s %-4" PRIu64 " %-6" PRIu64 " %-20.20s %s\n",
               number(record, "index"), number(record, "display_index"), flag(record, "active") ? "*" : "",
               number(record, "type"), number(record, "id"), display, uuid);
    }
    CFRelease(spaces);
    return EXIT_SUCCESS;
}
