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

local requests = {}
local png = "iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAYAAAC09K7GAAAAEklEQVR42mPwKdrwHxkzEBQAANiRHR2gDahVAAAAAElFTkSuQmCC"

interactive._set_client_factory(function()
	return {
		request = function(_, request_type, payload, _, callback)
			table.insert(requests, { type = request_type, payload = payload })
			if request_type == "plotly.open" then
				callback(nil, {
					figure_id = payload.figure_id,
					png = png,
					width = 900,
					height = 540,
					frame_latency_ms = 12.5,
					open_latency_ms = 42.0,
				})
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
	assert(requests[1].type == "plotly.open")
	assert(requests[1].payload.width == config.options.interactive.width_px)
	assert(rendered.outputs[1].data["image/png"] == png)
	assert(rendered.outputs[1].metadata["image/png"].width == 900)
	assert(next(seen) ~= nil)
	assert(cell.outputs[1].data["image/png"] == nil, "original notebook MIME bundle was mutated")
	interactive.finish_render(state, seen)
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
	assert(requests[#requests].type == "plotly.close")
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
