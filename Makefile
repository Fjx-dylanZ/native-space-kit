# native-space-kit build. macOS only; requires Xcode command-line tools.
#
#   make            static library and CLI
#   make example    pure-C consumer of the public header
#   make check      read-only ABI and CLI contract tests (never mutates desktops)
#   make probes     Cocoa helpers used by the probe runners under probes/
#   make clean
#
# Every tool and flag can be overridden on the command line or in the environment:
#   make CC="clang" ARCH="-arch arm64" OPT="-O0 -g" BUILD=out
#   make CFLAGS="-DNDEBUG" OBJCFLAGS="-fobjc-weak"

SDK    ?= macosx
BUILD  ?= build
OPT    ?= -O2
ARCH   ?=
STD    ?= -std=c11
WARN   ?= -Wall -Wextra -Werror
# Extra strictness for the pure-C consumers this repo owns (example, contract test).
CWARN  ?= -Wshadow -Wstrict-prototypes -Wmissing-prototypes
PYTHON ?= python3

# GNU make predefines CC/AR as cc/ar; replace only those defaults so explicit
# CC=... overrides still win.
ifeq ($(origin CC),default)
CC := xcrun --sdk $(SDK) clang
endif
ifeq ($(origin AR),default)
AR := xcrun --sdk $(SDK) ar
endif

INCLUDE    := -Iinclude
COMMON     := $(ARCH) $(OPT) $(WARN) $(INCLUDE)
CFLAGS     ?=
OBJCFLAGS  ?=
LDFLAGS    ?=
FRAMEWORKS := -framework Cocoa

ALL_CFLAGS    := $(STD) $(COMMON) $(CWARN) $(CFLAGS)
ALL_OBJCFLAGS := -fobjc-arc $(COMMON) $(OBJCFLAGS)
# -ObjC and -lobjc let a pure-C link pull the Objective-C runtime and every class
# in the static library, which is what any C consumer of the header needs.
ALL_LDFLAGS   := $(ARCH) $(LDFLAGS) -ObjC -lobjc $(FRAMEWORKS)

LIB      := $(BUILD)/libnative-space-kit.a
CLI      := $(BUILD)/nsk
EXAMPLE  := $(BUILD)/list-spaces
CONTRACT := $(BUILD)/contract-test
FIXTURE  := $(BUILD)/window-fixture
STICKY   := $(BUILD)/sticky-probe
HEADER   := include/native_space_kit.h

.PHONY: all example check probes clean
.DELETE_ON_ERROR:

all: $(LIB) $(CLI)

example: $(EXAMPLE)

probes: $(FIXTURE) $(STICKY)

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/native_space_kit.o: src/native_space_kit.m $(HEADER) | $(BUILD)
	$(CC) $(ALL_OBJCFLAGS) -c $< -o $@

$(LIB): $(BUILD)/native_space_kit.o
	$(AR) rcs $@ $^

$(BUILD)/cli_main.o: cli/main.m $(HEADER) | $(BUILD)
	$(CC) $(ALL_OBJCFLAGS) -c $< -o $@

$(CLI): $(BUILD)/cli_main.o $(LIB)
	$(CC) $(ALL_LDFLAGS) $^ -o $@

# Compiled as C, not Objective-C: proves the header is usable without a
# Foundation/ObjC toolchain on the consumer side.
$(BUILD)/list_spaces.o: examples/list_spaces.c $(HEADER) | $(BUILD)
	$(CC) -x c $(ALL_CFLAGS) -c $< -o $@

$(EXAMPLE): $(BUILD)/list_spaces.o $(LIB)
	$(CC) $(ALL_LDFLAGS) $^ -o $@

$(BUILD)/contract.o: tests/contract.c $(HEADER) | $(BUILD)
	$(CC) -x c $(ALL_CFLAGS) -c $< -o $@

$(CONTRACT): $(BUILD)/contract.o $(LIB)
	$(CC) $(ALL_LDFLAGS) $^ -o $@

# Read-only: the ABI test only initializes and queries; the CLI test runs
# --version/--help/capabilities/list plus argument-rejection cases. Neither
# ever submits a native write.
check: $(CONTRACT) $(CLI) $(EXAMPLE)
	$(CONTRACT)
	$(PYTHON) tests/cli_test.py $(CLI)
	$(PYTHON) tests/probe_test.py

# Probe helpers dlopen SkyLight at runtime; no private framework is linked.
$(FIXTURE): probes/window_fixture.m | $(BUILD)
	$(CC) $(ALL_OBJCFLAGS) $(LDFLAGS) $(FRAMEWORKS) $< -o $@

$(STICKY): probes/sticky_probe.m | $(BUILD)
	$(CC) $(ALL_OBJCFLAGS) $(LDFLAGS) $(FRAMEWORKS) $< -o $@

clean:
	rm -rf $(BUILD)
