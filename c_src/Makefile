# Static ARMv7 builds of the native helpers for the Nest Gen2 (kernel 2.6.37, musl).
# Needs the arm-nest-linux-musleabi crosstool-NG toolchain on PATH.
CROSS   ?= arm-nest-linux-musleabi-
CC      := $(CROSS)gcc
STRIP   := $(CROSS)strip
CFLAGS  ?= -O2 -std=gnu17 -Wall -Wextra
LDFLAGS ?= -static
BUILD   := ../priv

HELPERS := evwatch bplink regread textrender

all: $(addprefix $(BUILD)/,$(HELPERS))

$(BUILD)/%: %.c | $(BUILD)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $< -lm
	$(STRIP) $@

$(BUILD)/textrender: vendor/stb_truetype.h

$(BUILD):
	mkdir -p $@

clean:
	rm -f $(addprefix $(BUILD)/,$(HELPERS))

.PHONY: all clean
