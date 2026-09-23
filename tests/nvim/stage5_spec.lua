local config = require("nvjup.config")
local interactive = require("nvjup.interactive")

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

config.options.interactive.require_trust = false
assert(config.options.keymaps.plot_focus == "<leader>nf")
assert(config.options.keymaps.plot_focus_tui == "<leader>nF")

local requests = {}
local client_options
local png = "iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAYAAAC09K7GAAAAEklEQVR42mPwKdrwHxkzEBQAANiRHR2gDahVAAAAAElFTkSuQmCC"

interactive._set_client_factory(function(options)
	client_options = options
	return {
		request = function(_, request_type, payload, _, callback)
			table.insert(requests, { type = request_type, payload = payload })
			if request_type == "renderer.open" then
				callback(nil, {
					figure_id = payload.figure_id,
					png = png,
					width = 900,
					height = 540,
					frame_latency_ms = 12.5,
					open_latency_ms = 42.0,
				})
			elseif request_type == "renderer.export_external" then
				callback(
					nil,
					{ figure_id = payload.figure_id, path = "/tmp/nvjup.html", url = "file:///tmp/nvjup.html" }
				)
			elseif callback then
				callback(nil, { closed = true })
			end
		end,
		kill = function() end,
	}
end)

test("turns Plotly MIME into a cached PNG frame", function()
	local state = { buf = 99123 }
	local cell = {
		id = "plot-cell",
		outputs = {
			{
				output_type = "display_data",
				data = {
					["application/vnd.plotly.v1+json"] = {
						data = { { type = "scatter", x = { 1, 2 }, y = { 2, 3 } } },
						layout = { title = { text = "stage 5" } },
					},
				},
				metadata = {},
			},
		},
	}
	local rendered, seen = interactive.prepare_cell(state, cell)
	assert(requests[1].type == "renderer.open")
	assert(requests[1].payload.width == config.options.interactive.width_px)
	assert(rendered.outputs[1].data["image/png"] == png)
	assert(rendered.outputs[1].metadata["image/png"].width == 900)
	assert(next(seen) ~= nil)
	assert(cell.outputs[1].data["image/png"] == nil, "original notebook MIME bundle was mutated")
	interactive.finish_render(state, seen)
end)

test("opens Awrit externally and keeps TUI focus as a separate action", function()
	local launched
	local closed = false
	interactive._set_external_launcher(function(entry, exported, callback)
		launched = { entry = entry, exported = exported }
		callback(nil)
		return {
			close = function()
				closed = true
			end,
		}
	end)
	local state = { buf = 99126 }
	local cell = {
		id = "external-plot",
		outputs = {
			{
				output_type = "display_data",
				data = { ["application/vnd.plotly.v1+json"] = { data = {}, layout = {} } },
				metadata = {},
			},
		},
	}
	interactive.prepare_cell(state, cell)
	assert(interactive.open_external(state, cell))
	assert(requests[#requests].type == "renderer.export_external")
	assert(launched.exported.url == "file:///tmp/nvjup.html")
	assert(interactive.status().external_windows == 1)
	local focus_buf, focus_win = interactive.open_focus(state, cell)
	assert(vim.api.nvim_buf_is_valid(focus_buf))
	assert(vim.api.nvim_win_is_valid(focus_win))
	assert(closed)
	assert(interactive.status().external_windows == 0)
	interactive._close_focus()
	interactive.finish_render(state, {})
	interactive._set_external_launcher(nil)
end)

test("accepts pushed renderer frames", function()
	local entry = interactive._cache["99123:plot-cell:1"]
	assert(entry)
	client_options.on_event({
		type = "renderer.frame",
		payload = {
			figure_id = entry.figure_id,
			png = png,
			width = 720,
			height = 432,
			source_width = 900,
			source_height = 540,
			frame_sequence = 2,
			frame_latency_ms = 16.7,
			quality = "interactive",
			frame_source = "screencast",
		},
	})
	assert(entry.png == png)
	assert(entry.frame_sequence == 2)
	assert(entry.source_width == 900)
	assert(entry.quality == "interactive")
end)

test("recognizes safe Bokeh notebook payloads", function()
	local backend, payload = interactive._interactive_payload({
		data = {
			["application/vnd.bokehjs_exec.v0+json"] = "",
			["application/javascript"] = "const docs_json = {}; const render_items = [];",
		},
	})
	assert(backend == "bokeh")
	assert(payload.script:find("docs_json", 1, true))
end)

test("closes browser figures that disappear from notebook output", function()
	local state = { buf = 99124 }
	local cell = {
		id = "removed-plot",
		outputs = {
			{
				output_type = "display_data",
				data = { ["application/vnd.plotly.v1+json"] = { data = {}, layout = {} } },
				metadata = {},
			},
		},
	}
	interactive.prepare_cell(state, cell)
	local before = #requests
	interactive.finish_render(state, {})
	assert(#requests == before + 1)
	assert(requests[#requests].type == "renderer.close")
end)

test("maps mouse cells only inside the rendered figure", function()
	assert(config.options.interactive.focus_width >= 100)
	assert(config.options.interactive.focus_height >= 36)
	local geometry = { col = 3, row = 1, cols = 100, rows = 30 }
	local entry = { width = 900, height = 540 }
	local x, y = interactive._pixel_position({ wincol = 3, winrow = 1 }, geometry, entry)
	assert(x == 0 and y == 0)
	x, y = interactive._pixel_position({ wincol = 102, winrow = 30 }, geometry, entry)
	assert(math.floor(x + 0.5) == 899 and math.floor(y + 0.5) == 539)
	assert(interactive._pixel_position({ wincol = 2, winrow = 1 }, geometry, entry) == nil)
	assert(interactive._pixel_position({ wincol = 103, winrow = 1 }, geometry, entry) == nil)
end)

test("queues clicks and releases behind an in-flight hover frame", function()
	local sent = {}
	local callbacks = {}
	interactive._set_client_factory(function()
		return {
			request = function(_, request_type, payload, _, callback)
				assert(request_type == "renderer.event")
				table.insert(sent, payload.event)
				table.insert(callbacks, callback)
			end,
			kill = function() end,
		}
	end)
	local active = {
		entry = { state = { buf = 99125 }, figure_id = "queued", width = 900, height = 540 },
		event_queue = {},
	}
	local function enqueue(event)
		interactive._queue_event(active, { figure_id = "queued", event = event, x = 1, y = 1 })
	end
	enqueue("move")
	enqueue("down")
	enqueue("move")
	enqueue("up")
	assert(vim.deep_equal(sent, { "move" }))
	while #callbacks > 0 do
		local callback = table.remove(callbacks, 1)
		callback(nil, { png = png, width = 900, height = 540, frame_latency_ms = 1 })
	end
	assert(vim.deep_equal(sent, { "move", "down", "move", "up" }), vim.inspect(sent))
end)

interactive._set_client_factory(nil)

if #failures > 0 then
	print(
		string.format(
			"Stage 5 Lua tests: %d passed, %d failed\n\n%s",
			passed,
			#failures,
			table.concat(failures, "\n\n")
		)
	)
	vim.cmd("cquit 1")
	return
end

print(string.format("Stage 5 Lua tests: %d passed", passed))
vim.cmd("qa!")
