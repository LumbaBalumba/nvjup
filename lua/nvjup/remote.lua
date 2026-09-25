local config = require("nvjup.config")

local M = {}
local session_override_set = false
local session_profile = nil

local function configured(state, ignore_session)
	if session_override_set and not ignore_session then
		return session_profile
	end
	local options = (config.options.kernel or {}).remote
	if type(options) == "function" then
		options = options(state and state.path or "", state)
	end
	if type(options) ~= "table" or type(options.url) ~= "string" or options.url == "" then
		return nil
	end
	return options
end

local function normalized(state, options)
	if not options then
		return nil
	end
	local token = options.token
	if type(token) == "function" then
		token = token(state and state.path or "", state)
	end
	if (type(token) ~= "string" or token == "") and type(options.token_env) == "string" then
		token = vim.env[options.token_env]
	end
	local files = config.options.remote_files or {}
	local provider = options.provider == "colab" and "colab" or "jupyter"
	return {
		url = options.url:gsub("/+$", ""),
		token = type(token) == "string" and token or "",
		provider = provider,
		auth = provider == "colab" and "proxy_token" or (options.auth or "token"),
		verify_ssl = options.verify_ssl ~= false,
		origin = type(options.origin) == "string" and options.origin ~= "" and options.origin or nil,
		reconnect_attempts = math.max(0, math.min(tonumber(options.reconnect_attempts) or 2, 5)),
		file_timeout_seconds = math.max(
			1,
			math.min(tonumber(options.file_timeout_seconds) or files.timeout_seconds or 60, 300)
		),
		max_file_bytes = math.max(
			1,
			math.min(tonumber(options.max_file_bytes) or files.max_file_bytes or 64 * 1024 * 1024, 512 * 1024 * 1024)
		),
		max_entries = math.max(1, math.min(tonumber(options.max_entries) or files.max_entries or 10000, 100000)),
		kernel_name = type(options.kernel_name) == "string" and options.kernel_name ~= "" and options.kernel_name
			or nil,
		colab_session = provider == "colab" and type(options.colab_session) == "string" and options.colab_session:sub(
			1,
			64
		) or nil,
		colab_endpoint = provider == "colab"
				and type(options.colab_endpoint) == "string"
				and options.colab_endpoint:sub(1, 512)
			or nil,
		colab_hardware = provider == "colab"
				and type(options.colab_hardware) == "string"
				and options.colab_hardware:sub(1, 128)
			or nil,
		colab_recovery_argv = provider == "colab" and type(options.colab_recovery_argv) == "table" and vim.deepcopy(
			options.colab_recovery_argv
		) or nil,
		colab_recovery_command = provider == "colab"
				and type(options.colab_recovery_command) == "string"
				and options.colab_recovery_command:sub(1, 32768)
			or nil,
	}
end

function M.enabled(state)
	return configured(state) ~= nil
end

function M.resolve(state)
	return normalized(state, configured(state))
end

function M.configured(state)
	return normalized(state, configured(state, true))
end

function M.set_session(profile)
	assert(type(profile) == "table" and type(profile.url) == "string" and profile.url ~= "")
	session_override_set = true
	session_profile = vim.deepcopy(profile)
end

function M.disconnect()
	session_override_set = true
	session_profile = nil
end

function M.reset_session()
	session_override_set = false
	session_profile = nil
end

function M.session()
	return session_override_set and session_profile and vim.deepcopy(session_profile) or nil
end

function M.kernel_name(state)
	local options = configured(state)
	return options and type(options.kernel_name) == "string" and options.kernel_name ~= "" and options.kernel_name
		or nil
end

function M.status(state)
	local options = configured(state)
	return {
		connected = options ~= nil,
		source = session_override_set and (session_profile and "session" or "disconnected") or "config",
		url = options and options.url:gsub("/+$", "") or nil,
		kernel_name = options and options.kernel_name or nil,
		verify_ssl = options and options.verify_ssl ~= false,
		provider = options and (options.provider == "colab" and "colab" or "jupyter") or nil,
		colab_session = options and options.colab_session or nil,
		colab_hardware = options and options.colab_hardware or nil,
		colab_recovery_argv = options and options.colab_recovery_argv and vim.deepcopy(options.colab_recovery_argv)
			or nil,
		colab_recovery_command = options and options.colab_recovery_command or nil,
		has_token = options
				and ((type(options.token) == "string" and options.token ~= "") or type(options.token) == "function" or options.token_env ~= nil)
			or false,
	}
end

return M
