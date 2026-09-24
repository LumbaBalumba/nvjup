local config = require("nvjup.config")

local M = {}
local Client = {}
Client.__index = Client

local function plugin_root()
	local source = debug.getinfo(1, "S").source:gsub("^@", "")
	return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

local function python_has_jupyter(python)
	if not python or python == "" or not vim.uv.fs_stat(python) then
		return false
	end
	local result = vim.system({ python, "-c", "import jupyter_client" }, { text = true }):wait(3000)
	return result.code == 0
end

local function default_python(options)
	if type(options.python) == "string" and options.python ~= "" then
		return options.python
	end
	local root = plugin_root()
	local candidates = { vim.fs.joinpath(root, ".venv", "bin", "python") }
	local function add(candidate)
		if candidate and candidate ~= "" then
			table.insert(candidates, candidate)
		end
	end
	add(vim.env.VIRTUAL_ENV and vim.fs.joinpath(vim.env.VIRTUAL_ENV, "bin", "python") or nil)
	add(vim.g.python3_host_prog)
	add(vim.fn.exepath("python3"))
	add("/usr/bin/python3")
	add(vim.fn.exepath("python"))
	local seen = {}
	for _, python in ipairs(candidates) do
		if python and python ~= "" and not seen[python] then
			seen[python] = true
			if python_has_jupyter(python) then
				return python
			end
		end
	end
	return vim.fn.exepath("python3") ~= "" and vim.fn.exepath("python3") or "python3"
end

local function default_command()
	local options = config.options.sidecar or {}
	if type(options.command) == "function" then
		return options.command()
	end
	if type(options.command) == "table" and #options.command > 0 then
		return vim.deepcopy(options.command)
	end
	return { default_python(options), vim.fs.joinpath(plugin_root(), "python", "nvjup_sidecar_main.py") }
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
	return setmetatable({
		command = options.command or default_command(),
		cwd = options.cwd,
		env = options.env,
		on_event = options.on_event,
		on_exit = options.on_exit,
		on_stderr = options.on_stderr,
		pending = {},
		request_seq = 0,
		stdout_buffer = "",
		stderr_buffer = "",
		alive = false,
	}, Client)
end

function Client:start()
	if self.process and not self.process:is_closing() then
		return true
	end
	local ok, process = pcall(vim.system, self.command, {
		cwd = self.cwd,
		env = self.env,
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
	if not ok then
		return nil, process
	end
	self.process = process
	self.alive = true
	return true
end

function Client:_consume_stdout(data)
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
		if pending.callback then
			pending.callback(message.error, message.payload or {}, message)
		end
	elseif message.kind == "event" and self.on_event then
		self.on_event(message)
	end
end

function Client:_fail_all(err)
	local pending = self.pending
	self.pending = {}
	for _, request in pairs(pending) do
		if not request.done and request.callback then
			request.done = true
			request.callback(err, {}, nil)
		end
	end
end

function Client:request(request_type, payload, context, callback)
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
	self.pending[id] = { callback = callback, done = false }
	local encoded_ok, encoded = pcall(vim.json.encode, message)
	if not encoded_ok then
		self.pending[id] = nil
		if callback then
			callback(structured_error("request_encode_failed", tostring(encoded), false), {}, nil)
		end
		return nil
	end
	local write_ok, write_err = pcall(self.process.write, self.process, encoded .. "\n")
	if not write_ok then
		self.pending[id] = nil
		if callback then
			callback(structured_error("sidecar_write_failed", tostring(write_err), true), {}, nil)
		end
		return nil
	end
	local timeout = (context and context.timeout_ms)
		or (config.options.sidecar and config.options.sidecar.request_timeout_ms)
		or 30000
	if timeout > 0 then
		vim.defer_fn(function()
			local pending = self.pending[id]
			if pending and not pending.done then
				self.pending[id] = nil
				pending.done = true
				if pending.callback then
					pending.callback(
						structured_error("request_timeout", string.format("%s timed out", request_type), true),
						{},
						nil
					)
				end
			end
		end, timeout)
	end
	return id
end

function Client:shutdown(callback)
	if not self.alive then
		if callback then
			callback()
		end
		return
	end
	self:request("sidecar.shutdown", {}, {}, function(err)
		if self.process and not self.process:is_closing() then
			self.process:write(nil)
		end
		if callback then
			callback(err)
		end
	end)
end

function Client:kill()
	if self.process and not self.process:is_closing() then
		pcall(self.process.write, self.process, nil)
		pcall(self.process.kill, self.process, "sigterm")
	end
	self.alive = false
end

M.Client = Client
M.new = Client.new
M.default_command = default_command
M.plugin_root = plugin_root

return M
