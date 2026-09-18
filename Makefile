# Makefile for fibonacci.S — AArch64, pure syscalls, no libc.
#
# Build commands (as specified):
#   as fibonacci.S -o fibonacci.o
#   ld  fibonacci.o -o fibonacci
#
# Note: on an AArch64 host the plain `as`/`ld` are AArch64-native and the
# plain link produces a static AArch64 ELF, so no -no-pie is required.

AS      := as
LD      := ld
TARGET  := fibonacci

.PHONY: all run test clean

all: $(TARGET)

$(TARGET): fibonacci.o
	$(LD) $< -o $@

fibonacci.o: fibonacci.S
	$(AS) $< -o $@

# Usage: make run ARGS="10"
run: all
	./$(TARGET) $(ARGS)

test: all
	./test.sh

clean:
	rm -f $(TARGET) fibonacci.o