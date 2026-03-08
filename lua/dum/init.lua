local selection = require("dum.selection")
local copilot = require("dum.copilot")
local ui = require("dum.ui")

local M = {}

--- @type { keymap: string, keymap_ctx: string, model: string }
M.config = {
	keymap = "<leader>ch",
	keymap_ctx = "<leader>cH",
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
		end)
	end, { model = model })
end

--- Like ask(), but also sends the full buffer as additional context.
function M.ask_with_context()
	local lines, start_line, end_line = selection.get()

	local stripped, indent = selection.strip_indent(lines)
	local code = table.concat(stripped, "\n")
	local model = M.config.model

	local buf_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	local context = table.concat(buf_lines, "\n")

	ui.input("Requirement (+ buffer context)", function(requirement)
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
--- @param opts? { keymap?: string, keymap_ctx?: string, model?: string }
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})

	vim.keymap.set(
		"v",
		M.config.keymap,
		":<C-u>lua require('dum').ask()<CR>",
		{ silent = true, desc = "Prompt Copilot on visual selection" }
	)

	vim.keymap.set(
		"v",
		M.config.keymap_ctx,
		":<C-u>lua require('dum').ask_with_context()<CR>",
		{ silent = true, desc = "Prompt Copilot on visual selection (with buffer context)" }
	)
end

return M
