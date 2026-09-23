local config = require("nvjup.config")
local language = require("nvjup.language")

local M = {}

local function fingerprint(state)
	local parts = {}
	for _, cell in ipairs(state.cells) do
		table.insert(
			parts,
			table.concat({
				cell.id,
				cell.cell_type,
				language.for_cell(state, cell),
				tostring(cell.range.start_row),
				tostring(cell.range.end_row),
				cell.source,
			}, "\0")
		)
	end
	return vim.fn.sha256(table.concat(parts, "\1"))
end

local function parser_available(lang)
	if lang == "text" then
		return false, "plain text cells do not use a parser"
	end
	local ok, err = pcall(vim.treesitter.language.add, lang)
	if ok then
		return true, nil
	end
	return false, tostring(err)
end

local function escaped_source_offset(state, cell, row)
	local source_line = vim.split(cell.source, "\n", { plain = true, trimempty = false })[row + 1]
	if not source_line then
		return 0
	end
	local visible =
		vim.api.nvim_buf_get_lines(state.buf, cell.range.start_row + row, cell.range.start_row + row + 1, false)[1]
	return visible == "\\" .. source_line and 1 or 0
end

local function add_capture(state, lang, capture, node)
	if capture:sub(1, 1) == "_" then
		return
	end
	local start_row, start_col, end_row, end_col = node:range()
	if start_row == end_row and start_col == end_col then
		return
	end
	local cell = state.treesitter.current_cell
	local buffer_start = cell.range.start_row
	start_col = start_col + escaped_source_offset(state, cell, start_row)
	end_col = end_col + escaped_source_offset(state, cell, end_row)
	local ok =
		pcall(vim.api.nvim_buf_set_extmark, state.buf, state.treesitter_ns, buffer_start + start_row, start_col, {
			end_row = buffer_start + end_row,
			end_col = end_col,
			hl_group = "@" .. capture .. "." .. lang,
			hl_mode = "combine",
			priority = config.options.treesitter.priority,
		})
	if ok then
		state.treesitter.capture_count = state.treesitter.capture_count + 1
	end
end

local function highlight_cell(state, cell, lang)
	local available, parser_error = parser_available(lang)
	state.treesitter.languages[lang] = {
		available = available,
		error = parser_error,
	}
	if not available or cell.source == "" then
		return
	end

	local ok, parser = pcall(vim.treesitter.get_string_parser, cell.source, lang)
	if not ok then
		state.treesitter.languages[lang].available = false
		state.treesitter.languages[lang].error = tostring(parser)
		return
	end
	local parsed, parse_error = pcall(parser.parse, parser, true)
	if not parsed then
		state.treesitter.languages[lang].error = tostring(parse_error)
		return
	end

	state.treesitter.current_cell = cell
	parser:for_each_tree(function(tree, language_tree)
		local tree_lang = language_tree:lang()
		local query_ok, highlights = pcall(vim.treesitter.query.get, tree_lang, "highlights")
		if not query_ok or not highlights then
			return
		end
		for capture_id, node in highlights:iter_captures(tree:root(), cell.source, 0, -1) do
			local capture = highlights.captures[capture_id]
			if capture then
				add_capture(state, tree_lang, capture, node)
			end
		end
	end)
	state.treesitter.current_cell = nil
end

function M.update(state)
	if not config.options.treesitter.enabled or not vim.api.nvim_buf_is_valid(state.buf) then
		M.detach(state)
		return false
	end
	local current_fingerprint = fingerprint(state)
	state.treesitter = state.treesitter or {}
	if state.treesitter.fingerprint == current_fingerprint then
		return false
	end

	vim.api.nvim_buf_clear_namespace(state.buf, state.treesitter_ns, 0, -1)
	state.treesitter.fingerprint = current_fingerprint
	state.treesitter.capture_count = 0
	state.treesitter.languages = {}
	vim.bo[state.buf].syntax = ""

	for _, cell in ipairs(state.cells) do
		local lang = language.for_cell(state, cell)
		if cell.cell_type ~= "raw" then
			highlight_cell(state, cell, lang)
		end
	end
	return true
end

function M.status(state)
	return state and state.treesitter or nil
end

function M.detach(state)
	if not state or not vim.api.nvim_buf_is_valid(state.buf) then
		return
	end
	vim.api.nvim_buf_clear_namespace(state.buf, state.treesitter_ns, 0, -1)
	state.treesitter = nil
end

return M
