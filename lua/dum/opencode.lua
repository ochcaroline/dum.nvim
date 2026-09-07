local M = {}

local DUM_AGENT = {
	description = "Return replacement code without modifying files",
	mode = "primary",
	permission = {
		["*"] = "deny",
		read = "allow",
		glob = "allow",
		grep = "allow",
		lsp = "allow",
	},
	prompt = table.concat({
		"Apply the requirement to the code fragment provided in the prompt.",
		"Return only the complete replacement code.",
		"Do not edit files, run shell commands, ask questions, or delegate work.",
	}, "\n"),
}

local SYSTEM = table.concat({
	"You are editing a selected code fragment.",
	"Apply the user's requirement to the fragment and return ONLY the complete replacement code.",
	"Do not include explanations or markdown fences.",
	"Preserve the original indentation style and language conventions.",
	"PONYTAIL MODE ACTIVE: use the smallest correct change; reuse existing code, then prefer the standard library or native features; do not add unrequested abstractions, dependencies, or boilerplate.",
}, " ")

local _current_job = nil

--- Cancel the currently in-flight OpenCode request, if any.
function M.cancel()
	if _current_job then
		vim.fn.jobstop(_current_job)
		_current_job = nil
	end
end

--- Run OpenCode non-interactively and return the replacement fragment.
--- @param code string
--- @param requirement string
--- @param model string|nil provider/model, when configured
--- @param cb fun(err:string|nil, result:string|nil)
--- @param opts table|nil
function M.complete(code, requirement, model, cb, opts)
	opts = opts or {}
	local context = opts.context
	local prompt = SYSTEM .. "\n\n"
	if context then
		prompt = prompt .. "Context (for reference only):\n" .. context .. "\n\n"
	end
	prompt = prompt .. "Requirement: " .. requirement .. "\n\nCode to edit:\n" .. code

	local command = opts.command or "opencode"
	local timeout = opts.timeout or 120000
	local args = { command, "run", "--format", "json" }
	if opts.pure ~= false then
		table.insert(args, "--pure")
	end
	if model and model ~= "" then
		table.insert(args, "--model")
		table.insert(args, model)
	end
	if opts.agent and opts.agent ~= "" then
		table.insert(args, "--agent")
		table.insert(args, opts.agent)
	end
	table.insert(args, "--")
	table.insert(args, prompt)

	local output = {}
	local errors = {}
	local done = false
	local timer = vim.uv.new_timer()
	local job_id
	local function finish(err, result)
		if done then
			return
		end
		done = true
		timer:stop()
		timer:close()
		cb(err, result)
	end

	job_id = vim.fn.jobstart(args, {
		env = { OPENCODE_CONFIG_CONTENT = vim.json.encode({ agent = { dum = DUM_AGENT } }) },
		stdin = "null",
		stdout_buffered = true,
		stderr_buffered = true,
		on_stdout = function(_, data)
			for _, line in ipairs(data) do
				if line ~= "" then
					output[#output + 1] = line
				end
			end
		end,
		on_stderr = function(_, data)
			for _, line in ipairs(data) do
				if line ~= "" then
					errors[#errors + 1] = line
				end
			end
		end,
		on_exit = function(_, code)
			if _current_job == job_id then
				_current_job = nil
			end
			if done then
				return
			end
			vim.schedule(function()
				if code ~= 0 then
					return finish("OpenCode exited with code " .. code .. (errors[1] and (": " .. errors[1]) or ""))
				end

				local result = {}
				for _, line in ipairs(output) do
					local ok, event = pcall(vim.json.decode, line)
					if ok and event and event.type == "text" and event.part and event.part.text then
						result[#result + 1] = event.part.text
					end
				end
				if #result == 0 then
					return finish("OpenCode returned no replacement code")
				end
				finish(nil, vim.trim(table.concat(result)))
			end)
		end,
	})
	_current_job = job_id
	timer:start(timeout, 0, vim.schedule_wrap(function()
		if not done then
			vim.fn.jobstop(job_id)
			_current_job = nil
			finish("OpenCode timed out after " .. timeout .. " ms")
		end
	end))
end

return M
