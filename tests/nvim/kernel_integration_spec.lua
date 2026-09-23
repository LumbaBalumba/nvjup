local config = require("nvjup.config")
local kernel = require("nvjup.kernel")
local notebook = require("nvjup.notebook")
local render = require("nvjup.render")

local root = assert(vim.g.nvjup_project_root)
local fixture = vim.fs.joinpath(root, "tests", "fixtures", "notebooks", "00_minimal.ipynb")
local python = vim.fs.joinpath(root, ".venv", "bin", "python")
local state
local failures = {}
local passed = 0

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

local function wait_for(predicate, message, timeout)
	assert(vim.wait(timeout or 30000, predicate, 20), message)
end

local function set_source(cell, source)
	cell.source = source
	cell.revision = (cell.revision or 0) + 1
	state:replace_buffer()
	vim.bo[state.buf].modified = true
	render.render(state)
end

local function output_text(cell)
	local result = {}
	for _, item in ipairs(cell.outputs or {}) do
		if item.output_type == "stream" then
			table.insert(result, type(item.text) == "table" and table.concat(item.text, "") or item.text)
		elseif item.data and item.data["text/plain"] then
			table.insert(result, item.data["text/plain"])
		elseif item.output_type == "error" then
			table.insert(result, item.ename .. ": " .. item.evalue)
		end
	end
	return table.concat(result, "\n")
end

config.options.sidecar.command = false
config.options.sidecar.python = python
config.options.sidecar.request_timeout_ms = 60000
config.options.kernel.start_timeout_seconds = 30
config.options.execution.stop_on_error = true
config.options.execution.repeat_policy = "queue"
config.options.execution.clear_before_run = true
vim.cmd.edit(vim.fn.fnameescape(fixture))
state = assert(notebook.get())
assert(state:sync_from_buffer())
local cell = assert(state.cells[1])

test("streams output and persists a real execute result", function()
	set_source(cell, "import sys\nprint('hello from nvjup', flush=True)\nsys.executable")
	kernel.run_cells(state, { cell })
	wait_for(function()
		return cell.execution_status == "completed"
	end, "real kernel execution did not complete", 40000)
	assert(output_text(cell):find("hello from nvjup", 1, true))
	local status = kernel.status(state)
	assert(status.python_source == "project_venv")
	assert(status.python_path == python)
	local reported_python = cell.outputs[#cell.outputs].data["text/plain"]:gsub("^['\"]", ""):gsub("['\"]$", "")
	assert(vim.uv.fs_realpath(reported_python) == vim.uv.fs_realpath(python))
	assert(type(cell.execution_count) == "number")
	local path = vim.fn.tempname() .. ".ipynb"
	assert(state:save(path))
	local file = assert(io.open(path, "rb"))
	local document = vim.json.decode(file:read("*a"))
	file:close()
	assert(document.cells[1].execution_count == cell.execution_count)
	assert(#document.cells[1].outputs == #cell.outputs)
	local validation = vim.system({
		python,
		"-c",
		"import nbformat,sys; nbformat.validate(nbformat.read(sys.argv[1], as_version=4))",
		path,
	}, { text = true }):wait(10000)
	assert(validation.code == 0, validation.stderr)
	vim.fs.rm(path, { force = true })
end)

test("marks a real running result stale after an edit", function()
	set_source(cell, "import time\nprint('started', flush=True)\ntime.sleep(0.4)\nprint('old result')")
	kernel.run_cells(state, { cell })
	wait_for(function()
		return cell.execution_status == "running" and output_text(cell):find("started", 1, true)
	end, "cell did not enter running state")
	vim.api.nvim_buf_set_lines(state.buf, cell.range.start_row, cell.range.start_row, false, { "# edited" })
	assert(state:sync_from_buffer())
	wait_for(function()
		return cell.execution_status == "stale"
	end, "edited execution was not marked stale")
	assert(cell.stale)
	assert(output_text(cell):find("old result", 1, true))
end)

test("answers stdin requests through vim.ui.input", function()
	set_source(cell, "value = input('Name: ')\nprint('hello ' + value)")
	local original_input = vim.ui.input
	vim.ui.input = function(options, callback)
		assert(options.prompt == "Name: ")
		callback("nvjup")
	end
	kernel.run_cells(state, { cell })
	wait_for(function()
		return cell.execution_status == "completed"
	end, "stdin execution did not complete")
	vim.ui.input = original_input
	assert(output_text(cell):find("hello nvjup", 1, true))
end)

test("maps errors and interrupts a real kernel", function()
	set_source(cell, "raise RuntimeError('stage3 failure')")
	kernel.run_cells(state, { cell })
	wait_for(function()
		return cell.execution_status == "failed"
	end, "error execution did not fail")
	assert(cell.outputs[#cell.outputs].ename == "RuntimeError")

	set_source(cell, "import time\ntime.sleep(30)")
	kernel.run_cells(state, { cell })
	wait_for(function()
		return cell.execution_status == "running"
	end, "long execution did not start")
	assert(kernel.interrupt())
	wait_for(function()
		return cell.execution_status == "failed" or cell.execution_status == "cancelled"
	end, "interrupt did not terminate execution", 15000)
end)

test("restarts the kernel and executes a sequential batch", function()
	local restarted = false
	kernel.restart(function()
		restarted = true
	end)
	wait_for(function()
		return restarted
	end, "kernel restart did not complete", 40000)
	assert(kernel.status(state).generation >= 2)

	set_source(cell, "value_after_restart = 10\nprint('batch one')")
	local second = state:insert_cell(2, "code")
	set_source(second, "print('batch two')\nvalue_after_restart + 5")
	kernel.run_cells(state, { cell, second })
	wait_for(function()
		return cell.execution_status == "completed" and second.execution_status == "completed"
	end, "sequential batch did not complete", 40000)
	assert(output_text(cell):find("batch one", 1, true))
	assert(output_text(second):find("batch two", 1, true))
	assert(output_text(second):find("15", 1, true))
end)

if state then
	kernel.shutdown(state)
	vim.wait(500)
	if vim.api.nvim_buf_is_valid(state.buf) then
		vim.api.nvim_buf_delete(state.buf, { force = true })
	end
end

if #failures > 0 then
	print(table.concat(failures, "\n\n"))
	vim.cmd("cquit " .. math.min(255, #failures))
else
	print(string.format("Stage 3 kernel integration tests: %d passed", passed))
	vim.cmd("qa!")
end
