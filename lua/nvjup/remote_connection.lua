local kernel = require("nvjup.kernel")
local notebook = require("nvjup.notebook")
local remote = require("nvjup.remote")
local remote_client = require("nvjup.remote_files_client")

local M = {}
local client_factory = remote_client.new
local kernel_api = kernel
local colab_api = require("nvjup.colab")
local pending_colab = nil
local colab_generation = 0

local function notify(message, level)
	vim.notify("nvjup: " .. message, level or vim.log.levels.INFO)
end

local function valid_session_id(value)
	return type(value) == "string" and #value <= 64 and value:match("^[%w][%w_-]*$") ~= nil
end

local function shell_argument(value)
	if value:match("^[%w_@%%+=:,./%-]+$") then
		return value
	end
	return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function recovery_command(argv, session_id)
	if type(argv) ~= "table" or #argv < 8 or #argv > 32 or not valid_session_id(session_id) then
		return nil
	end
	if argv[#argv - 2] ~= "stop" or argv[#argv - 1] ~= "-s" or argv[#argv] ~= session_id then
		return nil
	end
	local has_auth, has_config = false, false
	local result = {}
	for index, argument in ipairs(argv) do
		if type(argument) ~= "string" or argument == "" or #argument > 4096 or argument:find("[%c]") then
			return nil
		end
		has_auth = has_auth or (argument == "--auth" and (argv[index + 1] == "oauth2" or argv[index + 1] == "adc"))
		has_config = has_config or (argument == "--config" and type(argv[index + 1]) == "string")
		result[index] = shell_argument(argument)
	end
	return has_auth and has_config and table.concat(result, " ") or nil
end

local function recovery_notice(candidate, reason)
	if type(candidate) ~= "table" or not valid_session_id(candidate.colab_session) then
		return nil
	end
	local command = recovery_command(candidate.colab_recovery_argv, candidate.colab_session)
	if not command then
		return string.format(
			"Google Colab runtime %s may still be running after %s; inspect it with the same configured Colab CLI provider",
			candidate.colab_session,
			reason
		)
	end
	return string.format(
		"Google Colab runtime %s may still be running after %s; stop it with `%s`",
		candidate.colab_session,
		reason,
		command
	)
end

local function abandon_pending(pending, reason)
	if not pending or pending_colab ~= pending then
		return nil
	end
	colab_generation = colab_generation + 1
	pending_colab = nil
	pending.cancelled = true
	if pending.operation and pending.operation.cancel then
		pending.operation.cancel()
	end
	local message = recovery_notice(pending.candidate, reason)
	pending.recovery_reported = message ~= nil
	return message
end

local function cancel_pending_colab(reason)
	return abandon_pending(pending_colab, reason or "connection cancellation")
end

local function error_message(err)
	local message = type(err) == "table" and (err.message or err.code) or tostring(err)
	message = tostring(message or "Google Colab connection failed")
	local details = type(err) == "table" and err.details or nil
	local session_id = type(details) == "table" and details.session_id or nil
	local command = type(details) == "table" and recovery_command(details.recovery_argv, session_id) or nil
	if command and not message:find(command, 1, true) then
		message = message .. "; the Colab VM may still be running—stop it with `" .. command .. "`"
	end
	return message
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
	local auth = status.provider == "colab" and "Colab proxy token" or (status.has_token and "token" or "no token")
	local tls = status.url:match("^https://") and (status.verify_ssl and "TLS verified" or "TLS verification disabled")
		or "HTTP"
	local provider = status.provider == "colab" and ("Google Colab " .. (status.colab_hardware or "runtime"))
		or "Jupyter Server"
	return string.format(
		"%s · %s · kernel %s · %s · %s · %s",
		provider,
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
	local pending_recovery = cancel_pending_colab("disconnect during connection setup")
	local status = remote.status(state)
	require("nvjup.remote_files").close_all()
	kernel_api.shutdown_remote_sessions()
	remote.disconnect()
	local suffix = ""
	if pending_recovery then
		suffix = "; " .. pending_recovery
	elseif status.provider == "colab" then
		local command = recovery_command(status.colab_recovery_argv, status.colab_session)
		suffix = command and ("; the Colab VM is still running (use `" .. command .. "`)")
			or ("; Colab runtime " .. tostring(status.colab_session) .. " may still be running")
	end
	notify("remote Jupyter session disconnected; nvjup's in-memory connection copy cleared" .. suffix)
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

local function select_kernel(state, candidate, prefer_python, lifecycle)
	local function valid()
		return not lifecycle or not lifecycle.valid or lifecycle.valid()
	end
	local function activate(kernel_name)
		if not valid() then
			return
		end
		if lifecycle and lifecycle.activate then
			lifecycle.activate(kernel_name)
		else
			M.activate(state, candidate, kernel_name)
		end
	end
	local function abandon(reason, level)
		if lifecycle and lifecycle.abandon then
			lifecycle.abandon(reason, level)
		else
			notify(reason, level)
		end
	end

	notify("checking Jupyter Server and loading kernels…")
	M.probe(state, candidate, function(err, payload)
		if not valid() then
			return
		end
		if err then
			local message = type(err) == "table" and (err.message or err.code) or tostring(err)
			abandon("server probe failed: " .. tostring(message), vim.log.levels.ERROR)
			return
		end
		local kernels = payload.kernels or {}
		if #kernels == 0 then
			abandon("the server did not return any kernelspecs", vim.log.levels.ERROR)
			return
		end
		if prefer_python then
			local preferred = {}
			for _, item in ipairs(kernels) do
				if item.name == "python3" then
					table.insert(preferred, item)
				end
			end
			if #preferred == 1 then
				activate(preferred[1].name)
				return
			end
		end
		vim.ui.select(kernels, {
			prompt = string.format("Kernel on %s", payload.url or candidate.url),
			format_item = function(item)
				local language = item.language ~= "" and (" · " .. item.language) or ""
				return string.format("%s [%s]%s", item.display_name, item.name, language)
			end,
		}, function(item)
			if not valid() then
				return
			end
			if not item then
				abandon("kernel selection was dismissed", vim.log.levels.WARN)
				return
			end
			activate(item.name)
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

function M.connect_colab(state)
	state = state or current_state()
	local replaced = cancel_pending_colab("replacement by a new connection attempt")
	if replaced then
		notify(replaced, vim.log.levels.WARN)
	end
	if not colab_api.available() then
		notify(
			"Google Colab CLI was not found; install `google-colab-cli` and ensure `colab` is executable",
			vim.log.levels.ERROR
		)
		return false
	end
	local generation = colab_generation
	local pending = { cancelled = false, operation = nil, candidate = nil, recovery_reported = false }
	pending_colab = pending
	pending.operation = colab_api.connect(function(err, candidate)
		if pending_colab ~= pending or pending.cancelled then
			if candidate and not pending.recovery_reported then
				pending.recovery_reported = true
				local message = recovery_notice(candidate, "connection cancellation after allocation")
				if message then
					notify(message, vim.log.levels.WARN)
				end
			end
			return
		end
		if err then
			pending_colab = nil
			pending.cancelled = true
			colab_generation = colab_generation + 1
			notify(error_message(err), vim.log.levels.ERROR)
			return
		end
		pending.candidate = candidate
		pending.operation = nil
		select_kernel(state, candidate, true, {
			valid = function()
				return pending_colab == pending and not pending.cancelled and generation == colab_generation
			end,
			abandon = function(reason, level)
				local message = abandon_pending(pending, reason)
				notify(message or reason, level)
			end,
			activate = function(kernel_name)
				if pending_colab ~= pending or pending.cancelled or generation ~= colab_generation then
					return
				end
				pending_colab = nil
				pending.transferred = true
				colab_generation = colab_generation + 1
				M.activate(state, candidate, kernel_name)
			end,
		})
	end)
	if pending.cancelled and pending.operation and pending.operation.cancel then
		pending.operation.cancel()
	end
	return true
end

function M.connect(state)
	state = state or current_state()
	local replaced = cancel_pending_colab("replacement by a Jupyter Server connection attempt")
	if replaced then
		notify(replaced, vim.log.levels.WARN)
	end
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

local function choose_provider(state)
	vim.ui.select({ "Jupyter Server", "Google Colab" }, { prompt = "Remote Jupyter provider" }, function(choice)
		if choice == "Jupyter Server" then
			M.connect(state)
		elseif choice == "Google Colab" then
			M.connect_colab(state)
		end
	end)
end

function M.open(state)
	state = state or current_state()
	if not remote.enabled(state) then
		choose_provider(state)
		return true
	end
	vim.ui.select({ "Reconnect or change provider", "Show connection status", "Disconnect", "Cancel" }, {
		prompt = "Remote Jupyter",
	}, function(choice)
		if choice == "Reconnect or change provider" then
			choose_provider(state)
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

function M._set_colab(api)
	local recovery = cancel_pending_colab("Colab provider reset")
	if recovery then
		notify(recovery, vim.log.levels.WARN)
	end
	colab_api = api or require("nvjup.colab")
end

function M._has_pending_colab()
	return pending_colab ~= nil
end

return M
