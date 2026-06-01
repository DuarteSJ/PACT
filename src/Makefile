# Makefile for the PACT runtime.

CC      = gcc
CFLAGS  = -Wall -Wextra -O3 -g -D_GNU_SOURCE -I. -MMD -MP
LDFLAGS = -lm -lnuma -lpthread

TARGET  = pact

# All sources except logging.c, which is an optional build (its symbols are
# no-ops via logging.h unless PACT_ENABLE_LOGGING is set; see `make logging`).
SOURCES = $(filter-out logging.c,$(wildcard *.c))
OBJECTS = $(SOURCES:.c=.o)
DEPS    = $(OBJECTS:.o=.d)

.PHONY: all clean logging format check-format

all: $(TARGET)

# usage.c prints the version string from the generated build-info.h.
build-info.h:
	@GIT=$$(git describe --always --dirty --tags 2>/dev/null || echo unknown); \
	printf '#define PACT_GIT_VERSION "%s"\n#define PACT_BUILD_DATE "%s"\n' \
	    "$$GIT" "$$(date -u +%Y-%m-%dT%H:%M:%SZ)" > $@

usage.o: build-info.h

$(TARGET): $(OBJECTS)
	$(CC) $(OBJECTS) -o $(TARGET) $(LDFLAGS)

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

-include $(DEPS)

# Optional build with file logging enabled.
logging:
	$(MAKE) clean
	$(MAKE) CFLAGS="$(CFLAGS) -DPACT_ENABLE_LOGGING" SOURCES="$(wildcard *.c)"

clean:
	rm -f *.o *.d $(TARGET) build-info.h

# clang-format helpers (config in .clang-format; see CODING_STYLE.md).
# Override the binary if unversioned `clang-format` is absent, e.g.
# `make check-format CLANG_FORMAT=clang-format-18`.
CLANG_FORMAT ?= clang-format
FMT_SRCS = $(filter-out khashl.h minicoro.h build-info.h,$(wildcard *.c *.h))
format:
	$(CLANG_FORMAT) -i $(FMT_SRCS)
check-format:
	$(CLANG_FORMAT) --dry-run -Werror $(FMT_SRCS)
