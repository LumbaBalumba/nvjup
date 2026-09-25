local config = require("nvjup.config")
local trust = require("nvjup.trust")

local M = {}

local PLACEHOLDER = 0x10EEEE
-- Keep the entire APC escape sequence below terminal parser limits. Using a
-- 4096-byte payload plus control metadata caused Kitty to terminate oversized
-- chunks and paint their base64 tail as ordinary text.
local KITTY_CHUNK = 3072
local next_image_id = 0x181818
local placements = {}
local allocated_image_ids = {}
local retiring_image_ids = {}
local test_writer

-- Kitty's Unicode-placeholder protocol indexes rows/columns with this fixed
-- sequence of combining marks. Keep enough entries for the enlarged Plotly
-- focus window while preserving the protocol-defined order.
local DIACRITICS = {
	0x0305,
	0x030D,
	0x030E,
	0x0310,
	0x0312,
	0x033D,
	0x033E,
	0x033F,
	0x0346,
	0x034A,
	0x034B,
	0x034C,
	0x0350,
	0x0351,
	0x0352,
	0x0357,
	0x035B,
	0x0363,
	0x0364,
	0x0365,
	0x0366,
	0x0367,
	0x0368,
	0x0369,
	0x036A,
	0x036B,
	0x036C,
	0x036D,
	0x036E,
	0x036F,
	0x0483,
	0x0484,
	0x0485,
	0x0486,
	0x0487,
	0x0592,
	0x0593,
	0x0594,
	0x0595,
	0x0597,
	0x0598,
	0x0599,
	0x059C,
	0x059D,
	0x059E,
	0x059F,
	0x05A0,
	0x05A1,
	0x05A8,
	0x05A9,
	0x05AB,
	0x05AC,
	0x05AF,
	0x05C4,
	0x0610,
	0x0611,
	0x0612,
	0x0613,
	0x0614,
	0x0615,
	0x0616,
	0x0617,
	0x0657,
	0x0658,
	0x0659,
	0x065A,
	0x065B,
	0x065D,
	0x065E,
	0x06D6,
	0x06D7,
	0x06D8,
	0x06D9,
	0x06DA,
	0x06DB,
	0x06DC,
	0x06DF,
	0x06E0,
	0x06E1,
	0x06E2,
	0x06E4,
	0x06E7,
	0x06E8,
	0x06EB,
	0x06EC,
	0x0730,
	0x0732,
	0x0733,
	0x0735,
	0x0736,
	0x073A,
	0x073D,
	0x073F,
	0x0740,
	0x0741,
	0x0743,
	0x0745,
	0x0747,
	0x0749,
	0x074A,
	0x07EB,
	0x07EC,
	0x07ED,
	0x07EE,
	0x07EF,
	0x07F0,
	0x07F1,
	0x07F3,
	0x0816,
	0x0817,
	0x0818,
	0x0819,
	0x081B,
	0x081C,
	0x081D,
	0x081E,
	0x081F,
	0x0820,
	0x0821,
	0x0822,
	0x0823,
	0x0825,
	0x0826,
	0x0827,
	0x0829,
	0x082A,
	0x082B,
	0x082C,
	0x082D,
}

local function utf8(codepoint)
	if codepoint < 0x80 then
		return string.char(codepoint)
	end
	if codepoint < 0x800 then
		return string.char(0xC0 + math.floor(codepoint / 0x40), 0x80 + (codepoint % 0x40))
	end
	if codepoint < 0x10000 then
		return string.char(
			0xE0 + math.floor(codepoint / 0x1000),
			0x80 + (math.floor(codepoint / 0x40) % 0x40),
			0x80 + (codepoint % 0x40)
		)
	end
	return string.char(
		0xF0 + math.floor(codepoint / 0x40000),
		0x80 + (math.floor(codepoint / 0x1000) % 0x40),
		0x80 + (math.floor(codepoint / 0x40) % 0x40),
		0x80 + (codepoint % 0x40)
	)
end

local function image_options()
	return config.options.render.images or {}
end

local function animation_options()
	return image_options().animations or {}
end

local function normalize_data(value, maximum)
	if type(value) == "string" then
		if maximum and #value > maximum then
			return nil
		end
		return value
	end
	if type(value) ~= "table" then
		return nil
	end
	local size = 0
	for _, chunk in ipairs(value) do
		if type(chunk) ~= "string" then
			return nil
		end
		size = size + #chunk
		if maximum and size > maximum then
			return nil
		end
	end
	return table.concat(value, "")
end

local function animation_html_kind(value)
	if type(value) ~= "string" then
		return nil
	end
	if value:find("<video", 1, true) and value:find("data:video/mp4;base64,", 1, true) then
		return "video"
	end
	if
		value:find("function Animation(", 1, true)
		and value:find("new Animation(frames", 1, true)
		and value:find("data:image/png;base64,", 1, true)
	then
		return "frames"
	end
	return nil
end

local function is_animation_bundle(data)
	if type(data) ~= "table" or animation_options().enabled == false then
		return false
	end
	local maximum = tonumber(animation_options().max_bytes) or (64 * 1024 * 1024)
	local video = normalize_data(data["video/mp4"], maximum)
	local gif = normalize_data(data["image/gif"], maximum)
	if (video and video ~= "") or (gif and gif ~= "") then
		return true
	end
	return animation_html_kind(normalize_data(data["text/html"], maximum)) ~= nil
end

local function descriptor_hash(descriptor)
	local metadata = type(descriptor.metadata) == "table" and descriptor.metadata[descriptor.mime] or nil
	local width = type(metadata) == "table" and tonumber(metadata.width) or nil
	local height = type(metadata) == "table" and tonumber(metadata.height) or nil
	local rendering_metadata = table.concat({
		width and tostring(width) or "",
		height and tostring(height) or "",
		descriptor.trust_status or "",
	}, "\0")
	local identity = table.concat({
		tostring(#descriptor.mime),
		descriptor.mime,
		tostring(#descriptor.data),
		descriptor.data,
		tostring(#rendering_metadata),
		rendering_metadata,
	}, "\0")
	return vim.fn.sha256(identity)
end

local function image_key(state, cell, output_index)
	return table.concat({ state.buf, cell.id, output_index }, ":")
end

local function kitty_environment()
	local term = ((vim.env.TERM_PROGRAM or "") .. " " .. (vim.env.TERM or "")):lower()
	return term:find("kitty", 1, true) ~= nil
		or term:find("ghostty", 1, true) ~= nil
		or (vim.env.KITTY_WINDOW_ID or "") ~= ""
		or (vim.env.GHOSTTY_RESOURCES_DIR or "") ~= ""
end

local function kitty_available()
	return kitty_environment() and (#vim.api.nvim_list_uis() > 0 or test_writer ~= nil)
end

local function selected_backend()
	local options = image_options()
	if options.enabled == false then
		return "text"
	end
	local requested = options.backend or "auto"
	if requested == "text" then
		return "text"
	end
	if requested == "kitty" then
		return (kitty_available() or test_writer ~= nil) and "kitty" or "text"
	end
	if requested == "chafa" then
		return vim.fn.executable("chafa") == 1 and "chafa" or "text"
	end
	if kitty_available() or test_writer ~= nil then
		return "kitty"
	end
	if vim.fn.executable("chafa") == 1 then
		return "chafa"
	end
	return "text"
end

local function tmux_wrap(value)
	if not vim.env.TMUX or vim.env.TMUX == "" then
		return value
	end
	return "\27Ptmux;" .. value:gsub("\27", "\27\27") .. "\27\\"
end

local function tty_write(value)
	value = tmux_wrap(value)
	if test_writer then
		return test_writer(value)
	end
	if vim.v.stderr and vim.v.stderr ~= 0 then
		local ok = pcall(vim.api.nvim_chan_send, vim.v.stderr, value)
		if ok then
			return true
		end
	end
	local ok = pcall(function()
		io.stdout:write(value)
		io.stdout:flush()
	end)
	return ok
end

local function encode_transmit(image_id, png_base64, rows, cols)
	local commands = {}
	local position = 1
	local first = true
	while position <= #png_base64 do
		local stop = math.min(position + KITTY_CHUNK - 1, #png_base64)
		local chunk = png_base64:sub(position, stop)
		local more = stop < #png_base64 and 1 or 0
		if first then
			table.insert(commands, string.format("\27_Ga=t,f=100,i=%d,q=2,m=%d;%s\27\\", image_id, more, chunk))
			first = false
		else
			table.insert(commands, string.format("\27_Gm=%d,q=2;%s\27\\", more, chunk))
		end
		position = stop + 1
	end
	table.insert(commands, string.format("\27_Ga=p,U=1,i=%d,p=1,c=%d,r=%d,q=2\27\\", image_id, cols, rows))
	return table.concat(commands)
end

local function encode_animation_frame(image_id, png_base64, gap_ms)
	local commands = {}
	local position = 1
	local first = true
	while position <= #png_base64 do
		local stop = math.min(position + KITTY_CHUNK - 1, #png_base64)
		local chunk = png_base64:sub(position, stop)
		local more = stop < #png_base64 and 1 or 0
		if first then
			table.insert(
				commands,
				string.format("\27_Ga=f,f=100,i=%d,q=2,z=%d,m=%d;%s\27\\", image_id, gap_ms, more, chunk)
			)
			first = false
		else
			table.insert(commands, string.format("\27_Ga=f,m=%d,q=2;%s\27\\", more, chunk))
		end
		position = stop + 1
	end
	return table.concat(commands)
end

local function delete_image(image_id)
	tty_write(string.format("\27_Ga=d,d=I,i=%d,q=2\27\\", image_id))
	allocated_image_ids[image_id] = nil
	retiring_image_ids[image_id] = nil
end

local function cancel_entry(entry)
	if not entry then
		return
	end
	entry.cancelled = true
	if entry.cancel then
		entry.cancel()
		entry.cancel = nil
	end
end

local function retire_image(image_id)
	if not image_id or retiring_image_ids[image_id] then
		return
	end
	retiring_image_ids[image_id] = true
	-- Keep the currently displayed frame alive until the replacement has been
	-- transmitted and Neovim has had a chance to paint its new placeholders.
	vim.defer_fn(function()
		delete_image(image_id)
	end, 50)
end

local function next_id()
	for _ = 1, 0xffffff do
		next_image_id = (next_image_id % 0xffffff) + 1
		if not allocated_image_ids[next_image_id] and not retiring_image_ids[next_image_id] then
			allocated_image_ids[next_image_id] = true
			return next_image_id
		end
	end
	error("Kitty image ID space is exhausted")
end

local function ensure_highlight(image_id)
	local name = "NvJupImage" .. image_id
	vim.api.nvim_set_hl(0, name, { fg = string.format("#%06x", image_id) })
	return name
end

local function placeholder_lines(entry)
	local highlight = ensure_highlight(entry.image_id)
	local placeholder = utf8(PLACEHOLDER)
	local lines = {}
	for row = 0, entry.rows - 1 do
		local text = {}
		local row_mark = utf8(DIACRITICS[row + 1] or DIACRITICS[1])
		for column = 0, entry.cols - 1 do
			local column_mark = utf8(DIACRITICS[column + 1] or DIACRITICS[1])
			table.insert(text, placeholder .. row_mark .. column_mark)
		end
		table.insert(lines, { { "  ", "NvJupOutput" }, { table.concat(text), highlight } })
	end
	return lines
end

local function normalize_base64(value)
	if type(value) ~= "string" then
		return nil
	end
	-- Jupyter Server normally sends compact base64, while Colab currently
	-- inserts a trailing newline. RFC 4648 decoders may accept that whitespace,
	-- but vim.base64.decode() is intentionally strict, so remove only ASCII
	-- transport whitespace and reject every other non-base64 byte.
	local normalized = value:gsub("[ \t\r\n]", "")
	if normalized == "" or normalized:find("[^A-Za-z0-9+/=]") then
		return nil
	end
	return normalized
end

local function decode_base64(value)
	local normalized = normalize_base64(value)
	if not normalized then
		return nil
	end
	local ok, decoded = pcall(vim.base64.decode, normalized)
	return ok and decoded or nil
end

local function png_dimensions(bytes)
	if not bytes or #bytes < 24 or bytes:sub(1, 8) ~= "\137PNG\r\n\26\n" then
		return nil, nil
	end
	local function u32(offset)
		local a, b, c, d = bytes:byte(offset, offset + 3)
		return ((a * 256 + b) * 256 + c) * 256 + d
	end
	return u32(17), u32(21)
end

local function metadata_dimensions(descriptor)
	local metadata = descriptor.metadata
	local values = type(metadata) == "table" and metadata[descriptor.mime] or nil
	if type(values) ~= "table" then
		return nil, nil
	end
	return tonumber(values.width), tonumber(values.height)
end

local function grid_dimensions(descriptor, available_width, png_bytes, limits)
	local options = image_options()
	limits = limits or {}
	local configured_width = limits.max_width or options.max_width or 64
	local configured_height = limits.max_height or options.max_height or 24
	local max_cols = math.max(8, math.min(configured_width, available_width - 4, #DIACRITICS))
	local max_rows = math.max(4, math.min(configured_height, #DIACRITICS))
	local width, height = metadata_dimensions(descriptor)
	if not width or not height then
		width, height = png_dimensions(png_bytes)
	end
	if not width or not height or width <= 0 or height <= 0 then
		return math.min(48, max_cols), math.min(16, max_rows)
	end
	local columns = max_cols
	local rows = math.max(1, math.floor((height / width) * columns / 2 + 0.5))
	if rows > max_rows then
		columns = math.max(1, math.floor(columns * max_rows / rows))
		rows = max_rows
	end
	return columns, rows
end

local function safe_svg(value)
	local lowered = value:lower()
	local blocked = {
		"<!doctype",
		"<!entity",
		"<script",
		"<foreignobject",
		"<iframe",
		"<object",
		"<embed",
		"javascript:",
		"file:",
		"url%s*%(",
		"@import",
		"%son[%w_-]+%s*=",
		"[%s:]href%s*=",
		"[%s:]src%s*=",
	}
	for _, pattern in ipairs(blocked) do
		if lowered:find(pattern) then
			return false
		end
	end
	return lowered:find("<svg", 1, true) ~= nil
end

local function descriptor_bytes(descriptor, maximum)
	if descriptor.mime == "image/svg+xml" then
		if not safe_svg(descriptor.data) then
			return nil, "unsafe SVG was blocked"
		end
		return descriptor.data
	end
	local value = descriptor.data
	local data_url_prefix = "data:" .. descriptor.mime .. ";base64,"
	if value:sub(1, #data_url_prefix):lower() == data_url_prefix then
		value = value:sub(#data_url_prefix + 1)
	end
	-- Bound encoded input before allocating decoded bytes. The small allowance
	-- covers MIME line wrapping without permitting an arbitrarily large
	-- whitespace-only payload to bypass the decoded-size limit.
	local encoded_limit = math.ceil(maximum / 3) * 4
	if #value > encoded_limit + math.ceil(encoded_limit / 10) + 4096 then
		return nil, string.format("image exceeds %d byte limit", maximum)
	end
	local normalized = normalize_base64(value)
	if not normalized then
		return nil, "invalid base64 image data"
	end
	if #normalized > encoded_limit + 4 then
		return nil, string.format("image exceeds %d byte limit", maximum)
	end
	local decoded = decode_base64(normalized)
	if not decoded then
		return nil, "invalid base64 image data"
	end
	return decoded
end

local function bounded_bytes(descriptor)
	local options = image_options()
	local maximum = options.max_bytes or (10 * 1024 * 1024)
	local bytes, err = descriptor_bytes(descriptor, maximum)
	if not bytes then
		return nil, err
	end
	if #bytes > maximum then
		return nil, string.format("image exceeds %d byte limit", maximum)
	end
	if descriptor.mime == "image/png" then
		local width, height = png_dimensions(bytes)
		local max_pixels = options.max_pixels or (16 * 1024 * 1024)
		if width and height and width * height > max_pixels then
			return nil, string.format("image exceeds %d pixel limit", max_pixels)
		end
	end
	return bytes
end

local function extension_for(mime)
	return ({
		["image/png"] = ".png",
		["image/jpeg"] = ".jpg",
		["image/svg+xml"] = ".svg",
		["application/pdf"] = ".pdf",
	})[mime] or ".bin"
end

local function write_bytes(path, bytes)
	local file = io.open(path, "wb")
	if not file then
		return false
	end
	file:write(bytes)
	file:close()
	return true
end

local function read_bytes(path)
	local file = io.open(path, "rb")
	if not file then
		return nil
	end
	local value = file:read("*a")
	file:close()
	return value
end

local function refresh_when_ready(state, entry)
	if vim.api.nvim_buf_is_valid(state.buf) then
		require("nvjup.render").request_cell(state, entry and entry.cell_id, 10)
	end
end

local function run_bounded(command, callback, timeout_override)
	local timeout = timeout_override or image_options().conversion_timeout_ms or 10000
	local completed = false
	local timed_out = false
	local terminating = false
	local handle
	local timer = vim.uv.new_timer()
	local function close_timer()
		if timer then
			timer:stop()
			if not timer:is_closing() then
				timer:close()
			end
			timer = nil
		end
	end
	local function terminate()
		if terminating then
			return
		end
		terminating = true
		if handle then
			pcall(handle.kill, handle, 15)
			vim.defer_fn(function()
				pcall(handle.kill, handle, 9)
			end, 500)
		end
	end
	local function finish(result)
		if completed then
			return
		end
		completed = true
		close_timer()
		if timed_out then
			result = { code = 124, stderr = "conversion timed out" }
		end
		callback(result, timed_out)
	end
	handle = vim.system(command, { text = true }, function(result)
		vim.schedule(function()
			finish(result)
		end)
	end)
	timer:start(timeout, 0, function()
		timed_out = true
		vim.schedule(terminate)
	end)
	return function()
		if completed then
			return
		end
		completed = true
		close_timer()
		terminate()
	end
end

local function run_bounded_binary(command, maximum, callback, timeout)
	local stdout = vim.uv.new_pipe(false)
	local stderr = vim.uv.new_pipe(false)
	local timer = vim.uv.new_timer()
	local chunks = {}
	local size = 0
	local errors = {}
	local error_size = 0
	local completed = false
	local cancelled = false
	local exited = false
	local stdout_done = false
	local stderr_done = false
	local exit_code = 1
	local exit_signal = 0
	local timed_out = false
	local terminating = false
	local handle
	local function close(value)
		if value and not value:is_closing() then
			value:close()
		end
	end
	local function stop_timer()
		if timer then
			timer:stop()
			close(timer)
			timer = nil
		end
	end
	local function terminate()
		if terminating then
			return
		end
		terminating = true
		if handle and not handle:is_closing() then
			pcall(handle.kill, handle, 15)
			vim.defer_fn(function()
				if handle and not handle:is_closing() then
					pcall(handle.kill, handle, 9)
				end
			end, 500)
		end
	end
	local function maybe_finish()
		if completed or not (exited and stdout_done and stderr_done) then
			return
		end
		completed = true
		stop_timer()
		close(handle)
		if cancelled then
			chunks = {}
			return
		end
		local output = exit_code == 0 and table.concat(chunks) or nil
		chunks = {}
		callback({
			code = timed_out and 124 or exit_code,
			signal = exit_signal,
			stdout = output,
			stderr = table.concat(errors),
			overflow = size > maximum,
		})
	end
	local args = {}
	for index = 2, #command do
		table.insert(args, command[index])
	end
	handle = vim.uv.spawn(command[1], {
		args = args,
		stdio = { nil, stdout, stderr },
	}, function(code, signal)
		exit_code = code
		exit_signal = signal
		exited = true
		vim.schedule(maybe_finish)
	end)
	if not handle then
		stdout_done, stderr_done, exited = true, true, true
		exit_code = 127
		close(stdout)
		close(stderr)
		vim.schedule(maybe_finish)
	else
		stdout:read_start(function(err, data)
			if err then
				table.insert(errors, tostring(err))
			end
			if data then
				size = size + #data
				if size <= maximum then
					table.insert(chunks, data)
				else
					terminate()
				end
			else
				stdout_done = true
				close(stdout)
				vim.schedule(maybe_finish)
			end
		end)
		stderr:read_start(function(err, data)
			if err and error_size < 16384 then
				table.insert(errors, tostring(err))
			end
			if data and error_size < 16384 then
				local retained = data:sub(1, 16384 - error_size)
				error_size = error_size + #retained
				table.insert(errors, retained)
			elseif not data then
				stderr_done = true
				close(stderr)
				vim.schedule(maybe_finish)
			end
		end)
	end
	timer:start(timeout, 0, function()
		timed_out = true
		terminate()
	end)
	return function()
		if completed or cancelled then
			return
		end
		cancelled = true
		stop_timer()
		terminate()
		pcall(stdout.read_stop, stdout)
		pcall(stderr.read_stop, stderr)
		stdout_done, stderr_done = true, true
		close(stdout)
		close(stderr)
		chunks = {}
		maybe_finish()
	end
end

local function convert_to_png(state, entry, descriptor, bytes)
	local imagemagick = vim.fn.executable("magick") == 1 and "magick"
		or (vim.fn.executable("convert") == 1 and "convert" or nil)
	local use_rsvg = descriptor.mime == "image/svg+xml" and vim.fn.executable("rsvg-convert") == 1
	if not imagemagick and not use_rsvg then
		entry.status = "failed"
		entry.error = "ImageMagick or rsvg-convert is required for " .. descriptor.mime
		return
	end
	entry.status = "pending"
	local input = vim.fn.tempname() .. extension_for(descriptor.mime)
	local destination = vim.fn.tempname() .. ".png"
	if not write_bytes(input, bytes) then
		entry.status = "failed"
		entry.error = "could not create image conversion input"
		return
	end
	local command
	if use_rsvg then
		-- librsvg does not resolve any references because the SVG sanitizer
		-- rejects href/src/url/import. Explicit dimensions also bound output.
		command = { "rsvg-convert", "-a", "-w", "4096", "-h", "4096", "-o", destination, input }
	else
		local source = descriptor.mime == "application/pdf" and (input .. "[0]") or input
		command = {
			imagemagick,
			"-limit",
			"memory",
			"128MiB",
			"-limit",
			"map",
			"256MiB",
			"-limit",
			"area",
			"64MP",
			"-limit",
			"disk",
			"256MiB",
			source,
			"-thumbnail",
			"4096x4096>",
			"-strip",
			destination,
		}
	end
	local cancel
	cancel = run_bounded(command, function(result, timed_out)
		entry.cancel = nil
		local png = result.code == 0 and read_bytes(destination) or nil
		pcall(os.remove, input)
		pcall(os.remove, destination)
		if placements[entry.key] ~= entry then
			return
		end
		if not png then
			entry.status = "failed"
			local stderr = (result.stderr or ""):gsub("%s+$", "")
			entry.error = timed_out and "image conversion timed out"
				or (stderr ~= "" and stderr or "image conversion failed")
		else
			entry.png_bytes = png
			entry.png_base64 = vim.base64.encode(png)
			entry.status = "converted"
		end
		refresh_when_ready(state, entry)
	end)
	entry.cancel = function()
		cancel()
		pcall(os.remove, input)
		pcall(os.remove, destination)
	end
end

local function prepare_chafa(state, entry, descriptor, bytes, limits)
	if vim.fn.executable("chafa") ~= 1 then
		entry.status = "failed"
		entry.error = "Kitty graphics unavailable and chafa is not installed"
		return
	end
	entry.status = "pending"
	local input = vim.fn.tempname() .. extension_for(descriptor.mime)
	if not write_bytes(input, bytes) then
		entry.status = "failed"
		entry.error = "could not create chafa input"
		return
	end
	local options = image_options()
	limits = limits or {}
	local size = string.format(
		"%dx%d",
		limits.max_width or options.max_width or 64,
		limits.max_height or options.max_height or 24
	)
	local cancel
	cancel = run_bounded({ "chafa", "--format", "symbols", "--animate=off", "--size", size, input }, function(result)
		entry.cancel = nil
		pcall(os.remove, input)
		if placements[entry.key] ~= entry then
			return
		end
		if result.code ~= 0 or not result.stdout or result.stdout == "" then
			entry.status = "failed"
			entry.error = (result.stderr or "chafa rendering failed"):gsub("%s+$", "")
		else
			local value = result.stdout:gsub("\27%[[0-?]*[ -/]*[@-~]", "")
			entry.ascii_lines = vim.split(value, "\n", { plain = true, trimempty = true })
			entry.status = "ready"
		end
		refresh_when_ready(state, entry)
	end)
	entry.cancel = function()
		cancel()
		pcall(os.remove, input)
	end
end

local function animation_number(name, default)
	local value = tonumber(animation_options()[name])
	return value and value > 0 and value or default
end

local function extract_embedded_payload(html, prefix)
	local start = html:find(prefix, 1, true)
	if not start then
		return nil
	end
	local payload_start = start + #prefix
	local double_quote = html:find('"', payload_start, true)
	local single_quote = html:find("'", payload_start, true)
	local payload_end
	if double_quote and single_quote then
		payload_end = math.min(double_quote, single_quote)
	else
		payload_end = double_quote or single_quote
	end
	return payload_end and html:sub(payload_start, payload_end - 1) or nil
end

local function bounded_animation_bytes(value)
	local maximum = animation_number("max_bytes", 64 * 1024 * 1024)
	local encoded_limit = math.ceil(maximum / 3) * 4
	if type(value) ~= "string" or #value > encoded_limit + math.ceil(encoded_limit / 10) + 4096 then
		return nil, string.format("animation exceeds %d byte limit", maximum)
	end
	local normalized = normalize_base64(value)
	if not normalized then
		return nil, "invalid base64 animation data"
	end
	if #normalized > encoded_limit + 4 then
		return nil, string.format("animation exceeds %d byte limit", maximum)
	end
	local decoded = decode_base64(normalized)
	if not decoded then
		return nil, "invalid base64 animation data"
	end
	if #decoded > maximum then
		return nil, string.format("animation exceeds %d byte limit", maximum)
	end
	return decoded
end

local function parse_jshtml_frames(html)
	local maximum = animation_number("max_bytes", 64 * 1024 * 1024)
	local max_frames = math.floor(animation_number("max_frames", 240))
	local max_pixels = image_options().max_pixels or (16 * 1024 * 1024)
	local max_total_pixels = animation_number("max_total_pixels", 32 * 1024 * 1024)
	local max_fps = animation_number("max_fps", 30)
	local max_duration_ms = animation_number("max_duration_seconds", 60) * 1000
	local encoded_limit = math.ceil(maximum / 3) * 4
	if #html > encoded_limit + math.ceil(encoded_limit / 10) + 2 * 1024 * 1024 then
		return nil, nil, string.format("animation exceeds %d byte limit", maximum)
	end
	local interval = tonumber(html:match("new%s+Animation%s*%(%s*frames%s*,%s*[%w_]+%s*,%s*[%w_]+%s*,%s*([%d%.]+)"))
		or 100
	local gap_ms = math.max(math.ceil(1000 / max_fps), math.min(10000, math.floor(interval + 0.5)))
	local frames = {}
	local decoded_total = 0
	local total_pixels = 0
	local retained_total = #html
	local largest_encoded_frame = 0
	local canvas_width, canvas_height
	local prefix = "data:image/png;base64,"
	local position = 1
	while true do
		local start = html:find(prefix, position, true)
		if not start then
			break
		end
		local payload_start = start + #prefix
		local stop = html:find('"', payload_start, true)
		if not stop then
			return nil, nil, "invalid Matplotlib JS animation frame"
		end
		local payload = html:sub(payload_start, stop - 1):gsub("\\\r\n", ""):gsub("\\\n", "")
		local normalized = normalize_base64(payload)
		local bytes = normalized and decode_base64(normalized) or nil
		if not bytes or bytes:sub(1, 8) ~= "\137PNG\r\n\26\n" then
			return nil, nil, "invalid Matplotlib JS animation frame"
		end
		local width, height = png_dimensions(bytes)
		if not width or not height or width <= 0 or height <= 0 then
			return nil, nil, "invalid Matplotlib JS animation frame dimensions"
		end
		if width * height > max_pixels then
			return nil, nil, string.format("animation frame exceeds %d pixel limit", max_pixels)
		end
		total_pixels = total_pixels + width * height
		if total_pixels > max_total_pixels then
			return nil, nil, string.format("animation exceeds %d total pixel limit", max_total_pixels)
		end
		if canvas_width and (width ~= canvas_width or height ~= canvas_height) then
			return nil, nil, "Matplotlib animation frames have inconsistent dimensions"
		end
		canvas_width, canvas_height = canvas_width or width, canvas_height or height
		decoded_total = decoded_total + #bytes
		if decoded_total > maximum then
			return nil, nil, string.format("animation exceeds %d byte limit", maximum)
		end
		if retained_total + #bytes > maximum then
			return nil, nil, string.format("animation peak data exceeds %d byte limit", maximum)
		end
		local canonical = vim.base64.encode(bytes)
		largest_encoded_frame = math.max(largest_encoded_frame, #canonical)
		retained_total = retained_total + #canonical + (#frames == 0 and #bytes or 0)
		if retained_total + 2 * largest_encoded_frame > maximum then
			return nil, nil, string.format("animation retained data exceeds %d byte limit", maximum)
		end
		table.insert(frames, { bytes = #frames == 0 and bytes or nil, base64 = canonical })
		if #frames > max_frames then
			return nil, nil, string.format("animation exceeds %d frame limit", max_frames)
		end
		position = stop + 1
	end
	if #frames == 0 then
		return nil, nil, "Matplotlib JS animation contains no frames"
	end
	if #frames * gap_ms > max_duration_ms then
		return nil, nil, string.format("animation exceeds %.0f second limit", max_duration_ms / 1000)
	end
	frames.total_pixels = total_pixels
	return frames, gap_ms
end

local function animation_frame_rate(value)
	if type(value) ~= "string" then
		return nil
	end
	local numerator, denominator = value:match("^(%d+)%/(%d+)$")
	if numerator then
		denominator = tonumber(denominator)
		return denominator and denominator > 0 and tonumber(numerator) / denominator or nil
	end
	return tonumber(value)
end

local function transmit_animation_frames(state, entry, descriptor, frames, gap_ms, available_width, limits)
	entry.png_bytes = frames[1].bytes
	entry.animation_frame_count = #frames
	if entry.backend == "chafa" then
		prepare_chafa(state, entry, { mime = "image/png" }, frames[1].bytes, limits)
		return
	end
	if entry.backend ~= "kitty" then
		entry.status = "fallback"
		return
	end
	if entry.previous and entry.previous.animation_pixels then
		if entry.previous.image_id then
			delete_image(entry.previous.image_id)
		end
		entry.previous = nil
	end
	local total_pixels = frames.total_pixels or 0
	local maximum_pixels = animation_number("max_total_pixels", 32 * 1024 * 1024)
	local active_pixels = 0
	for _, placement in pairs(placements) do
		if placement ~= entry then
			active_pixels = active_pixels + (placement.animation_pixels or 0)
		end
	end
	if active_pixels + total_pixels > maximum_pixels then
		entry.status = "failed"
		entry.error = string.format("active animations exceed %d total pixel limit", maximum_pixels)
		return
	end
	entry.animation_pixels = total_pixels
	entry.cols, entry.rows = grid_dimensions(descriptor, available_width, entry.png_bytes, limits)
	entry.image_id = next_id()
	tty_write(encode_transmit(entry.image_id, frames[1].base64, entry.rows, entry.cols))
	entry.status = "ready"
	if #frames == 1 then
		return
	end
	entry.animation_loading = true
	local frame_index = 2
	local function upload_batch()
		if placements[entry.key] ~= entry or not entry.image_id then
			return
		end
		local transmitted = 0
		while frame_index <= #frames and transmitted < 2 do
			tty_write(encode_animation_frame(entry.image_id, frames[frame_index].base64, gap_ms))
			frame_index = frame_index + 1
			transmitted = transmitted + 1
		end
		if frame_index <= #frames then
			vim.schedule(upload_batch)
			return
		end
		tty_write(string.format("\27_Ga=a,i=%d,r=1,z=%d,q=2\27\\", entry.image_id, gap_ms))
		tty_write(string.format("\27_Ga=a,i=%d,s=3,v=1,q=2\27\\", entry.image_id))
		entry.animation_loading = false
	end
	vim.schedule(upload_batch)
end

local function parse_converted_frames(data, maximum, max_frames, retained_source_size)
	if type(data) ~= "string" or data == "" then
		return nil, "animation conversion produced no frames"
	end
	local function u32(offset)
		local a, b, c, d = data:byte(offset, offset + 3)
		if not d then
			return nil
		end
		return ((a * 256 + b) * 256 + c) * 256 + d
	end
	local frames = {}
	local retained_total = retained_source_size or 0
	local largest_encoded_frame = 0
	local max_pixels = image_options().max_pixels or (16 * 1024 * 1024)
	local max_total_pixels = animation_number("max_total_pixels", 32 * 1024 * 1024)
	local total_pixels = 0
	local canvas_width, canvas_height
	local position = 1
	while position <= #data do
		if data:sub(position, position + 7) ~= "\137PNG\r\n\26\n" then
			return nil, "animation conversion produced an invalid PNG stream"
		end
		local cursor = position + 8
		local frame_end
		while cursor <= #data do
			local length = u32(cursor)
			if not length or length > maximum then
				return nil, "animation conversion produced an invalid PNG chunk"
			end
			local kind = data:sub(cursor + 4, cursor + 7)
			local chunk_end = cursor + 12 + length - 1
			if chunk_end > #data then
				return nil, "animation conversion produced a truncated PNG frame"
			end
			cursor = chunk_end + 1
			if kind == "IEND" then
				frame_end = chunk_end
				break
			end
		end
		if not frame_end then
			return nil, "animation conversion produced a PNG without IEND"
		end
		local bytes = data:sub(position, frame_end)
		local width, height = png_dimensions(bytes)
		if not width or not height or width <= 0 or height <= 0 then
			return nil, "animation conversion produced invalid frame dimensions"
		end
		if width * height > max_pixels then
			return nil, string.format("animation frame exceeds %d pixel limit", max_pixels)
		end
		total_pixels = total_pixels + width * height
		if total_pixels > max_total_pixels then
			return nil, string.format("animation exceeds %d total pixel limit", max_total_pixels)
		end
		if canvas_width and (width ~= canvas_width or height ~= canvas_height) then
			return nil, "animation conversion produced inconsistent frame dimensions"
		end
		canvas_width, canvas_height = canvas_width or width, canvas_height or height
		if retained_total + #bytes > maximum then
			return nil, string.format("animation peak data exceeds %d byte limit", maximum)
		end
		local canonical = vim.base64.encode(bytes)
		largest_encoded_frame = math.max(largest_encoded_frame, #canonical)
		retained_total = retained_total + #canonical + (#frames == 0 and #bytes or 0)
		if retained_total + 2 * largest_encoded_frame > maximum then
			return nil, string.format("animation retained data exceeds %d byte limit", maximum)
		end
		table.insert(frames, { bytes = #frames == 0 and bytes or nil, base64 = canonical })
		if #frames > max_frames then
			return nil, string.format("animation exceeds %d frame limit", max_frames)
		end
		position = frame_end + 1
	end
	frames.total_pixels = total_pixels
	return frames
end

local function convert_animation(state, entry, descriptor, source, retained_source_size, available_width, limits)
	if vim.fn.executable("ffmpeg") ~= 1 then
		entry.status = "failed"
		entry.error = "ffmpeg is required for video animations"
		return
	end
	local input = vim.fn.tempname() .. (descriptor.source_mime == "image/gif" and ".gif" or ".mp4")
	if not write_bytes(input, source) then
		entry.status = "failed"
		entry.error = "could not create animation conversion input"
		return
	end
	source = nil
	entry.status = "pending"
	local timeout = animation_number("conversion_timeout_ms", 30000)
	local maximum = animation_number("max_bytes", 64 * 1024 * 1024)
	local max_frames = math.floor(animation_number("max_frames", 240))
	local max_fps = animation_number("max_fps", 30)
	local max_duration = animation_number("max_duration_seconds", 60)
	local max_width = math.floor(animation_number("max_width_px", 1280))
	local max_height = math.floor(animation_number("max_height_px", 960))
	local cancelled = false
	local cleaned = false
	local active_cancel
	local function cleanup()
		if cleaned then
			return
		end
		cleaned = true
		pcall(os.remove, input)
		vim.defer_fn(function()
			pcall(os.remove, input)
		end, 250)
	end
	local function fail(message)
		if cancelled then
			return
		end
		cancelled = true
		if active_cancel then
			active_cancel()
			active_cancel = nil
		end
		cleanup()
		entry.cancel = nil
		if placements[entry.key] == entry then
			entry.status = "failed"
			entry.error = message
			refresh_when_ready(state, entry)
		end
	end
	entry.cancel = function()
		if cancelled then
			return
		end
		cancelled = true
		if active_cancel then
			active_cancel()
			active_cancel = nil
		end
		cleanup()
	end
	local function run_conversion(rate, duration)
		if cancelled or placements[entry.key] ~= entry then
			entry.cancel()
			return
		end
		if duration and duration > max_duration then
			fail(string.format("animation exceeds %.0f second limit", max_duration))
			return
		end
		local fps = math.max(0.2, math.min(max_fps, rate or 10))
		local gap_ms = math.max(1, math.floor(1000 / fps + 0.5))
		local filter =
			string.format("fps=%.6g,scale=%d:%d:force_original_aspect_ratio=decrease", fps, max_width, max_height)
		local stream_limit = math.max(1, math.floor(math.max(0, maximum - retained_source_size) / 6))
		local command = {
			"ffmpeg",
			"-nostdin",
			"-v",
			"error",
			"-protocol_whitelist",
			"file,pipe",
			"-i",
			input,
			"-an",
			"-t",
			tostring(max_duration),
			"-vf",
			filter,
			"-frames:v",
			tostring(max_frames + 1),
			"-compression_level",
			"6",
			"-f",
			"image2pipe",
			"-vcodec",
			"png",
			"pipe:1",
		}
		active_cancel = run_bounded_binary(command, stream_limit, function(result)
			active_cancel = nil
			if cancelled or placements[entry.key] ~= entry then
				cleanup()
				return
			end
			local frames, err
			if result.overflow then
				err = string.format("animation frame stream exceeds %d byte limit", stream_limit)
			elseif result.code == 0 then
				frames, err = parse_converted_frames(result.stdout, maximum, max_frames, retained_source_size)
			else
				err = result.code == 124 and "animation conversion timed out"
					or (
						(result.stderr or ""):gsub("%s+$", "") ~= "" and (result.stderr or ""):gsub("%s+$", "")
						or "animation conversion failed"
					)
			end
			cleanup()
			entry.cancel = nil
			if not frames then
				entry.status = "failed"
				entry.error = err
			else
				transmit_animation_frames(state, entry, descriptor, frames, gap_ms, available_width, limits)
			end
			refresh_when_ready(state, entry)
		end, timeout)
	end
	if vim.fn.executable("ffprobe") ~= 1 then
		run_conversion(nil, nil)
		return
	end
	active_cancel = run_bounded({
		"ffprobe",
		"-v",
		"error",
		"-protocol_whitelist",
		"file,pipe",
		"-select_streams",
		"v:0",
		"-show_entries",
		"stream=avg_frame_rate:format=duration",
		"-of",
		"json",
		input,
	}, function(result)
		active_cancel = nil
		if cancelled or placements[entry.key] ~= entry then
			cleanup()
			return
		end
		local rate, duration
		if result.code == 0 then
			local ok, payload = pcall(vim.json.decode, result.stdout or "")
			if ok and type(payload) == "table" then
				local stream = type(payload.streams) == "table" and payload.streams[1] or nil
				rate = stream and animation_frame_rate(stream.avg_frame_rate) or nil
				duration = type(payload.format) == "table" and tonumber(payload.format.duration) or nil
			end
		end
		run_conversion(rate, duration)
	end, math.min(timeout, 5000))
end

local function prepare_animation(state, entry, descriptor, available_width, limits)
	if descriptor.trust_status ~= "trusted_interactive" then
		entry.status = "failed"
		entry.error = "animation blocked; use :NvJupTrustInteractive"
		return
	end
	if entry.backend == "text" then
		entry.status = "fallback"
		return
	end
	if descriptor.animation_kind == "frames" then
		local frames, gap_ms, err = parse_jshtml_frames(descriptor.data)
		if not frames then
			entry.status = "failed"
			entry.error = err
			return
		end
		transmit_animation_frames(state, entry, descriptor, frames, gap_ms, available_width, limits)
		return
	end
	local payload = descriptor.data
	if descriptor.embedded then
		payload = extract_embedded_payload(payload, "data:video/mp4;base64,")
	end
	local retained_source_size = #descriptor.data
	local maximum = animation_number("max_bytes", 64 * 1024 * 1024)
	if retained_source_size >= maximum then
		entry.status = "failed"
		entry.error = string.format("animation retained data exceeds %d byte limit", maximum)
		return
	end
	local source, err = bounded_animation_bytes(payload)
	if not source then
		entry.status = "failed"
		entry.error = err
		return
	end
	if retained_source_size + #source > maximum then
		entry.status = "failed"
		entry.error = string.format("animation peak data exceeds %d byte limit", maximum)
		return
	end
	convert_animation(state, entry, descriptor, source, retained_source_size, available_width, limits)
end

local function prepare(state, entry, descriptor, available_width, limits)
	if descriptor.animation then
		prepare_animation(state, entry, descriptor, available_width, limits)
		return
	end
	if entry.backend == "text" then
		entry.status = "fallback"
		return
	end
	local bytes, err = bounded_bytes(descriptor)
	if not bytes then
		entry.status = "failed"
		entry.error = err
		return
	end
	entry.source_bytes = bytes
	if entry.backend == "chafa" then
		prepare_chafa(state, entry, descriptor, bytes, limits)
		return
	end
	if descriptor.mime == "image/png" then
		entry.png_bytes = bytes
		-- Kitty requires a compact raw base64 payload. Re-encode validated bytes
		-- rather than forwarding MIME whitespace or a data-URL prefix.
		entry.png_base64 = vim.base64.encode(bytes)
		entry.status = "converted"
	else
		convert_to_png(state, entry, descriptor, bytes)
	end
	if entry.status == "converted" then
		entry.cols, entry.rows = grid_dimensions(descriptor, available_width, entry.png_bytes, limits)
		entry.image_id = next_id()
		tty_write(encode_transmit(entry.image_id, entry.png_base64, entry.rows, entry.cols))
		entry.status = "ready"
	end
end

local function finalize_conversion(entry, descriptor, available_width, limits)
	if entry.backend ~= "kitty" or entry.status ~= "converted" then
		return
	end
	entry.cols, entry.rows = grid_dimensions(descriptor, available_width, entry.png_bytes, limits)
	entry.image_id = next_id()
	tty_write(encode_transmit(entry.image_id, entry.png_base64, entry.rows, entry.cols))
	entry.status = "ready"
end

local function dimensions_suffix(descriptor)
	local width, height = metadata_dimensions(descriptor)
	if width and height then
		return string.format(" %dx%d", width, height)
	end
	return ""
end

local function fallback_line(descriptor, entry)
	local reason = entry.error and (" · " .. entry.error) or ""
	local label = descriptor.animation and "Matplotlib animation" or descriptor.mime
	local frames = entry.animation_frame_count and string.format(" · %d frames", entry.animation_frame_count) or ""
	return {
		{
			string.format("  [%s%s%s%s]", label, dimensions_suffix(descriptor), frames, reason),
			entry.error and "NvJupWarning" or "NvJupImage",
		},
	}
end

function M.descriptors(cell)
	local revision = cell.output_revision
	local cached = revision ~= nil and cell.image_descriptor_cache or nil
	if cached and cached.revision == revision then
		return cached.descriptors
	end
	local descriptors = {}
	for output_index, item in ipairs(cell.outputs or {}) do
		if item.output_type == "execute_result" or item.output_type == "display_data" then
			local data = type(item.data) == "table" and item.data or {}
			local animation
			if animation_options().enabled ~= false then
				local maximum = animation_number("max_bytes", 64 * 1024 * 1024)
				local video = normalize_data(data["video/mp4"], maximum)
				local gif = normalize_data(data["image/gif"], maximum)
				local html = normalize_data(data["text/html"], maximum)
				local html_kind = animation_html_kind(html)
				if video and video ~= "" then
					animation = { kind = "video", source_mime = "video/mp4", data = video }
				elseif gif and gif ~= "" then
					animation = { kind = "video", source_mime = "image/gif", data = gif }
				elseif html_kind then
					animation = {
						kind = html_kind,
						source_mime = html_kind == "video" and "video/mp4" or "image/png",
						data = html,
						embedded = html_kind == "video",
					}
				end
			end
			if animation then
				table.insert(descriptors, {
					output_index = output_index,
					mime = "application/vnd.nvjup.animation",
					data = animation.data,
					metadata = item.metadata or {},
					animation = true,
					animation_kind = animation.kind,
					source_mime = animation.source_mime,
					embedded = animation.embedded,
					item = item,
					cell = cell,
				})
			else
				local maximum = tonumber(image_options().max_bytes) or (10 * 1024 * 1024)
				local encoded_limit = math.ceil(maximum / 3) * 4 + math.ceil(maximum / 10) + 4096
				for _, mime in ipairs({ "image/png", "image/jpeg", "image/svg+xml", "application/pdf" }) do
					local value = normalize_data(data[mime], mime == "image/svg+xml" and maximum or encoded_limit)
					if value and value ~= "" then
						table.insert(descriptors, {
							output_index = output_index,
							mime = mime,
							data = value,
							metadata = item.metadata or {},
						})
						break
					end
				end
			end
		end
	end
	if revision ~= nil then
		cell.image_descriptor_cache = { revision = revision, descriptors = descriptors }
	end
	return descriptors
end

function M.render(state, cell, available_width, limits)
	local virtual_lines = {}
	local seen = {}
	local by_output = {}
	local geometry_by_output = {}
	if not config.options.render.outputs or cell.output_collapsed then
		return virtual_lines, seen, by_output, geometry_by_output
	end
	for _, descriptor in ipairs(M.descriptors(cell)) do
		local first_line = #virtual_lines + 1
		local key = image_key(state, cell, descriptor.output_index)
		seen[key] = true
		if descriptor.animation then
			descriptor.trust_status = trust.status(state, cell, descriptor.item)
		end
		local hash = descriptor_hash(descriptor)
		local backend = selected_backend()
		local entry = placements[key]
		if not entry or entry.hash ~= hash or entry.backend ~= backend then
			local previous = entry
			cancel_entry(previous)
			if previous and previous.status ~= "ready" and previous.previous then
				previous = previous.previous
			end
			entry = {
				key = key,
				buf = state.buf,
				cell_id = cell.id,
				hash = hash,
				backend = backend,
				status = "new",
				previous = previous,
			}
			placements[key] = entry
			prepare(state, entry, descriptor, available_width, limits)
		end
		finalize_conversion(entry, descriptor, available_width, limits)
		if entry.status == "ready" and entry.backend == "kitty" then
			local columns, rows = grid_dimensions(descriptor, available_width, entry.png_bytes, limits)
			if columns ~= entry.cols or rows ~= entry.rows then
				entry.cols, entry.rows = columns, rows
				tty_write(string.format("\27_Ga=p,U=1,i=%d,p=1,c=%d,r=%d,q=2\27\\", entry.image_id, columns, rows))
			end
			vim.list_extend(virtual_lines, placeholder_lines(entry))
			geometry_by_output[descriptor.output_index] = { cols = entry.cols, rows = entry.rows, col = 3, row = 1 }
			if entry.previous then
				retire_image(entry.previous.image_id)
				entry.previous = nil
			end
		elseif entry.status == "ready" and entry.ascii_lines then
			geometry_by_output[descriptor.output_index] = {
				cols = math.max(1, available_width - 4),
				rows = #entry.ascii_lines,
				col = 3,
				row = 1,
			}
			for _, line in ipairs(entry.ascii_lines) do
				table.insert(virtual_lines, { { "  " .. line, "NvJupOutput" } })
			end
			if entry.previous then
				retire_image(entry.previous.image_id)
				entry.previous = nil
			end
		elseif
			(entry.status == "pending" or entry.status == "converted")
			and entry.previous
			and entry.previous.status == "ready"
			and entry.previous.backend == "kitty"
		then
			vim.list_extend(virtual_lines, placeholder_lines(entry.previous))
			geometry_by_output[descriptor.output_index] = {
				cols = entry.previous.cols,
				rows = entry.previous.rows,
				col = 3,
				row = 1,
			}
		elseif entry.status == "pending" or entry.status == "converted" then
			table.insert(virtual_lines, { { "  [rendering " .. descriptor.mime .. "…]", "NvJupMuted" } })
		else
			table.insert(virtual_lines, fallback_line(descriptor, entry))
			if entry.previous then
				retire_image(entry.previous.image_id)
				entry.previous = nil
			end
		end
		by_output[descriptor.output_index] = {}
		for index = first_line, #virtual_lines do
			table.insert(by_output[descriptor.output_index], virtual_lines[index])
		end
	end
	return virtual_lines, seen, by_output, geometry_by_output
end

function M.finish_render(state, seen)
	for key, entry in pairs(placements) do
		if entry.buf == state.buf and not seen[key] then
			cancel_entry(entry)
			cancel_entry(entry.previous)
			if entry.image_id then
				delete_image(entry.image_id)
			end
			if entry.previous and entry.previous.image_id then
				delete_image(entry.previous.image_id)
			end
			placements[key] = nil
		end
	end
end

function M.detach(state)
	if not state then
		return
	end
	M.finish_render(state, {})
end

function M.capabilities()
	return {
		backend = selected_backend(),
		kitty = kitty_environment(),
		chafa = vim.fn.executable("chafa") == 1,
		imagemagick = vim.fn.executable("magick") == 1 or vim.fn.executable("convert") == 1,
		rsvg = vim.fn.executable("rsvg-convert") == 1,
		ffmpeg = vim.fn.executable("ffmpeg") == 1,
	}
end

function M._set_test_writer(writer)
	test_writer = writer
end

M.is_animation_bundle = is_animation_bundle
M._encode_transmit = encode_transmit
M._encode_animation_frame = encode_animation_frame
M._placeholder_lines = placeholder_lines
M._safe_svg = safe_svg
M._normalize_base64 = normalize_base64
M._bounded_bytes = bounded_bytes
M._grid_dimensions = grid_dimensions
M._descriptor_hash = descriptor_hash
M._placements = placements

return M
