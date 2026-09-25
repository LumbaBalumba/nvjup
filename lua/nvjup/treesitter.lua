local config = require("nvjup.config")
local language = require("nvjup.language")
local util = require("nvjup.util")

local M = {}

local function structure_fingerprint(state)
	local parts = {}
	for _, cell in ipairs(state.cells) do
		table.insert(parts, table.concat({ cell.id, cell.cell_type, language.for_cell(state, cell) }, "\0"))
	end
	return vim.fn.sha256(table.concat(parts, "\1"))
end

local function parser_available(ts, lang)
	if ts.languages[lang] then
		return ts.languages[lang].available, ts.languages[lang].error
	end
	if lang == "text" then
		ts.languages[lang] = { available = false, error = "plain text cells do not use a parser" }
		return false, ts.languages[lang].error
	end
	local ok, err = pcall(vim.treesitter.language.add, lang)
	ts.languages[lang] = { available = ok, error = ok and nil or tostring(err) }
	return ok, ts.languages[lang].error
end

local function delete_cell_marks(state, entry)
	if not entry then
		return
	end
	for _, mark in ipairs(entry.marks or {}) do
		pcall(vim.api.nvim_buf_del_extmark, state.buf, state.treesitter_ns, mark)
	end
	state.treesitter.capture_count = math.max(0, state.treesitter.capture_count - #(entry.marks or {}))
end

local function add_capture(state, entry, lang, capture, node, offsets)
	if capture:sub(1, 1) == "_" then
		return
	end
	local start_row, start_col, end_row, end_col = node:range()
	if start_row == end_row and start_col == end_col then
		return
	end
	start_col = start_col + (offsets[start_row + 1] or 0)
	end_col = end_col + (offsets[end_row + 1] or 0)
	local ok, mark =
		pcall(vim.api.nvim_buf_set_extmark, state.buf, state.treesitter_ns, entry.start_row + start_row, start_col, {
			end_row = entry.start_row + end_row,
			end_col = end_col,
			hl_group = "@" .. capture .. "." .. lang,
			hl_mode = "combine",
			priority = config.options.treesitter.priority,
		})
	if ok then
		table.insert(entry.marks, mark)
		state.treesitter.capture_count = state.treesitter.capture_count + 1
	end
end

local function highlight_cell(state, cell, lang)
	local ts = state.treesitter
	local entry = {
		revision = cell.revision,
		source = cell.source,
		cell_type = cell.cell_type,
		lang = lang,
		start_row = cell.range.start_row,
		marks = {},
	}
	ts.cells[cell.id] = entry
	local available = parser_available(ts, lang)
	if not available or cell.source == "" then
		return
	end

	local source_lines = util.source_to_lines(cell.source)
	local visible_lines =
		vim.api.nvim_buf_get_lines(state.buf, cell.range.start_row, cell.range.start_row + #source_lines, false)
	local offsets = {}
	for index, source_line in ipairs(source_lines) do
		offsets[index] = visible_lines[index] == "\\" .. source_line and 1 or 0
	end

	local ok, parser = pcall(vim.treesitter.get_string_parser, cell.source, lang)
	if not ok then
		ts.languages[lang] = { available = false, error = tostring(parser) }
		return
	end
	local parsed, parse_error = pcall(parser.parse, parser, true)
	if not parsed then
		ts.languages[lang].error = tostring(parse_error)
		return
	end

	parser:for_each_tree(function(tree, language_tree)
		local tree_lang = language_tree:lang()
		local query_ok, highlights = pcall(vim.treesitter.query.get, tree_lang, "highlights")
		if not query_ok or not highlights then
			return
		end
		for capture_id, node in highlights:iter_captures(tree:root(), cell.source, 0, -1) do
			local capture = highlights.captures[capture_id]
			if capture then
				add_capture(state, entry, tree_lang, capture, node, offsets)
			end
		end
	end)
end

function M.update(state)
	if not config.options.treesitter.enabled or not vim.api.nvim_buf_is_valid(state.buf) then
		M.detach(state)
		return false
	end
	local structure = structure_fingerprint(state)
	state.treesitter = state.treesitter or {
		structure = nil,
		capture_count = 0,
		languages = {},
		cells = {},
	}
	local ts = state.treesitter
	local structural_change = ts.structure ~= nil and ts.structure ~= structure
	if structural_change then
		vim.api.nvim_buf_clear_namespace(state.buf, state.treesitter_ns, 0, -1)
		ts.capture_count = 0
		ts.cells = {}
	end
	ts.structure = structure
	vim.bo[state.buf].syntax = ""

	local changed = structural_change
	local present = {}
	for _, cell in ipairs(state.cells) do
		present[cell.id] = true
		local lang = language.for_cell(state, cell)
		local previous = ts.cells[cell.id]
		local dirty = not previous
			or previous.revision ~= cell.revision
			or previous.source ~= cell.source
			or previous.cell_type ~= cell.cell_type
			or previous.lang ~= lang
		if dirty then
			changed = true
			delete_cell_marks(state, previous)
			ts.cells[cell.id] = nil
			if cell.cell_type ~= "raw" then
				highlight_cell(state, cell, lang)
			end
		elseif previous then
			-- Extmarks follow buffer edits; retain the actual current start for diagnostics.
			previous.start_row = cell.range.start_row
		end
	end
	for id, entry in pairs(ts.cells) do
		if not present[id] then
			delete_cell_marks(state, entry)
			ts.cells[id] = nil
			changed = true
		end
	end
	return changed
end

function M.status(state)
	return state and state.treesitter or nil
end

function M.detach(state)
	if not state then
		return
	end
	if vim.api.nvim_buf_is_valid(state.buf) then
		vim.api.nvim_buf_clear_namespace(state.buf, state.treesitter_ns, 0, -1)
	end
	state.treesitter = nil
end

return M
