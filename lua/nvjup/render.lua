local config = require("nvjup.config")
local features = require("nvjup.features")
local image = require("nvjup.image")
local interactive = require("nvjup.interactive")
local language = require("nvjup.language")
local markdown = require("nvjup.markdown")
local notebook = require("nvjup.notebook")
local output = require("nvjup.output")

local M = {}

local kind_highlight = {
	stdout = "NvJupOutput",
	stderr = "NvJupError",
	error = "NvJupError",
	image = "NvJupImage",
	interactive = "NvJupInteractive",
	widget = "NvJupInteractive",
	markdown = "NvJupMarkdown",
	html = "NvJupOutput",
	latex = "NvJupOutput",
	text = "NvJupOutput",
	unsupported = "NvJupWarning",
	truncated = "NvJupMuted",
}

local function define_highlights()
	local highlights = {
		NvJupBorder = { link = "FloatBorder" },
		NvJupHeader = { link = "Title" },
		NvJupHeaderActive = { link = "CursorLineNr" },
		NvJupCode = { link = "Function" },
		NvJupMarkdown = { link = "Special" },
		NvJupRaw = { link = "Comment" },
		NvJupMuted = { link = "Comment" },
		NvJupSeparator = { link = "NonText" },
		NvJupOutput = { link = "Normal" },
		NvJupOutputHeader = { link = "DiagnosticInfo" },
		NvJupError = { link = "DiagnosticError" },
		NvJupWarning = { link = "DiagnosticWarn" },
		NvJupImage = { link = "DiagnosticHint" },
		NvJupInteractive = { link = "DiagnosticOk" },
		NvJupActiveCell = { link = "CursorLine" },
		NvJupMarkdownH1 = { link = "markdownH1" },
		NvJupMarkdownH2 = { link = "markdownH2" },
		NvJupMarkdownH3 = { link = "markdownH3" },
		NvJupMarkdownH4 = { link = "markdownH4" },
		NvJupMarkdownH5 = { link = "markdownH5" },
		NvJupMarkdownH6 = { link = "markdownH6" },
	}
	for name, value in pairs(highlights) do
		vim.api.nvim_set_hl(0, name, { default = true, link = value.link })
	end
end

local function window_width(buf)
	local windows = vim.fn.win_findbuf(buf)
	local win = vim.api.nvim_get_current_buf() == buf and vim.api.nvim_get_current_win() or windows[1]
	if not win or not vim.api.nvim_win_is_valid(win) then
		return math.max(24, tonumber(config.options.border_width) or 88)
	end
	local info = vim.fn.getwininfo(win)[1] or {}
	local available = math.max(24, vim.api.nvim_win_get_width(win) - (info.textoff or 0))
	if config.options.render.full_width == false then
		return math.min(tonumber(config.options.border_width) or 88, available)
	end
	return available
end

function M.content_width(buf)
	return window_width(buf)
end

local language_labels = {
	cpp = "C++",
	javascript = "JavaScript",
	python = "Python",
	r = "R",
	rust = "Rust",
	typescript = "TypeScript",
}

local function cell_label(state, cell)
	if cell.cell_type == "markdown" then
		return "Markdown"
	end
	if cell.cell_type == "raw" then
		return "Raw"
	end
	local name = language.for_cell(state, cell)
	return language_labels[name] or (name:sub(1, 1):upper() .. name:sub(2))
end

local function aligned_border(left, right, width)
	local padding = width - vim.fn.strwidth(left) - vim.fn.strwidth(right)
	return left .. string.rep("─", math.max(0, padding)) .. right
end

local function format_duration(ns)
	if not ns then
		return nil
	end
	local seconds = ns / 1e9
	if seconds < 10 then
		return string.format("%.1fs", seconds)
	end
	if seconds < 60 then
		return string.format("%.0fs", seconds)
	end
	return string.format("%dm %ds", math.floor(seconds / 60), math.floor(seconds % 60))
end

local function execution_label(cell)
	local count = cell.execution_count ~= nil and cell.execution_count ~= vim.NIL and tostring(cell.execution_count)
		or " "
	local duration = format_duration(cell.execution_duration_ns)
	if cell.stale or cell.execution_status == "stale" then
		return string.format("[%s] * stale", count)
	end
	local states = {
		queued = "… queued",
		sent = "… sent",
		running = "● running",
		waiting_input = "? input",
		failed = "✗",
		cancelled = "× cancelled",
		completed = "✓",
	}
	local status = states[cell.execution_status]
	if not status and cell.execution_count ~= nil and cell.execution_count ~= vim.NIL then
		status = "✓"
	end
	if not status then
		return "[ ]"
	end
	return string.format("[%s] %s%s", count, status, duration and (" " .. duration) or "")
end

local function header_text(cell, index, width, active)
	local left = cell.execution_status == "running" and "╭─ (running) " or "╭"
	local right = string.format("─ #%d ─╮", index)
	return aligned_border(left, right, width), active and "NvJupHeaderActive" or "NvJupHeader"
end

local function footer_text(state, cell, width)
	local status = cell.cell_type == "code" and ("─ " .. execution_label(cell) .. " ") or ""
	local label = "─ " .. cell_label(state, cell) .. " ─╯"
	return aligned_border("╰" .. status, label, width)
end

local function output_virtual_lines(state, cell, width)
	local result = { { { footer_text(state, cell, width), "NvJupBorder" } } }
	local render_cell, seen_interactive = cell, {}
	if config.options.render.outputs and not cell.output_collapsed then
		render_cell, seen_interactive = interactive.prepare_cell(state, cell)
	end
	local segments = {}
	local image_lines, seen_images, images_by_output = {}, {}, {}
	if config.options.render.outputs and not cell.output_collapsed then
		local output_options = { include_images = false }
		if cell.output_expanded then
			output_options.limit = false
		end
		segments = output.segments(render_cell, output_options)
		image_lines, seen_images, images_by_output = image.render(state, render_cell, width)
	end
	local text_line_count = 0
	for _, segment in pairs(segments) do
		text_line_count = text_line_count + #segment.lines
	end
	if text_line_count > 0 or #image_lines > 0 then
		local execution = cell.execution_count ~= nil
				and cell.execution_count ~= vim.NIL
				and tostring(cell.execution_count)
			or " "
		local suffix = cell.output_expanded and " · full output" or ""
		table.insert(result, { { string.format("  Out[%s]%s", execution, suffix), "NvJupOutputHeader" } })
		for output_index = 1, #(cell.outputs or {}) do
			local segment = segments[output_index]
			if segment then
				for index, line in ipairs(segment.lines) do
					local clipped = vim.fn.strcharpart(line, 0, math.max(1, width - 3))
					table.insert(result, {
						{ "  " .. clipped, kind_highlight[segment.kinds[index]] or "NvJupOutput" },
					})
				end
			end
			vim.list_extend(result, images_by_output[output_index] or {})
		end
	end
	return result, seen_images, seen_interactive
end

local function render_markdown_line(state, cell, row, line)
	if not config.options.render.markdown or cell.cell_type ~= "markdown" or markdown.external_active(state) then
		return
	end
	local hashes = line:match("^(#+)%s")
	if hashes then
		local level = math.min(6, #hashes)
		return vim.api.nvim_buf_set_extmark(state.buf, state.render_ns, row, 0, {
			end_col = #line,
			hl_group = "NvJupMarkdownH" .. level,
			priority = 120,
		})
	elseif line:match("^%s*[-*+]%s") then
		return vim.api.nvim_buf_set_extmark(state.buf, state.render_ns, row, 0, {
			end_col = #line,
			hl_group = "NvJupMarkdown",
			priority = 110,
		})
	end
end

function M.configure_window(win)
	if not vim.api.nvim_win_is_valid(win) then
		return
	end
	vim.wo[win].conceallevel = 2
	vim.wo[win].concealcursor = "nc"
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true
	vim.wo[win].breakindent = true
	vim.wo[win].breakindentopt = "min:2"
	vim.wo[win].showbreak = "  "
end

local function current_active_index(state)
	if vim.api.nvim_get_current_buf() ~= state.buf then
		return nil
	end
	local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
	return state:cell_index_at(cursor_row)
end

local function update_header(state, index, active)
	local cell = index and state.cells[index] or nil
	if not cell or not cell.render_header_mark then
		return
	end
	local header, highlight = header_text(cell, index, state.render_width or window_width(state.buf), active)
	cell.render_header_mark = vim.api.nvim_buf_set_extmark(state.buf, state.render_ns, cell.range.start_row, 0, {
		id = cell.render_header_mark,
		virt_lines = { { { header, highlight } } },
		virt_lines_above = true,
		priority = 100,
	})
end

function M.active(state, force)
	if not state or not state.rendered or not vim.api.nvim_buf_is_valid(state.buf) then
		return false
	end
	local active_index = current_active_index(state)
	if not force and active_index == state.render_active_index then
		return true
	end
	update_header(state, state.render_active_index, false)
	vim.api.nvim_buf_clear_namespace(state.buf, state.active_ns, 0, -1)
	state.render_active_index = active_index
	update_header(state, active_index, true)
	local cell = active_index and state.cells[active_index] or nil
	if cell then
		for row = cell.range.start_row, cell.range.end_row do
			vim.api.nvim_buf_set_extmark(state.buf, state.active_ns, row, 0, {
				line_hl_group = "NvJupActiveCell",
				priority = 70,
			})
		end
	end
	return true
end

local function set_output_mark(state, cell, width)
	local output_lines, cell_images, cell_interactive = output_virtual_lines(state, cell, width)
	local options = {
		virt_lines = output_lines,
		priority = 100,
	}
	if cell.render_output_mark then
		options.id = cell.render_output_mark
	end
	local ok, mark = pcall(vim.api.nvim_buf_set_extmark, state.buf, state.render_ns, cell.range.end_row, 0, options)
	if not ok and options.id then
		options.id = nil
		mark = vim.api.nvim_buf_set_extmark(state.buf, state.render_ns, cell.range.end_row, 0, options)
	end
	cell.render_output_mark = mark
	state.render_cell_images = state.render_cell_images or {}
	state.render_cell_interactive = state.render_cell_interactive or {}
	state.render_cell_images[cell.id] = cell_images
	state.render_cell_interactive[cell.id] = cell_interactive
	return cell_images, cell_interactive
end

local function delete_mark(buf, namespace, mark)
	if mark then
		pcall(vim.api.nvim_buf_del_extmark, buf, namespace, mark)
	end
end

local function render_cell_chrome(state, cell, index, width, buffer_lines, clear)
	if clear then
		delete_mark(state.buf, state.render_ns, cell.render_header_mark)
		delete_mark(state.buf, state.render_ns, cell.render_output_mark)
		delete_mark(state.buf, state.marker_ns, cell.render_marker_mark)
		for _, mark in ipairs(cell.render_body_marks or {}) do
			delete_mark(state.buf, state.render_ns, mark)
		end
	end
	cell.render_body_marks = {}
	local header = header_text(cell, index, width, index == state.render_active_index)
	cell.render_header_mark = vim.api.nvim_buf_set_extmark(state.buf, state.render_ns, cell.range.start_row, 0, {
		virt_lines = { { { header, index == state.render_active_index and "NvJupHeaderActive" or "NvJupHeader" } } },
		virt_lines_above = true,
		priority = 100,
	})
	local marker_line = buffer_lines[cell.range.marker_row + 1] or ""
	cell.render_marker_mark = vim.api.nvim_buf_set_extmark(state.buf, state.marker_ns, cell.range.marker_row, 0, {
		end_col = #marker_line,
		conceal = "",
		virt_text = { { "····", "NvJupSeparator" } },
		virt_text_pos = "overlay",
		priority = 200,
	})
	local function body_mark(row, options)
		table.insert(cell.render_body_marks, vim.api.nvim_buf_set_extmark(state.buf, state.render_ns, row, 0, options))
	end
	for row = cell.range.start_row, cell.range.end_row do
		local line = buffer_lines[row + 1] or ""
		body_mark(row, {
			virt_text = { { "│ ", "NvJupBorder" } },
			virt_text_pos = "inline",
			hl_mode = "combine",
			priority = 80,
		})
		body_mark(row, {
			virt_text = { { "│", "NvJupBorder" } },
			virt_text_win_col = 0,
			virt_text_repeat_linebreak = true,
			hl_mode = "combine",
			priority = 75,
		})
		if config.options.render.right_border then
			body_mark(row, {
				virt_text = { { "│", "NvJupBorder" } },
				-- Unlike right_align, eol_right_align never overlays the final
				-- display cell of Markdown or wrapped source text.
				virt_text_pos = "eol_right_align",
				virt_text_repeat_linebreak = true,
				hl_mode = "combine",
				priority = 80,
			})
		end
		local markdown_mark = render_markdown_line(state, cell, row, line)
		if markdown_mark then
			table.insert(cell.render_body_marks, markdown_mark)
		end
	end
	set_output_mark(state, cell, width)
end

local function finish_seen(state)
	local seen_images, seen_interactive = {}, {}
	for _, values in pairs(state.render_cell_images or {}) do
		for key in pairs(values) do
			seen_images[key] = true
		end
	end
	for _, values in pairs(state.render_cell_interactive or {}) do
		for key in pairs(values) do
			seen_interactive[key] = true
		end
	end
	image.finish_render(state, seen_images)
	interactive.finish_render(state, seen_interactive)
end

function M.render_cell(state, cell_or_id, options)
	options = options or {}
	if not state or not state.rendered or not vim.api.nvim_buf_is_valid(state.buf) then
		return false
	end
	local cell, index
	if type(cell_or_id) == "table" then
		cell = cell_or_id
		index = cell.index
	else
		cell, index = state:cell_by_id(cell_or_id)
	end
	if not cell or not index then
		return false
	end
	local width = window_width(state.buf)
	if width ~= state.render_width then
		return M.render(state)
	end
	if options.source then
		local lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
		render_cell_chrome(state, cell, index, width, lines, true)
	else
		update_header(state, index, index == state.render_active_index)
		set_output_mark(state, cell, width)
	end
	finish_seen(state)
	return true
end

function M.render(state, options)
	options = options or {}
	if not state or not vim.api.nvim_buf_is_valid(state.buf) then
		return false
	end
	state.render_request_generation = (state.render_request_generation or 0) + 1
	if state.render_request_timer and not state.render_request_timer:is_closing() then
		state.render_request_timer:stop()
	end
	state.render_request_full = false
	state.render_request_cells = {}
	if options.sync ~= false then
		local ok = state:sync_from_buffer()
		if not ok then
			return false
		end
	end

	define_highlights()
	vim.api.nvim_buf_clear_namespace(state.buf, state.render_ns, 0, -1)
	vim.api.nvim_buf_clear_namespace(state.buf, state.active_ns, 0, -1)
	vim.api.nvim_buf_clear_namespace(state.buf, state.marker_ns, 0, -1)

	local width = window_width(state.buf)
	local buffer_lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
	state.render_cell_images = {}
	state.render_cell_interactive = {}
	state.render_active_index = nil

	for index, cell in ipairs(state.cells) do
		render_cell_chrome(state, cell, index, width, buffer_lines, false)
	end
	finish_seen(state)

	state.render_width = width
	state.rendered = true
	M.active(state, true)
	for _, win in ipairs(vim.fn.win_findbuf(state.buf)) do
		M.configure_window(win)
	end
	features.update(state)
	markdown.refresh(state)
	return true
end

local function ensure_request_timer(state)
	if state.render_request_timer and not state.render_request_timer:is_closing() then
		return state.render_request_timer
	end
	state.render_request_timer = vim.uv.new_timer()
	return state.render_request_timer
end

local function schedule_request(state, delay_ms)
	local timer = ensure_request_timer(state)
	timer:stop()
	timer:start(math.max(0, tonumber(delay_ms) or tonumber(config.options.render.debounce_ms) or 30), 0, function()
		vim.schedule(function()
			if not vim.api.nvim_buf_is_valid(state.buf) or notebook.get(state.buf) ~= state then
				return
			end
			local full = state.render_request_full
			local cells = state.render_request_cells or {}
			state.render_request_full = false
			state.render_request_cells = {}
			if full or not state.rendered then
				M.render(state)
				return
			end
			local source_changed = false
			for id, reason in pairs(cells) do
				local source = reason == "source"
				source_changed = source_changed or source
				M.render_cell(state, id, { source = source })
			end
			if source_changed then
				M.active(state, true)
				features.update(state)
				markdown.refresh(state)
			end
		end)
	end)
end

function M.request(state, delay_ms)
	if not state or not vim.api.nvim_buf_is_valid(state.buf) then
		return
	end
	state.render_request_full = true
	schedule_request(state, delay_ms)
end

function M.request_cell(state, cell_or_id, delay_ms, reason)
	if not state or not vim.api.nvim_buf_is_valid(state.buf) then
		return
	end
	local id = type(cell_or_id) == "table" and cell_or_id.id or cell_or_id
	if not id then
		return M.request(state, delay_ms)
	end
	state.render_request_cells = state.render_request_cells or {}
	if reason == "source" or state.render_request_cells[id] == nil then
		state.render_request_cells[id] = reason or "output"
	end
	schedule_request(state, delay_ms)
end

function M.request_source(state, changed, structural, delay_ms)
	if structural then
		return M.request(state, delay_ms)
	end
	local any = false
	for id in pairs(changed or {}) do
		any = true
		M.request_cell(state, id, delay_ms, "source")
	end
	if not any then
		M.active(state)
	end
end

function M.detach(state)
	if not state then
		return
	end
	local timer = state.render_request_timer
	if timer and not timer:is_closing() then
		timer:stop()
		timer:close()
	end
	state.render_request_timer = nil
	state.render_request_cells = nil
end

function M.refresh_window(state)
	if not state or not vim.api.nvim_buf_is_valid(state.buf) then
		return
	end
	for _, win in ipairs(vim.fn.win_findbuf(state.buf)) do
		M.configure_window(win)
	end
	if not state.rendered or state.render_width ~= window_width(state.buf) then
		M.render(state)
	else
		M.active(state)
	end
end

function M.render_current_buffer()
	M.render(notebook.get())
end

return M
