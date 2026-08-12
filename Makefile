# Builds the remarkup tree-sitter parser from vendored grammar source
# (tree-sitter-remarkup/) into parser/remarkup.so, which is what Neovim
# actually loads. The .so is NOT committed -- it's a platform/arch-specific
# binary, so every machine builds its own.
#
# Run manually with `make`, or point a plugin manager's `build` step at it
# (e.g. lazy.nvim: `build = 'make'`).

GRAMMAR_DIR := tree-sitter-remarkup
PARSER_SO := parser/remarkup.so
CC ?= cc

# macOS's linker needs -undefined dynamic_lookup for a .so that references
# symbols (malloc, etc.) resolved by the process that loads it (Neovim);
# Linux's ld resolves those at load time regardless, and doesn't have this
# flag at all.
ifeq ($(shell uname -s),Darwin)
	SHARED_FLAGS := -undefined dynamic_lookup
else
	SHARED_FLAGS :=
endif

.PHONY: all clean

all: $(PARSER_SO)

$(PARSER_SO): $(GRAMMAR_DIR)/src/parser.c
	@mkdir -p parser
	$(CC) -shared -Os -fPIC $(SHARED_FLAGS) -I $(GRAMMAR_DIR)/src -o $@ $(GRAMMAR_DIR)/src/parser.c

clean:
	rm -f $(PARSER_SO)
