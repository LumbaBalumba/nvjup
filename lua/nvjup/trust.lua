local config = require("nvjup.config")
local util = require("nvjup.util")

local M = {}
local POLICY_VERSION = 1
local records
local loaded_path

local ACTIVE_MIMES = {
	["application/javascript"] = true,
	["application/vnd.bokehjs_exec.v0+json"] = true,
	["application/vnd.bokehjs_load.v0+json"] = true,
	["application/vnd.jupyter.widget-state+json"] = true,
	["application/vnd.jupyter.widget-view+json"] = true,
	["application/vnd.plotly.v1+json"] = true,
	["text/html"] = true,
}

local function store_path()
	local configured = config.options.interactive and config.options.interactive.trust_file
	if type(configured) == "string" and configured ~= "" then
		return vim.fs.normalize(configured)
	end
	return vim.fs.joinpath(vim.fn.stdpath("state"), "nvjup", "trust.json")
end

local function canonical_path(state)
	local path = state and state.path or ""
	if path == "" and state and state.buf and vim.api.nvim_buf_is_valid(state.buf) then
		path = vim.api.nvim_buf_get_name(state.buf)
	end
	if path == "" then
		return nil
	end
	return vim.uv.fs_realpath(path) or vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function is_array(value)
	if type(value) ~= "table" then
		return false, 0
	end
	local count = 0
	local maximum = 0
	for key in pairs(value) do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
			return false, 0
		end
		count = count + 1
		maximum = math.max(maximum, key)
	end
	return count == maximum, maximum
end

local function stable_json(value, seen)
	if value == vim.NIL or value == nil then
		return "null"
	end
	local kind = type(value)
	if kind ~= "table" then
		local ok, encoded = pcall(vim.json.encode, value)
		return ok and encoded or vim.json.encode(tostring(value))
	end
	seen = seen or {}
	if seen[value] then
		error("cyclic trust identity value")
	end
	seen[value] = true
	local array, length = is_array(value)
	local parts = {}
	if array then
		for index = 1, length do
			table.insert(parts, stable_json(value[index], seen))
		end
		seen[value] = nil
		return "[" .. table.concat(parts, ",") .. "]"
	end
	local keys = {}
	for key in pairs(value) do
		table.insert(keys, tostring(key))
	end
	table.sort(keys)
	for _, key in ipairs(keys) do
		table.insert(parts, vim.json.encode(key) .. ":" .. stable_json(value[key], seen))
	end
	seen[value] = nil
	return "{" .. table.concat(parts, ",") .. "}"
end

local function cache_token(state)
	local parts = { tostring(state and state._nvjup_trust_epoch or 0) }
	if state and state.buf and vim.api.nvim_buf_is_valid(state.buf) then
		table.insert(parts, tostring(vim.api.nvim_buf_get_changedtick(state.buf)))
	end
	for _, cell in ipairs(state and state.cells or {}) do
		table.insert(parts, table.concat({ cell.id or "", cell.revision or 0, #(cell.outputs or {}) }, ":"))
		for _, output in ipairs(cell.outputs or {}) do
			table.insert(parts, tostring(output.data))
		end
	end
	return table.concat(parts, "|")
end

local function active_identity(state)
	local cells = {}
	for _, cell in ipairs(state and state.cells or {}) do
		local outputs = {}
		for _, output in ipairs(cell.outputs or {}) do
			local active = {}
			for mime, value in pairs(type(output.data) == "table" and output.data or {}) do
				if ACTIVE_MIMES[mime] then
					active[mime] = value
				end
			end
			if next(active) then
				table.insert(outputs, active)
			end
		end
		table.insert(cells, {
			cell_type = cell.cell_type,
			source = cell.source or "",
			active_outputs = outputs,
			attachments = cell.raw and cell.raw.attachments or nil,
		})
	end
	return {
		policy_version = POLICY_VERSION,
		cells = cells,
		widgets = state and state.document and state.document.metadata and state.document.metadata.widgets or nil,
	}
end

local function load_records()
	local path = store_path()
	if records and loaded_path == path then
		return records
	end
	loaded_path = path
	records = {}
	local content = util.read_file(path)
	if not content then
		return records
	end
	local ok, decoded = pcall(vim.json.decode, content)
	if ok and type(decoded) == "table" and type(decoded.records) == "table" then
		records = decoded.records
	end
	return records
end

local function save_records()
	local path = store_path()
	local directory = vim.fs.dirname(path)
	vim.fn.mkdir(directory, "p", tonumber("700", 8))
	local ok, encoded = pcall(vim.json.encode, { policy_version = POLICY_VERSION, records = records or {} })
	if not ok then
		return nil, encoded
	end
	local written, err = util.atomic_write(path, encoded .. "\n")
	if written then
		pcall(vim.uv.fs_chmod, path, tonumber("600", 8))
	end
	return written, err
end

function M.identity(state)
	local path = canonical_path(state)
	if not path then
		return nil, "notebook has no canonical path"
	end
	local token = cache_token(state)
	if state and state._nvjup_trust_identity and state._nvjup_trust_identity.token == token then
		return state._nvjup_trust_identity.hash, path
	end
	local ok, encoded = pcall(stable_json, active_identity(state))
	if not ok then
		return nil, encoded
	end
	local hash = vim.fn.sha256(encoded)
	if state then
		state._nvjup_trust_identity = { token = token, hash = hash }
	end
	return hash, path
end

function M.invalidate(state)
	if not state then
		return
	end
	state._nvjup_trust_epoch = (state._nvjup_trust_epoch or 0) + 1
	state._nvjup_trust_identity = nil
end

local function locally_executed(cell)
	return config.options.execution
		and config.options.execution.trust_local_kernel ~= false
		and cell
		and cell._nvjup_local_execution_revision ~= nil
		and cell._nvjup_local_execution_revision == (cell.revision or 0)
end

function M.status(state, cell)
	if config.options.interactive and config.options.interactive.require_trust == false then
		return "trusted_interactive", { bypassed = true }
	end
	local hash, path = M.identity(state)
	if not hash then
		if locally_executed(cell) then
			return "trusted_interactive", { local_kernel = true, ephemeral = true }
		end
		return "unknown", { reason = path }
	end
	local record = load_records()[path]
	if record and record.level == "revoked" then
		return "revoked", { hash = hash, path = path, record = record }
	end
	if locally_executed(cell) then
		return "trusted_interactive", { hash = hash, path = path, local_kernel = true }
	end
	if not record then
		return "unknown", { hash = hash, path = path }
	end
	if record.policy_version ~= POLICY_VERSION or record.hash ~= hash then
		return "untrusted", { hash = hash, path = path, record = record, reason = "content_changed" }
	end
	return record.level or "untrusted", { hash = hash, path = path, record = record }
end

function M.allows_interactive(state, cell)
	return M.status(state, cell) == "trusted_interactive"
end

function M.mark_local_execution(cell, revision)
	if config.options.execution and config.options.execution.trust_local_kernel ~= false and cell then
		cell._nvjup_local_execution_revision = revision == nil and (cell.revision or 0) or revision
	end
end

function M.grant(state)
	local hash, path = M.identity(state)
	if not hash then
		return nil, path
	end
	load_records()[path] = {
		hash = hash,
		level = "trusted_interactive",
		policy_version = POLICY_VERSION,
		decided_at = os.time(),
	}
	local ok, err = save_records()
	if not ok then
		return nil, err
	end
	return true
end

function M.revoke(state)
	local hash, path = M.identity(state)
	if not hash then
		return nil, path
	end
	load_records()[path] = {
		level = "revoked",
		policy_version = POLICY_VERSION,
		decided_at = os.time(),
	}
	return save_records()
end

function M.reset_cache()
	records = nil
	loaded_path = nil
end

M.active_mimes = ACTIVE_MIMES
M.policy_version = POLICY_VERSION
M._stable_json = stable_json

return M
