local language = require("nvjup.language")
local util = require("nvjup.util")

local M = {}
local Manager = {}
Manager.__index = Manager

local function source_fingerprint(state)
	local parts = { state.path or "" }
	for _, cell in ipairs(state.cells) do
		table.insert(
			parts,
			table.concat({
				cell.id,
				cell.cell_type,
				language.for_cell(state, cell),
				tostring(cell.range.start_row),
				cell.source,
			}, "\0")
		)
	end
	return vim.fn.sha256(table.concat(parts, "\1"))
end

local function python_placeholder(line)
	if line == "" then
		return ""
	end
	return "#" .. string.rep(" ", math.max(0, #line - 1))
end

local python_code_line_magics = { time = true, timeit = true, prun = true }
local python_code_cell_magics = { time = true, timeit = true, prun = true }

local function full_placeholder(lines, transformed, index, line)
	lines[index] = python_placeholder(line)
	transformed[index] = true
end

local function preserve_python_magic(lines, transformed, index, line)
	local indent, name, whitespace, suffix = line:match("^(%s*)%%([%a_][%w_]*)(%s+)(.*)$")
	if not name or not python_code_line_magics[name] or suffix == "" or suffix:match("^%-") then
		return false
	end
	local prefix_width = 1 + #name + #whitespace
	lines[index] = indent .. "pass;" .. string.rep(" ", prefix_width - #"pass;") .. suffix
	transformed[index] = {
		{ start_col = #indent, end_col = #indent + prefix_width },
	}
	return true
end

local function transform_source(lang, source)
	local lines = util.source_to_lines(source)
	local transformed = {}
	if lang ~= "python" then
		return lines, transformed
	end

	local cell_magic_name
	local cell_magic_index
	for index, line in ipairs(lines) do
		if line:match("%S") then
			cell_magic_name = line:match("^%s*%%%%([%a_][%w_]*)")
			cell_magic_index = cell_magic_name and index or nil
			break
		end
	end
	local python_cell_magic = cell_magic_name and python_code_cell_magics[cell_magic_name]
	for index, line in ipairs(lines) do
		if cell_magic_name and not python_cell_magic then
			full_placeholder(lines, transformed, index, line)
		elseif index == cell_magic_index then
			full_placeholder(lines, transformed, index, line)
		elseif line:match("^%s*%%") then
			if not preserve_python_magic(lines, transformed, index, line) then
				full_placeholder(lines, transformed, index, line)
			end
		elseif line:match("^%s*!") or line:match("^%s*%?[%w_.]") then
			full_placeholder(lines, transformed, index, line)
		end
	end
	return lines, transformed
end

local function make_shadow_name(state, lang)
	local base = state.path ~= "" and state.path or vim.fs.joinpath(vim.uv.cwd(), "untitled.ipynb")
	return string.format("%s.%d.nvjup-shadow.%s", base, state.buf, language.extension(lang))
end

local function create_document(state, lang)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].buflisted = false
	vim.bo[buf].swapfile = false
	vim.bo[buf].undofile = false
	vim.bo[buf].filetype = lang
	vim.api.nvim_buf_set_name(buf, make_shadow_name(state, lang))
	vim.b[buf].nvjup_shadow = true
	vim.b[buf].nvjup_notebook_buf = state.buf
	return {
		buf = buf,
		lang = lang,
		segments = {},
		version = 0,
		uri = vim.uri_from_bufnr(buf),
	}
end

local function destroy_document(document)
	if document and vim.api.nvim_buf_is_valid(document.buf) then
		pcall(vim.api.nvim_buf_delete, document.buf, { force = true })
	end
end

local function build_document(state, lang, cells)
	local lines = {}
	local segments = {}
	for _, item in ipairs(cells) do
		local cell = item.cell
		local source_lines, transformed_lines = transform_source(lang, cell.source)
		local separator_row = #lines
		table.insert(lines, string.format("%s nvjup-cell:%s", language.comment(lang), cell.id))
		local shadow_start_row = #lines
		vim.list_extend(lines, source_lines)
		local shadow_end_exclusive = #lines
		table.insert(lines, "")
		table.insert(segments, {
			cell_id = cell.id,
			cell_index = item.index,
			notebook_start_row = cell.range.start_row,
			notebook_end_exclusive = cell.range.end_exclusive,
			separator_row = separator_row,
			shadow_start_row = shadow_start_row,
			shadow_end_exclusive = shadow_end_exclusive,
			source_lines = source_lines,
			transformed_lines = transformed_lines,
		})
	end
	if #lines == 0 then
		lines = { "" }
	end
	return lines, segments
end

local function source_byte_column(state, segment, local_row, buffer_col)
	local source_line = segment.source_lines[local_row + 1] or ""
	local visible = vim.api.nvim_buf_get_lines(
		state.buf,
		segment.notebook_start_row + local_row,
		segment.notebook_start_row + local_row + 1,
		false
	)[1] or ""
	if visible == "\\" .. source_line then
		return math.max(0, buffer_col - 1), 1
	end
	return buffer_col, 0
end

local function encoding_column(line, byte_col, encoding)
	byte_col = math.max(0, math.min(byte_col, #line))
	if encoding == "utf-8" then
		return byte_col
	end
	local ok, result = pcall(vim.str_utfindex, line, encoding or "utf-16", byte_col, false)
	return ok and result or byte_col
end

local function byte_column(line, character, encoding)
	if encoding == "utf-8" then
		return math.max(0, math.min(character, #line))
	end
	local ok, result = pcall(vim.str_byteindex, line, encoding or "utf-16", character, false)
	return ok and result or character
end

function Manager:document(lang)
	return self.documents[language.normalize(lang)]
end

function Manager:document_for_uri(uri)
	for _, document in pairs(self.documents) do
		if document.uri == uri then
			return document
		end
	end
	return nil
end

local function transformed_at(segment, local_row, col)
	local value = segment.transformed_lines[local_row + 1]
	if value == true then
		return true
	end
	for _, range in ipairs(type(value) == "table" and value or {}) do
		if col >= range.start_col and col < range.end_col then
			return true
		end
	end
	return false
end

local function range_touches_transformed(document, range, encoding)
	for _, segment in ipairs(document.segments) do
		local first_row = math.max(range.start.line, segment.shadow_start_row)
		local last_row = math.min(range["end"].line, segment.shadow_end_exclusive - 1)
		for shadow_row = first_row, last_row do
			local local_row = shadow_row - segment.shadow_start_row
			local line = segment.source_lines[local_row + 1] or ""
			local start_col = shadow_row == range.start.line and byte_column(line, range.start.character, encoding) or 0
			local end_col = shadow_row == range["end"].line and byte_column(line, range["end"].character, encoding)
				or #line
			local value = segment.transformed_lines[local_row + 1]
			if value == true then
				return true
			end
			for _, transformed_range in ipairs(type(value) == "table" and value or {}) do
				if start_col == end_col then
					if start_col >= transformed_range.start_col and start_col < transformed_range.end_col then
						return true
					end
				elseif start_col < transformed_range.end_col and end_col > transformed_range.start_col then
					return true
				end
			end
		end
	end
	return false
end

function Manager:notebook_to_shadow(row, byte_col, encoding)
	for _, document in pairs(self.documents) do
		for _, segment in ipairs(document.segments) do
			if row >= segment.notebook_start_row and row < segment.notebook_end_exclusive then
				local local_row = row - segment.notebook_start_row
				if local_row >= #segment.source_lines then
					return nil, "position is outside editable cell source"
				end
				local source_col = source_byte_column(self.state, segment, local_row, byte_col)
				return {
					document = document,
					cell_id = segment.cell_id,
					transformed = transformed_at(segment, local_row, source_col),
					position = {
						line = segment.shadow_start_row + local_row,
						character = encoding_column(segment.source_lines[local_row + 1], source_col, encoding),
					},
				}
			end
		end
	end
	return nil, "position is not inside a code cell"
end

function Manager:shadow_to_notebook(document, position, encoding)
	for _, segment in ipairs(document.segments) do
		if position.line >= segment.shadow_start_row and position.line < segment.shadow_end_exclusive then
			local local_row = position.line - segment.shadow_start_row
			local source_line = segment.source_lines[local_row + 1] or ""
			local col = byte_column(source_line, position.character, encoding)
			local _, visible_offset = source_byte_column(self.state, segment, local_row, col)
			return {
				buf = self.state.buf,
				cell_id = segment.cell_id,
				row = segment.notebook_start_row + local_row,
				col = col + visible_offset,
				transformed = transformed_at(segment, local_row, col),
			}
		end
	end
	return nil, "shadow position touches a synthetic separator"
end

function Manager:range_to_notebook(document, range, encoding)
	local start_position, start_error = self:shadow_to_notebook(document, range.start, encoding)
	if not start_position then
		return nil, start_error
	end
	local end_position, end_error = self:shadow_to_notebook(document, range["end"], encoding)
	if not end_position then
		return nil, end_error
	end
	if start_position.cell_id ~= end_position.cell_id then
		return nil, "edit crosses a cell boundary"
	end
	if
		start_position.transformed
		or end_position.transformed
		or range_touches_transformed(document, range, encoding)
	then
		return nil, "edit touches an IPython magic placeholder"
	end
	return {
		start = { line = start_position.row, character = start_position.col },
		["end"] = { line = end_position.row, character = end_position.col },
		cell_id = start_position.cell_id,
	}
end

function Manager:update()
	local state = self.state
	local current_fingerprint = source_fingerprint(state)
	if self.fingerprint == current_fingerprint then
		return false
	end
	self.fingerprint = current_fingerprint
	self.version = self.version + 1

	local grouped = {}
	for index, cell in ipairs(state.cells) do
		if cell.cell_type == "code" then
			local lang = language.for_cell(state, cell)
			grouped[lang] = grouped[lang] or {}
			table.insert(grouped[lang], { cell = cell, index = index })
		end
	end

	for lang, document in pairs(self.documents) do
		if not grouped[lang] then
			destroy_document(document)
			self.documents[lang] = nil
		end
	end

	for lang, cells in pairs(grouped) do
		local document = self.documents[lang]
		if not document or not vim.api.nvim_buf_is_valid(document.buf) then
			document = create_document(state, lang)
			self.documents[lang] = document
		end
		local lines, segments = build_document(state, lang, cells)
		vim.bo[document.buf].modifiable = true
		vim.api.nvim_buf_set_lines(document.buf, 0, -1, false, lines)
		vim.bo[document.buf].modifiable = false
		vim.bo[document.buf].modified = false
		document.segments = segments
		document.version = self.version
		document.uri = vim.uri_from_bufnr(document.buf)
	end

	return true
end

function Manager:destroy()
	for _, document in pairs(self.documents) do
		destroy_document(document)
	end
	self.documents = {}
end

function M.get(state)
	if not state.shadow then
		state.shadow = setmetatable({
			state = state,
			documents = {},
			version = 0,
		}, Manager)
	end
	return state.shadow
end

function M.update(state)
	local manager = M.get(state)
	return manager:update(), manager
end

function M.detach(state)
	if state and state.shadow then
		state.shadow:destroy()
		state.shadow = nil
	end
end

M.Manager = Manager
M.transform_source = transform_source
M.encoding_column = encoding_column
M.byte_column = byte_column

return M
