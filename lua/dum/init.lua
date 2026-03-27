local selection = require("dum.selection")
local copilot = require("dum.copilot")
local ui = require("dum.ui")

local M = {}

--- @type { keymap: string, cancel_keymap: string, model: string, filetype_prompts: table<string,string> }
M.config = {
	keymap = "<leader>ch",
	cancel_keymap = "<leader>chc",
	model = "claude-sonnet-4.6",
	filetype_prompts = {},
}

-- Tracks the active request so M.cancel() can abort it from any keymap.
-- Set to { stop_spinner: fun(), cancel_token: {cancelled: bool} } during a request.
local _active = nil

--- Cancel the currently in-flight request, if any.
function M.cancel()
	if not _active then
		return
	end
	_active.cancel_token.cancelled = true
	_active.stop_spinner()
	_active = nil
	copilot.cancel()
	vim.notify("[dum] cancelled", vim.log.levels.INFO)
end

--- Entry point: capture the last visual selection, prompt for a requirement,
--- call Copilot, and replace the selection in-place.
--- Call this after exiting visual mode so '< and '> marks are finalised.
function M.ask()
	local lines, start_line, end_line = selection.get()

	if selection.is_empty(lines) then
		vim.notify("[dum] selection is empty", vim.log.levels.WARN)
		return
	end

	-- Strip common base indentation before sending; restore after.
	local stripped, indent = selection.strip_indent(lines)
	local code = table.concat(stripped, "\n")
	local model = M.config.model

	-- Lightweight automatic context: language, filename.
	local filetype = vim.bo.filetype
	local filename = vim.fn.expand("%:t")

	local ctx_parts = {
		"Language: " .. (filetype ~= "" and filetype or "unknown"),
		"File: " .. (filename ~= "" and filename or "unnamed"),
	}
	local context = table.concat(ctx_parts, "\n")

	local system_extra = M.config.filetype_prompts[filetype]

	ui.input("Requirement", function(requirement)
		if not requirement then
			return
		end

		local stop_spinner = ui.spinner(0, start_line, end_line)
		local cancel_token = { cancelled = false }
		_active = { stop_spinner = stop_spinner, cancel_token = cancel_token }

		local spinner_stopped = false
		local current_end = end_line
		local first_write = true

		local function ensure_spinner_stopped()
			if not spinner_stopped then
				spinner_stopped = true
				stop_spinner()
				_active = nil
			end
		end

		copilot.complete(code, requirement, model, function(err, result)
			ensure_spinner_stopped()
			if cancel_token.cancelled then
				return
			end
			if err then
				vim.notify("[dum] " .. err, vim.log.levels.ERROR)
				return
			end

			-- Final authoritative write; also the sole write when on_chunk is absent.
			local new_lines = selection.apply_indent(vim.split(result, "\n", { plain = true }), indent)
			if not first_write then
				pcall(vim.cmd, "undojoin")
			end
			first_write = false
			selection.replace(start_line, current_end, new_lines)
		end, {
			context = context,
			system_extra = system_extra,
			on_chunk = function(partial)
				if cancel_token.cancelled then
					return
				end
				ensure_spinner_stopped()
				local new_lines = selection.apply_indent(vim.split(partial, "\n", { plain = true }), indent)
				if not first_write then
					pcall(vim.cmd, "undojoin")
				end
				first_write = false
				selection.replace(start_line, current_end, new_lines)
				current_end = start_line - 1 + #new_lines
			end,
		})
	end, { model = model })
end

--- Configure the plugin and register the keymaps.
--- @param opts? { keymap?: string, cancel_keymap?: string, model?: string, filetype_prompts?: table<string,string> }
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})

	vim.keymap.set(
		"v",
		M.config.keymap,
		":<C-u>lua require('dum').ask()<CR>",
		{ silent = true, desc = "Prompt Copilot on visual selection" }
	)

	vim.keymap.set(
		"n",
		M.config.cancel_keymap,
		"<cmd>lua require('dum').cancel()<CR>",
		{ silent = true, desc = "Cancel in-flight Copilot request" }
	)
end

return M
