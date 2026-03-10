--- Minimal floating-window prompt for multi-line user input.
--- Interface: :w  → submit and close
---            :q  → cancel and close
local M = {}

--- Open a floating input window centered on the screen.
---
--- @param title string   Window border title.
--- @param cb fun(input: string|nil)  Called with the text or nil on cancel.
--- @param opts? { model?: string }  `model` is shown in the lower-right footer.
function M.input(title, cb, opts)
	-- Wipe any leftover buffer from a previous session that wasn't cleaned up.
	local stale = vim.fn.bufnr("dum://prompt")
	if stale ~= -1 then
		pcall(vim.api.nvim_buf_delete, stale, { force = true })
	end

	local buf = vim.api.nvim_create_buf(false, true)

	-- "acwrite" routes :w through BufWriteCmd instead of the filesystem.
	-- A name is required; E32 ("No file name") fires without one.
	vim.bo[buf].buftype = "acwrite"
	vim.api.nvim_buf_set_name(buf, "dum://prompt")

	local height = 5
	local width = math.min(70, vim.o.columns - 4)
	local row = math.floor((vim.o.lines - height - 2) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	local model = opts and opts.model
	local win_cfg = {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " " .. title .. " │ :w submit  :q cancel ",
		title_pos = "center",
	}
	if model then
		win_cfg.footer = " " .. model .. " "
		win_cfg.footer_pos = "right"
	end
	local win = vim.api.nvim_open_win(buf, true, win_cfg)

	vim.wo[win].wrap = true

	-- go to insert mode
	vim.schedule(function()
		vim.cmd("startinsert")
	end)

	local submitted = false
	local closed = false

	local function close()
		if closed then
			return
		end
		closed = true
		-- Delete buffer first (implicitly closes the window and avoids save-prompt).
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_delete(buf, { force = true })
		elseif vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
		-- Return to normal mode in case we closed programmatically from insert.
		if vim.fn.mode() ~= "n" then
			vim.cmd("stopinsert")
		end
	end

	-- :w  → submit
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		buffer = buf,
		callback = function()
			submitted = true
			local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
			local text = vim.trim(table.concat(lines, " "))
			close()
			cb(text ~= "" and text or nil)
		end,
	})

	-- Fires when the window is closed by any means (:q, :close, layout change, etc.)
	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(win),
		once = true,
		callback = function()
			if not submitted then
				vim.schedule(function()
					close()
					cb(nil)
				end)
			end
		end,
	})

	-- Safety net: if the buffer is wiped by something other than close() above
	-- (e.g. :bwipeout, session restore), still fire the cancel callback once.
	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		once = true,
		callback = function()
			if not submitted and not closed then
				closed = true
				vim.schedule(function()
					cb(nil)
				end)
			end
		end,
	})
end

-- spinner
local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local SPINNER_NS = vim.api.nvim_create_namespace("dum_spinner")

--- Show an animated spinner as virtual text on the selected lines.
--- Returns a stop() function that cancels the animation and clears the marks.
---
--- @param bufnr     integer  buffer to annotate (0 = current)
--- @param start_line integer 1-indexed first line of selection
--- @param end_line   integer 1-indexed last line of selection
--- @return fun() stop
function M.spinner(bufnr, start_line, end_line)
	if bufnr == 0 then
		bufnr = vim.api.nvim_get_current_buf()
	end

	local frame = 1

	local function set_marks()
		vim.api.nvim_buf_clear_namespace(bufnr, SPINNER_NS, 0, -1)

		local icon = SPINNER_FRAMES[frame]
		local label = icon .. " Asking Copilot…"

		-- Line above the selection (virt_lines_above on start_line)
		vim.api.nvim_buf_set_extmark(bufnr, SPINNER_NS, start_line - 1, 0, {
			virt_lines = { { { label, "DiagnosticInfo" } } },
			virt_lines_above = true,
			hl_mode = "combine",
			priority = 100,
		})

		-- Line below the selection (virt_lines on end_line)
		vim.api.nvim_buf_set_extmark(bufnr, SPINNER_NS, end_line - 1, 0, {
			virt_lines = { { { label, "DiagnosticInfo" } } },
			hl_mode = "combine",
			priority = 100,
		})
	end

	vim.schedule(set_marks)

	local timer = vim.uv.new_timer()
	timer:start(
		100,
		100,
		vim.schedule_wrap(function()
			frame = (frame % #SPINNER_FRAMES) + 1
			if vim.api.nvim_buf_is_valid(bufnr) then
				set_marks()
			end
		end)
	)

	local stopped = false
	return function()
		if stopped then
			return
		end
		stopped = true
		timer:stop()
		timer:close()
		vim.schedule(function()
			if vim.api.nvim_buf_is_valid(bufnr) then
				vim.api.nvim_buf_clear_namespace(bufnr, SPINNER_NS, 0, -1)
			end
		end)
	end
end

return M
