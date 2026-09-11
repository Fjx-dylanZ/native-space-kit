// nsk: thin JSON front end for include/native_space_kit.h.
//
// Arguments are validated before nsk_initialize runs, every operation goes
// through the public C API, and the only private-API knowledge lives in the
// library. Success prints one JSON object on stdout; failure prints one JSON
// object on stderr and exits 2 for argument errors, 1 otherwise.

#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>
#include <sys/sysctl.h>
#include "native_space_kit.h"

enum { EXIT_OPERATION_FAILED = 1, EXIT_USAGE = 2 };

typedef enum {
    CMD_VERSION,
    CMD_HELP,
    CMD_CAPABILITIES,
    CMD_LIST,
    CMD_CREATE,
    CMD_ACTIVATE,
    CMD_DESTROY,
    CMD_WINDOW_SPACES,
    CMD_MOVE_WINDOW,
    CMD_MOVE,
    CMD_SWAP
} nsk_command;

typedef struct {
    nsk_command command;
    nsk_space_id space[2];
    nsk_window_id window;
    uint32_t destroy_options;
} nsk_request;

static const struct {
    const char *name;
    nsk_command command;
    int positionals;
} commands[] = {
    {"--version", CMD_VERSION, 0},
    {"--help", CMD_HELP, 0},
    {"-h", CMD_HELP, 0},
    {"help", CMD_HELP, 0},
    {"capabilities", CMD_CAPABILITIES, 0},
    {"list", CMD_LIST, 0},
    {"create", CMD_CREATE, 0},
    {"activate", CMD_ACTIVATE, 1},
    {"destroy", CMD_DESTROY, 1},
    {"window-spaces", CMD_WINDOW_SPACES, 1},
    {"move-window", CMD_MOVE_WINDOW, 2},
    {"move", CMD_MOVE, 2},
    {"swap", CMD_SWAP, 2},
};

static const char usage[] =
    "Usage: nsk COMMAND [ARGS]\n"
    "\n"
    "  nsk --version                        {\"version\": \"" NSK_VERSION "\"}\n"
    "  nsk capabilities                     runtime entry-point availability and OS build\n"
    "  nsk list                             every managed Space on every display\n"
    "  nsk create                           create an ordinary Desktop; returns its record\n"
    "  nsk activate ID                      make ID the current Space on its display\n"
    "  nsk destroy ID [--migrate]           remove an inactive, non-last, ordinary Desktop\n"
    "  nsk window-spaces WINDOW_ID          native Space IDs that contain a window\n"
    "  nsk move-window WINDOW_ID SPACE_ID   move an ordinary window to an ordinary Desktop\n"
    "  nsk move SOURCE_ID TARGET_ID         place SOURCE at TARGET's original position\n"
    "  nsk swap ID_A ID_B                   exchange two positions (two moves; not atomic)\n"
    "\n"
    "IDs are native Space IDs from `list`/`create` (never Desktop numbers) and CGWindow\n"
    "IDs, written as plain decimal digits: no sign, whitespace, zero, or overflow.\n"
    "destroy refuses active, last, non-Desktop, and populated targets; --migrate lets\n"
    "macOS migrate application windows to the active Desktop instead of refusing.\n"
    "\n"
    "Success: one JSON object on stdout, exit 0. Failure: {\"error\":{code,message,\n"
    "space_id?,window_id?,request_may_have_applied}} on stderr; exit 2 when arguments\n"
    "are rejected before anything initializes, 1 otherwise. If a native write may\n"
    "already have applied, observed_spaces carries a fresh snapshot when one is\n"
    "available; inspect it before retrying.\n";

static bool parse_decimal(const char *text, uint64_t limit, uint64_t *out) {
    if (!*text) return false;
    uint64_t value = 0;
    for (const char *p = text; *p; ++p) {
        if (*p < '0' || *p > '9') return false;
        uint64_t digit = (uint64_t)(*p - '0');
        if (value > (limit - digit) / 10) return false;
        value = value * 10 + digit;
    }
    if (!value) return false;
    *out = value;
    return true;
}

static int emit(FILE *stream, NSDictionary *object, int status) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:NULL];
    if (!data) {
        fputs("{\"error\":{\"code\":\"internal_error\",\"message\":\"JSON serialization failed\","
              "\"request_may_have_applied\":false}}\n", stderr);
        return EXIT_OPERATION_FAILED;
    }
    if (fwrite(data.bytes, 1, data.length, stream) != data.length || fputc('\n', stream) == EOF) {
        return EXIT_OPERATION_FAILED;
    }
    return status;
}

static NSString *c_string(const char *text, size_t limit) {
    NSString *value = [[NSString alloc] initWithBytes:text length:strnlen(text, limit) encoding:NSUTF8StringEncoding];
    return value ?: @"";
}

static int fail(const nsk_error *error) {
    NSMutableDictionary *detail = [NSMutableDictionary dictionaryWithCapacity:5];
    detail[@"code"] = @(nsk_status_name(error->status));
    NSString *message = c_string(error->message, sizeof error->message);
    detail[@"message"] = message.length ? message : @"(no message)";
    if (error->space_id) detail[@"space_id"] = @(error->space_id);
    if (error->window_id) detail[@"window_id"] = @(error->window_id);
    detail[@"request_may_have_applied"] = @(error->request_may_have_applied);

    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithObject:detail forKey:@"error"];
    if (error->request_may_have_applied) {
        CFArrayRef spaces = NULL;
        if (nsk_copy_spaces(&spaces, NULL) == NSK_OK) payload[@"observed_spaces"] = CFBridgingRelease(spaces);
    }
    return emit(stderr, payload, EXIT_OPERATION_FAILED);
}

// Argument rejection happens before nsk_initialize, so nothing can have applied.
static bool usage_error(const char *message) {
    nsk_error error;
    nsk_error_clear(&error);
    error.status = NSK_INVALID_ARGUMENT;
    snprintf(error.message, sizeof error.message, "%s; run `nsk --help`", message);
    fail(&error);
    return false;
}

static bool parse_space(const char *text, const char *label, nsk_space_id *out) {
    if (parse_decimal(text, UINT64_MAX, out)) return true;
    char message[128];
    snprintf(message, sizeof message, "%s must be a nonzero decimal uint64 Space ID with no sign or whitespace", label);
    return usage_error(message);
}

static bool parse_window(const char *text, const char *label, nsk_window_id *out) {
    uint64_t value = 0;
    if (parse_decimal(text, UINT32_MAX, &value)) {
        *out = (nsk_window_id)value;
        return true;
    }
    char message[128];
    snprintf(message, sizeof message, "%s must be a nonzero decimal uint32 window ID with no sign or whitespace", label);
    return usage_error(message);
}

static bool parse(int argc, const char *argv[], nsk_request *request) {
    memset(request, 0, sizeof *request);
    if (argc < 2) return usage_error("missing command");

    int positionals = -1;
    for (size_t i = 0; i < sizeof commands / sizeof commands[0]; ++i) {
        if (strcmp(argv[1], commands[i].name) == 0) {
            request->command = commands[i].command;
            positionals = commands[i].positionals;
            break;
        }
    }
    if (positionals < 0) return usage_error("unknown command");

    const char *positional[2] = {"", ""};
    int count = 0;
    for (int i = 2; i < argc; ++i) {
        const char *argument = argv[i];
        if (strcmp(argument, "--migrate") == 0) {
            if (request->command != CMD_DESTROY) return usage_error("--migrate only applies to destroy");
            request->destroy_options |= NSK_DESTROY_MIGRATE_WINDOWS;
            continue;
        }
        if (argument[0] == '-') return usage_error("unknown option");
        if (count == positionals) return usage_error("too many arguments");
        positional[count++] = argument;
    }
    if (count < positionals) return usage_error("missing argument");

    switch (request->command) {
    case CMD_ACTIVATE:
    case CMD_DESTROY:
        return parse_space(positional[0], "ID", &request->space[0]);
    case CMD_WINDOW_SPACES:
        return parse_window(positional[0], "WINDOW_ID", &request->window);
    case CMD_MOVE_WINDOW:
        return parse_window(positional[0], "WINDOW_ID", &request->window) &&
               parse_space(positional[1], "SPACE_ID", &request->space[0]);
    case CMD_MOVE:
        return parse_space(positional[0], "SOURCE_ID", &request->space[0]) &&
               parse_space(positional[1], "TARGET_ID", &request->space[1]);
    case CMD_SWAP:
        return parse_space(positional[0], "ID_A", &request->space[0]) &&
               parse_space(positional[1], "ID_B", &request->space[1]);
    default:
        return true;
    }
}

// A confirmed mutation whose follow-up query failed: the write applied, so say
// so and let fail() attach whatever state is still observable.
static int fail_after_write(nsk_error *error, nsk_space_id space, nsk_window_id window) {
    error->request_may_have_applied = true;
    if (!error->space_id) error->space_id = space;
    if (!error->window_id) error->window_id = window;
    return fail(error);
}

static NSArray *copy_snapshot(nsk_error *error) {
    CFArrayRef spaces = NULL;
    if (nsk_copy_spaces(&spaces, error) != NSK_OK) return nil;
    return CFBridgingRelease(spaces);
}

static NSDictionary *find_record(NSArray *spaces, nsk_space_id space) {
    for (NSDictionary *record in spaces) {
        if ([record[@"id"] unsignedLongLongValue] == space) return record;
    }
    return nil;
}

// {key: fresh record of space} plus, when spaces_key is set, the whole snapshot.
static int emit_record(NSString *key, nsk_space_id space, NSString *spaces_key) {
    nsk_error error;
    nsk_error_clear(&error);
    NSArray *spaces = copy_snapshot(&error);
    if (!spaces) return fail_after_write(&error, space, 0);
    NSDictionary *record = find_record(spaces, space);
    if (!record) {
        error.status = NSK_STATE_CHANGED;
        snprintf(error.message, sizeof error.message,
                 "operation confirmed, but Space %llu is absent from the follow-up snapshot",
                 (unsigned long long)space);
        return fail_after_write(&error, space, 0);
    }
    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithObject:record forKey:key];
    if (spaces_key) payload[spaces_key] = spaces;
    return emit(stdout, payload, 0);
}

static int emit_window_spaces(nsk_window_id window, nsk_space_id destination) {
    nsk_error error;
    nsk_error_clear(&error);
    CFArrayRef ids = NULL;
    if (nsk_copy_window_spaces(window, &ids, &error) != NSK_OK) {
        return destination ? fail_after_write(&error, destination, window) : fail(&error);
    }
    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithCapacity:3];
    payload[@"window_id"] = @(window);
    if (destination) payload[@"space_id"] = @(destination);
    payload[@"space_ids"] = CFBridgingRelease(ids);
    return emit(stdout, payload, 0);
}

static int capabilities(void) {
    nsk_error error;
    nsk_error_clear(&error);
    nsk_capabilities caps;
    if (nsk_get_capabilities(&caps, &error) != NSK_OK) return fail(&error);

    NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
    char build[64] = "";
    size_t size = sizeof build;
    if (sysctlbyname("kern.osversion", build, &size, NULL, 0) != 0) build[0] = '\0';

    return emit(stdout, @{
        @"runtime_entrypoints": @{
            @"space_query": @(caps.space_query),
            @"window_query": @(caps.window_query),
            @"create_space": @(caps.create_space),
            @"destroy_space": @(caps.destroy_space),
            @"activate_space": @(caps.activate_space),
            @"move_window": @(caps.move_window),
            @"reorder_spaces": @(caps.reorder_spaces),
        },
        @"os": @{
            @"version": [NSString stringWithFormat:@"%ld.%ld.%ld",
                         (long)os.majorVersion, (long)os.minorVersion, (long)os.patchVersion],
            @"build": c_string(build, sizeof build),
        },
    }, 0);
}

static int run(const nsk_request *request) {
    nsk_error error;
    nsk_error_clear(&error);
    if (nsk_initialize(&error) != NSK_OK) return fail(&error);

    const nsk_space_id a = request->space[0], b = request->space[1];
    switch (request->command) {
    case CMD_CAPABILITIES:
        return capabilities();
    case CMD_LIST: {
        NSArray *spaces = copy_snapshot(&error);
        return spaces ? emit(stdout, @{@"spaces": spaces}, 0) : fail(&error);
    }
    case CMD_CREATE: {
        nsk_space_id created = 0;
        if (nsk_create_space(&created, &error) != NSK_OK) return fail(&error);
        return emit_record(@"created", created, nil);
    }
    case CMD_ACTIVATE:
        if (nsk_activate_space(a, &error) != NSK_OK) return fail(&error);
        return emit_record(@"activated", a, nil);
    case CMD_DESTROY:
        if (nsk_destroy_space(a, request->destroy_options, &error) != NSK_OK) return fail(&error);
        return emit(stdout, @{@"destroyed": @(a)}, 0);
    case CMD_WINDOW_SPACES:
        return emit_window_spaces(request->window, 0);
    case CMD_MOVE_WINDOW:
        if (nsk_move_window(request->window, a, &error) != NSK_OK) return fail(&error);
        return emit_window_spaces(request->window, a);
    case CMD_MOVE:
        if (nsk_move_space(a, b, &error) != NSK_OK) return fail(&error);
        return emit_record(@"moved", a, @"spaces");
    case CMD_SWAP: {
        if (nsk_swap_spaces(a, b, &error) != NSK_OK) return fail(&error);
        NSArray *spaces = copy_snapshot(&error);
        if (!spaces) return fail_after_write(&error, a, 0);
        return emit(stdout, @{@"swapped": @[@(a), @(b)], @"spaces": spaces}, 0);
    }
    default:
        return EXIT_OPERATION_FAILED;
    }
}

static bool mutates(nsk_command command) {
    switch (command) {
    case CMD_CREATE:
    case CMD_ACTIVATE:
    case CMD_DESTROY:
    case CMD_MOVE_WINDOW:
    case CMD_MOVE:
    case CMD_SWAP:
        return true;
    default:
        return false;
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        nsk_request request;
        if (!parse(argc, argv, &request)) return EXIT_USAGE;
        if (request.command == CMD_HELP) {
            fputs(usage, stdout);
            return 0;
        }
        if (request.command == CMD_VERSION) return emit(stdout, @{@"version": @NSK_VERSION}, 0);

        @try {
            return run(&request);
        } @catch (NSException *exception) {
            nsk_error error;
            nsk_error_clear(&error);
            error.status = NSK_INTERNAL_ERROR;
            error.space_id = request.space[0];
            error.window_id = request.window;
            // A write may have been submitted before the exception escaped.
            error.request_may_have_applied = mutates(request.command);
            snprintf(error.message, sizeof error.message, "uncaught %s: %s",
                     exception.name.UTF8String, exception.reason.UTF8String ?: "(no reason)");
            return fail(&error);
        }
    }
}
