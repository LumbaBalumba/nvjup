local config = require("nvjup.config")

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

local function normalize_data(value)
	if type(value) == "table" then
		return table.concat(value, "")
	end
	return type(value) == "string" and value or nil
end

local function quick_hash(value)
	local hash = 5381
	local step = math.max(1, math.floor(#value / 128))
	for index = 1, #value, step do
		hash = (hash * 33 + value:byte(index)) % 0x7fffffff
	end
	return tostring(hash) .. ":" .. #value
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

local function delete_image(image_id)
	tty_write(string.format("\27_Ga=d,d=I,i=%d,q=2\27\\", image_id))
	allocated_image_ids[image_id] = nil
	retiring_image_ids[image_id] = nil
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

local function decode_base64(value)
	local ok, decoded = pcall(vim.base64.decode, value)
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

local function descriptor_bytes(descriptor)
	if descriptor.mime == "image/svg+xml" then
		if not safe_svg(descriptor.data) then
			return nil, "unsafe SVG was blocked"
		end
		return descriptor.data
	end
	local decoded = decode_base64(descriptor.data)
	if not decoded then
		return nil, "invalid base64 image data"
	end
	return decoded
end

local function bounded_bytes(descriptor)
	local bytes, err = descriptor_bytes(descriptor)
	if not bytes then
		return nil, err
	end
	local options = image_options()
	local maximum = options.max_bytes or (10 * 1024 * 1024)
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

local function run_bounded(command, callback)
	local timeout = image_options().conversion_timeout_ms or 10000
	local completed = false
	local handle
	local timer = vim.uv.new_timer()
	local function finish(result, timed_out)
		if completed then
			return
		end
		completed = true
		if timer then
			timer:stop()
			timer:close()
		end
		callback(result, timed_out)
	end
	handle = vim.system(command, { text = true }, function(result)
		vim.schedule(function()
			finish(result, false)
		end)
	end)
	timer:start(timeout, 0, function()
		if handle then
			pcall(handle.kill, handle, 15)
		end
		vim.schedule(function()
			finish({ code = 124, stderr = "conversion timed out" }, true)
		end)
	end)
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
	run_bounded(command, function(result, timed_out)
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
	run_bounded({ "chafa", "--format", "symbols", "--animate=off", "--size", size, input }, function(result)
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
end

local function prepare(state, entry, descriptor, available_width, limits)
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
		entry.png_base64 = descriptor.data
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
	return {
		{
			string.format("  [%s%s%s]", descriptor.mime, dimensions_suffix(descriptor), reason),
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
			for _, mime in ipairs({ "image/png", "image/jpeg", "image/svg+xml", "application/pdf" }) do
				local value = normalize_data(data[mime])
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
		local hash = descriptor.mime .. ":" .. quick_hash(descriptor.data)
		local backend = selected_backend()
		local entry = placements[key]
		if not entry or entry.hash ~= hash or entry.backend ~= backend then
			local previous = entry
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
	}
end

function M._set_test_writer(writer)
	test_writer = writer
end

M._encode_transmit = encode_transmit
M._placeholder_lines = placeholder_lines
M._safe_svg = safe_svg
M._grid_dimensions = grid_dimensions
M._placements = placements

return M
