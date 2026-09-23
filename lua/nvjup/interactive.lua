local config = require("nvjup.config")
local image = require("nvjup.image")
local rpc = require("nvjup.rpc")

local M = {}
local client
local cache = {}
local focus
local client_factory = rpc.new

local PLOTLY_MIME = "application/vnd.plotly.v1+json"

local function options()
	return config.options.interactive or {}
end

local function renderer_command()
	local configured = options().command
	if type(configured) == "function" then
		return configured()
	end
	if type(configured) == "table" and #configured > 0 then
		return vim.deepcopy(configured)
	end
	local sidecar = rpc.default_command()
	return { sidecar[1], vim.fs.joinpath(rpc.plugin_root(), "python", "nvjup_plotly_renderer_main.py") }
end

local function get_client()
	if not client then
		client = client_factory({
			command = renderer_command(),
			on_exit = function()
				client = nil
			end,
		})
	end
	return client
end

local function key(state, cell, output_index)
	return table.concat({ state.buf, cell.id, output_index }, ":")
end

local function figure_id(state, cell, output_index)
	return string.format("nvjup-%d-%s-%d", state.buf, cell.id:gsub("[^%w_-]", "_"), output_index)
end

local function figure_hash(figure)
	local ok, encoded = pcall(vim.json.encode, figure)
	if not ok then
		return nil, encoded
	end
	return vim.fn.sha256(encoded), encoded
end

local function refresh(state)
	if state and vim.api.nvim_buf_is_valid(state.buf) then
		vim.schedule(function()
			if vim.api.nvim_buf_is_valid(state.buf) then
				require("nvjup.render").render(state)
			end
		end)
	end
end

local function update_focus(entry)
	if not focus or focus.entry ~= entry or not vim.api.nvim_buf_is_valid(focus.buf) then
		return
	end
	local cell = {
		id = "plotly-focus-" .. entry.figure_id,
		outputs = {
			{
				output_type = "display_data",
				data = { ["image/png"] = entry.png },
				metadata = { ["image/png"] = { width = entry.width, height = entry.height } },
			},
		},
	}
	local state = { buf = focus.buf }
	local available_width = math.max(24, vim.api.nvim_win_get_width(focus.win) - 2)
	local lines, seen, _, geometry = image.render(state, cell, available_width, {
		max_width = math.max(8, available_width - 2),
		max_height = math.max(4, vim.api.nvim_win_get_height(focus.win) - 3),
	})
	focus.image_geometry = geometry[1]
	vim.api.nvim_buf_clear_namespace(focus.buf, focus.namespace, 0, -1)
	vim.api.nvim_buf_set_extmark(focus.buf, focus.namespace, 0, 0, {
		virt_lines = lines,
		virt_lines_above = true,
	})
	image.finish_render(state, seen)
	vim.api.nvim_buf_set_lines(focus.buf, 0, -1, false, {
		string.format(
			"Plotly focus · click/drag/hover/wheel · q close · frame %.1f ms",
			entry.frame_latency_ms or 0
		),
	})
end

local function store_frame(state, entry, payload)
	entry.pending = false
	entry.png = payload.png
	entry.width = payload.width
	entry.height = payload.height
	entry.frame_latency_ms = payload.frame_latency_ms
	entry.open_latency_ms = payload.open_latency_ms or entry.open_latency_ms
	entry.error = nil
	refresh(state)
	update_focus(entry)
end

local function request_open(state, cell, output_index, figure, entry)
	entry.pending = true
	get_client():request("plotly.open", {
		figure_id = entry.figure_id,
		figure = figure,
		width = options().width_px or 900,
		height = options().height_px or 540,
	}, {}, function(err, payload)
		if err then
			entry.pending = false
			entry.error = err.message or tostring(err)
			if not entry.notified then
				entry.notified = true
				vim.notify("nvjup Plotly renderer: " .. entry.error, vim.log.levels.WARN)
			end
			refresh(state)
			return
		end
		store_frame(state, entry, payload)
	end)
end

function M.prepare_cell(state, cell)
	local copy = vim.deepcopy(cell)
	local seen = {}
	for output_index, item in ipairs(cell.outputs or {}) do
		local figure = type(item.data) == "table" and item.data[PLOTLY_MIME] or nil
		if type(figure) == "table" and options().enabled ~= false then
			local cache_key = key(state, cell, output_index)
			seen[cache_key] = true
			local hash, encoded = figure_hash(figure)
			local entry = cache[cache_key]
			if not hash then
				entry = { error = tostring(encoded), figure_id = figure_id(state, cell, output_index) }
				cache[cache_key] = entry
			elseif not entry or entry.hash ~= hash then
				entry = {
					key = cache_key,
					hash = hash,
					figure_id = figure_id(state, cell, output_index),
					state = state,
					cell_id = cell.id,
					output_index = output_index,
				}
				cache[cache_key] = entry
				request_open(state, cell, output_index, figure, entry)
			end
			if entry.png then
				copy.outputs[output_index].data["image/png"] = entry.png
				copy.outputs[output_index].metadata = vim.tbl_deep_extend(
					"force",
					copy.outputs[output_index].metadata or {},
					{ ["image/png"] = { width = entry.width, height = entry.height } }
				)
			end
		end
	end
	return copy, seen
end

function M.seen(state, cell, output_index)
	return cache[key(state, cell, output_index)] ~= nil
end

function M.finish_render(state, seen)
	for cache_key, entry in pairs(cache) do
		if entry.state == state and not seen[cache_key] then
			if client and entry.figure_id then
				client:request("plotly.close", { figure_id = entry.figure_id }, {}, function() end)
			end
			cache[cache_key] = nil
		end
	end
end

local function pixel_position(mouse, geometry, entry)
	if not geometry or not entry or not entry.width or not entry.height then
		return nil
	end
	local column = mouse.wincol - geometry.col
	local row = mouse.winrow - geometry.row
	if column < 0 or row < 0 or column >= geometry.cols or row >= geometry.rows then
		return nil
	end
	local x = geometry.cols > 1 and (column / (geometry.cols - 1)) * (entry.width - 1) or 0
	local y = geometry.rows > 1 and (row / (geometry.rows - 1)) * (entry.height - 1) or 0
	return x, y
end

local function pointer_position()
	local mouse = vim.fn.getmousepos()
	if not focus or mouse.winid ~= focus.win then
		return nil
	end
	return pixel_position(mouse, focus.image_geometry, focus.entry)
end

local dispatch_event

local function queue_event(active, payload)
	if active.event_pending then
		local queue = active.event_queue
		if payload.event == "move" and queue[#queue] and queue[#queue].event == "move" then
			queue[#queue] = payload
		else
			if #queue >= 32 then
				for index, queued in ipairs(queue) do
					if queued.event == "move" then
						table.remove(queue, index)
						break
					end
				end
			end
			table.insert(queue, payload)
		end
		return
	end
	dispatch_event(active, payload)
end

function dispatch_event(active, payload)
	active.event_pending = true
	get_client():request("plotly.event", payload, {}, function(err, frame)
		active.event_pending = false
		if not err then
			store_frame(active.entry.state, active.entry, frame)
		end
		local next_event = table.remove(active.event_queue, 1)
		if next_event then
			dispatch_event(active, next_event)
		end
	end)
end

local function send_event(event, extra)
	if not focus or not focus.entry.png then
		return
	end
	local active = focus
	local x, y = pointer_position()
	if x then
		active.last_pointer = { x, y }
	elseif event == "up" and active.last_pointer then
		x, y = active.last_pointer[1], active.last_pointer[2]
	else
		return
	end
	queue_event(
		active,
		vim.tbl_extend("force", {
			figure_id = active.entry.figure_id,
			event = event,
			x = x,
			y = y,
		}, extra or {})
	)
end

local function close_focus()
	if not focus then
		return
	end
	local active = focus
	focus = nil
	active.event_queue = {}
	vim.o.mousemoveevent = active.previous_mousemoveevent
	if vim.api.nvim_buf_is_valid(active.buf) then
		image.detach({ buf = active.buf })
	end
	if vim.api.nvim_win_is_valid(active.win) then
		vim.api.nvim_win_close(active.win, true)
	end
end

function M.open_focus(state, cell)
	state = state or require("nvjup.notebook").get()
	if not state then
		return nil
	end
	cell = cell or state:current_cell()
	if not cell then
		return nil
	end
	local entry
	for output_index, item in ipairs(cell.outputs or {}) do
		if type(item.data) == "table" and type(item.data[PLOTLY_MIME]) == "table" then
			entry = cache[key(state, cell, output_index)]
			if not entry then
				M.prepare_cell(state, cell)
				entry = cache[key(state, cell, output_index)]
			end
			break
		end
	end
	if not entry then
		vim.notify("current cell has no Plotly output", vim.log.levels.INFO)
		return nil
	end
	if not entry.png then
		vim.notify("Plotly frame is still rendering", vim.log.levels.INFO)
		return nil
	end
	close_focus()
	local buffer = vim.api.nvim_create_buf(false, true)
	local width = math.min(vim.o.columns - 4, (options().focus_width or 112))
	local height = math.min(vim.o.lines - 4, (options().focus_height or 40))
	local window = vim.api.nvim_open_win(buffer, true, {
		relative = "editor",
		row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
		col = math.max(0, math.floor((vim.o.columns - width) / 2)),
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " nvjup Plotly ",
	})
	focus = {
		buf = buffer,
		win = window,
		entry = entry,
		namespace = vim.api.nvim_create_namespace("nvjup-plotly-focus-" .. buffer),
		previous_mousemoveevent = vim.o.mousemoveevent,
		event_queue = {},
	}
	vim.bo[buffer].buftype = "nofile"
	vim.bo[buffer].bufhidden = "wipe"
	vim.bo[buffer].modifiable = true
	vim.o.mousemoveevent = true
	vim.keymap.set("n", "q", close_focus, { buffer = buffer, silent = true })
	vim.keymap.set("n", "<Esc>", close_focus, { buffer = buffer, silent = true })
	vim.keymap.set("n", "<LeftMouse>", function()
		send_event("down")
	end, { buffer = buffer, silent = true })
	vim.keymap.set("n", "<LeftDrag>", function()
		send_event("move")
	end, { buffer = buffer, silent = true })
	vim.keymap.set("n", "<LeftRelease>", function()
		send_event("up")
	end, { buffer = buffer, silent = true })
	vim.keymap.set("n", "<MouseMove>", function()
		send_event("move")
	end, { buffer = buffer, silent = true })
	vim.keymap.set("n", "<ScrollWheelUp>", function()
		send_event("wheel", { delta_y = -160 })
	end, { buffer = buffer, silent = true })
	vim.keymap.set("n", "<ScrollWheelDown>", function()
		send_event("wheel", { delta_y = 160 })
	end, { buffer = buffer, silent = true })
	local previous_mousemoveevent = focus.previous_mousemoveevent
	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = buffer,
		once = true,
		callback = function()
			if focus and focus.buf == buffer then
				focus = nil
				vim.o.mousemoveevent = previous_mousemoveevent
			end
		end,
	})
	update_focus(entry)
	return buffer, window
end

function M.detach(state)
	M.finish_render(state, {})
	if focus and focus.entry.state == state then
		close_focus()
	end
end

function M.shutdown()
	close_focus()
	if client then
		client:request("renderer.shutdown", {}, {}, function()
			if client then
				client:kill()
				client = nil
			end
		end)
	end
	cache = {}
end

function M.status()
	local count = 0
	for _ in pairs(cache) do
		count = count + 1
	end
	return { figures = count, running = client ~= nil }
end

function M._set_client_factory(factory)
	if client then
		client:kill()
	end
	client = nil
	client_factory = factory or rpc.new
end

M._cache = cache
M._close_focus = close_focus
M._pixel_position = pixel_position
M._queue_event = queue_event

return M
