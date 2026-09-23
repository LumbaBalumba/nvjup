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
	local lines, seen = image.render(state, cell, math.max(24, vim.api.nvim_win_get_width(focus.win) - 2))
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

local function pointer_position()
	local mouse = vim.fn.getmousepos()
	if not focus or mouse.winid ~= focus.win then
		return nil
	end
	local width = math.max(1, vim.api.nvim_win_get_width(focus.win))
	local height = math.max(1, vim.api.nvim_win_get_height(focus.win))
	return math.max(0, (mouse.wincol - 1) / width * focus.entry.width),
		math.max(0, (mouse.winrow - 1) / height * focus.entry.height)
end

local function send_event(event, extra)
	if not focus or not focus.entry.png or focus.event_pending then
		return
	end
	local active = focus
	local x, y = pointer_position()
	if not x then
		return
	end
	local payload = vim.tbl_extend("force", {
		figure_id = focus.entry.figure_id,
		event = event,
		x = x,
		y = y,
	}, extra or {})
	active.event_pending = true
	get_client():request("plotly.event", payload, {}, function(err, frame)
		active.event_pending = false
		if not err then
			store_frame(active.entry.state, active.entry, frame)
		end
	end)
end

local function close_focus()
	if not focus then
		return
	end
	local active = focus
	focus = nil
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
	local width = math.min(vim.o.columns - 4, (options().focus_width or 76))
	local height = math.min(vim.o.lines - 4, (options().focus_height or 30))
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
	}
	vim.bo[buffer].buftype = "nofile"
	vim.bo[buffer].bufhidden = "wipe"
	vim.bo[buffer].modifiable = true
	vim.o.mousemoveevent = true
	vim.keymap.set("n", "q", close_focus, { buffer = buffer, silent = true })
	vim.keymap.set("n", "<Esc>", close_focus, { buffer = buffer, silent = true })
	vim.keymap.set("n", "<LeftMouse>", function()
		local x, y = pointer_position()
		if x then
			focus.drag_start = { x, y }
			send_event("click")
		end
	end, { buffer = buffer, silent = true })
	vim.keymap.set("n", "<LeftDrag>", function()
		local x, y = pointer_position()
		if x and focus.drag_start then
			local start = focus.drag_start
			focus.drag_start = { x, y }
			send_event("drag", { x = start[1], y = start[2], to_x = x, to_y = y })
		end
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

return M
