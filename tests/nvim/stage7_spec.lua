local config = require("nvjup.config")
local image = require("nvjup.image")
local inspector = require("nvjup.inspector")
local kernel = require("nvjup.kernel")
local notebook = require("nvjup.notebook")
local output = require("nvjup.output")
local statusline = require("nvjup.statusline")

local root = assert(vim.g.nvjup_project_root)
local passed = 0
local failures = {}
local clients = {}

local function test(name, callback)
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		passed = passed + 1
	else
		table.insert(failures, name .. ":\n" .. err)
	end
end

local function fixture_path(name)
	return vim.fs.joinpath(root, "tests", "fixtures", "notebooks", name)
end

local function open_fixture(name)
	vim.cmd.edit(vim.fn.fnameescape(fixture_path(name)))
	local state = assert(notebook.get())
	assert(state:sync_from_buffer())
	return state
end

local function close_fixture(state)
	if state and vim.api.nvim_buf_is_valid(state.buf) then
		vim.api.nvim_buf_delete(state.buf, { force = true })
	end
end

local function factory(options)
	local client = { alive = false, requests = {}, options = options }
	function client:start()
		self.alive = true
		return true
	end
	function client:request(request_type, payload, context, callback)
		table.insert(self.requests, { type = request_type, payload = payload, context = context })
		if not callback then
			return
		end
		if request_type == "sidecar.hello" then
			callback(nil, { protocols = { "nvjup/1" } })
		elseif request_type == "kernel.start" then
			callback(nil, {
				state = "idle",
				generation = 1,
				transport = payload.remote and "remote" or "local",
				python_source = payload.remote and "remote" or payload.python_source,
			})
		elseif request_type == "completion.request" then
			callback(nil, { matches = { "answer" }, cursor_start = 0, cursor_end = 3 })
		elseif request_type == "inspect.request" then
			callback(nil, { found = true, data = { ["text/plain"] = "42" } })
		elseif request_type == "variables.list" then
			callback(nil, {
				generation = 1,
				variables = { { name = "answer", type = "int", value = "42" } },
			})
		else
			callback(nil, {})
		end
	end
	function client:shutdown()
		self.alive = false
	end
	function client:kill()
		self.alive = false
	end
	table.insert(clients, client)
	return client
end

kernel._set_client_factory(factory)
config.options.completion.kernel = true
config.options.integrations.telescope = false

test("requests optional live-kernel completion in cell coordinates", function()
	local state = open_fixture("00_minimal.ipynb")
	kernel.start()
	local cell = state.cells[1]
	local result
	assert(kernel.complete_at(state.buf, cell.range.start_row, 3, function(err, payload)
		assert(err == nil)
		result = payload
	end))
	assert(result.matches[1] == "answer")
	local request = clients[#clients].requests[#clients[#clients].requests]
	assert(request.type == "completion.request")
	assert(request.payload.code == cell.source)
	assert(request.payload.cursor_pos == 3)

	cell.source = "é = 1\npri"
	state:replace_buffer({ preserve_cursor = false })
	local unicode_result
	assert(kernel.complete_at(state.buf, cell.range.start_row + 1, 3, function(err, payload)
		assert(err == nil)
		unicode_result = payload
	end))
	assert(unicode_result)
	local unicode_request = clients[#clients].requests[#clients[#clients].requests]
	assert(unicode_request.payload.cursor_pos == 9)
	close_fixture(state)
end)

test("resolves remote Jupyter transport settings for the sidecar", function()
	vim.env.NVJUP_TEST_JUPYTER_TOKEN = "secret-token"
	config.options.kernel.remote = {
		url = "https://jupyter.example.test/base",
		token_env = "NVJUP_TEST_JUPYTER_TOKEN",
		verify_ssl = true,
		reconnect_attempts = 3,
	}
	local state = open_fixture("00_minimal.ipynb")
	kernel.start()
	local client = clients[#clients]
	local start_request
	for _, request in ipairs(client.requests) do
		if request.type == "kernel.start" then
			start_request = request
		end
	end
	local status = kernel.status(state)
	local cell = state.cells[1]
	local session = kernel._sessions[state.buf]
	session.executions.remote_output = {
		execution_id = "remote_output",
		cell_id = cell.id,
		revision = cell.revision,
		source = cell.source,
	}
	kernel._handle_event(session, {
		type = "execution.display",
		notebook_id = session.notebook_id,
		cell_id = cell.id,
		revision = cell.revision,
		payload = {
			execution_id = "remote_output",
			output_type = "display_data",
			data = { ["text/plain"] = "remote output" },
			metadata = {},
		},
	})
	local remote_trust_revision = cell._nvjup_local_execution_revision
	close_fixture(state)
	config.options.kernel.remote = false
	vim.env.NVJUP_TEST_JUPYTER_TOKEN = nil
	assert(start_request.payload.remote.url == "https://jupyter.example.test/base")
	assert(start_request.payload.remote.token == "secret-token")
	assert(start_request.payload.remote.reconnect_attempts == 3)
	assert(start_request.payload.python_path == nil)
	assert(status.transport == "remote")
	assert(status.python_source == "remote")
	assert(remote_trust_revision == nil)
end)

test("opens the variable inspector and exposes statusline state", function()
	local state = open_fixture("00_minimal.ipynb")
	assert(inspector.open(state))
	local inspector_buf
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "nvjup-variables" then
			inspector_buf = buf
			break
		end
	end
	assert(inspector_buf)
	assert(table.concat(vim.api.nvim_buf_get_lines(inspector_buf, 0, -1, false), "\n"):find("answer", 1, true))
	local component = statusline.component(state.buf)
	assert(component:find("python3", 1, true))
	inspector._close(inspector_buf)
	close_fixture(state)
end)

test("renders a bounded basic ipywidgets subset", function()
	local cell = {
		outputs = {
			{
				output_type = "display_data",
				data = { ["application/vnd.jupyter.widget-view+json"] = { model_id = "root" } },
				metadata = {},
			},
		},
		widget_models = {
			root = { state = { _model_name = "HBoxModel", children = { "IPY_MODEL_check", "IPY_MODEL_choice" } } },
			check = { state = { _model_name = "CheckboxModel", description = "Ready", value = true } },
			choice = {
				state = {
					_model_name = "DropdownModel",
					description = "Mode",
					_options_labels = { "fast", "safe" },
					index = 1,
				},
			},
		},
	}
	local lines, kinds = output.render(cell)
	local text = table.concat(lines, "\n")
	assert(text:find("[x] Ready", 1, true))
	assert(text:find("Mode: safe", 1, true))
	assert(kinds[1] == "widget")
end)

test("materializes ipympl data-url frames as Kitty-compatible PNG output", function()
	local png = "iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAYAAAC09K7GAAAAEklEQVR42mPwKdrwHxkzEBQAANiRHR2gDahVAAAAAElFTkSuQmCC"
	local cell = {
		outputs = {
			{
				output_type = "display_data",
				data = { ["application/vnd.jupyter.widget-view+json"] = { model_id = "canvas" } },
				metadata = {},
			},
		},
	}
	local session = {
		widget_models = {
			canvas = {
				state = {
					_model_name = "MPLCanvasModel",
					_data_url = "data:image/png;base64," .. png,
					_size = { 640, 480 },
				},
			},
		},
	}
	cell.widget_models = session.widget_models
	assert(kernel._materialize_widget_images(session, cell))
	assert(cell.outputs[1].data["image/png"] == png)
	assert(cell.outputs[1].metadata["image/png"].width == 640)
	assert(#image.descriptors(cell) == 1)
	local lines = output.render(cell)
	assert(table.concat(lines, "\n"):find("ipympl canvas", 1, true))
end)

test("registers Stage 7 commands and default variable mapping", function()
	local state = open_fixture("00_minimal.ipynb")
	assert(vim.fn.exists(":NvJupVariables") == 2)
	local found = false
	for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(state.buf, "n")) do
		if mapping.lhs == "<Space>nv" or mapping.desc == "Kernel variable inspector" then
			found = true
		end
	end
	assert(found)
	close_fixture(state)
end)

kernel._set_client_factory(nil)

if #failures > 0 then
	print(
		string.format(
			"Stage 7 Lua tests: %d passed, %d failed\n\n%s",
			passed,
			#failures,
			table.concat(failures, "\n\n")
		)
	)
	vim.cmd("cquit 1")
	return
end

print(string.format("Stage 7 Lua tests: %d passed", passed))
vim.cmd("qa!")
