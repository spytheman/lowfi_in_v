SBCL ?= sbcl
TARGET := lowfi_in_sbcl
SOURCE := lowfi_in_sbcl.lisp

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SOURCE)
	$(SBCL) --noinform --disable-debugger \
		--load $(SOURCE) \
		--eval '(sb-ext:save-lisp-and-die "$(TARGET)" :toplevel (function lowfi-in-sbcl::main) :executable t :purify t :compression 9)' \
		--quit

clean:
	rm -f $(TARGET)
