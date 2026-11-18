# tsconfig-lens.nvim

See which tsconfig **really** applies to the file you are editing, and its final settings after `extends`.

```
src/features/user/page.tsx
project: apps/web/tsconfig.json                        (via tsserver)

Extends
  apps/web/tsconfig.json
  └ packages/tsconfig/react.json
    └ packages/tsconfig/base.json

Effective compilerOptions                              (tsc --showConfig)
  strict                    true                 packages/tsconfig/base.json:3
  jsx                       "react-jsx"          packages/tsconfig/react.json:4
  moduleResolution          "bundler"            packages/tsconfig/base.json:5
  paths                     {"@/*":["./src/*"]}  apps/web/tsconfig.json:5
  noUncheckedIndexedAccess  true                 apps/web/tsconfig.json:6
```

Files outside every `include` are type-checked with default options, silently:

```
src/scripts/seed.ts
project: none (inferred project)                       (via tsserver)
  This file is not included by any tsconfig.json.
  TypeScript checks it with default options.
```

## The principle: this plugin decides nothing

Which tsconfig applies and what the final values are is **asked to TypeScript itself** — tsserver (through your LSP), `tsc --showConfig`, and the TypeScript API — using the `typescript` installed **in your project**. The plugin does not re-implement `extends` or `include`/`exclude`; a re-implementation would start lying the moment it drifts from TypeScript. Anything TypeScript does not answer is shown as `unknown`.

The only computed part is the origin of each option (`file:line`). It is verified against TypeScript's final options every time; if a single option disagrees, every origin is shown as `unknown` and the reason goes to `:TsconfigLens log`.

## Requirements

- Neovim >= 0.10
- Node.js
- `typescript` in your project
- Optional: ts_ls, vtsls, or TypeScript 7's LSP (`tsc --lsp`), to get the same answer your editor uses

## Install

```lua
-- lazy.nvim
{ "harukikuri/tsconfig-lens.nvim", cmd = "TsconfigLens", opts = {} }
```

## Usage

| Command | |
|---|---|
| `:TsconfigLens` | tsconfig, extends chain, effective `compilerOptions` |
| `:TsconfigLens chain` | extends chain only |
| `:TsconfigLens log` | self-check failures and errors |

In the window: `<CR>` opens the tsconfig / the line that set the option, `y` yanks `"key": value`, `r` refreshes, `q` closes.

Origins read as:

- `file:line` — the last file in the chain that set it
- `not set in any file` — TypeScript reports it but no file sets it (implied, e.g. `composite` → `declaration`)
- `unknown` — self-check failed

### Statusline

```lua
require("tsconfig-lens").status() -- "apps/web/tsconfig.json" | "inferred" | ""
```

Fetched asynchronously on `BufEnter` / `LspAttach` and cached per buffer; drawing never starts Node.js. Requires `setup()`.

## Configuration

```lua
require("tsconfig-lens").setup({
  open = "float",                  -- "float" | "split" | "vsplit"
  node = "node",                   -- Node.js executable
  sources = { "tsserver", "api" }, -- LSP first, then the project's TypeScript API
  show_origin = true,
  warn_inferred = false,           -- HINT diagnostic on files outside every tsconfig
  keymaps = { jump = "<CR>", yank = "y", refresh = "r", close = "q" },
})
```

## TypeScript 7

TypeScript 7 (the native port) does not expose the extends chain in its API, so the chain and origins are shown as unavailable. The project and effective options still come from TypeScript.

## Development

```sh
npm ci --prefix tests && npm ci --prefix tests/fixtures/ts7
nvim --headless -u NONE -l tests/run.lua
```

## License

MIT
