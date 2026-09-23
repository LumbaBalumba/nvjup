local config = require("nvjup.config")
local notebook = require("nvjup.notebook")
local render = require("nvjup.render")
local rpc = require("nvjup.rpc")

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

local function refresh(state)
	if state and vim.api.nvim_buf_is_valid(state.buf) then
		render.render(state)
	end
end

local function mark_outputs_changed(state, cell)
	cell.raw.outputs = cell.outputs
	cell.raw.execution_count = cell.execution_count == nil and vim.NIL or cell.execution_count
	vim.bo[state.buf].modified = true
	refresh(state)
end

local function remove_display_refs(session, cell_id)
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
end

local function clear_cell_for_execution(session, cell)
	remove_display_refs(session, cell.id)
	cell.outputs = {}
	cell.raw.outputs = cell.outputs
	cell.execution_count = nil
	cell.raw.execution_count = vim.NIL
	cell.output_collapsed = false
	cell.clear_output_wait = false
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
	remove_display_refs(session, cell.id)
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
		previous.text = (type(previous.text) == "table" and table.concat(previous.text, "") or previous.text or "")
			.. text
	else
		table.insert(cell.outputs, { output_type = "stream", name = name, text = text })
	end
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
	local display_id = payload.transient and payload.transient.display_id
	if display_id then
		session.display_ids[display_id] = session.display_ids[display_id] or {}
		table.insert(session.display_ids[display_id], { cell_id = cell.id, item = item })
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
			changed[cell.id] = cell
		end
	end
	return changed
end

local function append_error(session, cell, payload)
	apply_pending_clear(session, cell)
	table.insert(cell.outputs, {
		output_type = "error",
		ename = payload.ename or "Error",
		evalue = payload.evalue or "",
		traceback = payload.traceback or {},
	})
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
	local cell = session.state:cell_by_id(item.cell_id)
	if cell then
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
		mark_outputs_changed(session.state, cell)
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
		if terminal_states[state_name] then
			finish_execution(session, item, state_name, payload)
		else
			cell.execution_status = state_name
			refresh(session.state)
		end
	elseif message.type == "execution.stream" then
		append_stream(session, cell, payload)
		mark_outputs_changed(session.state, cell)
	elseif message.type == "execution.display" then
		append_display(session, cell, payload)
		if payload.execution_count ~= nil and payload.execution_count ~= vim.NIL then
			cell.execution_count = payload.execution_count
		end
		mark_outputs_changed(session.state, cell)
	elseif message.type == "execution.display_update" then
		local cleared = apply_pending_clear(session, cell)
		local changed = update_display(session, payload)
		if cleared then
			changed[cell.id] = cell
		end
		local any_changed = false
		for _, target in pairs(changed) do
			target.raw.outputs = target.outputs
			any_changed = true
		end
		if any_changed then
			vim.bo[session.state.buf].modified = true
			refresh(session.state)
		end
	elseif message.type == "execution.clear_output" then
		if payload.wait then
			cell.clear_output_wait = true
		else
			remove_display_refs(session, cell.id)
			cell.outputs = {}
			cell.clear_output_wait = false
			mark_outputs_changed(session.state, cell)
		end
	elseif message.type == "execution.error" then
		append_error(session, cell, payload)
		cell.execution_status = "failed"
		mark_outputs_changed(session.state, cell)
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
	local metadata = state.document.metadata or {}
	local kernelspec = metadata.kernelspec or {}
	return kernelspec.name or config.options.kernel.default_name or "python3"
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
		session.client:request("kernel.start", {
			kernel_name = kernel_name(session.state),
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
		session.active = item
		session.executions[item.execution_id] = item
		if config.options.execution.clear_before_run then
			clear_cell_for_execution(session, cell)
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
		if cell and cell.cell_type == "code" then
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
	refresh(state)
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

function M.forget_displays(state, cell_id)
	local session = state and sessions[state.buf]
	if not session then
		return
	end
	if cell_id then
		remove_display_refs(session, cell_id)
	else
		session.display_ids = {}
	end
end

function M.status(state)
	state = state or notebook.get()
	local session = state and sessions[state.buf]
	if not session then
		return { state = "stopped", queued = 0 }
	end
	return {
		state = session.kernel_state,
		generation = session.generation,
		queued = #session.queue,
		active = session.active and session.active.execution_id or nil,
		kernel_name = kernel_name(state),
		notebook_id = session.notebook_id,
	}
end

function M._set_client_factory(factory)
	client_factory = factory or rpc.new
end

M._sessions = sessions
M._handle_event = handle_event
M._rebuild_display_ids = rebuild_display_ids

return M
