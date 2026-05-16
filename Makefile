CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -std=c11
LDLIBS ?= -pthread

all: lowfi_in_c

run: lowfi_in_c
	./lowfi_in_c

lowfi_in_c: lowfi_in_c.c chillhop_embedded.h
	$(CC) $(CFLAGS) lowfi_in_c.c $(LDLIBS) -o $@

chillhop_embedded.h: chillhop.txt
	@od -An -v -tx1 $< | awk 'BEGIN { print "static const unsigned char chillhop_txt[] = {"; count = 0; } { for (i = 1; i <= NF; ++i) { if (count % 12 == 0) printf("    "); if (count > 0) printf(", "); printf("0x%s", $$i); count++; if (count % 12 == 0) printf("\n"); } } END { if (count % 12 != 0) printf("\n"); print "};" }' > $@

clean:
	rm -f lowfi_in_c lowfi_in_c.exe chillhop_embedded.h

.PHONY: all run clean
