local selection = require("dum.selection")
local copilot = require("dum.copilot")
local ui = require("dum.ui")

local M = {}

--- @type { keymap: string, model: string }
M.config = {
	keymap = "<leader>ch",
	model = "claude-sonnet-4.6",
}

--- Entry point: capture the last visual selection, prompt for a requirement,
--- call Copilot, and replace the selection in-place.
--- Call this after exiting visual mode so '< and '> marks are finalised.
function M.ask()
	local lines, start_line, end_line = selection.get()

	-- Strip common base indentation before sending; restore after.
	local stripped, indent = selection.strip_indent(lines)
	local code = table.concat(stripped, "\n")
	local model = M.config.model

	-- Lightweight automatic context: language, filename, surrounding lines.
	local filetype = vim.bo.filetype
	local filename = vim.fn.expand("%:t")
	local total_lines = vim.api.nvim_buf_line_count(0)
	local before = vim.api.nvim_buf_get_lines(0, math.max(0, start_line - 51), start_line - 1, false)
	local after = vim.api.nvim_buf_get_lines(0, end_line, math.min(total_lines, end_line + 50), false)

	local ctx_parts = {
		"Language: " .. (filetype ~= "" and filetype or "unknown"),
		"File: " .. (filename ~= "" and filename or "unnamed"),
	}
	if #before > 0 then
		table.insert(ctx_parts, "\n--- Lines before selection ---\n" .. table.concat(before, "\n"))
	end
	if #after > 0 then
		table.insert(ctx_parts, "\n--- Lines after selection ---\n" .. table.concat(after, "\n"))
	end
	local context = table.concat(ctx_parts, "\n")

	ui.input("Requirement", function(requirement)
		if not requirement then
			return
		end

		local stop_spinner = ui.spinner(0, start_line, end_line)

		copilot.complete(code, requirement, model, function(err, result)
			stop_spinner()
			if err then
				vim.notify("[dum] " .. err, vim.log.levels.ERROR)
				return
			end

			local new_lines = selection.apply_indent(vim.split(result, "\n", { plain = true }), indent)

			selection.replace(start_line, end_line, new_lines)
		end, context)
	end, { model = model })
end

--- Configure the plugin and register the keymap.
--- @param opts? { keymap?: string, model?: string }
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})

	vim.keymap.set(
		"v",
		M.config.keymap,
		":<C-u>lua require('dum').ask()<CR>",
		{ silent = true, desc = "Prompt Copilot on visual selection" }
	)
end

return M
