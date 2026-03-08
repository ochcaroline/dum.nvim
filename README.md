# dum.nvim

Ask GitHub Copilot to complete a **visual selection** using the minimum possible context — only the selected fragment and your requirement are sent, nothing else from the file.

Plugin is heavily inspired by the workflow frm [99](https://github.com/ThePrimeagen/99) - tradcoders' AI agent :D

Since 99 works with all providers, but not with copilot directly - I created something that does it.

> ℹ️ This is heavily opinionated. It's supposed to work for **ME**, not anyone else. Though PRs appreciated

## Why "dum"

Regular LLMs are cool and everything, but I want something that gives me the ability to work precisely how I need

I want the LLM to do precise, short things.

So I named it `dum`. Because AI is kinda dum-dum. `Dum dum" (or dum-dum) is primarily slang for a silly, stupid, or foolish person`

## Requirements

- Neovim ≥ 0.10
- [`gh`](https://cli.github.com/) installed and authenticated (`gh auth login`)
- `curl` available in `$PATH`
- A GitHub account with Copilot access

## Installation

### lazy.nvim

```lua
{
  "ochcaroline/dum.nvim",
  config = function()
    require("dum").setup()
  end,
}
```

## Usage

1. Select code in **visual mode** (`v`, `V`, or `<C-v>`).
2. Press `<leader>ch` (default).
3. Type your prompt
4. Copilot completes the selection in-place. The change is fully undoable.

## Configuration

```lua
require("dum").setup({
  keymap = "<leader>ch", -- visual-mode keybinding
  model  = "claude-sonnet-4.6", -- Copilot model
})
```

## How it works

- The **stripped selected lines** (with some basic context information) and your **requirement** are sent to the Copilot Chat Completions API.
- The context information: filetype, filename
- The plugin exchanges your `gh` OAuth token for a short-lived Copilot token (cached for ~30 minutes).
- Common leading indentation is stripped before sending and restored on the result, keeping diffs clean.
