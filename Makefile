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

.PHONY: all clean test test-unit test-integration

all: $(PARSER_SO)

$(PARSER_SO): $(GRAMMAR_DIR)/src/parser.c
	@mkdir -p parser
	$(CC) -shared -Os -fPIC $(SHARED_FLAGS) -I $(GRAMMAR_DIR)/src -o $@ $(GRAMMAR_DIR)/src/parser.c

clean:
	rm -f $(PARSER_SO)

# Runs every tests/<dir>/**/test_*.lua under mini.test, from a Neovim
# bootstrapped by tests/init.lua.
run_tests = nvim --headless --noplugin -u tests/init.lua \
	-c "lua MiniTest.run({ collect = { find_files = function() return vim.fn.globpath('$(1)', '**/test_*.lua', true, true) end } })"

# Runs the whole Lua test suite (both tiers below).
test: test-unit test-integration

# Pure-logic unit tests (tests/unit/) via mini.test. Independent of `all` --
# these never touch vim.treesitter, so they don't need the parser built
# first, or a C compiler on $PATH at all.
test-unit:
	$(call run_tests,tests/unit)

# Drives a real (child) Neovim process through arcanist.nvim's actual UI --
# buffers, keymaps, quickfix -- against a fake `arc` (tests/integration/fixtures/),
# so no real Phorge/network is involved. Needs the built parser, since these
# open real remarkup/arcanist:// buffers.
test-integration: all
	$(call run_tests,tests/integration)
