local config = require("nvjup.config")
local interactive = require("nvjup.interactive")
local output = require("nvjup.output")
local trust = require("nvjup.trust")

local passed = 0
local failures = {}

local function test(name, callback)
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		passed = passed + 1
	else
		table.insert(failures, name .. ":\n" .. err)
	end
end

local temporary = vim.fn.tempname()
vim.fn.mkdir(temporary, "p")
config.options.interactive.require_trust = true
config.options.interactive.trust_file = vim.fs.joinpath(temporary, "trust.json")
config.options.interactive.restart_delay_ms = 1
config.options.execution.trust_local_kernel = true
trust.reset_cache()

local function state(path)
	return {
		buf = 99200,
		path = path,
		document = { metadata = {} },
		cells = {
			{
				id = "trusted-cell",
				cell_type = "code",
				source = "print('safe to inspect')",
				raw = {},
				outputs = {
					{
						output_type = "display_data",
						data = {
							["application/vnd.plotly.v1+json"] = {
								data = { { type = "scatter", x = { 1, 2 }, y = { 2, 1 } } },
								layout = {},
							},
						},
						metadata = {},
					},
				},
			},
		},
	}
end

local notebook_path = vim.fs.joinpath(temporary, "stage6.ipynb")
vim.fn.writefile({ "{}" }, notebook_path)

local requests = {}
local client_options = {}
local clients = 0
local png = "iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAYAAAC09K7GAAAAEklEQVR42mPwKdrwHxkzEBQAANiRHR2gDahVAAAAAElFTkSuQmCC"

interactive._set_client_factory(function(options)
	clients = clients + 1
	client_options[clients] = options
	return {
		request = function(_, request_type, payload, _, callback)
			table.insert(requests, { type = request_type, payload = payload })
			if request_type == "renderer.open" then
				callback(nil, {
					figure_id = payload.figure_id,
					png = png,
					width = 900,
					height = 540,
					source_width = 900,
					source_height = 540,
					frame_sequence = 1,
					frame_latency_ms = 18,
					push_frames = true,
				})
			elseif callback then
				callback(nil, { closed = true })
			end
		end,
		kill = function() end,
	}
end)

test("trust is local, content-addressed, and invalidated by code changes", function()
	local current = state(notebook_path)
	assert(trust.status(current) == "unknown")
	assert(trust.grant(current))
	assert(trust.status(current) == "trusted_interactive")
	local content = table.concat(vim.fn.readfile(config.options.interactive.trust_file), "\n")
	assert(not content:find("print('safe to inspect')", 1, true), "trust file leaked notebook source")
	current.cells[1].source = "print('changed')"
	trust.invalidate(current)
	assert(trust.status(current) == "untrusted")
	assert(trust.revoke(current))
	assert(trust.status(current) == "revoked")
end)

test("active MIME changes invalidate an otherwise unchanged notebook", function()
	local current = state(notebook_path)
	assert(trust.grant(current))
	current.cells[1].outputs[1].data["application/vnd.plotly.v1+json"].layout.title = "changed"
	trust.invalidate(current)
	assert(trust.status(current) == "untrusted")
end)

test("interactive output produced by the local kernel is trusted by default", function()
	local local_path = vim.fs.joinpath(temporary, "local-kernel.ipynb")
	vim.fn.writefile({ "{}" }, local_path)
	local current = state(local_path)
	local cell = current.cells[1]
	trust.mark_local_execution(cell)
	local status, details = trust.status(current, cell)
	assert(status == "trusted_interactive")
	assert(details.local_kernel == true)
	local unsaved = state("")
	unsaved.buf = -1
	trust.mark_local_execution(unsaved.cells[1])
	assert(trust.status(unsaved, unsaved.cells[1]) == "trusted_interactive")
	local revoked_path = vim.fs.joinpath(temporary, "revoked-local-kernel.ipynb")
	vim.fn.writefile({ "{}" }, revoked_path)
	local revoked = state(revoked_path)
	assert(trust.revoke(revoked))
	trust.mark_local_execution(revoked.cells[1])
	assert(trust.status(revoked, revoked.cells[1]) == "revoked")
	local before = #requests
	interactive.prepare_cell(current, cell)
	assert(#requests == before + 1)
	assert(requests[#requests].type == "renderer.open")
	interactive.finish_render(current, {})
	cell.source = "print('edited after execution')"
	cell.revision = 1
	trust.invalidate(current)
	assert(trust.status(current, cell) == "unknown")
end)

test("untrusted output is blocked without starting Chromium", function()
	local current = state(notebook_path)
	trust.revoke(current)
	local before = #requests
	local copy, seen = interactive.prepare_cell(current, current.cells[1])
	assert(#requests == before)
	assert(next(seen) == nil)
	assert(copy.outputs[1].data["application/vnd.plotly.v1+json"] == nil)
	assert(copy.outputs[1].data["text/plain"]:find("blocked", 1, true))
	local segments = output.segments(copy, { include_images = false })
	assert(segments[1].lines[1]:find("blocked", 1, true))
	assert(current.cells[1].outputs[1].data["application/vnd.plotly.v1+json"] ~= nil)
end)

test("trusted output opens and renderer crashes replay cached figures", function()
	local current = state(notebook_path)
	assert(trust.grant(current))
	local before = #requests
	local copy = interactive.prepare_cell(current, current.cells[1])
	assert(#requests == before + 1)
	assert(requests[#requests].type == "renderer.open")
	assert(copy.outputs[1].data["image/png"] == png)
	local first_client = clients
	client_options[first_client].on_exit({ code = 1 })
	assert(vim.wait(1000, function()
		return clients > first_client
	end, 5))
	assert(requests[#requests].type == "renderer.open")
end)

interactive.shutdown()
interactive._set_client_factory(nil)
trust.reset_cache()
vim.fn.delete(temporary, "rf")

if #failures > 0 then
	print(
		string.format(
			"Stage 6 Lua tests: %d passed, %d failed\n\n%s",
			passed,
			#failures,
			table.concat(failures, "\n\n")
		)
	)
	vim.cmd("cquit 1")
	return
end

print(string.format("Stage 6 Lua tests: %d passed", passed))
vim.cmd("qa!")
