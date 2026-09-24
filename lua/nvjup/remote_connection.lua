local kernel = require("nvjup.kernel")
local notebook = require("nvjup.notebook")
local remote = require("nvjup.remote")
local remote_client = require("nvjup.remote_files_client")

local M = {}
local client_factory = remote_client.new
local kernel_api = kernel

local function notify(message, level)
	vim.notify("nvjup: " .. message, level or vim.log.levels.INFO)
end

local function current_state()
	return notebook.get() or {
		buf = vim.api.nvim_get_current_buf(),
		path = vim.api.nvim_buf_get_name(0),
	}
end

local function input(prompt, default, callback)
	vim.ui.input({ prompt = prompt, default = default or "" }, function(value)
		if value == nil then
			callback(nil)
			return
		end
		callback(vim.trim(value))
	end)
end

local function default_secret_reader(prompt, callback)
	vim.schedule(function()
		local ok, value = pcall(vim.fn.inputsecret, prompt)
		vim.cmd.redraw()
		callback(ok and value or nil)
	end)
end

local secret_reader = default_secret_reader

local function valid_url(url)
	return type(url) == "string"
		and url:match("^https?://[^/%s?#]+") ~= nil
		and not url:find("?", 1, true)
		and not url:find("#", 1, true)
		and not url:match("^https?://[^/]*@")
end

local function status_message(state)
	local status = remote.status(state)
	if not status.connected then
		return "remote Jupyter Server is disconnected"
	end
	local auth = status.has_token and "token" or "no token"
	local tls = status.url:match("^https://") and (status.verify_ssl and "TLS verified" or "TLS verification disabled")
		or "HTTP"
	return string.format(
		"remote %s · kernel %s · %s · %s · %s",
		status.url,
		status.kernel_name or "not selected",
		auth,
		tls,
		status.source
	)
end

function M.status(state)
	state = state or current_state()
	local message = status_message(state)
	notify(message, remote.enabled(state) and vim.log.levels.INFO or vim.log.levels.WARN)
	return remote.status(state)
end

function M.disconnect(state)
	state = state or current_state()
	require("nvjup.remote_files").close_all()
	kernel_api.shutdown_remote_sessions()
	remote.disconnect()
	notify("remote Jupyter session disconnected; in-memory credentials cleared")
	return true
end

function M.probe(state, candidate, callback)
	local client = client_factory(state, candidate)
	client:probe(function(err, payload)
		client:shutdown()
		callback(err, payload)
	end)
end

function M.activate(state, candidate, selected_kernel, callback)
	candidate = vim.tbl_deep_extend("force", candidate, { kernel_name = selected_kernel })
	require("nvjup.remote_files").close_all()
	kernel_api.shutdown_remote_sessions()
	if state.document then
		kernel_api.shutdown(state)
	end
	remote.set_session(candidate)
	if not state.document then
		notify(string.format("connected to %s; kernel %s selected", candidate.url, selected_kernel))
		if callback then
			callback(nil, remote.status(state))
		end
		return
	end
	kernel_api.start(state, function(err, status)
		if not err then
			notify(string.format("connected to %s; kernel %s is ready", candidate.url, selected_kernel))
		end
		if callback then
			callback(err, status)
		end
	end)
end

local function select_kernel(state, candidate)
	notify("checking Jupyter Server and loading kernels…")
	M.probe(state, candidate, function(err, payload)
		if err then
			notify(err.message or err.code or tostring(err), vim.log.levels.ERROR)
			return
		end
		local kernels = payload.kernels or {}
		if #kernels == 0 then
			notify("the server did not return any kernelspecs", vim.log.levels.ERROR)
			return
		end
		vim.ui.select(kernels, {
			prompt = string.format("Kernel on %s", payload.url or candidate.url),
			format_item = function(item)
				local language = item.language ~= "" and (" · " .. item.language) or ""
				return string.format("%s [%s]%s", item.display_name, item.name, language)
			end,
		}, function(item)
			if item then
				M.activate(state, candidate, item.name)
			end
		end)
	end)
end

local function ask_origin(state, candidate, default)
	input("Jupyter Origin header (optional): ", default or "", function(origin)
		if origin == nil then
			return
		end
		candidate.origin = origin ~= "" and origin or nil
		select_kernel(state, candidate)
	end)
end

local function ask_tls(state, candidate, default)
	if candidate.url:match("^https://") then
		vim.ui.select({
			{ label = "Verify TLS certificate (recommended)", verify = true },
			{ label = "Disable TLS verification", verify = false },
		}, {
			prompt = "TLS policy",
			format_item = function(item)
				return item.label
			end,
		}, function(item)
			if item then
				candidate.verify_ssl = item.verify
				ask_origin(state, candidate, default and default.origin)
			end
		end)
		return
	end
	vim.ui.select({ "Continue through HTTP/SSH tunnel", "Cancel" }, {
		prompt = "The connection is not end-to-end HTTPS",
	}, function(choice)
		if choice == "Continue through HTTP/SSH tunnel" then
			candidate.verify_ssl = true
			ask_origin(state, candidate, default and default.origin)
		end
	end)
end

local function ask_auth(state, candidate, default)
	local choices = { "Enter token", "Connect without token" }
	if default and default.token and default.token ~= "" then
		table.insert(choices, 1, "Reuse current in-memory token")
	end
	vim.ui.select(choices, { prompt = "Jupyter authentication" }, function(choice)
		if choice == "Reuse current in-memory token" then
			candidate.token = default.token
			ask_tls(state, candidate, default)
		elseif choice == "Connect without token" then
			candidate.token = ""
			ask_tls(state, candidate, default)
		elseif choice == "Enter token" then
			secret_reader("Jupyter token (input is hidden): ", function(token)
				if token ~= nil then
					candidate.token = token
					ask_tls(state, candidate, default)
				end
			end)
		end
	end)
end

function M.connect(state)
	state = state or current_state()
	local default = remote.session() or remote.configured(state)
	input("Jupyter Server URL: ", default and default.url or "", function(url)
		if url == nil then
			return
		end
		url = url:gsub("/+$", "")
		if not valid_url(url) then
			notify(
				"URL must use http:// or https:// and cannot contain credentials, query, or fragment",
				vim.log.levels.ERROR
			)
			return
		end
		ask_auth(state, {
			url = url,
			reconnect_attempts = default and default.reconnect_attempts or 2,
			file_timeout_seconds = default and default.file_timeout_seconds or 60,
			max_file_bytes = default and default.max_file_bytes or nil,
			max_entries = default and default.max_entries or nil,
		}, default)
	end)
	return true
end

function M.open(state)
	state = state or current_state()
	if not remote.enabled(state) then
		return M.connect(state)
	end
	vim.ui.select({ "Reconnect or change server", "Show connection status", "Disconnect", "Cancel" }, {
		prompt = "Remote Jupyter",
	}, function(choice)
		if choice == "Reconnect or change server" then
			M.connect(state)
		elseif choice == "Show connection status" then
			M.status(state)
		elseif choice == "Disconnect" then
			M.disconnect(state)
		end
	end)
	return true
end

function M._set_client_factory(factory)
	client_factory = factory or remote_client.new
end

function M._set_kernel(api)
	kernel_api = api or kernel
end

function M._set_secret_reader(reader)
	secret_reader = reader or default_secret_reader
end

return M
