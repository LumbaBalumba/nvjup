local config = require("nvjup.config")

local M = {}
local Client = {}
Client.__index = Client
local python_resolver = {
	probe_cache = {},
	resolved = false,
	resolving = false,
	selected = nil,
	waiters = {},
}

local function plugin_root()
	local source = debug.getinfo(1, "S").source:gsub("^@", "")
	return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

local function sidecar_path()
	return vim.fs.joinpath(plugin_root(), "python", "nvjup_sidecar_main.py")
end

local function python_candidates()
	local root = plugin_root()
	local candidates = {
		vim.fs.joinpath(root, ".venv", "bin", "python"),
		vim.fs.joinpath(root, ".venv", "Scripts", "python.exe"),
	}
	local function add(candidate)
		if candidate and candidate ~= "" then
			table.insert(candidates, candidate)
		end
	end
	if vim.env.VIRTUAL_ENV then
		add(vim.fs.joinpath(vim.env.VIRTUAL_ENV, "bin", "python"))
		add(vim.fs.joinpath(vim.env.VIRTUAL_ENV, "Scripts", "python.exe"))
	end
	add(vim.g.python3_host_prog)
	add(vim.fn.exepath("python3"))
	add(vim.fn.exepath("python.exe"))
	add("/usr/bin/python3")
	add(vim.fn.exepath("python"))

	local unique = {}
	local seen = {}
	for _, candidate in ipairs(candidates) do
		if candidate ~= "" and not seen[candidate] then
			seen[candidate] = true
			table.insert(unique, candidate)
		end
	end
	return unique
end

local function default_probe_factory(python, callback)
	local ok, process = pcall(vim.system, { python, "-c", "import jupyter_client" }, {
		text = true,
		timeout = 3000,
	}, function(result)
		vim.schedule(function()
			callback(result.code == 0)
		end)
	end)
	if not ok then
		vim.schedule(function()
			callback(false)
		end)
		return nil
	end
	return process
end

local function resolve_python(probe_factory, callback)
	if python_resolver.resolved then
		callback(python_resolver.selected)
		return
	end
	table.insert(python_resolver.waiters, callback)
	if python_resolver.resolving then
		return
	end
	python_resolver.resolving = true
	local candidates = python_candidates()
	local index = 0

	local function finish(python)
		python_resolver.selected = python
		python_resolver.resolved = true
		python_resolver.resolving = false
		local waiters = python_resolver.waiters
		python_resolver.waiters = {}
		for _, waiter in ipairs(waiters) do
			waiter(python)
		end
	end

	local function probe_next()
		index = index + 1
		local python = candidates[index]
		if not python then
			finish(nil)
			return
		end
		local cached = python_resolver.probe_cache[python]
		if cached ~= nil then
			if cached then
				finish(python)
			else
				probe_next()
			end
			return
		end
		local completed = false
		local function on_probe(available)
			if completed then
				return
			end
			completed = true
			python_resolver.probe_cache[python] = available == true
			if available then
				finish(python)
			else
				probe_next()
			end
		end
		local ok = pcall(probe_factory, python, on_probe)
		if not ok then
			on_probe(false)
		end
	end

	probe_next()
end

local function configured_command(options)
	if type(options.command) == "function" then
		return options.command()
	end
	if type(options.command) == "table" and #options.command > 0 then
		return vim.deepcopy(options.command)
	end
	if type(options.python) == "string" and options.python ~= "" then
		return { options.python, sidecar_path() }
	end
end

local function default_command()
	local options = config.options.sidecar or {}
	local command = configured_command(options)
	if command then
		return command
	end
	local python = python_resolver.selected
	if not python then
		for _, candidate in ipairs(python_candidates()) do
			if vim.uv.fs_stat(candidate) then
				python = candidate
				break
			end
		end
	end
	return { python or "python3", sidecar_path() }
end

local function structured_error(code, message, retryable, details)
	return {
		code = code,
		message = message,
		retryable = retryable == true,
		details = details or {},
	}
end

function Client.new(options)
	options = options or {}
	local command = options.command
	if not command then
		command = configured_command(config.options.sidecar or {})
	end
	return setmetatable({
		command = command and vim.deepcopy(command) or nil,
		cwd = options.cwd,
		env = options.env,
		on_event = options.on_event,
		on_exit = options.on_exit,
		on_stderr = options.on_stderr,
		probe_factory = options.probe_factory or default_probe_factory,
		process_factory = options.process_factory or vim.system,
		pending = {},
		queued = {},
		request_seq = 0,
		stdout_buffer = "",
		stderr_buffer = "",
		alive = false,
		starting = false,
		closed = false,
		generation = 0,
	}, Client)
end

function Client:_start_process()
	if self.closed then
		return nil, "sidecar client is closed"
	end
	if self.alive and self.process and not self.process:is_closing() then
		return true
	end
	if self.starting then
		return true
	end
	self.starting = true
	local maximum = (config.options.sidecar and config.options.sidecar.max_message_bytes) or (128 * 1024 * 1024)
	local env = vim.tbl_extend("force", {}, self.env or {}, { NVJUP_MAX_MESSAGE_BYTES = tostring(maximum) })
	local ok, process = pcall(self.process_factory, self.command, {
		cwd = self.cwd,
		env = env,
		stdin = true,
		text = true,
		stdout = function(err, data)
			if err then
				vim.schedule(function()
					self:_fail_all(structured_error("sidecar_stdout_failed", err, true))
				end)
				return
			end
			if data then
				vim.schedule(function()
					self:_consume_stdout(data)
				end)
			end
		end,
		stderr = function(_, data)
			if data then
				vim.schedule(function()
					self:_consume_stderr(data)
				end)
			end
		end,
	}, function(result)
		vim.schedule(function()
			self.alive = false
			self.starting = false
			self:_fail_all(
				structured_error(
					"sidecar_exited",
					string.format("sidecar exited with code %d", result.code),
					true,
					{ code = result.code, signal = result.signal, stderr = self.stderr_buffer }
				)
			)
			if self.on_exit then
				self.on_exit(result)
			end
		end)
	end)
	if not ok or not process then
		self.starting = false
		return nil, process or "process factory returned no process"
	end
	self.process = process
	self.alive = true
	self.starting = false
	self:_flush_queue()
	return true
end

function Client:start()
	if self.closed then
		return nil, "sidecar client is closed"
	end
	if self.alive and self.process and not self.process:is_closing() then
		return true
	end
	if self.starting then
		return true
	end
	if self.command then
		return self:_start_process()
	end
	self.starting = true
	self.last_start_error = nil
	local generation = self.generation
	resolve_python(self.probe_factory, function(python)
		if self.closed or generation ~= self.generation then
			return
		end
		self.starting = false
		if not python then
			self.last_start_error = "no Python with jupyter_client was found"
			self:_fail_all(structured_error("sidecar_start_failed", self.last_start_error, true))
			return
		end
		self.command = { python, sidecar_path() }
		local ok, err = self:_start_process()
		if not ok then
			self.last_start_error = tostring(err)
			self:_fail_all(structured_error("sidecar_start_failed", self.last_start_error, true))
		end
	end)
	if self.last_start_error then
		return nil, self.last_start_error
	end
	return true
end

function Client:_consume_stdout(data)
	local maximum = (config.options.sidecar and config.options.sidecar.max_message_bytes) or (128 * 1024 * 1024)
	if #self.stdout_buffer + #data > maximum then
		self.stdout_buffer = ""
		local err = structured_error(
			"sidecar_message_too_large",
			string.format("sidecar message exceeds %d bytes", maximum),
			false
		)
		self:_fail_all(err)
		self:kill()
		return
	end
	self.stdout_buffer = self.stdout_buffer .. data
	while true do
		local newline = self.stdout_buffer:find("\n", 1, true)
		if not newline then
			break
		end
		local line = self.stdout_buffer:sub(1, newline - 1)
		self.stdout_buffer = self.stdout_buffer:sub(newline + 1)
		if line ~= "" then
			local ok, message = pcall(vim.json.decode, line)
			if ok and type(message) == "table" and message.protocol == "nvjup/1" then
				self:_dispatch(message)
			else
				self:_consume_stderr("invalid sidecar message: " .. line .. "\n")
			end
		end
	end
end

function Client:_consume_stderr(data)
	self.stderr_buffer = self.stderr_buffer .. data
	local limit = (config.options.sidecar and config.options.sidecar.stderr_limit) or 16384
	if #self.stderr_buffer > limit then
		self.stderr_buffer = self.stderr_buffer:sub(-limit)
	end
	if self.on_stderr then
		self.on_stderr(data)
	end
end

function Client:_dispatch(message)
	if message.kind == "response" then
		local pending = message.id and self.pending[message.id]
		if not pending then
			return
		end
		self.pending[message.id] = nil
		pending.done = true
		if pending.timer and not pending.timer:is_closing() then
			pending.timer:stop()
			pending.timer:close()
		end
		if pending.callback then
			pending.callback(message.error, message.payload or {}, message)
		end
	elseif message.kind == "event" and self.on_event then
		self.on_event(message)
	end
end

local function fail_request(request, err)
	if request.timer and not request.timer:is_closing() then
		request.timer:stop()
		request.timer:close()
	end
	if not request.done and request.callback then
		request.done = true
		request.callback(err, {}, nil)
	end
end

function Client:_fail_all(err)
	local pending = self.pending
	self.pending = {}
	local queued = self.queued
	self.queued = {}
	for _, item in ipairs(queued) do
		local request = pending[item.id]
		pending[item.id] = nil
		if request then
			fail_request(request, err)
		end
	end
	for _, request in pairs(pending) do
		fail_request(request, err)
	end
end

function Client:_write_request(item)
	local request = self.pending[item.id]
	if not request then
		return nil
	end
	local write_ok, write_err = pcall(self.process.write, self.process, item.encoded .. "\n")
	if not write_ok then
		self.pending[item.id] = nil
		fail_request(request, structured_error("sidecar_write_failed", tostring(write_err), true))
		return nil
	end
	if item.timeout > 0 then
		local timer = vim.uv.new_timer()
		request.timer = timer
		timer:start(item.timeout, 0, function()
			vim.schedule(function()
				local pending = self.pending[item.id]
				if pending and not pending.done then
					self.pending[item.id] = nil
					fail_request(
						pending,
						structured_error("request_timeout", string.format("%s timed out", item.request_type), true)
					)
				end
			end)
		end)
	end
	return true
end

function Client:_flush_queue()
	if not self.alive or not self.process or self.process:is_closing() then
		return
	end
	local queued = self.queued
	self.queued = {}
	for _, item in ipairs(queued) do
		self:_write_request(item)
	end
end

function Client:request(request_type, payload, context, callback)
	if self.closed then
		if callback then
			callback(structured_error("sidecar_start_failed", "sidecar client is closed", false), {}, nil)
		end
		return nil
	end
	if not self.alive or not self.process or self.process:is_closing() then
		local ok, err = self:start()
		if not ok then
			if callback then
				callback(structured_error("sidecar_start_failed", tostring(err), true), {}, nil)
			end
			return nil
		end
	end
	self.request_seq = self.request_seq + 1
	local id = string.format("request-%d", self.request_seq)
	payload = payload or {}
	if type(payload) == "table" and next(payload) == nil then
		payload = vim.empty_dict()
	end
	local message = {
		protocol = "nvjup/1",
		kind = "request",
		type = request_type,
		id = id,
		seq = self.request_seq,
		payload = payload,
	}
	for _, field in ipairs({ "notebook_id", "cell_id", "revision" }) do
		if context and context[field] ~= nil then
			message[field] = context[field]
		end
	end
	self.pending[id] = { callback = callback, done = false, timer = nil }
	local encoded_ok, encoded = pcall(vim.json.encode, message)
	if not encoded_ok then
		self.pending[id] = nil
		if callback then
			callback(structured_error("request_encode_failed", tostring(encoded), false), {}, nil)
		end
		return nil
	end
	local maximum = (config.options.sidecar and config.options.sidecar.max_message_bytes) or (128 * 1024 * 1024)
	if #encoded + 1 > maximum then
		self.pending[id] = nil
		if callback then
			callback(
				structured_error(
					"request_message_too_large",
					string.format("request message exceeds %d bytes", maximum),
					false
				),
				{},
				nil
			)
		end
		return nil
	end
	local item = {
		id = id,
		encoded = encoded,
		request_type = request_type,
		timeout = (context and context.timeout_ms)
			or (config.options.sidecar and config.options.sidecar.request_timeout_ms)
			or 30000,
	}
	if self.alive and self.process and not self.process:is_closing() then
		if not self:_write_request(item) then
			return nil
		end
	else
		table.insert(self.queued, item)
	end
	return id
end

function Client:shutdown(callback)
	if not self.alive then
		self.closed = true
		self.generation = self.generation + 1
		self.starting = false
		self:_fail_all(structured_error("sidecar_cancelled", "sidecar shutdown before startup completed", false))
		if callback then
			callback()
		end
		return
	end
	self:request("sidecar.shutdown", {}, {}, function(err)
		self.closed = true
		if self.process and not self.process:is_closing() then
			self.process:write(nil)
		end
		if callback then
			callback(err)
		end
	end)
end

function Client:kill()
	self.closed = true
	self.generation = self.generation + 1
	self.starting = false
	self:_fail_all(structured_error("sidecar_cancelled", "sidecar client was killed", false))
	if self.process and not self.process:is_closing() then
		pcall(self.process.write, self.process, nil)
		pcall(self.process.kill, self.process, "sigterm")
	end
	self.alive = false
end

local function reset_python_resolver()
	python_resolver.probe_cache = {}
	python_resolver.resolved = false
	python_resolver.resolving = false
	python_resolver.selected = nil
	python_resolver.waiters = {}
end

M.Client = Client
M.new = Client.new
M.default_command = default_command
M.plugin_root = plugin_root
M._reset_python_resolver = reset_python_resolver

return M
