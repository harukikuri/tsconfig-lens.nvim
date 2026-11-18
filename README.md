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

In the window: `<CR>` jump to the file and line, `<Tab>` fold a section, `y` yank, `r` refresh, `q` close.

Statusline: `require("tsconfig-lens").status()` returns the tsconfig path, `"inferred"`, or `""`.

## How it works

The plugin asks TypeScript and shows the answer. It never re-implements tsconfig rules.

| Shown | Comes from |
|---|---|
| Which tsconfig owns the file | your LSP (ts_ls, vtsls, or TypeScript 7's `tsc --lsp`). Without one, your project's `typescript` package |
| Final values | `tsc --showConfig`, run with your project's `tsc` |
| Extends chain | TypeScript's list of the files it loaded |
| Line where each option is set | Computed by the plugin, then checked against TypeScript's final options. If any value differs, every origin shows `unknown` |

Options and TypeScript 7 notes: `:help tsconfig-lens`
