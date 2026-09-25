local config = require("nvjup.config")
local kernel = require("nvjup.kernel")
local notebook = require("nvjup.notebook")
local output = require("nvjup.output")
local render = require("nvjup.render")
local rpc = require("nvjup.rpc")
local trust = require("nvjup.trust")

local root = assert(vim.g.nvjup_project_root)
local failures = {}
local passed = 0
local clients = {}

local function test(name, callback)
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		passed = passed + 1
		print("ok - " .. name)
	else
		table.insert(failures, name .. "\n" .. err)
		print("not ok - " .. name)
	end
end

local function fixture_path(name)
	return vim.fs.joinpath(root, "tests", "fixtures", "notebooks", name)
end

local function open_fixture(name)
	vim.cmd.edit(vim.fn.fnameescape(fixture_path(name)))
	local state = assert(notebook.get())
	assert(state:sync_from_buffer())
	render.render(state)
	return state
end

local function close_fixture(state)
	if state and vim.api.nvim_buf_is_valid(state.buf) then
		vim.api.nvim_buf_delete(state.buf, { force = true })
	end
end

local function fake_factory(options)
	local client = {
		alive = false,
		requests = {},
		options = options,
	}
	function client:start()
		self.alive = true
		return true
	end
	function client:request(request_type, payload, context, callback)
		local request = {
			type = request_type,
			payload = vim.deepcopy(payload or {}),
			context = vim.deepcopy(context or {}),
			callback = callback,
		}
		table.insert(self.requests, request)
		if request_type == "sidecar.hello" and callback then
			callback(nil, { protocols = { "nvjup/1" } })
		elseif request_type == "kernel.start" and callback then
			callback(nil, { state = "idle", generation = 1 })
		elseif request_type == "execution.enqueue" and callback then
			callback(nil, { execution_id = payload.execution_id, state = "queued" })
		elseif request_type == "kernel.restart" and callback then
			callback(nil, { state = "idle", generation = 2 })
		elseif callback then
			callback(nil, {})
		end
		return "fake-request-" .. #self.requests
	end
	function client:emit(message_type, payload, request)
		request = request or self:last("execution.enqueue")
		self.options.on_event({
			protocol = "nvjup/1",
			kind = "event",
			type = message_type,
			notebook_id = request and request.context.notebook_id or nil,
			cell_id = request and request.context.cell_id or nil,
			revision = request and request.context.revision or nil,
			payload = vim.deepcopy(payload or {}),
		})
	end
	function client:last(request_type)
		for index = #self.requests, 1, -1 do
			if self.requests[index].type == request_type then
				return self.requests[index]
			end
		end
	end
	function client:count(request_type)
		local count = 0
		for _, request in ipairs(self.requests) do
			if request.type == request_type then
				count = count + 1
			end
		end
		return count
	end
	function client:shutdown(callback)
		self.alive = false
		if callback then
			callback()
		end
	end
	function client:kill()
		self.alive = false
	end
	table.insert(clients, client)
	return client
end

local function setup_fake()
	clients = {}
	kernel._set_client_factory(fake_factory)
	config.options.execution.stop_on_error = true
	config.options.execution.repeat_policy = "queue"
	config.options.execution.clear_before_run = true
	config.options.execution.allow_stdin = true
end

local function code_cells(state)
	local result = {}
	for _, cell in ipairs(state.cells) do
		if cell.cell_type == "code" then
			table.insert(result, cell)
		end
	end
	return result
end

local function terminal(client, request, state_name, execution_count)
	client:emit("execution.state", {
		execution_id = request.payload.execution_id,
		state = state_name,
		execution_count = execution_count,
	}, request)
end

setup_fake()

test("builds the default Python sidecar command from the plugin root", function()
	local command = rpc.default_command()
	assert(command[1]:find("python", 1, true))
	assert(command[2] == vim.fs.joinpath(root, "python", "nvjup_sidecar_main.py"))
end)

test("probes every runtime dependency required by the sidecar", function()
	local command = rpc._probe_command("/tmp/python")
	assert(command[1] == "/tmp/python" and command[2] == "-c")
	assert(command[3]:find("sys.exit", 1, true))
	assert(command[3]:find("sys.version_info >= (3, 11)", 1, true))
	assert(not command[3]:find("assert", 1, true))
	assert(command[3]:find("aiohttp", 1, true))
	assert(command[3]:find("jupyter_client", 1, true))

	local runtime = rpc._probe_command(rpc.default_command()[1])
	local optimized = { runtime[1], "-O", runtime[2], runtime[3] }
	local result = vim.system(optimized, { text = true, env = { PYTHONOPTIMIZE = "1" } }):wait(5000)
	assert(result.code == 0, result.stderr)
end)

local function rpc_process_factory(record)
	return function(command, _, on_exit)
		table.insert(record.commands, vim.deepcopy(command))
		local process = { closing = false, writes = {}, on_exit = on_exit }
		function process:is_closing()
			return self.closing
		end
		function process:write(data)
			table.insert(self.writes, data)
		end
		function process:kill()
			self.closing = true
		end
		table.insert(record.processes, process)
		return process
	end
end

test("resolves sidecar Python asynchronously and flushes concurrent requests in order", function()
	rpc._reset_python_resolver()
	local probes = {}
	local record = { commands = {}, processes = {} }
	local client = rpc.Client.new({
		probe_factory = function(python, callback)
			table.insert(probes, { python = python, callback = callback })
		end,
		process_factory = rpc_process_factory(record),
	})
	assert(#probes == 0 and #record.processes == 0)
	local first = client:request("test.first", {}, {}, function() end)
	local second = client:request("test.second", {}, {}, function() end)
	assert(first == "request-1" and second == "request-2")
	local first_timer = assert(client.pending[first].timer)
	assert(#probes == 1 and #record.processes == 0)

	probes[1].callback(false)
	assert(#probes == 2 and #record.processes == 0)
	local fallback = probes[2].python
	probes[2].callback(true)
	assert(#record.processes == 1)
	assert(record.commands[1][1] == fallback)
	assert(#record.processes[1].writes == 2)
	assert(vim.json.decode(record.processes[1].writes[1]).type == "test.first")
	assert(vim.json.decode(record.processes[1].writes[2]).type == "test.second")
	assert(client.pending[first].timer == first_timer)
	client:kill()
end)

test("times out queued requests before delayed Python resolution", function()
	rpc._reset_python_resolver()
	local probe_callback
	local callback_count = 0
	local failure
	local record = { commands = {}, processes = {} }
	local client = rpc.Client.new({
		probe_factory = function(_, callback)
			probe_callback = callback
		end,
		process_factory = rpc_process_factory(record),
	})
	local id = assert(client:request("test.deadline", {}, { timeout_ms = 10 }, function(err)
		callback_count = callback_count + 1
		failure = err
	end))
	assert(
		vim.wait(1000, function()
			return callback_count == 1
		end),
		"queued request did not time out"
	)
	assert(failure and failure.code == "request_timeout")
	assert(client.pending[id] == nil and #client.queued == 0)
	probe_callback(true)
	vim.wait(20)
	assert(callback_count == 1)
	assert(#record.processes == 0)
end)

test("does not launch a sidecar after cancellation during Python resolution", function()
	rpc._reset_python_resolver()
	local probe_callback
	local failure
	local record = { commands = {}, processes = {} }
	local client = rpc.Client.new({
		probe_factory = function(_, callback)
			probe_callback = callback
		end,
		process_factory = rpc_process_factory(record),
	})
	assert(client:request("test.cancel", {}, {}, function(err)
		failure = err
	end))
	assert(probe_callback and #record.processes == 0)
	client:kill()
	assert(failure and failure.code == "sidecar_cancelled")
	probe_callback(true)
	assert(#record.processes == 0)
end)

test("does not launch a sidecar after shutdown during Python resolution", function()
	rpc._reset_python_resolver()
	local probe_callback
	local record = { commands = {}, processes = {} }
	local client = rpc.Client.new({
		probe_factory = function(_, callback)
			probe_callback = callback
		end,
		process_factory = rpc_process_factory(record),
	})
	assert(client:request("test.shutdown", {}, {}, function() end))
	local shutdown_called = false
	client:shutdown(function()
		shutdown_called = true
	end)
	assert(shutdown_called)
	probe_callback(true)
	assert(#record.processes == 0)
end)

test("reuses the process-wide Python selection without probing again", function()
	rpc._reset_python_resolver()
	local probe_count = 0
	local record = { commands = {}, processes = {} }
	local options = {
		probe_factory = function(_, callback)
			probe_count = probe_count + 1
			callback(true)
		end,
		process_factory = rpc_process_factory(record),
	}
	local first = rpc.Client.new(options)
	assert(first:request("test.cache.first", {}, {}, function() end))
	local second = rpc.Client.new(options)
	assert(second:request("test.cache.second", {}, {}, function() end))
	assert(probe_count == 1)
	assert(#record.processes == 2)
	first:kill()
	second:kill()
end)

test("retries automatic Python selection after a transient all-candidate failure", function()
	rpc._reset_python_resolver()
	local failed_probes = 0
	local first_failure
	local first = rpc.Client.new({
		probe_factory = function(_, callback)
			failed_probes = failed_probes + 1
			callback(false)
		end,
		process_factory = function()
			error("must not start after failed probes")
		end,
	})
	assert(first:request("test.retry.failure", {}, {}, function(err)
		first_failure = err
	end) == nil)
	assert(first_failure and first_failure.code == "sidecar_start_failed")
	assert(failed_probes > 0)

	local successful_probes = 0
	local record = { commands = {}, processes = {} }
	local options = {
		probe_factory = function(_, callback)
			successful_probes = successful_probes + 1
			callback(true)
		end,
		process_factory = rpc_process_factory(record),
	}
	local second = rpc.Client.new(options)
	assert(second:request("test.retry.success", {}, {}, function() end))
	local third = rpc.Client.new(options)
	assert(third:request("test.retry.cached", {}, {}, function() end))
	assert(successful_probes == 1)
	assert(#record.processes == 2)
	second:kill()
	third:kill()
end)

test("unsubscribes one or all clients from shared Python resolution", function()
	rpc._reset_python_resolver()
	local probe_callback
	local probe_cancellations = 0
	local record = { commands = {}, processes = {} }
	local options = {
		probe_factory = function(_, callback)
			probe_callback = callback
			return {
				cancel = function()
					probe_cancellations = probe_cancellations + 1
				end,
			}
		end,
		process_factory = rpc_process_factory(record),
	}
	local first = rpc.Client.new(options)
	local second = rpc.Client.new(options)
	assert(first:request("test.shared.first", {}, {}, function() end))
	assert(second:request("test.shared.second", {}, {}, function() end))
	first:kill()
	assert(probe_cancellations == 0)
	probe_callback(true)
	assert(#record.processes == 1)
	assert(second.alive and not first.alive)
	second:kill()

	rpc._reset_python_resolver()
	probe_callback = nil
	probe_cancellations = 0
	record = { commands = {}, processes = {} }
	options.process_factory = rpc_process_factory(record)
	first = rpc.Client.new(options)
	second = rpc.Client.new(options)
	assert(first:request("test.shared.cancel-first", {}, {}, function() end))
	assert(second:request("test.shared.cancel-second", {}, {}, function() end))
	first:shutdown()
	second:kill()
	assert(probe_cancellations == 1)
	probe_callback(true)
	assert(#record.processes == 0)
end)

test("fails queued sidecar requests cleanly when process startup fails", function()
	rpc._reset_python_resolver()
	local probe_callback
	local failures = {}
	local client = rpc.Client.new({
		probe_factory = function(_, callback)
			probe_callback = callback
		end,
		process_factory = function()
			error("process unavailable")
		end,
	})
	assert(client:request("test.failure.first", {}, {}, function(err)
		table.insert(failures, err.code)
	end))
	assert(client:request("test.failure.second", {}, {}, function(err)
		table.insert(failures, err.code)
	end))
	probe_callback(true)
	assert(vim.deep_equal(failures, { "sidecar_start_failed", "sidecar_start_failed" }))
end)

test("ignores delayed callbacks from an earlier sidecar process", function()
	local launches = {}
	local stderr_calls = 0
	local exit_calls = 0
	local response_calls = 0
	local client = rpc.Client.new({
		command = { "fake-sidecar" },
		on_stderr = function()
			stderr_calls = stderr_calls + 1
		end,
		on_exit = function()
			exit_calls = exit_calls + 1
		end,
		process_factory = function(_, options, on_exit)
			local process = { closing = false, options = options, on_exit = on_exit, writes = {} }
			function process:is_closing()
				return self.closing
			end
			function process:write(data)
				table.insert(self.writes, data)
			end
			function process:kill()
				self.closing = true
			end
			table.insert(launches, process)
			return process
		end,
	})
	assert(client:start())
	local first = launches[1]
	first.closing = true
	client.alive = false
	assert(client:start())
	local second = launches[2]
	local id = assert(client:request("test.current-process", {}, { timeout_ms = 60000 }, function()
		response_calls = response_calls + 1
	end))

	first.options.stdout(nil, vim.json.encode({
		protocol = "nvjup/1",
		kind = "response",
		id = id,
		payload = {},
	}) .. "\n")
	first.options.stderr(nil, "old stderr\n")
	first.on_exit({ code = 1, signal = 0 })
	local scheduled = false
	vim.schedule(function()
		scheduled = true
	end)
	assert(vim.wait(1000, function()
		return scheduled
	end))
	assert(client.alive and client.process == second)
	assert(client.pending[id] ~= nil)
	assert(response_calls == 0 and stderr_calls == 0 and exit_calls == 0)
	assert(client.stdout_buffer == "" and client.stderr_buffer == "")
	client:kill()
end)

test("reports no automatic Python candidate and preserves explicit Python", function()
	rpc._reset_python_resolver()
	local failure
	local unavailable = rpc.Client.new({
		probe_factory = function(_, callback)
			callback(false)
		end,
		process_factory = function()
			error("must not start")
		end,
	})
	assert(unavailable:request("test.unavailable", {}, {}, function(err)
		failure = err
	end) == nil)
	assert(failure and failure.code == "sidecar_start_failed")

	local previous_python = config.options.sidecar.python
	local previous_command = config.options.sidecar.command
	config.options.sidecar.python = "configured-python"
	local record = { commands = {}, processes = {} }
	local explicit = rpc.Client.new({ process_factory = rpc_process_factory(record) })
	assert(explicit:request("test.explicit", {}, {}, function() end))
	assert(record.commands[1][1] == "configured-python")

	config.options.sidecar.command = { "configured-sidecar", "--stdio" }
	local commanded = rpc.Client.new({ process_factory = rpc_process_factory(record) })
	assert(commanded:request("test.command", {}, {}, function() end))
	assert(vim.deep_equal(record.commands[2], { "configured-sidecar", "--stdio" }))
	config.options.sidecar.python = previous_python
	config.options.sidecar.command = previous_command
end)

test("prefers the project virtualenv and falls back to system Python", function()
	local state = open_fixture("00_minimal.ipynb")
	local python, source = kernel.find_kernel_python(state)
	assert(python == vim.fs.joinpath(root, ".venv", "bin", "python"))
	assert(source == "project_venv")
	close_fixture(state)

	local directory = vim.fn.tempname()
	assert(vim.fn.mkdir(vim.fs.joinpath(directory, ".venv", "bin"), "p") == 1)
	local unusable = vim.fs.joinpath(directory, ".venv", "bin", "python")
	local file = assert(io.open(unusable, "wb"))
	file:write("#!/bin/sh\nexit 1\n")
	file:close()
	assert(vim.uv.fs_chmod(unusable, 493))
	local fallback, fallback_source = kernel.find_kernel_python({
		path = vim.fs.joinpath(directory, "notebook.ipynb"),
		document = { metadata = { language_info = { name = "python" } } },
	})
	assert(fallback_source == "system")
	assert(fallback ~= "" and fallback ~= vim.fs.joinpath(directory, ".venv", "bin", "python"))
	vim.fs.rm(directory, { recursive = true, force = true })
end)

test("executes immutable cell snapshots sequentially and persists outputs", function()
	setup_fake()
	local state = open_fixture("09_lsp_mapping.ipynb")
	local cells = code_cells(state)
	local _, count = kernel.run_cells(state, { cells[1], cells[2] })
	assert(count == 2)
	local client = assert(clients[1])
	assert(client:count("execution.enqueue") == 1)
	local start = assert(client:last("kernel.start"))
	assert(start.payload.python_path == vim.fs.joinpath(root, ".venv", "bin", "python"))
	assert(start.payload.python_source == "project_venv")
	local first = assert(client:last("execution.enqueue"))
	assert(first.payload.code == cells[1].source)
	client:emit("execution.stream", {
		execution_id = first.payload.execution_id,
		name = "stdout",
		text = "first output\n",
	}, first)
	client:emit("execution.stream", {
		execution_id = first.payload.execution_id,
		name = "stdout",
		text = "",
	}, first)
	client:emit("execution.display", {
		execution_id = first.payload.execution_id,
		output_type = "execute_result",
		data = { ["text/plain"] = "42" },
		metadata = {},
		execution_count = 7,
	}, first)
	assert(trust.status(state, cells[1]) == "trusted_interactive")
	terminal(client, first, "completed", 7)
	assert(vim.wait(1000, function()
		return client:count("execution.enqueue") == 2
	end))
	local second = assert(client:last("execution.enqueue"))
	assert(second.context.cell_id == cells[2].id)
	terminal(client, second, "completed", 8)
	assert(cells[1].execution_count == 7)
	assert(type(cells[1].outputs[1].text) == "table")
	assert(table.concat(cells[1].outputs[1].text) == "first output\n")
	assert(cells[1].outputs[2].data["text/plain"] == "42")
	local path = vim.fn.tempname() .. ".ipynb"
	assert(state:save(path))
	local document = vim.json.decode(assert(io.open(path, "rb")):read("*a"))
	assert(document.cells[2].execution_count == 7)
	assert(type(document.cells[2].outputs[1].text) == "table")
	assert(table.concat(document.cells[2].outputs[1].text) == "first output\n")
	vim.fs.rm(path, { force = true })
	close_fixture(state)
end)

test("routes display updates, deferred clears, errors, and stdin replies", function()
	setup_fake()
	local state = open_fixture("09_lsp_mapping.ipynb")
	local cell = code_cells(state)[1]
	kernel.run_cells(state, { cell })
	local client = assert(clients[1])
	local request = assert(client:last("execution.enqueue"))
	local execution_id = request.payload.execution_id
	client:emit("execution.display", {
		execution_id = execution_id,
		output_type = "display_data",
		data = { ["text/plain"] = "before" },
		metadata = {},
		transient = { display_id = "slot" },
	}, request)
	client:emit("execution.display_update", {
		execution_id = execution_id,
		data = { ["text/plain"] = "updated" },
		metadata = {},
		transient = { display_id = "slot" },
	}, request)
	assert(cell.outputs[1].data["text/plain"] == "updated")
	client:emit("execution.clear_output", { execution_id = execution_id, wait = true }, request)
	assert(#cell.outputs == 1)
	client:emit("execution.stream", {
		execution_id = execution_id,
		name = "stderr",
		text = "replacement\n",
	}, request)
	assert(#cell.outputs == 1 and cell.outputs[1].text == "replacement\n")

	local original_input = vim.ui.input
	vim.ui.input = function(options, callback)
		assert(options.prompt == "Name: ")
		callback("nvjup")
	end
	client:emit("execution.stdin_request", {
		execution_id = execution_id,
		prompt = "Name: ",
		password = false,
	}, request)
	assert(vim.wait(1000, function()
		return client:last("execution.stdin_reply") ~= nil
	end))
	assert(client:last("execution.stdin_reply").payload.value == "nvjup")
	vim.ui.input = original_input

	client:emit("execution.error", {
		execution_id = execution_id,
		ename = "ValueError",
		evalue = "bad value",
		traceback = { "trace" },
	}, request)
	terminal(client, request, "failed", 3)
	assert(cell.outputs[#cell.outputs].output_type == "error")
	assert(cell.execution_status == "failed")
	close_fixture(state)
end)

test("routes tqdm ipywidget updates into live terminal progress", function()
	setup_fake()
	local state = open_fixture("09_lsp_mapping.ipynb")
	local cell = code_cells(state)[1]
	kernel.run_cells(state, { cell })
	local client = assert(clients[1])
	local request = assert(client:last("execution.enqueue"))
	local execution_id = request.payload.execution_id
	local function widget(action, model_id, model_state)
		client:emit("execution.widget", {
			execution_id = execution_id,
			action = action,
			model_id = model_id,
			state = model_state,
		}, request)
	end
	widget("open", "left", { _model_name = "HTMLModel", value = " 0%" })
	widget("open", "progress", { _model_name = "FloatProgressModel", min = 0, max = 4, value = 0 })
	widget("open", "right", { _model_name = "HTMLModel", value = " 0/4" })
	widget("open", "root", {
		_model_name = "HBoxModel",
		children = { "IPY_MODEL_left", "IPY_MODEL_progress", "IPY_MODEL_right" },
	})
	client:emit("execution.display", {
		execution_id = execution_id,
		output_type = "display_data",
		data = {
			["text/plain"] = "TqdmHBox(children=(...))",
			["application/vnd.jupyter.widget-view+json"] = { model_id = "root" },
		},
		metadata = {},
	}, request)
	widget("update", "left", { value = " 50%" })
	widget("update", "progress", { value = 2 })
	widget("update", "right", { value = " 2/4" })
	local lines = output.render(cell, { limit = false })
	assert(table.concat(lines, "\n"):find("50%%"))
	assert(table.concat(lines, "\n"):find("2/4", 1, true))
	close_fixture(state)
end)

test("updates a display_id created by an earlier cell", function()
	setup_fake()
	local state = open_fixture("09_lsp_mapping.ipynb")
	local cells = code_cells(state)
	kernel.run_cells(state, { cells[1], cells[2] })
	local client = assert(clients[1])
	local first = assert(client:last("execution.enqueue"))
	client:emit("execution.display", {
		execution_id = first.payload.execution_id,
		output_type = "display_data",
		data = { ["text/plain"] = "before" },
		metadata = {},
		transient = { display_id = "shared-slot" },
	}, first)
	terminal(client, first, "completed", 1)
	assert(vim.wait(1000, function()
		return client:count("execution.enqueue") == 2
	end))
	local second = assert(client:last("execution.enqueue"))
	client:emit("execution.display_update", {
		execution_id = second.payload.execution_id,
		data = { ["text/plain"] = "updated later" },
		metadata = {},
		transient = { display_id = "shared-slot" },
	}, second)
	assert(cells[1].outputs[1].data["text/plain"] == "updated later")
	assert(cells[1].outputs[1].transient == nil)
	terminal(client, second, "completed", 2)
	close_fixture(state)
end)

test("marks results stale when source changes during execution", function()
	setup_fake()
	local state = open_fixture("09_lsp_mapping.ipynb")
	local cell = code_cells(state)[1]
	kernel.run_cells(state, { cell })
	local client = assert(clients[1])
	local request = assert(client:last("execution.enqueue"))
	vim.api.nvim_buf_set_lines(state.buf, cell.range.start_row, cell.range.start_row, false, { "# changed" })
	assert(state:sync_from_buffer())
	client:emit("execution.stream", {
		execution_id = request.payload.execution_id,
		name = "stdout",
		text = "old revision\n",
	}, request)
	terminal(client, request, "completed", 4)
	assert(cell.stale)
	assert(cell.execution_status == "stale")
	assert(cell.outputs[1].text == "old revision\n")
	assert(trust.status(state, cell) ~= "trusted_interactive")
	close_fixture(state)
end)

test("stops an immutable batch after an error", function()
	setup_fake()
	local state = open_fixture("09_lsp_mapping.ipynb")
	local cells = code_cells(state)
	kernel.run_cells(state, cells)
	local client = assert(clients[1])
	local first = assert(client:last("execution.enqueue"))
	terminal(client, first, "failed", 1)
	vim.wait(100)
	assert(client:count("execution.enqueue") == 1)
	assert(cells[2].execution_status == "cancelled")
	assert(cells[3].execution_status == "cancelled")
	close_fixture(state)
end)

test("exposes interrupt, restart, status, commands, and execution mappings", function()
	setup_fake()
	local state = open_fixture("09_lsp_mapping.ipynb")
	kernel.run_cells(state, { code_cells(state)[1] })
	local client = assert(clients[1])
	assert(kernel.interrupt())
	assert(client:last("kernel.interrupt"))
	state.cells[1].widget_models = { stale = true }
	local output_revision = state.cells[1].output_revision
	kernel.restart()
	assert(client:last("kernel.restart"))
	assert(kernel.status(state).generation == 2)
	assert(state.cells[1].widget_models == nil)
	assert(state.cells[1].output_revision == output_revision + 1)
	for _, command in ipairs({
		"NvJupRunCurrent",
		"NvJupRunAndAdvance",
		"NvJupRunAbove",
		"NvJupRunBelow",
		"NvJupRunAll",
		"NvJupRunRange",
		"NvJupKernelInterrupt",
		"NvJupKernelRestart",
		"NvJupKernelRestartRunAll",
		"NvJupKernelShutdown",
	}) do
		assert(vim.api.nvim_buf_get_commands(state.buf, {})[command], command)
	end
	for _, mapping in ipairs({ "<C-CR>", "<S-CR>", "<leader>nr", "<leader>nR", "<leader>nA", "<leader>nB" }) do
		assert(vim.fn.maparg(mapping, "n", false, true).buffer == 1, mapping)
	end
	for _, mapping in ipairs({ "<C-CR>", "<S-CR>" }) do
		assert(vim.fn.maparg(mapping, "i", false, true).buffer == 1, mapping .. " insert mode")
	end
	close_fixture(state)
end)

test("finishes a deleted active cell and pumps the queued execution", function()
	setup_fake()
	local state = open_fixture("09_lsp_mapping.ipynb")
	local cells = code_cells(state)
	kernel.run_cells(state, { cells[1], cells[2] })
	local client = assert(clients[1])
	local first = assert(client:last("execution.enqueue"))
	for index, candidate in ipairs(state.cells) do
		if candidate.id == cells[1].id then
			table.remove(state.cells, index)
			state.cell_store[candidate.id] = nil
			for shifted = index, #state.cells do
				state.cells[shifted].index = shifted
			end
			break
		end
	end
	terminal(client, first, "completed", 1)
	assert(
		vim.wait(1000, function()
			return client:count("execution.enqueue") == 2
		end),
		"queue remained blocked after the executing cell was deleted"
	)
	assert(kernel.status(state).active ~= first.payload.execution_id)
	close_fixture(state)
end)

test("trusts only output produced by a non-clearing local execution", function()
	setup_fake()
	config.options.execution.clear_before_run = false
	local state = open_fixture("05_plotly.ipynb")
	local cell = code_cells(state)[1]
	local persisted = cell.outputs[1]
	kernel.run_cells(state, { cell })
	local client = assert(clients[1])
	local request = assert(client:last("execution.enqueue"))
	client:emit("execution.display", {
		execution_id = request.payload.execution_id,
		output_type = "display_data",
		data = { ["application/vnd.plotly.v1+json"] = { data = {}, layout = {} } },
		metadata = {},
	}, request)
	local produced = cell.outputs[#cell.outputs]
	assert(trust.status(state, cell, persisted) ~= "trusted_interactive")
	assert(trust.status(state, cell, produced) == "trusted_interactive")
	assert(trust.status(state, cell) ~= "trusted_interactive")
	config.options.execution.clear_before_run = true
	close_fixture(state)
end)

test("targets widget and display-update burst renders to affected cells", function()
	setup_fake()
	local state = open_fixture("09_lsp_mapping.ipynb")
	local cell = code_cells(state)[1]
	kernel.run_cells(state, { cell })
	local client = assert(clients[1])
	local request = assert(client:last("execution.enqueue"))
	client:emit("execution.display", {
		execution_id = request.payload.execution_id,
		output_type = "display_data",
		data = { ["application/vnd.jupyter.widget-view+json"] = { model_id = "root" } },
		metadata = {},
		transient = { display_id = "burst" },
	}, request)
	local original_request, original_request_cell = render.request, render.request_cell
	local full, targeted = 0, 0
	render.request = function()
		full = full + 1
	end
	render.request_cell = function(_, target)
		assert(target.id == cell.id)
		targeted = targeted + 1
	end
	for index = 1, 5 do
		client:emit("execution.widget", {
			execution_id = request.payload.execution_id,
			action = "update",
			model_id = "root",
			state = { value = index },
		}, request)
		client:emit("execution.display_update", {
			execution_id = request.payload.execution_id,
			data = {
				["text/plain"] = tostring(index),
				["application/vnd.jupyter.widget-view+json"] = { model_id = "root" },
			},
			metadata = {},
			transient = { display_id = "burst" },
		}, request)
	end
	render.request, render.request_cell = original_request, original_request_cell
	assert(full == 0)
	assert(targeted == 10, "expected targeted burst renders, got " .. targeted)
	close_fixture(state)
end)

kernel._set_client_factory(nil)

test("rejects oversized outbound RPC before writing", function()
	local previous = config.options.sidecar.max_message_bytes
	config.options.sidecar.max_message_bytes = 128
	local writes, failure = 0
	local client = rpc.Client.new({ command = { "true" } })
	client.alive = true
	client.process = {
		is_closing = function()
			return false
		end,
		write = function()
			writes = writes + 1
		end,
	}
	assert(client:request("oversized", { value = string.rep("x", 256) }, {}, function(err)
		failure = err
	end) == nil)
	assert(writes == 0)
	assert(failure and failure.code == "request_message_too_large")
	config.options.sidecar.max_message_bytes = previous
end)

test("cancels RPC timeout handles after an immediate response", function()
	local client = rpc.Client.new({ command = { "true" } })
	client.alive = true
	client.process = {
		is_closing = function()
			return false
		end,
		write = function() end,
	}
	local id = assert(client:request("sidecar.ping", {}, { timeout_ms = 60000 }, function() end))
	local timer = assert(client.pending[id].timer)
	client:_dispatch({ kind = "response", id = id, payload = {} })
	assert(client.pending[id] == nil)
	assert(timer:is_closing())
end)

if #failures > 0 then
	print(table.concat(failures, "\n\n"))
	vim.cmd("cquit " .. math.min(255, #failures))
else
	print(string.format("Stage 3 Lua tests: %d passed", passed))
	vim.cmd("qa!")
end
