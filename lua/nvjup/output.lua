local config = require("nvjup.config")

local M = {}

local function strip_ansi(value)
	return value:gsub("\27%[[0-?]*[ -/]*[@-~]", "")
end

local function process_carriage_returns(value)
	-- tqdm and similar progress renderers rewrite one logical line with bare
	-- carriage returns. Jupyter preserves those updates in stream.text; keeping
	-- every segment either exposes control characters or shows stale frames.
	-- CRLF remains an ordinary newline, while each bare-CR line keeps only its
	-- latest frame.
	value = value:gsub("\r\n", "\n")
	local lines = {}
	for line in (value .. "\n"):gmatch("([^\n]*)\n") do
		local latest = line
		if line:find("\r", 1, true) then
			latest = line:match("([^\r]+)\r*$") or ""
		end
		table.insert(lines, latest)
	end
	if lines[#lines] == "" then
		table.remove(lines)
	end
	return table.concat(lines, "\n")
end

local function split_text(value)
	if type(value) == "table" then
		value = table.concat(value)
	end
	if type(value) ~= "string" then
		value = vim.inspect(value)
	end
	return vim.split(process_carriage_returns(strip_ansi(value)), "\n", { plain = true, trimempty = true })
end

local function decode_entities(value)
	local named = {
		amp = "&",
		apos = "'",
		gt = ">",
		lt = "<",
		nbsp = " ",
		quot = '"',
	}
	value = value:gsub("&#x([%da-fA-F]+);", function(hex)
		local codepoint = tonumber(hex, 16)
		return codepoint and vim.fn.nr2char(codepoint) or ""
	end)
	value = value:gsub("&#(%d+);", function(decimal)
		local codepoint = tonumber(decimal)
		return codepoint and vim.fn.nr2char(codepoint) or ""
	end)
	return value:gsub("&([%a]+);", function(name)
		return named[name] or ("&" .. name .. ";")
	end)
end

local function sanitize_html(value)
	value = value:gsub("<!%-%-[%s%S]-%-%->", "")
	value = value:gsub("<[sS][cC][rR][iI][pP][tT][^>]*>[%s%S]-</[sS][cC][rR][iI][pP][tT]%s*>", "")
	value = value:gsub("<[sS][tT][yY][lL][eE][^>]*>[%s%S]-</[sS][tT][yY][lL][eE]%s*>", "")
	value = value:gsub("<[iI][fF][rR][aA][mM][eE][^>]*>[%s%S]-</[iI][fF][rR][aA][mM][eE]%s*>", "")
	value = value:gsub("<[oO][bB][jJ][eE][cC][tT][^>]*>[%s%S]-</[oO][bB][jJ][eE][cC][tT]%s*>", "")
	return value
end

local function strip_tags(value)
	value = sanitize_html(value)
	value = value:gsub("<[bB][rR]%s*/?>", "\n")
	value = value:gsub("</[pP]%s*>", "\n")
	value = value:gsub("</[dD][iI][vV]%s*>", "\n")
	value = value:gsub("</[lL][iI]%s*>", "\n")
	value = value:gsub("<[^>]+>", "")
	value = decode_entities(value)
	value = value:gsub("[ \t]+\n", "\n"):gsub("\n[ \t]+", "\n")
	return value
end

local function table_rows(html)
	local rows = {}
	for row in html:gmatch("<[tT][rR][^>]*>([%s%S]-)</[tT][rR]%s*>") do
		local cells = {}
		-- Pandas uses <th> for the row index and <td> for numeric values in
		-- the same <tr>. Parse both tags in document order; choosing one tag
		-- family per row silently discarded every data value after the index.
		for cell in row:gmatch("<[tT][hHdD][^>]*>([%s%S]-)</[tT][hHdD]%s*>") do
			local text = strip_tags(cell):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
			table.insert(cells, text)
		end
		if #cells > 0 then
			table.insert(rows, cells)
		end
	end
	return rows
end

local function pad(value, width)
	return value .. string.rep(" ", math.max(0, width - vim.fn.strdisplaywidth(value)))
end

local function render_table(html)
	local rows = table_rows(html)
	if #rows == 0 then
		return nil
	end
	local columns = 0
	for _, row in ipairs(rows) do
		columns = math.max(columns, #row)
	end
	local available = math.max(20, (config.options.border_width or 88) - columns * 3 - 1)
	local per_column = math.max(4, math.floor(available / math.max(columns, 1)))
	local widths = {}
	for column = 1, columns do
		widths[column] = 1
		for _, row in ipairs(rows) do
			local value = row[column] or ""
			widths[column] = math.min(per_column, math.max(widths[column], vim.fn.strdisplaywidth(value)))
		end
	end
	local function border(left, middle, right)
		local parts = {}
		for _, width in ipairs(widths) do
			table.insert(parts, string.rep("─", width + 2))
		end
		return left .. table.concat(parts, middle) .. right
	end
	local lines = { border("┌", "┬", "┐") }
	for row_index, row in ipairs(rows) do
		local cells = {}
		for column, width in ipairs(widths) do
			local value = row[column] or ""
			if vim.fn.strdisplaywidth(value) > width then
				value = vim.fn.strcharpart(value, 0, math.max(1, width - 1)) .. "…"
			end
			table.insert(cells, " " .. pad(value, width) .. " ")
		end
		table.insert(lines, "│" .. table.concat(cells, "│") .. "│")
		if row_index < #rows then
			table.insert(lines, border("├", "┼", "┤"))
		end
	end
	table.insert(lines, border("└", "┴", "┘"))
	return lines
end

local function widget_text(value)
	if type(value) ~= "string" then
		return ""
	end
	local figure_space = vim.fn.nr2char(0x2007)
	return strip_tags(value):gsub(figure_space, " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function widget_models(cell, root_id)
	local models = (cell or {}).widget_models or {}
	local ordered = {}
	local visited = {}
	local function visit(model_id, depth)
		if depth > 8 or visited[model_id] then
			return
		end
		visited[model_id] = true
		local model = models[model_id]
		if not model then
			return
		end
		table.insert(ordered, model)
		for _, reference in ipairs((model.state or {}).children or {}) do
			local child_id = type(reference) == "string" and reference:match("^IPY_MODEL_(.+)$") or nil
			if child_id then
				visit(child_id, depth + 1)
			end
		end
	end
	visit(root_id, 0)
	return ordered
end

local function render_widget(data, cell)
	local view = data["application/vnd.jupyter.widget-view+json"]
	local root_id = type(view) == "table" and view.model_id or nil
	if type(root_id) ~= "string" then
		return { "[invalid Jupyter widget view]" }, "unsupported"
	end
	local progress
	local labels = {}
	for _, model in ipairs(widget_models(cell, root_id)) do
		local state = model.state or {}
		if state._model_name == "FloatProgressModel" or state._model_name == "IntProgressModel" then
			progress = state
		elseif state._model_name == "HTMLModel" then
			local text = widget_text(state.value)
			if text ~= "" then
				table.insert(labels, text)
			end
		end
	end
	if not progress then
		local fallback = split_text(data["text/plain"] or "Jupyter widget output · live state unavailable")
		return #fallback > 0 and fallback or { "[Jupyter widget output · live state unavailable]" }, "interactive"
	end
	local minimum = tonumber(progress.min) or 0
	local maximum = tonumber(progress.max) or 1
	local value = tonumber(progress.value) or minimum
	local fraction = maximum > minimum and ((value - minimum) / (maximum - minimum)) or 0
	fraction = math.max(0, math.min(1, fraction))
	local width = 20
	local filled = math.floor(fraction * width + 0.5)
	local bar = string.rep("█", filled) .. string.rep("░", width - filled)
	local left = labels[1] or widget_text(progress.description)
	if left == "" then
		left = string.format("%3d%%", math.floor(fraction * 100 + 0.5))
	end
	local right = labels[#labels] or string.format("%g/%g", value, maximum)
	local suffix = progress.bar_style == "success" and " ✓" or ""
	return { string.format("%s |%s| %s%s", left, bar, right, suffix) }, "widget"
end

local function dimensions(metadata, mime)
	local values = type(metadata) == "table" and metadata[mime] or nil
	if type(values) ~= "table" then
		return ""
	end
	if values.width and values.height then
		return string.format(" %sx%s", values.width, values.height)
	end
	if values.width then
		return string.format(" width=%s", values.width)
	end
	if values.height then
		return string.format(" height=%s", values.height)
	end
	return ""
end

local function render_bundle(data, metadata, options, cell)
	if type(data) ~= "table" then
		return { "[invalid MIME bundle]" }, "error"
	end

	if data["application/vnd.jupyter.widget-view+json"] then
		return render_widget(data, cell)
	end

	if data["application/vnd.plotly.v1+json"] then
		local lines = { "[Plotly interactive output · <leader>nf for focus mode]" }
		vim.list_extend(lines, split_text(data["text/plain"] or "Plotly figure"))
		return lines, "interactive"
	end

	if data["application/vnd.bokehjs_exec.v0+json"] or data["application/vnd.bokehjs_load.v0+json"] then
		local lines = { "[Bokeh interactive output · <leader>nf for focus mode]" }
		vim.list_extend(lines, split_text(data["text/plain"] or "Bokeh document"))
		return lines, "interactive"
	end

	for _, mime in ipairs({ "image/png", "image/jpeg", "image/svg+xml", "application/pdf" }) do
		if data[mime] then
			if options.include_images == false then
				return {}, "image"
			end
			local lines =
				{ string.format("[%s%s · use :NvJupOutputOpen for details]", mime, dimensions(metadata, mime)) }
			if data["text/plain"] then
				vim.list_extend(lines, split_text(data["text/plain"]))
			end
			return lines, "image"
		end
	end

	if data["text/markdown"] then
		return split_text(data["text/markdown"]), "markdown"
	end
	if data["text/html"] then
		local html = type(data["text/html"]) == "table" and table.concat(data["text/html"], "")
			or tostring(data["text/html"])
		local table_lines = render_table(sanitize_html(html))
		return table_lines or split_text(strip_tags(html)), "html"
	end
	if data["text/latex"] then
		return split_text(data["text/latex"]), "latex"
	end
	if data["text/plain"] then
		return split_text(data["text/plain"]), "text"
	end

	local mime_types = vim.tbl_keys(data)
	table.sort(mime_types)
	return { "[unsupported MIME bundle: " .. table.concat(mime_types, ", ") .. "]" }, "unsupported"
end

local function render_item(item, options, cell)
	local lines
	local kind
	if item.output_type == "stream" then
		lines = split_text(item.text or "")
		kind = item.name == "stderr" and "stderr" or "stdout"
	elseif item.output_type == "error" then
		lines = item.traceback and vim.deepcopy(item.traceback)
			or { string.format("%s: %s", item.ename or "Error", item.evalue or "") }
		for index, line in ipairs(lines) do
			lines[index] = strip_ansi(line)
		end
		kind = "error"
	elseif item.output_type == "execute_result" or item.output_type == "display_data" then
		lines, kind = render_bundle(item.data, item.metadata, options, cell)
	else
		lines = { "[unsupported output type: " .. tostring(item.output_type) .. "]" }
		kind = "unsupported"
	end
	local kinds = {}
	for _ = 1, #lines do
		table.insert(kinds, kind)
	end
	return lines, kinds
end

function M.segments(cell, options)
	options = options or {}
	if options.include_images == nil then
		options.include_images = true
	end
	local segments = {}
	local total = 0
	for output_index, item in ipairs(cell.outputs or {}) do
		local lines, kinds = render_item(item, options, cell)
		segments[output_index] = { lines = lines, kinds = kinds }
		total = total + #lines
	end

	local maximum
	if options.limit ~= false then
		maximum = config.options.render.max_output_lines
	end
	if maximum and total > maximum then
		local retained = 0
		for output_index = 1, #(cell.outputs or {}) do
			local segment = segments[output_index]
			local keep = math.max(0, math.min(#segment.lines, maximum - retained))
			while #segment.lines > keep do
				table.remove(segment.lines)
				table.remove(segment.kinds)
			end
			retained = retained + keep
		end
		local omitted = total - maximum
		local target = segments[#(cell.outputs or {})] or { lines = {}, kinds = {} }
		segments[#(cell.outputs or {})] = target
		table.insert(target.lines, string.format("… %d more output line%s", omitted, omitted == 1 and "" or "s"))
		table.insert(target.kinds, "truncated")
	end
	return segments
end

function M.render(cell, options)
	local rendered = {}
	local kinds = {}
	local segments = M.segments(cell, options)
	for output_index = 1, #(cell.outputs or {}) do
		local segment = segments[output_index]
		for index, line in ipairs(segment.lines) do
			table.insert(rendered, line)
			table.insert(kinds, segment.kinds[index])
		end
	end
	return rendered, kinds
end

function M.open(cell, mode)
	local lines = M.render(cell, { limit = false, include_images = true })
	if #lines == 0 then
		lines = { "[no output]" }
	end
	local buffer = vim.api.nvim_create_buf(false, true)
	vim.bo[buffer].buftype = "nofile"
	vim.bo[buffer].bufhidden = "wipe"
	vim.bo[buffer].swapfile = false
	vim.bo[buffer].modifiable = true
	vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
	vim.bo[buffer].modifiable = false
	vim.bo[buffer].filetype = "nvjup-output"
	local title = string.format(" Output [%s] ", cell.execution_count == vim.NIL and " " or cell.execution_count or " ")
	local window
	if mode == "split" or mode == "vsplit" or mode == "tab" then
		vim.cmd(mode == "tab" and "tabnew" or (mode == "vsplit" and "vnew" or "new"))
		window = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(window, buffer)
	else
		local width = math.min(math.max(40, config.options.border_width or 88), math.max(20, vim.o.columns - 8))
		local height = math.min(math.max(3, #lines), math.max(3, vim.o.lines - 8))
		window = vim.api.nvim_open_win(buffer, true, {
			relative = "editor",
			row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
			col = math.max(0, math.floor((vim.o.columns - width) / 2)),
			width = width,
			height = height,
			style = "minimal",
			border = "rounded",
			title = title,
			title_pos = "center",
		})
	end
	vim.wo[window].wrap = true
	vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buffer, silent = true, desc = "Close output" })
	vim.keymap.set("n", "<Esc>", "<cmd>close<cr>", { buffer = buffer, silent = true, desc = "Close output" })
	return buffer, window
end

M._render_table = render_table
M._sanitize_html = sanitize_html

return M
