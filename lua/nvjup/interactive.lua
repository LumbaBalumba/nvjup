local config = require("nvjup.config")
local image = require("nvjup.image")
local rpc = require("nvjup.rpc")
local trust = require("nvjup.trust")

local M = {}
local client
local cache = {}
local focus
local external_windows = {}
local external_generation = 0
local client_factory = rpc.new
local external_launcher
local shutting_down = false
local restart_attempts = 0
local last_renderer_status = {}

local PLOTLY_MIME = "application/vnd.plotly.v1+json"
local BOKEH_EXEC_MIME = "application/vnd.bokehjs_exec.v0+json"
local BOKEH_LOAD_MIME = "application/vnd.bokehjs_load.v0+json"
-- Logical render density; the 1:2 ratio matches Kitty's placeholder grid.
local TUI_CELL_WIDTH_PX = 10
local TUI_CELL_HEIGHT_PX = 20

local function options()
	return config.options.interactive or {}
end

local function awrit_command()
	local configured = options().awrit_command
	if type(configured) == "function" then
		configured = configured()
	end
	if type(configured) == "table" and #configured > 0 then
		return vim.deepcopy(configured)
	end
	if type(configured) == "string" and configured ~= "" then
		return { configured }
	end
	return { "awrit" }
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

local function refresh(state, cell_id)
	if state and state.buf and vim.api.nvim_buf_is_valid(state.buf) then
		if cell_id then
			require("nvjup.render").request_cell(state, cell_id, 16)
		else
			require("nvjup.render").request(state)
		end
	end
end

local function key(state, cell, output_index)
	return table.concat({ state.buf, cell.id, output_index }, ":")
end

local function figure_id(state, cell, output_index)
	return string.format("nvjup-%d-%s-%d", state.buf, cell.id:gsub("[^%w_-]", "_"), output_index)
end

local function figure_hash(backend, figure)
	local ok, encoded = pcall(vim.json.encode, { backend = backend, figure = figure })
	if not ok then
		return nil, encoded
	end
	return vim.fn.sha256(encoded), encoded
end

local function interactive_payload(item)
	local data = type(item.data) == "table" and item.data or {}
	if type(data[PLOTLY_MIME]) == "table" then
		return "plotly", data[PLOTLY_MIME]
	end
	if data[BOKEH_EXEC_MIME] ~= nil then
		local marker = data[BOKEH_EXEC_MIME]
		if type(marker) == "table" and next(marker) then
			return "bokeh", marker
		end
		if type(data["application/javascript"]) == "string" then
			return "bokeh", { script = data["application/javascript"] }
		end
	end
	return nil
end

local function blocked_copy(item, status)
	local copy = vim.tbl_extend("force", {}, item)
	copy.data = type(item.data) == "table" and vim.tbl_extend("force", {}, item.data) or {}
	copy.data[PLOTLY_MIME] = nil
	copy.data[BOKEH_EXEC_MIME] = nil
	copy.data[BOKEH_LOAD_MIME] = nil
	copy.data["application/javascript"] = nil
	copy.data["text/plain"] = string.format(
		"[nvjup interactive output blocked: notebook trust is %s; use :NvJupTrustInteractive after reviewing the notebook]",
		status
	)
	return copy
end

local function update_focus(entry)
	if not focus or focus.entry ~= entry or not vim.api.nvim_buf_is_valid(focus.buf) then
		return
	end
	local cell = {
		id = "interactive-focus-" .. entry.figure_id,
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
			"%s focus · pointer/keys · q close · %.1f ms · %s/%s",
			entry.backend == "bokeh" and "Bokeh" or "Plotly",
			entry.frame_latency_ms or 0,
			entry.frame_source or "pull",
			entry.quality or "high"
		),
	})
end

local function store_frame(state, entry, payload)
	if type(payload) ~= "table" or type(payload.png) ~= "string" then
		return false
	end
	local sequence = tonumber(payload.frame_sequence) or 0
	if sequence > 0 and entry.frame_sequence and sequence <= entry.frame_sequence then
		return false
	end
	entry.pending = false
	entry.opened = true
	entry.png = payload.png
	entry.width = payload.width
	entry.height = payload.height
	entry.source_width = payload.source_width or payload.width
	entry.source_height = payload.source_height or payload.height
	entry.frame_latency_ms = payload.frame_latency_ms
	entry.input_latency_ms = payload.input_latency_ms or entry.input_latency_ms
	entry.open_latency_ms = payload.open_latency_ms or entry.open_latency_ms
	entry.frame_sequence = sequence > 0 and sequence or entry.frame_sequence
	entry.frame_source = payload.frame_source or entry.frame_source
	entry.quality = payload.quality or entry.quality
	entry.push_frames = payload.push_frames == true or entry.push_frames == true
	entry.error = nil
	entry.notified = nil
	local cell = state and state.cell_by_id and state:cell_by_id(entry.cell_id) or nil
	if cell then
		cell.interactive_frame_generation = (cell.interactive_frame_generation or 0) + 1
		cell.interactive_render_cache = nil
	end
	refresh(state, entry.cell_id)
	update_focus(entry)
	return true
end

local function entry_for_figure(id)
	for _, entry in pairs(cache) do
		if entry.figure_id == id then
			return entry
		end
	end
end

local request_open
local function replay_after_crash()
	if shutting_down or restart_attempts >= (options().restart_attempts or 2) then
		return
	end
	restart_attempts = restart_attempts + 1
	vim.defer_fn(function()
		if shutting_down then
			return
		end
		for _, entry in pairs(cache) do
			local cell
			for _, candidate in ipairs(entry.state and entry.state.cells or {}) do
				if candidate.id == entry.cell_id then
					cell = candidate
					break
				end
			end
			if entry.state and entry.figure and trust.allows_interactive(entry.state, cell) then
				request_open(entry.state, entry)
			end
		end
	end, options().restart_delay_ms or 150)
end

local function on_renderer_event(message)
	if message.type == "renderer.frame" then
		local payload = message.payload or {}
		local entry = entry_for_figure(payload.figure_id)
		if entry then
			store_frame(entry.state, entry, payload)
		end
	elseif message.type == "renderer.warning" then
		vim.notify("nvjup renderer: " .. tostring((message.payload or {}).message), vim.log.levels.WARN)
	end
end

local function kitty_remote_command(arguments)
	local command = { "kitty", "@" }
	local socket = vim.env.KITTY_LISTEN_ON
	if socket and socket ~= "" then
		vim.list_extend(command, { "--to", socket })
	end
	vim.list_extend(command, arguments)
	return command
end

local function resolve_awrit(executable)
	local resolved = vim.fn.exepath(executable)
	if resolved ~= "" then
		return resolved
	end
	if executable == "awrit" then
		for _, candidate in ipairs({
			vim.fs.joinpath(vim.fn.expand("~/.local/bin"), "awrit"),
			vim.fs.joinpath(vim.fn.expand("~/awrit"), "awrit"),
		}) do
			if vim.fn.executable(candidate) == 1 then
				return candidate
			end
		end
	end
	return nil
end

local function default_external_launcher(_, exported, callback)
	local awrit = awrit_command()
	local resolved = resolve_awrit(awrit[1])
	if not resolved then
		callback(
			"awrit executable was not found; install https://github.com/chase/awrit or configure interactive.awrit_command"
		)
		return nil
	end
	awrit[1] = resolved
	if vim.fn.executable("kitty") ~= 1 or not vim.env.KITTY_LISTEN_ON or vim.env.KITTY_LISTEN_ON == "" then
		callback("a Kitty remote-control socket is required for the external Awrit window")
		return nil
	end
	local arguments = { "launch", "--type=os-window", "--title=nvjup interactive" }
	vim.list_extend(arguments, awrit)
	if options().awrit_disable_gpu ~= false then
		vim.list_extend(arguments, { "--disable-gpu", "--disable-gpu-compositing" })
	end
	table.insert(arguments, exported.url)
	local command = kitty_remote_command(arguments)
	local handle = {}
	handle.process = vim.system(command, { text = true }, function(result)
		vim.schedule(function()
			if result.code ~= 0 then
				callback((result.stderr or "kitty failed to launch Awrit"):gsub("%s+$", ""))
				return
			end
			handle.window_id = (result.stdout or ""):match("(%d+)")
			callback(nil, handle)
		end)
	end)
	function handle.close()
		if not handle.window_id then
			return
		end
		local window_id = handle.window_id
		handle.window_id = nil
		vim.system(kitty_remote_command({ "signal-child", "--match", "id:" .. window_id, "SIGTERM" }), {}, function()
			vim.defer_fn(function()
				vim.system(kitty_remote_command({ "close-window", "--match", "id:" .. window_id }), {}, function() end)
			end, 250)
		end)
	end
	return handle
end

external_launcher = default_external_launcher

local function close_external(cache_key, release)
	local handle = external_windows[cache_key]
	external_windows[cache_key] = nil
	local entry = cache[cache_key]
	local had_external = handle ~= nil or (entry and (entry.external or entry.external_pending))
	if entry then
		entry.external = false
		entry.external_pending = false
	end
	if handle and handle.close then
		pcall(handle.close)
	end
	if had_external and release ~= false and client and entry and entry.figure_id then
		client:request("renderer.release_external", { figure_id = entry.figure_id }, {}, function() end)
	end
end

local function close_all_external(release)
	external_generation = external_generation + 1
	for cache_key in pairs(external_windows) do
		close_external(cache_key, release)
	end
end

local function get_client()
	if client then
		return client
	end
	local created
	created = client_factory({
		command = renderer_command(),
		on_event = on_renderer_event,
		on_exit = function()
			close_all_external(false)
			if client == created then
				client = nil
			end
			for _, entry in pairs(cache) do
				entry.pending = false
				entry.opened = false
				entry.error = "renderer process exited; recovery scheduled"
			end
			replay_after_crash()
		end,
	})
	client = created
	return client
end

request_open = function(state, entry)
	entry.pending = true
	entry.error = nil
	get_client():request("renderer.open", {
		figure_id = entry.figure_id,
		backend = entry.backend,
		figure = entry.figure,
		width = options().width_px or 900,
		height = options().height_px or 540,
		interactive_width = options().interactive_width_px or 720,
		interactive_height = options().interactive_height_px or 432,
		screencast = options().screencast ~= false,
		adaptive_resolution = options().adaptive_resolution ~= false,
		max_figures = options().max_figures or 8,
		max_fps = options().max_fps or 60,
	}, {}, function(err, payload)
		if err then
			entry.pending = false
			entry.opened = false
			entry.error = err.message or tostring(err)
			if not entry.notified then
				entry.notified = true
				vim.notify("nvjup interactive renderer: " .. entry.error, vim.log.levels.WARN)
			end
			refresh(state)
			return
		end
		local stable_client = client
		vim.defer_fn(function()
			if client == stable_client then
				restart_attempts = 0
			end
		end, 5000)
		store_frame(state, entry, payload)
	end)
end

function M.prepare_cell(state, cell)
	if options().enabled == false then
		return cell, {}
	end
	local has_interactive = false
	for _, item in ipairs(cell.outputs or {}) do
		if interactive_payload(item) then
			has_interactive = true
			break
		end
	end
	if not has_interactive then
		return cell, {}
	end

	local trust_status = trust.status(state, cell)
	local prepared = cell.interactive_render_cache
	if
		prepared
		and prepared.output_revision == cell.output_revision
		and prepared.trust_status == trust_status
		and prepared.frame_generation == (cell.interactive_frame_generation or 0)
	then
		return prepared.cell, prepared.seen
	end
	local copy = vim.tbl_extend("force", {}, cell)
	copy.outputs = {}
	for index, item in ipairs(cell.outputs or {}) do
		copy.outputs[index] = item
	end
	-- The overlay substitutes trust placeholders or renderer frames without
	-- copying large MIME trees. It must not reuse the source segment cache.
	copy.output_revision = nil
	copy.output_render_cache = nil
	local seen = {}
	for output_index, item in ipairs(cell.outputs or {}) do
		local backend, figure = interactive_payload(item)
		if backend then
			if trust_status ~= "trusted_interactive" then
				copy.outputs[output_index] = blocked_copy(item, trust_status)
			else
				local cache_key = key(state, cell, output_index)
				seen[cache_key] = true
				local entry = cache[cache_key]
				local hash, encoded
				if entry and entry.output_revision == cell.output_revision and entry.figure == figure then
					hash = entry.hash
				else
					hash, encoded = figure_hash(backend, figure)
				end
				if not hash then
					entry = { error = tostring(encoded), figure_id = figure_id(state, cell, output_index) }
					cache[cache_key] = entry
				elseif not entry or entry.hash ~= hash then
					if entry and client and entry.figure_id then
						client:request("renderer.close", { figure_id = entry.figure_id }, {}, function() end)
					end
					entry = {
						key = cache_key,
						hash = hash,
						figure_id = figure_id(state, cell, output_index),
						state = state,
						cell_id = cell.id,
						output_index = output_index,
						backend = backend,
						figure = figure,
						output_revision = cell.output_revision,
					}
					cache[cache_key] = entry
					request_open(state, entry)
				else
					entry.output_revision = cell.output_revision
					entry.figure = figure
				end
				if entry.png then
					local item_copy = vim.tbl_extend("force", {}, item)
					item_copy.data = vim.tbl_extend("force", {}, item.data or {}, { ["image/png"] = entry.png })
					item_copy.metadata = vim.tbl_deep_extend(
						"force",
						{},
						item.metadata or {},
						{ ["image/png"] = { width = entry.width, height = entry.height } }
					)
					copy.outputs[output_index] = item_copy
				end
			end
		end
	end
	cell.interactive_render_cache = {
		output_revision = cell.output_revision,
		trust_status = trust_status,
		frame_generation = cell.interactive_frame_generation or 0,
		cell = copy,
		seen = seen,
	}
	return copy, seen
end

function M.seen(state, cell, output_index)
	return cache[key(state, cell, output_index)] ~= nil
end

function M.finish_render(state, seen)
	for cache_key, entry in pairs(cache) do
		if entry.state == state and not seen[cache_key] then
			close_external(cache_key)
			if client and entry.figure_id then
				client:request("renderer.close", { figure_id = entry.figure_id }, {}, function() end)
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
	local source_width = entry.source_width or entry.width
	local source_height = entry.source_height or entry.height
	local x = geometry.cols > 1 and (column / (geometry.cols - 1)) * (source_width - 1) or 0
	-- Kitty reports the terminal cell occupied by the pointer. Compensate for
	-- its one-cell vertical hotspot so the browser pointer does not trail below it.
	local adjusted_row = math.max(0, row - 1)
	local y = geometry.rows > 1 and (adjusted_row / (geometry.rows - 1)) * (source_height - 1) or 0
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
		local last = queue[#queue]
		if payload.event == "move" and last and last.event == "move" then
			queue[#queue] = payload
		elseif payload.event == "wheel" and last and last.event == "wheel" then
			last.delta_x = (last.delta_x or 0) + (payload.delta_x or 0)
			last.delta_y = (last.delta_y or 0) + (payload.delta_y or 0)
		else
			if #queue >= 64 then
				for index, queued in ipairs(queue) do
					if queued.event == "move" or queued.event == "wheel" then
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
	get_client():request("renderer.event", payload, {}, function(err, frame)
		active.event_pending = false
		if not err and frame and frame.png then
			store_frame(active.entry.state, active.entry, frame)
		elseif err then
			active.entry.error = err.message or tostring(err)
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

local function send_key(key)
	if not focus then
		return
	end
	queue_event(focus, { figure_id = focus.entry.figure_id, event = "key", key = key })
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

local function focus_render_dimensions(window)
	local columns = math.max(8, vim.api.nvim_win_get_width(window) - 6)
	local rows = math.max(4, vim.api.nvim_win_get_height(window) - 3)
	local width = columns * TUI_CELL_WIDTH_PX
	local height = rows * TUI_CELL_HEIGHT_PX
	local configured_width = options().width_px or 900
	local configured_height = options().height_px or 540
	local scale = math.min(
		(options().interactive_width_px or 720) / configured_width,
		(options().interactive_height_px or 432) / configured_height
	)
	return width, height, math.floor(width * scale + 0.5), math.floor(height * scale + 0.5)
end

local function resize_focus_renderer(entry)
	if not focus or focus.entry ~= entry or not vim.api.nvim_win_is_valid(focus.win) then
		return
	end
	local width, height, interactive_width, interactive_height = focus_render_dimensions(focus.win)
	get_client():request("renderer.resize", {
		figure_id = entry.figure_id,
		width = width,
		height = height,
		interactive_width = interactive_width,
		interactive_height = interactive_height,
	}, {}, function(err, frame)
		if not err and frame and frame.png then
			store_frame(entry.state, entry, frame)
		end
	end)
end

local function resolve_entry(state, cell)
	if not trust.allows_interactive(state, cell) then
		vim.notify("interactive output is blocked; use :NvJupTrustInteractive", vim.log.levels.WARN)
		return nil
	end
	for output_index, item in ipairs(cell.outputs or {}) do
		if interactive_payload(item) then
			local entry = cache[key(state, cell, output_index)]
			if not entry then
				M.prepare_cell(state, cell)
				entry = cache[key(state, cell, output_index)]
			end
			return entry
		end
	end
	vim.notify("current cell has no supported interactive output", vim.log.levels.INFO)
	return nil
end

function M.open_external(state, cell)
	state = state or require("nvjup.notebook").get()
	if not state then
		return nil
	end
	cell = cell or state:current_cell()
	if not cell then
		return nil
	end
	local entry = resolve_entry(state, cell)
	if not entry then
		return nil
	end
	if not entry.opened then
		vim.notify("interactive figure is still rendering", vim.log.levels.INFO)
		return nil
	end
	close_all_external()
	local generation = external_generation
	entry.external_pending = true
	get_client():request("renderer.export_external", { figure_id = entry.figure_id }, {}, function(err, exported)
		if generation ~= external_generation then
			entry.external_pending = false
			if client then
				client:request("renderer.release_external", { figure_id = entry.figure_id }, {}, function() end)
			end
			return
		end
		if err then
			entry.external_pending = false
			entry.error = err.message or tostring(err)
			vim.notify("nvjup external renderer: " .. entry.error, vim.log.levels.WARN)
			return
		end
		local handle
		handle = external_launcher(entry, exported, function(launch_error)
			if generation ~= external_generation then
				if handle and handle.close then
					pcall(handle.close)
				end
				return
			end
			entry.external_pending = false
			if launch_error then
				external_windows[entry.key] = nil
				if client then
					client:request("renderer.release_external", { figure_id = entry.figure_id }, {}, function() end)
				end
				entry.error = tostring(launch_error)
				vim.notify("nvjup external renderer: " .. entry.error, vim.log.levels.WARN)
				return
			end
			entry.external = true
		end)
		if handle then
			external_windows[entry.key] = handle
		end
	end)
	return entry.figure_id
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
	local entry = resolve_entry(state, cell)
	if not entry then
		return nil
	end
	close_all_external()
	if not entry.png then
		vim.notify("interactive frame is still rendering", vim.log.levels.INFO)
		return nil
	end
	close_focus()
	local buffer = vim.api.nvim_create_buf(false, true)
	local width = math.max(20, math.min(vim.o.columns - 4, (options().focus_width or 112)))
	local height = math.max(8, math.min(vim.o.lines - 4, (options().focus_height or 40)))
	local window = vim.api.nvim_open_win(buffer, true, {
		relative = "editor",
		row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
		col = math.max(0, math.floor((vim.o.columns - width) / 2)),
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " nvjup interactive ",
	})
	focus = {
		buf = buffer,
		win = window,
		entry = entry,
		namespace = vim.api.nvim_create_namespace("nvjup-interactive-focus-" .. buffer),
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
	for lhs, key_name in pairs({
		["<Left>"] = "ArrowLeft",
		["<Right>"] = "ArrowRight",
		["<Up>"] = "ArrowUp",
		["<Down>"] = "ArrowDown",
		["<CR>"] = "Enter",
		["<Space>"] = "Space",
		["<Tab>"] = "Tab",
		["<BS>"] = "Backspace",
		["+"] = "+",
		["-"] = "-",
		["="] = "=",
	}) do
		vim.keymap.set("n", lhs, function()
			send_key(key_name)
		end, { buffer = buffer, silent = true })
	end
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
	resize_focus_renderer(entry)
	return buffer, window
end

function M.resize_focus()
	if not focus or not vim.api.nvim_win_is_valid(focus.win) then
		return
	end
	local width = math.max(20, math.min(vim.o.columns - 4, options().focus_width or 112))
	local height = math.max(8, math.min(vim.o.lines - 4, options().focus_height or 40))
	vim.api.nvim_win_set_width(focus.win, width)
	vim.api.nvim_win_set_height(focus.win, height)
	resize_focus_renderer(focus.entry)
end

function M.detach(state)
	M.finish_render(state, {})
	if focus and focus.entry.state == state then
		close_focus()
	end
end

function M.shutdown()
	shutting_down = true
	close_focus()
	close_all_external()
	local active = client
	client = nil
	if active then
		active:request("renderer.shutdown", {}, {}, function()
			active:kill()
		end)
	end
	for cache_key in pairs(cache) do
		cache[cache_key] = nil
	end
end

function M.status()
	local figures = 0
	local errors = {}
	for _, entry in pairs(cache) do
		figures = figures + 1
		if entry.error then
			table.insert(errors, { figure_id = entry.figure_id, error = entry.error })
		end
	end
	return {
		figures = figures,
		external_windows = vim.tbl_count(external_windows),
		running = client ~= nil,
		restart_attempts = restart_attempts,
		focus = focus and focus.entry.figure_id or nil,
		renderer = last_renderer_status,
		errors = errors,
	}
end

function M.show_status()
	if not client then
		vim.notify(vim.inspect(M.status()), vim.log.levels.INFO, { title = "nvjup interactive" })
		return
	end
	client:request("renderer.status", {}, {}, function(err, payload)
		if not err then
			last_renderer_status = payload
		end
		vim.notify(vim.inspect(M.status()), err and vim.log.levels.WARN or vim.log.levels.INFO, {
			title = "nvjup interactive",
		})
	end)
end

function M.trust_interactive(state)
	state = state or require("nvjup.notebook").get()
	local ok, err = trust.grant(state)
	if not ok then
		vim.notify("nvjup trust: " .. tostring(err), vim.log.levels.ERROR)
		return nil
	end
	vim.notify("trusted interactive content for the current notebook identity", vim.log.levels.INFO)
	refresh(state)
	return true
end

function M.revoke_trust(state)
	state = state or require("nvjup.notebook").get()
	local ok, err = trust.revoke(state)
	if not ok then
		vim.notify("nvjup trust: " .. tostring(err), vim.log.levels.ERROR)
		return nil
	end
	M.finish_render(state, {})
	vim.notify("interactive trust revoked", vim.log.levels.INFO)
	refresh(state)
	return true
end

function M.trust_status(state)
	state = state or require("nvjup.notebook").get()
	local cell = state and state.current_cell and state:current_cell() or nil
	local status, details = trust.status(state, cell)
	return { status = status, details = details }
end

function M._set_client_factory(factory)
	close_all_external()
	if client then
		client:kill()
	end
	client = nil
	shutting_down = false
	restart_attempts = 0
	client_factory = factory or rpc.new
end

function M._set_external_launcher(launcher)
	close_all_external()
	external_launcher = launcher or default_external_launcher
end

M._cache = cache
M._close_focus = close_focus
M._pixel_position = pixel_position
M._queue_event = queue_event
M._on_renderer_event = on_renderer_event
M._interactive_payload = interactive_payload

return M
