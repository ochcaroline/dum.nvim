local M = {}

-- ─── constants ────────────────────────────────────────────────────────────────

local CURL_TIMEOUT   = 30    -- max seconds per request before curl gives up
local BEARER_TTL     = 1800  -- fallback bearer token TTL when API omits expires_at
local DEVICE_POLL_MAX = 24   -- max device-flow polls (~2 min at 5 s default interval)

-- ─── persistent oauth token cache ────────────────────────────────────────────

local _tokens = nil

local function tokens_path()
	return vim.fs.normalize(vim.fn.stdpath("data") .. "/dum/tokens.json")
end

local function load_tokens()
	if _tokens then
		return _tokens
	end
	local fd = io.open(tokens_path(), "r")
	if fd then
		local raw = fd:read("*a")
		fd:close()
		local ok, data = pcall(vim.json.decode, raw)
		if ok and type(data) == "table" then
			_tokens = data
			return _tokens
		end
	end
	_tokens = {}
	return _tokens
end

local function persist_token(tag, value)
	local tokens = load_tokens()
	tokens[tag] = value
	local path = tokens_path()
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":p:h"), "p")
	local fd = io.open(path, "w")
	if fd then
		fd:write(vim.json.encode(tokens))
		fd:close()
		vim.uv.fs_chmod(path, 384) -- 0o600: owner read/write only
	end
	return value
end

local function clear_token(tag)
	local tokens = load_tokens()
	if tokens[tag] ~= nil then
		tokens[tag] = nil
		persist_token(tag, nil)
	end
end

-- config file reader

local function config_dir()
	local xdg = vim.fs.normalize("$XDG_CONFIG_HOME")
	if xdg ~= "$XDG_CONFIG_HOME" and vim.uv.fs_stat(xdg) then
		return xdg
	end
	return vim.fs.normalize("$HOME/.config")
end

--- Read the GitHub oauth token that copilot.vim / VS Code cached on disk.
--- @return string|nil
local function read_oauth_from_config()
	local base = config_dir()
	local paths = {
		base .. "/github-copilot/hosts.json",
		base .. "/github-copilot/apps.json",
	}
	for _, path in ipairs(paths) do
		local fd = io.open(path, "r")
		if fd then
			local raw = fd:read("*a")
			fd:close()
			local ok, data = pcall(vim.json.decode, raw)
			if ok and type(data) == "table" then
				for key, value in pairs(data) do
					if key:find("github%.com") and type(value) == "table" and value.oauth_token then
						return value.oauth_token
					end
				end
			end
		end
	end
	return nil
end

--- Fire an async curl request and return the decoded JSON body via cb(err, obj).
--- @param method  string               "GET" or "POST"
--- @param url     string
--- @param headers table<string,string> extra request headers
--- @param body    table|nil            encoded as JSON when present (implies POST body)
--- @param cb      fun(err:string|nil, obj:table|nil)
local function curl_request(method, url, headers, body, cb)
	local args = { "curl", "-s", "--max-time", tostring(CURL_TIMEOUT), "-X", method, url }
	for k, v in pairs(headers or {}) do
		table.insert(args, "-H")
		table.insert(args, k .. ": " .. v)
	end
	table.insert(args, "-H")
	table.insert(args, "Accept: application/json")
	if body then
		table.insert(args, "-H")
		table.insert(args, "Content-Type: application/json")
		table.insert(args, "-d")
		table.insert(args, vim.json.encode(body))
	end

	local done = false
	vim.fn.jobstart(args, {
		stdout_buffered = true,
		on_stdout = function(_, data)
			if done then
				return
			end
			done = true
			local raw = table.concat(data, "")
			local ok, obj = pcall(vim.json.decode, raw)
			vim.schedule(function()
				if ok and type(obj) == "table" then
					cb(nil, obj)
				else
					cb("bad response: " .. raw, nil)
				end
			end)
		end,
		on_exit = function(_, code)
			if not done then
				done = true
				vim.schedule(function()
					cb("curl exited with code " .. code, nil)
				end)
			end
		end,
	})
end

local function curl_get(url, headers, cb)
	curl_request("GET", url, headers, nil, cb)
end

local function curl_post(url, body, cb)
	curl_request("POST", url, {}, body, cb)
end

-- GitHub OAuth device flow

-- use VS Code's OAuth client ID
-- believe it or not - this is actually used across multiple other CLIs and tools XD
local COPILOT_CLIENT_ID = "Iv1.b507a08c87ecfe98"

--- Authenticate via the GitHub device flow and yield the new oauth token.
--- This is the "last resort" for authentication, if no other token was found.
--- @param cb fun(err: string|nil, token: string|nil)
local function device_flow(cb)
	curl_post("https://github.com/login/device/code", { client_id = COPILOT_CLIENT_ID, scope = "" }, function(err, res)
		if err or not res or not res.device_code then
			return cb("device flow: failed to request code: " .. (err or vim.inspect(res)), nil)
		end

		local interval_ms = (res.interval or 5) * 1000
		local device_code = res.device_code
		local poll_count = 0

		vim.notify(
			"[dum] Visit "
				.. (res.verification_uri or "https://github.com/login/device")
				.. " and enter code: "
				.. (res.user_code or ""),
			vim.log.levels.WARN
		)

		local function poll()
			poll_count = poll_count + 1
			if poll_count > DEVICE_POLL_MAX then
				return cb("device flow timed out — run the command again to retry", nil)
			end
			curl_post("https://github.com/login/oauth/access_token", {
				client_id = COPILOT_CLIENT_ID,
				device_code = device_code,
				grant_type = "urn:ietf:params:oauth:grant-type:device_code",
			}, function(poll_err, poll_res)
				if poll_err then
					return cb("device flow poll error: " .. poll_err, nil)
				end
				if poll_res and poll_res.access_token then
					persist_token("github_copilot", poll_res.access_token)
					return cb(nil, poll_res.access_token)
				elseif poll_res and poll_res.error == "authorization_pending" then
					vim.defer_fn(poll, interval_ms)
				elseif poll_res and poll_res.error then
					cb("device flow error: " .. (poll_res.error_description or poll_res.error), nil)
				else
					cb("device flow: unexpected poll response", nil)
				end
			end)
		end

		vim.defer_fn(poll, interval_ms)
	end)
end

-- oauth token acquisition

--- Obtain the GitHub oauth token using the best available source, in priority order:
---   1. Our own persistent cache (written by a previous device flow)
---   2. copilot.vim / VS Code config files (hosts.json / apps.json)
---   3. Interactive GitHub OAuth device flow
--- @param cb fun(err: string|nil, token: string|nil)
local function get_oauth_token(cb)
	-- 1. Persistent cache written by a previous device-flow sign-in
	local cached = load_tokens()["github_copilot"]
	if cached then
		return vim.schedule(function()
			cb(nil, cached)
		end)
	end

	-- 2. copilot.vim / VS Code config files
	local from_config = read_oauth_from_config()
	if from_config then
		return vim.schedule(function()
			cb(nil, from_config)
		end)
	end

	-- 3. Interactive device flow (same client-id as VS Code Copilot extension & CopilotChat)
	device_flow(cb)
end

-- short-lived bearer token cache
local _bearer = { token = nil, expires_at = 0 }

--- Exchange the GitHub oauth token for a short-lived Copilot Bearer token.
--- Caches the result and refreshes 60 s before expiry.
--- @param cb fun(err: string|nil, token: string|nil)
local function bearer_token(cb)
	if _bearer.token and os.time() < (_bearer.expires_at - 60) then
		return vim.schedule(function()
			cb(nil, _bearer.token)
		end)
	end

	get_oauth_token(function(err, oauth)
		if err then
			return cb(err, nil)
		end

		curl_get(
			"https://api.github.com/copilot_internal/v2/token",
			{ ["Authorization"] = "Token " .. oauth },
			function(get_err, obj)
				if get_err then
					-- Clear cached oauth so the next attempt re-authenticates
					clear_token("github_copilot")
					return cb("Copilot token exchange failed: " .. get_err, nil)
				end

				if obj and obj.token then
					_bearer.token = obj.token
					_bearer.expires_at = obj.expires_at or (os.time() + BEARER_TTL)
					return cb(nil, _bearer.token)
				end

				-- API returned JSON but without a token (e.g. 401 Bad credentials)
				local msg = (obj and obj.message) or "unexpected response"
				-- Clear the bad oauth token so the next call triggers re-authentication
				clear_token("github_copilot")
				cb("Copilot token exchange failed: " .. msg, nil)
			end
		)
	end)
end

local _nvim_ver = vim.version()
local EDITOR_VERSION = ("Neovim/%d.%d.%d"):format(_nvim_ver.major, _nvim_ver.minor, _nvim_ver.patch)

local SYSTEM = table.concat({
	"You are a precise code completion assistant.",
	"Complete ONLY the provided code fragment based on the given requirement.",
	"Return ONLY the completed code — no explanations, no markdown fences and do not repeat the context provided.",
	"Preserve the original indentation style and language conventions.",
}, " ")

-- response cleanup

--- Strip markdown code fences the model may add despite instructions.
--- @param text string
--- @return string
local function strip_fences(text)
	text = text:gsub("^```[%w%-]*\n", "")
	text = text:gsub("\n```%s*$", "")
	text = text:gsub("^```[%w%-]*%s*", "")
	text = text:gsub("```%s*$", "")
	return text
end

-- cancellation

local _current_job = nil
local _cancelled = false

--- Cancel the currently in-flight completion request, if any.
function M.cancel()
	if _current_job then
		_cancelled = true
		vim.fn.jobstop(_current_job)
		_current_job = nil
	end
end

-- public API

--- Complete a code fragment via the Copilot Chat Completions API.
--- @param code        string
--- @param requirement string
--- @param model       string   e.g. "claude-sonnet-4.6"
--- @param cb          fun(err: string|nil, result: string|nil)
--- @param opts?       { context?: string, on_chunk?: fun(partial: string), system_extra?: string }
function M.complete(code, requirement, model, cb, opts)
	opts = opts or {}
	local context = opts.context
	local on_chunk = opts.on_chunk
	local system_extra = opts.system_extra

	bearer_token(function(err, token)
		if err then
			return cb(err)
		end

		local system = SYSTEM
		if system_extra then
			system = system .. " " .. system_extra
		end

		local user_content = "Requirement: " .. requirement .. "\n\nCode to complete:\n" .. code
		if context then
			user_content = "Context (for reference only — do NOT repeat it):\n" .. context .. "\n\n" .. user_content
		end

		local body = vim.json.encode({
			model = model,
			stream = true,
			messages = {
				{ role = "system", content = system },
				{ role = "user", content = user_content },
			},
		})

		local accumulated = ""
		local completed = false
		local line_buf = ""
		local raw_output = "" -- collect all output to diagnose non-SSE errors

		local function process_sse_line(line)
			if not line:match("%S") then
				return
			end
			if line:sub(1, 6) ~= "data: " then
				return
			end
			local payload = line:sub(7)
			if payload == "[DONE]" then
				if not completed then
					completed = true
					local final = strip_fences(vim.trim(accumulated))
					vim.schedule(function()
						cb(nil, final)
					end)
				end
				return
			end
			local ok, obj = pcall(vim.json.decode, payload)
			if ok and obj and obj.choices and obj.choices[1] then
				local delta = obj.choices[1].delta
				if delta and delta.content then
					accumulated = accumulated .. delta.content
					if on_chunk then
						local snap = accumulated
						vim.schedule(function()
							on_chunk(snap)
						end)
					end
				end
			end
		end

		_cancelled = false
		local job_id = vim.fn.jobstart({
			"curl",
			"-s",
			"--max-time",
			tostring(CURL_TIMEOUT),
			"-X",
			"POST",
			"https://api.githubcopilot.com/chat/completions",
			"-H",
			"Authorization: Bearer " .. token,
			"-H",
			"Content-Type: application/json",
			"-H",
			"Accept: text/event-stream",
			"-H",
			"Editor-Version: " .. EDITOR_VERSION,
			"-H",
			"Editor-Plugin-Version: dum.nvim/*",
			"-H",
			"Copilot-Integration-Id: vscode-chat",
			"-H",
			"x-github-api-version: 2025-10-01",
			"-d",
			body,
		}, {
			stdout_buffered = false,
			on_stdout = function(_, data)
				if completed then
					return
				end
				local chunk = table.concat(data, "\n")
				raw_output = raw_output .. chunk
				local joined = line_buf .. chunk
				local lines = vim.split(joined, "\n", { plain = true })
				line_buf = lines[#lines]
				for i = 1, #lines - 1 do
					process_sse_line(lines[i])
				end
			end,
			on_exit = function(_, code)
				_current_job = nil
				if completed or _cancelled then
					_cancelled = false
					return
				end
				-- Flush any line that arrived without a trailing newline.
				if line_buf ~= "" then
					process_sse_line(line_buf)
					line_buf = ""
				end
				-- process_sse_line may have set completed=true (found [DONE] in flush).
				if completed then
					return
				end
				completed = true
				vim.schedule(function()
					if accumulated ~= "" then
						cb(nil, strip_fences(vim.trim(accumulated)))
					elseif code ~= 0 then
						cb("curl exited with code " .. code)
					else
						-- No SSE content: try to surface a JSON error message.
						local ok, obj = pcall(vim.json.decode, raw_output)
						local msg = (ok and obj and obj.error and obj.error.message)
							or "no content received"
						cb(msg)
					end
				end)
			end,
		})
		_current_job = job_id
	end)
end

return M
