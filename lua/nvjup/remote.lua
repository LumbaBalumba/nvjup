local config = require("nvjup.config")

local M = {}

local function configured(state)
	local remote = (config.options.kernel or {}).remote
	if type(remote) == "function" then
		remote = remote(state and state.path or "", state)
	end
	if type(remote) ~= "table" or type(remote.url) ~= "string" or remote.url == "" then
		return nil
	end
	return remote
end

function M.enabled(state)
	return configured(state) ~= nil
end

function M.resolve(state)
	local remote = configured(state)
	if not remote then
		return nil
	end
	local token = remote.token
	if type(token) == "function" then
		token = token(state and state.path or "", state)
	end
	if (type(token) ~= "string" or token == "") and type(remote.token_env) == "string" then
		token = vim.env[remote.token_env]
	end
	local files = config.options.remote_files or {}
	return {
		url = remote.url,
		token = type(token) == "string" and token or "",
		verify_ssl = remote.verify_ssl ~= false,
		origin = type(remote.origin) == "string" and remote.origin or nil,
		reconnect_attempts = math.max(0, math.min(tonumber(remote.reconnect_attempts) or 2, 5)),
		file_timeout_seconds = math.max(
			1,
			math.min(tonumber(remote.file_timeout_seconds) or files.timeout_seconds or 60, 300)
		),
		max_file_bytes = math.max(
			1,
			math.min(tonumber(remote.max_file_bytes) or files.max_file_bytes or 64 * 1024 * 1024, 512 * 1024 * 1024)
		),
		max_entries = math.max(1, math.min(tonumber(remote.max_entries) or files.max_entries or 10000, 100000)),
	}
end

return M
