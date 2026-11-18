# tsconfig-lens.nvim

Which tsconfig applies to this file, and what are its final settings?

![tsconfig-lens window](assets/screenshot.png)

## Install

Needs Neovim >= 0.10, Node.js, and `typescript` in your project.

```lua
-- lazy.nvim
{ "harukikuri/tsconfig-lens.nvim", cmd = "TsconfigLens", opts = {} }
```

## Use

| Command | Shows |
|---|---|
| `:TsconfigLens` | tsconfig, extends chain, final options |
| `:TsconfigLens chain` | extends chain only |
| `:TsconfigLens log` | errors |

In the window: `<CR>` jump to the file and line, `y` yank, `r` refresh, `q` close.

Statusline: `require("tsconfig-lens").status()` returns the tsconfig path, `"inferred"`, or `""`.

## Why trust it

Every answer comes from TypeScript itself (your LSP, `tsc --showConfig`, your project's `typescript`). The plugin guesses nothing. Where TypeScript gives no answer, it shows `unknown`.

Options, origins and TypeScript 7 notes: `:help tsconfig-lens`
