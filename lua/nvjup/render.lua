local config = require("nvjup.config")
local notebook = require("nvjup.notebook")
local output = require("nvjup.output")
local util = require("nvjup.util")

local M = {}

local kind_highlight = {
	stdout = "NvJupOutput",
	stderr = "NvJupError",
	error = "NvJupError",
	image = "NvJupImage",
	interactive = "NvJupInteractive",
	markdown = "NvJupOutput",
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
	local width = config.options.border_width
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		if vim.api.nvim_win_is_valid(win) then
			width = math.min(width, math.max(24, vim.api.nvim_win_get_width(win) - 2))
			break
		end
	end
	return width
end

local function cell_type_label(cell)
	if cell.cell_type == "markdown" then
		return "Markdown", "NvJupMarkdown"
	end
	if cell.cell_type == "raw" then
		return "Raw", "NvJupRaw"
	end
	return "Code", "NvJupCode"
end

local function header_text(cell, index, count, width, active)
	local label = cell_type_label(cell)
	local execution = " "
	if cell.cell_type == "code" and cell.execution_count ~= nil and cell.execution_count ~= vim.NIL then
		execution = tostring(cell.execution_count)
	end
	local body = string.format("╭─ [%s] %s · cell %d/%d · %s ", execution, label, index, count, cell.id)
	return util.fit_border(body, width, "─"), active and "NvJupHeaderActive" or "NvJupHeader"
end

local function output_virtual_lines(cell, width)
	local result = {}
	local lines, kinds = {}, {}
	if config.options.render.outputs then
		lines, kinds = output.render(cell)
	end
	if #lines > 0 then
		local execution = cell.execution_count ~= nil
				and cell.execution_count ~= vim.NIL
				and tostring(cell.execution_count)
			or " "
		local suffix = cell.output_collapsed and string.format("· %d lines collapsed ", #lines) or ""
		table.insert(result, {
			{
				util.fit_border(string.format("├─ Out[%s] %s", execution, suffix), width, "─"),
				"NvJupOutputHeader",
			},
		})
		if not cell.output_collapsed then
			for index, line in ipairs(lines) do
				local prefix = "│ "
				local clipped = vim.fn.strcharpart(line, 0, math.max(1, width - 3))
				table.insert(result, { { prefix .. clipped, kind_highlight[kinds[index]] or "NvJupOutput" } })
			end
		end
	end
	table.insert(result, { { util.fit_border("╰", width, "─"), "NvJupBorder" } })
	return result
end

local function render_markdown_line(state, cell, row, line)
	if not config.options.render.markdown or cell.cell_type ~= "markdown" then
		return
	end
	local hashes = line:match("^(#+)%s")
	if hashes then
		local level = math.min(6, #hashes)
		vim.api.nvim_buf_set_extmark(state.buf, state.render_ns, row, 0, {
			end_col = #line,
			hl_group = "NvJupMarkdownH" .. level,
			priority = 120,
		})
	elseif line:match("^%s*[-*+]%s") then
		vim.api.nvim_buf_set_extmark(state.buf, state.render_ns, row, 0, {
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
	vim.wo[win].showbreak = " "
end

function M.render(state)
	if not state or not vim.api.nvim_buf_is_valid(state.buf) then
		return
	end
	local ok = state:sync_from_buffer()
	if not ok then
		return
	end

	define_highlights()
	vim.api.nvim_buf_clear_namespace(state.buf, state.render_ns, 0, -1)
	vim.api.nvim_buf_clear_namespace(state.buf, state.marker_ns, 0, -1)

	local width = window_width(state.buf)
	local cursor_row
	if vim.api.nvim_get_current_buf() == state.buf then
		cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
	end
	local active_index = cursor_row and state:cell_index_at(cursor_row) or nil
	local buffer_lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)

	for index, cell in ipairs(state.cells) do
		local active = index == active_index
		local header, header_highlight = header_text(cell, index, #state.cells, width, active)
		vim.api.nvim_buf_set_extmark(state.buf, state.render_ns, cell.range.start_row, 0, {
			virt_lines = { { { header, header_highlight } } },
			virt_lines_above = true,
			priority = 100,
		})

		local marker_line = buffer_lines[cell.range.marker_row + 1] or ""
		vim.api.nvim_buf_set_extmark(state.buf, state.marker_ns, cell.range.marker_row, 0, {
			end_col = #marker_line,
			conceal = "",
			virt_text = { { "····", "NvJupSeparator" } },
			virt_text_pos = "overlay",
			priority = 200,
		})

		for row = cell.range.start_row, cell.range.end_row do
			local line = buffer_lines[row + 1] or ""
			-- Shift the first visual row to make room for the left border.
			vim.api.nvim_buf_set_extmark(state.buf, state.render_ns, row, 0, {
				virt_text = { { "│ ", "NvJupBorder" } },
				virt_text_pos = "inline",
				hl_mode = "combine",
				line_hl_group = active and "NvJupActiveCell" or nil,
				priority = 80,
			})
			-- Wrapped continuation rows do not repeat inline virtual text. Pin a
			-- second border to window column zero and repeat it on every visual row.
			-- breakindentopt=min:2 reserves the same two columns on continuations.
			vim.api.nvim_buf_set_extmark(state.buf, state.render_ns, row, 0, {
				virt_text = { { "│ ", "NvJupBorder" } },
				virt_text_win_col = 0,
				virt_text_repeat_linebreak = true,
				hl_mode = "combine",
				priority = 75,
			})
			if config.options.render.right_border then
				vim.api.nvim_buf_set_extmark(state.buf, state.render_ns, row, 0, {
					virt_text = { { "│", "NvJupBorder" } },
					virt_text_pos = "right_align",
					virt_text_repeat_linebreak = true,
					hl_mode = "combine",
					priority = 80,
				})
			end
			render_markdown_line(state, cell, row, line)
		end

		vim.api.nvim_buf_set_extmark(state.buf, state.render_ns, cell.range.end_row, 0, {
			virt_lines = output_virtual_lines(cell, width),
			priority = 100,
		})
	end

	for _, win in ipairs(vim.fn.win_findbuf(state.buf)) do
		M.configure_window(win)
	end
end

function M.render_current_buffer()
	M.render(notebook.get())
end

return M
