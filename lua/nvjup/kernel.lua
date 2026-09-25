local config = require("nvjup.config")
local lsp = require("nvjup.lsp")
local notebook = require("nvjup.notebook")
local render = require("nvjup.render")
local remote = require("nvjup.remote")
local rpc = require("nvjup.rpc")
local trust = require("nvjup.trust")

local M = {}
local sessions = {}
local client_factory = rpc.new
local execution_sequence = 0
local batch_sequence = 0

local terminal_states = {
	completed = true,
	failed = true,
	cancelled = true,
	stale = true,
}

local function notify(message, level)
	vim.notify("nvjup: " .. tostring(message), level or vim.log.levels.INFO)
end

local function notebook_id(state)
	local identity = state.path ~= "" and state.path or ("buffer-" .. state.buf)
	return "notebook-" .. vim.fn.sha256(identity):sub(1, 24)
end

local function refresh(state, immediate)
	if state and vim.api.nvim_buf_is_valid(state.buf) then
		if immediate then
			render.render(state)
		else
			render.request(state)
		end
	end
end

local function mark_outputs_changed(session, cell, execution, changed_outputs, trust_cell)
	local state = session.state
	notebook.touch_outputs(cell)
	trust.invalidate(state)
	if session.transport ~= "remote" then
		if trust_cell then
			trust.mark_local_execution(cell, execution.revision)
		end
		for _, output_item in ipairs(changed_outputs or {}) do
			trust.mark_local_output(cell, output_item, execution.cell_id, execution.execution_id, execution.revision)
		end
	end
	cell.raw.outputs = cell.outputs
	cell.raw.execution_count = cell.execution_count == nil and vim.NIL or cell.execution_count
	vim.bo[state.buf].modified = true
	render.request_cell(state, cell)
end

local function remove_output_refs(session, cell_id)
	for display_id, references in pairs(session.display_ids) do
		local retained = {}
		for _, reference in ipairs(references) do
			if reference.cell_id ~= cell_id then
				table.insert(retained, reference)
			end
		end
		if #retained == 0 then
			session.display_ids[display_id] = nil
		else
			session.display_ids[display_id] = retained
		end
	end
	local retained = {}
	for _, reference in ipairs(session.widget_outputs or {}) do
		if reference.cell_id ~= cell_id then
			table.insert(retained, reference)
		end
	end
	session.widget_outputs = retained
end

local function clear_cell_for_execution(session, cell)
	remove_output_refs(session, cell.id)
	cell.outputs = {}
	cell.raw.outputs = cell.outputs
	cell.execution_count = nil
	cell.raw.execution_count = vim.NIL
	cell.output_collapsed = false
	cell.output_expanded = false
	cell.clear_output_wait = false
	notebook.touch_outputs(cell)
	cell.execution_duration_ns = nil
	cell.stale = false
	vim.bo[session.state.buf].modified = true
end

local function rebuild_display_ids(cell)
	-- display_id is transient Jupyter routing data and must not be persisted in
	-- nbformat outputs. It is rebuilt only from events in the live session.
	cell.display_ids = {}
end

local function apply_pending_clear(session, cell)
	if not cell.clear_output_wait then
		return false
	end
	remove_output_refs(session, cell.id)
	cell.outputs = {}
	cell.clear_output_wait = false
	return true
end

local function append_stream(session, cell, payload)
	apply_pending_clear(session, cell)
	local name = payload.name or "stdout"
	local text = payload.text or ""
	local previous = cell.outputs[#cell.outputs]
	if previous and previous.output_type == "stream" and previous.name == name then
		if type(previous.text) ~= "table" then
			previous.text = previous.text and { previous.text } or {}
		end
		table.insert(previous.text, text)
		return previous
	end
	local output_item = { output_type = "stream", name = name, text = text }
	table.insert(cell.outputs, output_item)
	return output_item
end

local function materialize_widget_output(session, output_item)
	local view = type(output_item.data) == "table" and output_item.data["application/vnd.jupyter.widget-view+json"]
	local model_id = type(view) == "table" and view.model_id or nil
	local model = model_id and session.widget_models[model_id] or nil
	local model_state = model and model.state or nil
	if
		not (model_state and model_state._model_name == "MPLCanvasModel" and type(model_state._data_url) == "string")
	then
		return false
	end
	local png = model_state._data_url:match("^data:image/png;base64,(.+)$") or model_state._data_url
	if not png:match("^[A-Za-z0-9+/=]+$") or #png > 16 * 1024 * 1024 then
		return false
	end
	local changed = output_item.data["image/png"] ~= png
	output_item.data["image/png"] = png
	local size = model_state._size
	if type(size) == "table" and tonumber(size[1]) and tonumber(size[2]) then
		output_item.metadata = output_item.metadata or {}
		local dimensions = output_item.metadata["image/png"]
		local width, height = tonumber(size[1]), tonumber(size[2])
		changed = changed or type(dimensions) ~= "table" or dimensions.width ~= width or dimensions.height ~= height
		output_item.metadata["image/png"] = { width = width, height = height }
	end
	return changed
end

local function materialize_widget_images(session, cell)
	local changed = false
	for _, output_item in ipairs(cell.outputs or {}) do
		changed = materialize_widget_output(session, output_item) or changed
	end
	return changed
end

local function append_display(session, cell, payload)
	apply_pending_clear(session, cell)
	local item = {
		output_type = payload.output_type or "display_data",
		data = payload.data or {},
		metadata = payload.metadata or {},
	}
	if payload.execution_count ~= nil and payload.execution_count ~= vim.NIL then
		item.execution_count = payload.execution_count
	end
	table.insert(cell.outputs, item)
	local view = type(item.data) == "table" and item.data["application/vnd.jupyter.widget-view+json"]
	local model_id = type(view) == "table" and view.model_id or nil
	if model_id then
		cell.widget_models = session.widget_models
		table.insert(session.widget_outputs, {
			cell_id = cell.id,
			item = item,
			model_id = model_id,
			execution_id = payload.execution_id,
		})
		materialize_widget_output(session, item)
	end
	local display_id = payload.transient and payload.transient.display_id
	if display_id then
		session.display_ids[display_id] = session.display_ids[display_id] or {}
		table.insert(session.display_ids[display_id], { cell_id = cell.id, item = item })
	end
	return item
end

local function widget_model_reaches(session, model_id, target_id, seen)
	if model_id == target_id then
		return true
	end
	seen = seen or {}
	if seen[model_id] then
		return false
	end
	seen[model_id] = true
	local model = session.widget_models[model_id]
	local function state_reaches(value)
		if type(value) == "string" then
			local child_id = value:match("^IPY_MODEL_(.+)$")
			return child_id ~= nil and widget_model_reaches(session, child_id, target_id, seen)
		end
		if type(value) == "table" then
			for _, child in pairs(value) do
				if state_reaches(child) then
					return true
				end
			end
		end
		return false
	end
	return model ~= nil and state_reaches(model.state)
end

local function update_widget(session, cell, item, payload)
	local model_id = payload.model_id
	if type(model_id) ~= "string" or model_id == "" then
		return
	end
	local model = session.widget_models[model_id]
	if not model then
		model = { state = {}, execution_id = item.execution_id, cell_id = item.cell_id, revision = item.revision }
	elseif model.execution_id ~= item.execution_id then
		return
	end
	model.state = vim.tbl_deep_extend("force", model.state or {}, payload.state or {})
	model.closed = payload.action == "close"
	session.widget_models[model_id] = model
	cell.widget_models = session.widget_models

	local image_changed = false
	local affected = {}
	for _, reference in ipairs(session.widget_outputs) do
		if widget_model_reaches(session, reference.model_id, model_id) then
			local notebook_cell = session.state:cell_by_id(reference.cell_id)
			local live = false
			for _, output_item in ipairs(notebook_cell and notebook_cell.outputs or {}) do
				if output_item == reference.item then
					live = true
					break
				end
			end
			if live then
				notebook_cell.widget_models = session.widget_models
				image_changed = materialize_widget_output(session, reference.item) or image_changed
				affected[notebook_cell.id] = affected[notebook_cell.id] or { cell = notebook_cell, outputs = {} }
				table.insert(affected[notebook_cell.id].outputs, reference.item)
			end
		end
	end
	for _, change in pairs(affected) do
		notebook.touch_outputs(change.cell)
		if session.transport ~= "remote" then
			for _, output_item in ipairs(change.outputs) do
				trust.mark_local_output(change.cell, output_item, item.cell_id, item.execution_id, item.revision)
			end
		end
	end
	if image_changed then
		trust.invalidate(session.state)
		vim.bo[session.state.buf].modified = true
	end
	for _, change in pairs(affected) do
		render.request_cell(session.state, change.cell)
	end
end

local function update_display(session, payload)
	local display_id = payload.transient and payload.transient.display_id
	local references = display_id and session.display_ids[display_id] or {}
	local changed = {}
	for _, reference in ipairs(references) do
		local cell = session.state:cell_by_id(reference.cell_id)
		local live = false
		for _, item in ipairs(cell and cell.outputs or {}) do
			if item == reference.item then
				live = true
				break
			end
		end
		if live then
			reference.item.data = payload.data or {}
			reference.item.metadata = payload.metadata or {}
			changed[cell.id] = changed[cell.id] or { cell = cell, outputs = {} }
			table.insert(changed[cell.id].outputs, reference.item)
		end
	end
	return changed
end

local function append_error(session, cell, payload)
	apply_pending_clear(session, cell)
	local output_item = {
		output_type = "error",
		ename = payload.ename or "Error",
		evalue = payload.evalue or "",
		traceback = payload.traceback or {},
	}
	table.insert(cell.outputs, output_item)
	return output_item
end

local function cancel_batch_tail(session, batch_id, reason)
	local retained = {}
	for _, item in ipairs(session.queue) do
		if batch_id == nil or item.batch_id == batch_id then
			local cell = session.state:cell_by_id(item.cell_id)
			if cell and cell.execution_status == "queued" then
				cell.execution_status = "cancelled"
			end
			item.state = "cancelled"
			item.reason = reason
		else
			table.insert(retained, item)
		end
	end
	session.queue = retained
end

local function next_execution_id()
	execution_sequence = execution_sequence + 1
	return string.format("execution-%d", execution_sequence)
end

local function next_batch_id()
	batch_sequence = batch_sequence + 1
	return string.format("batch-%d", batch_sequence)
end

local function finish_execution(session, item, state_name, payload)
	if item.terminal then
		return
	end
	item.terminal = true
	item.state = state_name
	if item.started_ns then
		item.duration_ns = vim.uv.hrtime() - item.started_ns
	end
	local cell = session.state:cell_by_id(item.cell_id)
	if cell then
		cell.execution_duration_ns = item.duration_ns
		if payload.execution_count ~= nil and payload.execution_count ~= vim.NIL then
			cell.execution_count = payload.execution_count
		end
		local stale = cell.revision ~= item.revision or cell.source ~= item.source or cell.stale
		if stale and state_name ~= "cancelled" then
			cell.stale = true
			cell.execution_status = "stale"
		else
			cell.execution_status = state_name
			cell.stale = state_name == "stale"
		end
		if state_name == "completed" or state_name == "failed" then
			cell.last_executed_source = item.source
		end
		mark_outputs_changed(session, cell, item)
	end
	if state_name == "failed" and item.stop_on_error then
		cancel_batch_tail(session, item.batch_id, "stopped after execution error")
	end
	session.executions[item.execution_id] = item
	if session.active == item then
		session.active = nil
	end
	vim.schedule(function()
		M._pump(session)
	end)
end

local function handle_stdin(session, item, payload)
	local function reply(value)
		session.client:request("execution.stdin_reply", {
			execution_id = item.execution_id,
			value = value or "",
		}, { notebook_id = session.notebook_id, cell_id = item.cell_id, revision = item.revision })
	end
	if payload.password then
		vim.schedule(function()
			reply(vim.fn.inputsecret(payload.prompt or ""))
		end)
	else
		vim.schedule(function()
			vim.ui.input({ prompt = payload.prompt or "" }, reply)
		end)
	end
end

local function handle_event(session, message)
	if message.notebook_id and message.notebook_id ~= session.notebook_id then
		return
	end
	local payload = message.payload or {}
	if message.type == "kernel.state" then
		session.kernel_state = payload.state or session.kernel_state
		session.generation = payload.generation or session.generation
		session.transport = payload.transport or session.transport
		session.kernel_python = payload.python_path or session.kernel_python
		session.kernel_python_source = payload.python_source or session.kernel_python_source
		refresh(session.state)
		return
	end
	if message.type == "kernel.dead" then
		session.kernel_state = "dead"
		if session.active then
			finish_execution(session, session.active, "failed", {})
		end
		cancel_batch_tail(session, nil, "kernel died")
		notify("kernel died: " .. tostring(payload.reason or "unknown reason"), vim.log.levels.ERROR)
		refresh(session.state)
		return
	end
	if message.type == "log" then
		if payload.level == "error" then
			notify(payload.message, vim.log.levels.ERROR)
		end
		return
	end

	local execution_id = payload.execution_id
	local item = execution_id and session.executions[execution_id]
	if not item then
		return
	end
	local cell = session.state:cell_by_id(item.cell_id)
	if message.type == "execution.state" and terminal_states[payload.state] then
		finish_execution(session, item, payload.state, payload)
		return
	end
	if not cell then
		return
	end
	if cell.revision ~= item.revision or cell.source ~= item.source then
		cell.stale = true
	end

	if message.type == "execution.state" then
		local state_name = payload.state
		item.state = state_name
		if payload.execution_count ~= nil and payload.execution_count ~= vim.NIL then
			cell.execution_count = payload.execution_count
		end
		cell.execution_status = state_name
		refresh(session.state)
	elseif message.type == "execution.widget" then
		update_widget(session, cell, item, payload)
	elseif message.type == "execution.stream" then
		local output_item = append_stream(session, cell, payload)
		mark_outputs_changed(session, cell, item, { output_item }, item.outputs_cleared)
	elseif message.type == "execution.display" then
		local output_item = append_display(session, cell, payload)
		if payload.execution_count ~= nil and payload.execution_count ~= vim.NIL then
			cell.execution_count = payload.execution_count
		end
		mark_outputs_changed(session, cell, item, { output_item }, item.outputs_cleared)
	elseif message.type == "execution.display_update" then
		local cleared = apply_pending_clear(session, cell)
		local changed = update_display(session, payload)
		if cleared then
			changed[cell.id] = changed[cell.id] or { cell = cell, outputs = {} }
			item.outputs_cleared = true
		end
		local any_changed = false
		for _, change in pairs(changed) do
			local target = change.cell
			target.raw.outputs = target.outputs
			notebook.touch_outputs(target)
			trust.invalidate(session.state)
			if session.transport ~= "remote" then
				if item.outputs_cleared and target == cell then
					trust.mark_local_execution(target, item.revision)
				end
				for _, output_item in ipairs(change.outputs) do
					trust.mark_local_output(target, output_item, item.cell_id, item.execution_id, item.revision)
				end
			end
			render.request_cell(session.state, target)
			any_changed = true
		end
		if any_changed then
			vim.bo[session.state.buf].modified = true
		end
	elseif message.type == "execution.clear_output" then
		if payload.wait then
			cell.clear_output_wait = true
		else
			remove_output_refs(session, cell.id)
			cell.outputs = {}
			cell.clear_output_wait = false
			item.outputs_cleared = true
			mark_outputs_changed(session, cell, item, nil, true)
		end
	elseif message.type == "execution.error" then
		local output_item = append_error(session, cell, payload)
		cell.execution_status = "failed"
		mark_outputs_changed(session, cell, item, { output_item }, item.outputs_cleared)
	elseif message.type == "execution.stdin_request" then
		cell.execution_status = "waiting_input"
		refresh(session.state)
		handle_stdin(session, item, payload)
	end
end

local function create_session(state)
	local session = {
		state = state,
		notebook_id = notebook_id(state),
		kernel_state = "stopped",
		generation = 0,
		queue = {},
		executions = {},
		active = nil,
		start_waiters = {},
		starting = false,
		display_ids = {},
		widget_models = {},
		widget_outputs = {},
	}
	session.client = client_factory({
		cwd = state.path ~= "" and vim.fs.dirname(state.path) or nil,
		on_event = function(message)
			handle_event(session, message)
		end,
		on_exit = function(result)
			if session.closing then
				return
			end
			session.kernel_state = "dead"
			cancel_batch_tail(session, nil, "sidecar exited")
			if session.active then
				finish_execution(session, session.active, "failed", {})
			end
			refresh(session.state)
			notify(string.format("sidecar exited with code %d", result.code), vim.log.levels.ERROR)
		end,
	})
	sessions[state.buf] = session
	state.kernel = session
	return session
end

local function get_session(state)
	return sessions[state.buf] or create_session(state)
end

local function flush_start_waiters(session, err)
	local waiters = session.start_waiters
	session.start_waiters = {}
	session.starting = false
	for _, callback in ipairs(waiters) do
		callback(err)
	end
end

local function kernel_name(state)
	local selected = remote.kernel_name(state)
	if selected then
		return selected
	end
	local metadata = state.document.metadata or {}
	local kernelspec = metadata.kernelspec or {}
	return kernelspec.name or config.options.kernel.default_name or "python3"
end

local function notebook_language(state)
	local metadata = state.document.metadata or {}
	local language_info = metadata.language_info or {}
	local kernelspec = metadata.kernelspec or {}
	return tostring(language_info.name or kernelspec.language or "python"):lower()
end

local function executable_file(path)
	local stat = path and path ~= "" and vim.uv.fs_stat(path) or nil
	return stat and stat.type == "file"
end

local function python_has_ipykernel(path)
	if not executable_file(path) then
		return false
	end
	local result = vim.system({ path, "-c", "import ipykernel" }, { text = true }):wait(3000)
	return result.code == 0
end

local function configured_kernel_python(state, remote_options)
	if remote_options then
		return nil, "remote"
	end
	if not notebook_language(state):match("^python") then
		return nil, "kernelspec"
	end
	local options = config.options.kernel or {}
	local configured = options.python_path
	if type(configured) == "function" then
		configured = configured(state.path, state)
	end
	if type(configured) == "string" and configured ~= "" then
		local path = vim.fs.normalize(configured)
		if not path:match("^/") and not path:match("^%a:[/\\]") then
			path = vim.fs.joinpath(lsp.project_root(state.path), path)
		end
		return path, "configured"
	end

	local root = lsp.project_root(state.path)
	for _, relative in ipairs({
		{ ".venv", "bin", "python" },
		{ "venv", "bin", "python" },
		{ ".venv", "Scripts", "python.exe" },
		{ "venv", "Scripts", "python.exe" },
	}) do
		local candidate = vim.fs.joinpath(root, unpack(relative))
		if python_has_ipykernel(candidate) then
			return candidate, "project_venv"
		end
	end

	local system = options.system_python
	if type(system) == "function" then
		system = system(state.path, state)
	end
	if type(system) == "string" and system ~= "" then
		return vim.fs.normalize(system), "configured_system"
	end
	local candidates = { vim.fn.exepath("python3"), "/usr/bin/python3", vim.fn.exepath("python") }
	for _, candidate in ipairs(candidates) do
		if python_has_ipykernel(candidate) then
			return candidate, "system"
		end
	end
	for _, candidate in ipairs(candidates) do
		if executable_file(candidate) then
			return candidate, "system"
		end
	end
	return "python3", "system"
end

local function ensure_kernel(session, callback)
	if session.kernel_state == "idle" or session.kernel_state == "busy" then
		callback()
		return
	end
	table.insert(session.start_waiters, callback)
	if session.starting then
		return
	end
	session.starting = true
	session.kernel_state = "starting"
	local ok, start_err = session.client:start()
	if not ok then
		flush_start_waiters(session, start_err)
		return
	end
	session.client:request("sidecar.hello", {
		protocols = { "nvjup/1" },
	}, { notebook_id = session.notebook_id }, function(hello_err)
		if hello_err then
			session.kernel_state = "error"
			flush_start_waiters(session, hello_err)
			return
		end
		local remote_options = remote.resolve(session.state)
		local python_path, python_source = configured_kernel_python(session.state, remote_options)
		session.kernel_python = python_path
		session.kernel_python_source = python_source
		session.client:request("kernel.start", {
			kernel_name = kernel_name(session.state),
			python_path = python_path,
			python_source = python_source,
			remote = remote_options,
			cwd = session.state.path ~= "" and vim.fs.dirname(session.state.path) or nil,
			timeout = config.options.kernel.start_timeout_seconds,
		}, { notebook_id = session.notebook_id }, function(err, payload)
			if err then
				session.kernel_state = "error"
				flush_start_waiters(session, err)
				return
			end
			session.kernel_state = payload.state or "idle"
			session.generation = payload.generation or 1
			session.kernel_python = payload.python_path or session.kernel_python
			session.kernel_python_source = payload.python_source or session.kernel_python_source
			session.transport = payload.transport or session.transport or "local"
			flush_start_waiters(session)
		end)
	end)
end

function M._pump(session)
	if session.closing or session.restarting or session.active or #session.queue == 0 then
		return
	end
	ensure_kernel(session, function(err)
		if err then
			local message = type(err) == "table" and err.message or tostring(err)
			notify("kernel start failed: " .. message, vim.log.levels.ERROR)
			for _, item in ipairs(session.queue) do
				local cell = session.state:cell_by_id(item.cell_id)
				if cell then
					cell.execution_status = "failed"
				end
			end
			session.queue = {}
			refresh(session.state)
			return
		end
		if session.active or #session.queue == 0 then
			return
		end
		local item = table.remove(session.queue, 1)
		local cell = session.state:cell_by_id(item.cell_id)
		if not cell or cell.cell_type ~= "code" then
			vim.schedule(function()
				M._pump(session)
			end)
			return
		end
		item.execution_id = next_execution_id()
		item.state = "created"
		item.started_ns = vim.uv.hrtime()
		session.active = item
		session.executions[item.execution_id] = item
		if config.options.execution.clear_before_run then
			clear_cell_for_execution(session, cell)
			item.outputs_cleared = true
		end
		cell.execution_status = "queued"
		refresh(session.state)
		session.client:request("execution.enqueue", {
			execution_id = item.execution_id,
			code = item.source,
			allow_stdin = item.allow_stdin,
			stop_on_error = item.stop_on_error,
		}, {
			notebook_id = session.notebook_id,
			cell_id = item.cell_id,
			revision = item.revision,
		}, function(request_err)
			if request_err then
				append_error(session, cell, {
					ename = request_err.code or "SidecarError",
					evalue = request_err.message or tostring(request_err),
					traceback = {},
				})
				finish_execution(session, item, "failed", {})
			end
		end)
	end)
end

local function conflict_for(session, cell_id)
	if session.active and session.active.cell_id == cell_id and not session.active.terminal then
		return true
	end
	for _, item in ipairs(session.queue) do
		if item.cell_id == cell_id then
			return true
		end
	end
	return false
end

local function remove_queued_cell(session, cell_id)
	local retained = {}
	for _, item in ipairs(session.queue) do
		if item.cell_id == cell_id then
			local cell = session.state:cell_by_id(item.cell_id)
			if cell then
				cell.execution_status = "cancelled"
			end
		else
			table.insert(retained, item)
		end
	end
	session.queue = retained
end

function M.run_cells(state, cells, options)
	options = options or {}
	assert(state:sync_from_buffer())
	local session = get_session(state)
	local batch_id = next_batch_id()
	local policy = options.repeat_policy or config.options.execution.repeat_policy
	local snapshots = {}
	for _, cell in ipairs(cells) do
		if cell and cell.cell_type == "markdown" then
			cell.markdown_rendered = true
		elseif cell and cell.cell_type == "code" then
			local conflict = conflict_for(session, cell.id)
			if conflict and policy == "cancel" then
				remove_queued_cell(session, cell.id)
				if session.active and session.active.cell_id == cell.id then
					M.cancel(state, session.active.execution_id)
				end
			elseif not conflict or policy ~= "cancel" then
				if conflict and policy == "replace" then
					remove_queued_cell(session, cell.id)
					if session.active and session.active.cell_id == cell.id then
						M.cancel(state, session.active.execution_id)
					end
				end
				table.insert(snapshots, {
					batch_id = batch_id,
					cell_id = cell.id,
					revision = cell.revision or 0,
					source = cell.source,
					allow_stdin = options.allow_stdin ~= false and config.options.execution.allow_stdin,
					stop_on_error = options.stop_on_error == nil and config.options.execution.stop_on_error
						or options.stop_on_error,
				})
			end
		end
	end
	for _, item in ipairs(snapshots) do
		table.insert(session.queue, item)
		local cell = state:cell_by_id(item.cell_id)
		if cell then
			cell.execution_status = "queued"
		end
	end
	refresh(state, true)
	M._pump(session)
	return batch_id, #snapshots
end

local function current_state()
	local state = assert(notebook.get(), "current buffer is not an nvjup notebook")
	assert(state:sync_from_buffer())
	return state
end

function M.run_current(options)
	local state = current_state()
	local cell = state:current_cell()
	return M.run_cells(state, { cell }, options)
end

function M.run_and_advance(options)
	local state = current_state()
	local cell, index = state:current_cell()
	local result = { M.run_cells(state, { cell }, options) }
	local target = state:find_cell(index, 1)
	if target then
		state:goto_cell(target)
	end
	return unpack(result)
end

function M.run_above(options)
	local state = current_state()
	local _, index = state:current_cell()
	local selected = {}
	for cell_index = 1, index - 1 do
		table.insert(selected, state.cells[cell_index])
	end
	return M.run_cells(state, selected, options)
end

function M.run_below(options)
	local state = current_state()
	local _, index = state:current_cell()
	local selected = {}
	for cell_index = index + 1, #state.cells do
		table.insert(selected, state.cells[cell_index])
	end
	return M.run_cells(state, selected, options)
end

function M.run_all(options)
	local state = current_state()
	return M.run_cells(state, state.cells, options)
end

function M.run_range(line1, line2, options)
	local state = current_state()
	local selected = {}
	for _, cell in ipairs(state.cells) do
		if cell.range.end_exclusive > line1 - 1 and cell.range.marker_row <= line2 - 1 then
			table.insert(selected, cell)
		end
	end
	return M.run_cells(state, selected, options)
end

function M.cancel(state, execution_id)
	state = state or current_state()
	local session = get_session(state)
	execution_id = execution_id or (session.active and session.active.execution_id)
	if not execution_id then
		return false
	end
	session.client:request("execution.cancel", { execution_id = execution_id }, {
		notebook_id = session.notebook_id,
	})
	return true
end

function M.start(state, callback)
	state = state or current_state()
	local session = get_session(state)
	ensure_kernel(session, function(err)
		if err then
			notify(err.message or tostring(err), vim.log.levels.ERROR)
		end
		if callback then
			callback(err, err and nil or M.status(state))
		end
	end)
	return true
end

function M.interrupt()
	local state = current_state()
	local session = get_session(state)
	if session.kernel_state == "stopped" then
		return false
	end
	session.client:request("kernel.interrupt", {}, { notebook_id = session.notebook_id }, function(err)
		if err then
			notify(err.message or err.code, vim.log.levels.ERROR)
		end
	end)
	return true
end

function M.restart(callback)
	local state = current_state()
	local session = get_session(state)
	session.restarting = true
	session.queue = {}
	ensure_kernel(session, function(start_err)
		if start_err then
			session.restarting = false
			notify(start_err.message or tostring(start_err), vim.log.levels.ERROR)
			return
		end
		session.client:request("kernel.restart", {}, { notebook_id = session.notebook_id }, function(err, payload)
			if err then
				session.restarting = false
				notify(err.message or err.code, vim.log.levels.ERROR)
				return
			end
			session.restarting = false
			session.kernel_state = payload.state or "idle"
			session.generation = payload.generation or session.generation + 1
			session.active = nil
			session.queue = {}
			session.widget_models = {}
			session.widget_outputs = {}
			for _, cell in ipairs(state.cells) do
				cell.widget_models = nil
				notebook.touch_outputs(cell)
			end
			refresh(state)
			if callback then
				callback()
			end
		end)
	end)
end

function M.restart_and_run_all()
	M.restart(function()
		M.run_all()
	end)
end

function M.shutdown(state)
	state = state or notebook.get()
	if not state then
		return
	end
	local session = sessions[state.buf]
	if not session then
		return
	end
	session.closing = true
	if session.kernel_state ~= "stopped" and session.client.alive then
		session.client:request("kernel.shutdown", { now = false }, {
			notebook_id = session.notebook_id,
		}, function()
			session.client:shutdown()
		end)
	else
		session.client:shutdown()
	end
	sessions[state.buf] = nil
	state.kernel = nil
end

function M.shutdown_remote_sessions()
	local states = {}
	for _, session in pairs(sessions) do
		if session.transport == "remote" or (session.kernel_state == "starting" and remote.enabled(session.state)) then
			table.insert(states, session.state)
		end
	end
	for _, state in ipairs(states) do
		M.shutdown(state)
	end
end

function M.detach(state)
	if state and config.options.kernel.shutdown_on_close then
		M.shutdown(state)
	elseif state then
		local session = sessions[state.buf]
		if session then
			session.client:kill()
			sessions[state.buf] = nil
		end
	end
end

local function tool_request(state, request_type, payload, callback, start_kernel)
	state = state or notebook.get()
	callback = callback or function() end
	if not state then
		callback({ message = "current buffer is not an nvjup notebook" })
		return false
	end
	local session = sessions[state.buf]
	if not session and not start_kernel then
		callback(nil, nil)
		return false
	end
	session = session or get_session(state)
	local function request()
		if session.active or session.kernel_state == "busy" then
			callback({ message = "kernel is busy" })
			return
		end
		session.client:request(request_type, payload or {}, {
			notebook_id = session.notebook_id,
		}, callback)
	end
	if session.kernel_state == "idle" then
		request()
	elseif start_kernel then
		ensure_kernel(session, function(err)
			if err then
				callback(err)
			else
				request()
			end
		end)
	else
		callback(nil, nil)
		return false
	end
	return true
end

local function completion_context(state, row, byte_col)
	local ok = state:sync_from_buffer()
	if not ok then
		return nil
	end
	local index = state:cell_index_at(row)
	local cell = index and state.cells[index] or nil
	if not cell or cell.cell_type ~= "code" then
		return nil
	end
	local local_row = math.max(0, row - cell.range.start_row)
	local lines = vim.split(cell.source or "", "\n", { plain = true })
	if local_row >= #lines then
		return nil
	end
	local byte_cursor = 0
	for line = 1, local_row do
		byte_cursor = byte_cursor + #lines[line] + 1
	end
	byte_cursor = byte_cursor + math.min(math.max(0, byte_col), #(lines[local_row + 1] or ""))
	local source = cell.source or ""
	local cursor = vim.str_utfindex(source, byte_cursor)
	return source, cursor
end

function M.complete_at(buf, row, byte_col, callback)
	local state = notebook.get(buf)
	local code, cursor
	if state then
		code, cursor = completion_context(state, row, byte_col)
	end
	if not code then
		callback(nil, nil)
		return false
	end
	return tool_request(state, "completion.request", {
		code = code,
		cursor_pos = cursor,
		timeout = (config.options.completion or {}).kernel_timeout_seconds or 2,
	}, callback, false)
end

function M.inspect(code, cursor_pos, callback, state)
	return tool_request(state, "inspect.request", {
		code = code,
		cursor_pos = cursor_pos or vim.str_utfindex(code),
		detail_level = 1,
		timeout = (config.options.completion or {}).kernel_timeout_seconds or 2,
	}, callback, false)
end

function M.variables(state, callback)
	return tool_request(state, "variables.list", {
		limit = (config.options.inspector or {}).max_variables or 200,
		timeout = (config.options.inspector or {}).timeout_seconds or 5,
	}, callback, true)
end

function M.forget_displays(state, cell_id)
	local session = state and sessions[state.buf]
	if not session then
		return
	end
	if cell_id then
		remove_output_refs(session, cell_id)
	else
		session.display_ids = {}
		session.widget_outputs = {}
	end
end

function M.status(state)
	state = state or notebook.get()
	local session = state and sessions[state.buf]
	if not session then
		local python_path, python_source
		local remote_enabled = state and remote.enabled(state) or false
		if state then
			python_path, python_source = configured_kernel_python(state, remote_enabled and {} or nil)
		end
		return {
			state = "stopped",
			queued = 0,
			kernel_name = state and kernel_name(state) or nil,
			python_path = python_path,
			python_source = python_source,
			transport = remote_enabled and "remote" or "local",
		}
	end
	return {
		state = session.kernel_state,
		generation = session.generation,
		queued = #session.queue,
		active = session.active and session.active.execution_id or nil,
		kernel_name = kernel_name(state),
		python_path = session.kernel_python,
		python_source = session.kernel_python_source,
		transport = session.transport or "local",
		notebook_id = session.notebook_id,
	}
end

function M._set_client_factory(factory)
	client_factory = factory or rpc.new
end

M._sessions = sessions
M._handle_event = handle_event
M._materialize_widget_images = materialize_widget_images
M.find_kernel_python = function(state)
	return configured_kernel_python(state, remote.enabled(state) and {} or nil)
end
M._rebuild_display_ids = rebuild_display_ids

return M
