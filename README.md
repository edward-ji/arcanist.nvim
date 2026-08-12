# arcanist.nvim

A Neovim plugin for [Arcanist], a command-line interface to Phorge.

## Requirements

- Neovim 0.9+ (uses `vim.treesitter.start()` / `vim.filetype.add()`).
- A C compiler (`cc`) on your `PATH`, to build the parser.
- No dependency on `nvim-treesitter` -- Remarkup isn't in its parser
  registry, so this plugin builds and loads its own parser directly via
  Neovim's built-in treesitter support.

## Installing

The parser must be built once per machine, so point your plugin manager's
build step at `make`.

### vim.pack (Neovim 0.12+)

`vim.pack.add()` has no built-in build step, so hook one in via the
`PackChanged` autocmd:

```lua
vim.pack.add({ 'https://github.com/edward-ji/arcanist.nvim' })

vim.api.nvim_create_autocmd('PackChanged', {
    callback = function(args)
        if args.data.spec.name == 'arcanist.nvim' and args.data.kind ~= 'delete' then
            vim.system({ 'make' }, { cwd = args.data.path }):wait()
        end
    end,
})
```

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
    'edward-ji/arcanist.nvim',
    build = 'make',
    ft = 'remarkup',
}
```

## Rebuilding the grammar

If you edit `tree-sitter-remarkup/grammar.js`, regenerate the parser source
and rebuild:

```sh
cd tree-sitter-remarkup
npx tree-sitter-cli generate
cd ..
make
```

(`npx tree-sitter-cli` downloads the CLI on first use; nothing needs to stay
installed afterward.)

[Arcanist]: (https://we.phorge.it/book/phorge/article/arcanist/)
