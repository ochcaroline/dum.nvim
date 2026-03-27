--- Visual selection utilities.
local M = {}

--- Returns true when every line in lines is blank or whitespace-only.
--- @param lines string[]
--- @return boolean
function M.is_empty(lines)
	for _, line in ipairs(lines) do
		if line:match("%S") then
			return false
		end
	end
	return true
end

--- Return the lines, start line, and end line of the last visual selection.
--- Must be called after exiting visual mode (marks '< and '> are set).
--- @return string[] lines
--- @return integer start_line  1-indexed
--- @return integer end_line    1-indexed
function M.get()
	local start_line = vim.fn.getpos("'<")[2]
	local end_line = vim.fn.getpos("'>")[2]
	local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
	return lines, start_line, end_line
end

--- Detect the common leading whitespace of a list of lines (ignores blank lines).
--- @param lines string[]
--- @return string prefix
local function base_indent(lines)
	local prefix
	for _, line in ipairs(lines) do
		if line:match("%S") then
			local indent = line:match("^(%s*)")
			if prefix == nil or #indent < #prefix then
				prefix = indent
			end
		end
	end
	return prefix or ""
end

--- Strip a common leading prefix from every line.
--- @param lines string[]
--- @return string[] stripped
--- @return string prefix  the removed prefix, for re-application
function M.strip_indent(lines)
	local prefix = base_indent(lines)
	local escaped = vim.pesc(prefix)
	local stripped = {}
	for _, line in ipairs(lines) do
		stripped[#stripped + 1] = line:gsub("^" .. escaped, "", 1)
	end
	return stripped, prefix
end

--- Re-apply a leading prefix to every non-blank line.
--- @param lines string[]
--- @param prefix string
--- @return string[]
function M.apply_indent(lines, prefix)
	local result = {}
	for _, line in ipairs(lines) do
		result[#result + 1] = (line ~= "" and line:match("%S")) and (prefix .. line) or line
	end
	return result
end

--- Replace lines in the current buffer (0-indexed exclusive end for nvim_buf_set_lines).
--- @param start_line integer  1-indexed
--- @param end_line   integer  1-indexed
--- @param new_lines  string[]
function M.replace(start_line, end_line, new_lines)
	vim.api.nvim_buf_set_lines(0, start_line - 1, end_line, false, new_lines)
end

return M
