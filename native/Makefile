# Static ARMv7 builds of the native helpers for the Nest Gen2 (kernel 2.6.37, musl).
# Needs the arm-nest-linux-musleabi crosstool-NG toolchain on PATH.
CROSS   ?= arm-nest-linux-musleabi-
CC      := $(CROSS)gcc
STRIP   := $(CROSS)strip
CFLAGS  ?= -O2 -std=gnu17 -Wall -Wextra
LDFLAGS ?= -static
BUILD   := build

HELPERS := evwatch bplink regread

all: $(addprefix $(BUILD)/,$(HELPERS))

$(BUILD)/%: %.c | $(BUILD)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<
	$(STRIP) $@

$(BUILD):
	mkdir -p $@

clean:
	rm -rf $(BUILD)

.PHONY: all clean
