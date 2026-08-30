# arcanist.nvim

A Neovim plugin for [Arcanist], a command-line interface to Phorge.

Edit Phorge tasks and revisions as buffers (`:e arcanist://T123`), browse them
in a picker, run `arc lint` into the quickfix list, and write Remarkup with
highlighting, completion and file upload on paste.

## Requirements

- Neovim 0.10+.
- A C compiler (`cc`) on your `PATH`, to build the parser.
- [`arc`](https://we.phorge.it/book/phorge/article/arcanist/) on your `PATH`,
  configured (`~/.arcrc`) against your Phorge instance.

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
    cmd = { 'ArcLint', 'ArcList', 'ArcWrite' },
    event = { 'BufReadCmd arcanist://*', 'BufWriteCmd arcanist://*' },
    keys = {
        {
            '<leader>rr',
            function() require('arcanist').list({ type = 'revision' }) end,
            desc = 'Arc revisions',
        },
        {
            '<leader>rt',
            function() require('arcanist').list({ type = 'task' }) end,
            desc = 'Arc tasks',
        },
    },
}
```

## Documentation

Once installed, run inside Neovim:

```
:help arcanist
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
