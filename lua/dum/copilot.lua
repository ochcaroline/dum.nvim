local M = {}

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

-- ─── config file reader ───────────────────────────────────────────────────────

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

-- ─── low-level async curl helper ─────────────────────────────────────────────

--- Fire an async curl request and return the decoded JSON body via cb(err, obj).
--- @param method  string               "GET" or "POST"
--- @param url     string
--- @param headers table<string,string> extra request headers
--- @param body    table|nil            encoded as JSON when present (implies POST body)
--- @param cb      fun(err:string|nil, obj:table|nil)
local function curl_request(method, url, headers, body, cb)
	local args = { "curl", "-s", "-X", method, url }
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

-- ─── GitHub OAuth device flow ─────────────────────────────────────────────────

-- use VS Code's OAuth client ID
-- believe it or not - this is actually used across multiple other CLIs and tools XD
local COPILOT_CLIENT_ID = "Iv1.b507a08c87ecfe98"

--- Authenticate via the GitHub device flow and yield the new oauth token.
--- THis is "last resort" for authentication, if no other token was found
--- @param cb fun(err: string|nil, token: string|nil)
local function device_flow(cb)
	curl_post("https://github.com/login/device/code", { client_id = COPILOT_CLIENT_ID, scope = "" }, function(err, res)
		if err or not res or not res.device_code then
			return cb("device flow: failed to request code: " .. (err or vim.inspect(res)), nil)
		end

		local interval_ms = (res.interval or 5) * 1000
		local device_code = res.device_code

		vim.notify(
			"[dum] Visit "
				.. (res.verification_uri or "https://github.com/login/device")
				.. " and enter code: "
				.. (res.user_code or ""),
			vim.log.levels.WARN
		)

		local function poll()
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

-- ─── oauth token acquisition ──────────────────────────────────────────────────

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

-- ─── short-lived bearer token cache ──────────────────────────────────────────
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
					_bearer.expires_at = obj.expires_at or (os.time() + 1800)
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

-- ─── module-level constants ──────────────────────────────────────────────────

local _nvim_ver = vim.version()
local EDITOR_VERSION = ("Neovim/%d.%d.%d"):format(_nvim_ver.major, _nvim_ver.minor, _nvim_ver.patch)

-- ─── minimal system prompt ───────────────────────────────────────────────────
local SYSTEM = table.concat({
	"You are a precise code completion assistant.",
	"Complete ONLY the provided code fragment based on the given requirement.",
	"Return ONLY the completed code — no explanations, no markdown fences.",
	"Preserve the original indentation style and language conventions.",
}, " ")

-- ─── response cleanup ────────────────────────────────────────────────────────

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

-- ─── public API ─────────────────────────────────────────────────────────────

--- Complete a code fragment via the Copilot Chat Completions API.
--- @param code        string
--- @param requirement string
--- @param model       string   e.g. "claude-sonnet-4.6"
--- @param cb fun(err: string|nil, result: string|nil)
function M.complete(code, requirement, model, cb)
	bearer_token(function(err, token)
		if err then
			return cb(err)
		end

		local body = vim.json.encode({
			model = model,
			stream = false,
			messages = {
				{ role = "system", content = SYSTEM },
				{
					role = "user",
					content = "Requirement: " .. requirement .. "\n\nCode to complete:\n" .. code,
				},
			},
		})

		local completed = false
		vim.fn.jobstart({
			"curl",
			"-s",
			"-X",
			"POST",
			"https://api.githubcopilot.com/chat/completions",
			"-H",
			"Authorization: Bearer " .. token,
			"-H",
			"Content-Type: application/json",
			"-H",
			"Accept: application/json",
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
			stdout_buffered = true,
			on_stdout = function(_, data)
				if completed then
					return
				end
				local raw = table.concat(data, "")
				if raw == "" then
					return
				end
				completed = true
				local ok, obj = pcall(vim.json.decode, raw)
				if ok and obj and obj.choices and obj.choices[1] then
					local content = obj.choices[1].message and obj.choices[1].message.content or ""
					cb(nil, strip_fences(vim.trim(content)))
				else
					local msg = (ok and obj and obj.error and obj.error.message) or raw
					cb("API error: " .. msg)
				end
			end,
			on_exit = function(_, code)
				if not completed and code ~= 0 then
					completed = true
					cb("curl exited with code " .. code)
				end
			end,
		})
	end)
end

return M
