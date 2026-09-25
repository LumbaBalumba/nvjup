local remote = require("nvjup.remote")
local rpc = require("nvjup.rpc")

local M = {}
local Client = {}
Client.__index = Client
local client_factory = rpc.new

local function structured_error(message)
	return { code = "remote_files_unavailable", message = message, retryable = false, details = {} }
end

function Client.new(state, remote_options)
	return setmetatable({
		state = state,
		remote_options = remote_options,
		ready = false,
		starting = false,
		waiters = {},
		client = client_factory({
			cwd = state.path ~= "" and vim.fs.dirname(state.path) or nil,
			on_exit = function(result)
				if result.code ~= 0 then
					vim.notify(
						string.format("nvjup: remote file sidecar exited with code %d", result.code),
						vim.log.levels.ERROR
					)
				end
			end,
		}),
	}, Client)
end

function Client:_flush(err)
	local waiters = self.waiters
	self.waiters = {}
	self.starting = false
	for _, callback in ipairs(waiters) do
		callback(err)
	end
end

function Client:_ensure(callback)
	if self.ready and self.client.alive then
		callback()
		return
	end
	table.insert(self.waiters, callback)
	if self.starting then
		return
	end
	self.starting = true
	local options = self.remote_options or remote.resolve(self.state)
	if not options then
		self:_flush(structured_error("kernel.remote must be configured before opening remote files"))
		return
	end
	local ok, err = self.client:start()
	if not ok then
		self:_flush(structured_error(tostring(err)))
		return
	end
	self.client:request("sidecar.hello", {}, {}, function(hello_err, payload)
		if hello_err then
			self:_flush(hello_err)
			return
		end
		local supported = false
		for _, request_type in ipairs(((payload or {}).capabilities or {}).requests or {}) do
			if request_type == "remote.files.list" then
				supported = true
				break
			end
		end
		if not supported then
			self:_flush(structured_error("sidecar does not advertise remote file operations"))
			return
		end
		self.ready = true
		self:_flush()
	end)
end

function Client:request_type(request_type, payload, callback)
	callback = callback or function() end
	self:_ensure(function(err)
		if err then
			callback(err)
			return
		end
		local options = self.remote_options or remote.resolve(self.state)
		if not options then
			callback(structured_error("kernel.remote is no longer configured"))
			return
		end
		payload = vim.tbl_extend("force", payload or {}, { remote = options })
		self.client:request(request_type, payload, {
			timeout_ms = options.file_timeout_seconds * 1000 + 5000,
		}, callback)
	end)
end

function Client:request(operation, payload, callback)
	self:request_type("remote.files." .. operation, payload, callback)
end

function Client:probe(callback)
	self:request_type("remote.server.probe", {}, callback)
end

function Client:list(path, callback)
	self:request("list", { path = path or "" }, callback)
end

function Client:stat(path, callback)
	self:request("stat", { path = path }, callback)
end

function Client:mkdir(path, callback)
	self:request("mkdir", { path = path }, callback)
end

function Client:touch(path, callback)
	self:request("touch", { path = path }, callback)
end

function Client:rename(path, new_path, callback)
	self:request("rename", { path = path, new_path = new_path }, callback)
end

function Client:delete(path, callback)
	self:request("delete", { path = path }, callback)
end

function Client:download(path, callback)
	self:request("download", { path = path }, function(err, payload)
		if err then
			callback(err)
			return
		end
		local ok, content = pcall(vim.base64.decode, payload.content or "")
		if not ok then
			callback(structured_error("sidecar returned invalid base64 file content"))
			return
		end
		callback(nil, content, payload)
	end)
end

function Client:upload(path, content, callback)
	local ok, encoded = pcall(vim.base64.encode, content)
	if not ok then
		callback(structured_error("failed to encode local file"))
		return
	end
	self:request("upload", { path = path, content = encoded }, callback)
end

function Client:download_to(path, local_path, callback)
	self:request("download_to", { path = path, local_path = local_path }, callback)
end

function Client:upload_from(path, local_path, callback)
	self:request("upload_from", { path = path, local_path = local_path }, callback)
end

function Client:copy(path, new_path, callback)
	self:request("copy", { path = path, new_path = new_path }, callback)
end

function Client:shutdown()
	self.ready = false
	self.client:shutdown()
end

function M.new(state, remote_options)
	return Client.new(state, remote_options)
end

function M._set_client_factory(factory)
	client_factory = factory or rpc.new
end

M.Client = Client

return M
