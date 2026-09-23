local util = require("nvjup.util")

local M = {}
local Notebook = {}
Notebook.__index = Notebook

M.MARKER_PREFIX = "# %%[nvjup:cell "

local notebooks = {}

local function parse_marker(line)
	if line:sub(1, #M.MARKER_PREFIX) ~= M.MARKER_PREFIX or line:sub(-1) ~= "]" then
		return nil
	end
	local body = line:sub(#M.MARKER_PREFIX + 1, -2)
	local id, cell_type = body:match("^id=([%w_-]+) type=(%a+)$")
	if not id or not vim.tbl_contains({ "code", "markdown", "raw" }, cell_type) then
		return nil
	end
	return id, cell_type
end

local function marker(cell)
	return string.format("%sid=%s type=%s]", M.MARKER_PREFIX, cell.id, cell.cell_type)
end

local function encode_source_line(line)
	if parse_marker(line) then
		return "\\" .. line
	end
	return line
end

local function decode_source_line(line)
	if line:sub(1, 1) == "\\" and parse_marker(line:sub(2)) then
		return line:sub(2)
	end
	return line
end

local function existing_ids(state)
	local ids = {}
	for id in pairs(state.cell_store) do
		ids[id] = true
	end
	return ids
end

local function initial_execution_status(outputs, execution_count)
	for _, item in ipairs(outputs or {}) do
		if item.output_type == "error" then
			return "failed"
		end
	end
	if execution_count ~= nil and execution_count ~= vim.NIL then
		return "completed"
	end
	return "not_executed"
end

local function wrap_cell(state, raw)
	raw = vim.deepcopy(raw)
	local had_id = type(raw.id) == "string" and raw.id ~= ""
	local id = had_id and raw.id or util.new_cell_id(existing_ids(state))
	local cell_type = vim.tbl_contains({ "code", "markdown", "raw" }, raw.cell_type) and raw.cell_type or "raw"
	local source = util.source_to_string(raw.source)
	local outputs = raw.outputs or {}
	local cell = {
		id = id,
		had_id = had_id,
		is_new = false,
		cell_type = cell_type,
		source = source,
		outputs = outputs,
		execution_count = raw.execution_count,
		raw = raw,
		range = {},
		revision = 0,
		execution_status = initial_execution_status(outputs, raw.execution_count),
		stale = false,
		last_executed_source = (#outputs > 0 or (raw.execution_count ~= nil and raw.execution_count ~= vim.NIL))
				and source
			or nil,
		display_ids = {},
	}
	state.cell_store[id] = cell
	return cell
end

local function new_raw_cell(cell_type, id)
	if cell_type == "code" then
		return {
			cell_type = "code",
			execution_count = vim.NIL,
			id = id,
			metadata = {},
			outputs = {},
			source = "",
		}
	end
	return {
		cell_type = cell_type,
		id = id,
		metadata = {},
		source = "",
	}
end

local function create_cell(state, cell_type, source)
	local id = util.new_cell_id(existing_ids(state))
	local raw = new_raw_cell(cell_type, id)
	local cell = {
		id = id,
		had_id = true,
		is_new = true,
		cell_type = cell_type,
		source = source or "",
		outputs = raw.outputs or {},
		execution_count = nil,
		raw = raw,
		range = {},
		revision = 0,
		execution_status = "not_executed",
		stale = false,
		display_ids = {},
	}
	state.cell_store[id] = cell
	return cell
end

local function clear_execution(cell)
	if cell.cell_type == "code" then
		cell.outputs = {}
		cell.execution_count = nil
		cell.raw.outputs = {}
		cell.raw.execution_count = vim.NIL
		cell.saved_code_state = nil
		cell.execution_status = "not_executed"
		cell.stale = false
		cell.last_executed_source = nil
		cell.display_ids = {}
	end
end

local function update_source(cell, source)
	if source == cell.source then
		return false
	end
	cell.source = source
	cell.revision = (cell.revision or 0) + 1
	if cell.cell_type == "code" then
		local has_result = cell.last_executed_source ~= nil
			or cell.execution_status == "running"
			or cell.execution_status == "waiting_input"
			or cell.execution_status == "queued"
		if has_result and source ~= cell.last_executed_source then
			cell.stale = true
		end
	end
	return true
end

local function apply_cell_type(cell, cell_type)
	if cell.cell_type == cell_type then
		return
	end
	if cell.cell_type == "code" then
		cell.saved_code_state = {
			outputs = vim.deepcopy(cell.outputs or {}),
			execution_count = cell.execution_count,
		}
	end
	if cell_type == "code" then
		local saved = cell.saved_code_state
		cell.outputs = saved and vim.deepcopy(saved.outputs) or cell.raw.outputs or {}
		cell.execution_count = saved and saved.execution_count or cell.raw.execution_count
		cell.execution_status = initial_execution_status(cell.outputs, cell.execution_count)
		cell.last_executed_source = (
			#cell.outputs > 0 or (cell.execution_count ~= nil and cell.execution_count ~= vim.NIL)
		)
				and cell.source
			or nil
	else
		cell.outputs = {}
		cell.execution_count = nil
		cell.execution_status = "not_executed"
		cell.stale = false
		cell.last_executed_source = nil
	end
	cell.cell_type = cell_type
end

function Notebook:_build_buffer_lines()
	local lines = {}
	for _, cell in ipairs(self.cells) do
		table.insert(lines, marker(cell))
		for _, source_line in ipairs(util.source_to_lines(cell.source)) do
			table.insert(lines, encode_source_line(source_line))
		end
	end
	if #lines == 0 then
		local cell = create_cell(self, "code", "")
		self.cells = { cell }
		return self:_build_buffer_lines()
	end
	return lines
end

function Notebook:_rebuild_ranges()
	local lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
	local marker_rows = {}
	for row, line in ipairs(lines) do
		if parse_marker(line) then
			table.insert(marker_rows, row - 1)
		end
	end

	for index, cell in ipairs(self.cells) do
		local marker_row = marker_rows[index]
		if marker_row then
			local next_marker = marker_rows[index + 1] or #lines
			cell.range = {
				marker_row = marker_row,
				start_row = marker_row + 1,
				end_row = math.max(marker_row + 1, next_marker - 1),
				end_exclusive = next_marker,
			}
		end
	end
end

function Notebook:replace_buffer(options)
	options = options or {}
	local cursor
	if vim.api.nvim_get_current_buf() == self.buf then
		cursor = vim.api.nvim_win_get_cursor(0)
	end

	self.internal_change = true
	vim.bo[self.buf].modifiable = true
	vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, self:_build_buffer_lines())
	self.internal_change = false
	self:_rebuild_ranges()

	if cursor and options.restore_cursor ~= false then
		local line_count = vim.api.nvim_buf_line_count(self.buf)
		pcall(vim.api.nvim_win_set_cursor, 0, { math.min(cursor[1], line_count), cursor[2] })
	end
end

function Notebook:sync_from_buffer()
	if self.internal_change or not vim.api.nvim_buf_is_valid(self.buf) then
		return true
	end

	local lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
	local parsed = {}
	local current
	local seen = {}

	for row, line in ipairs(lines) do
		local id, cell_type = parse_marker(line)
		if id then
			if seen[id] then
				return nil, string.format("duplicate cell id %s on line %d", id, row)
			end
			seen[id] = true
			current = { id = id, cell_type = cell_type, marker_row = row - 1, lines = {} }
			table.insert(parsed, current)
		elseif not current then
			return nil, "content exists before the first nvjup cell marker"
		else
			table.insert(current.lines, decode_source_line(line))
		end
	end

	if #parsed == 0 then
		return nil, "notebook buffer contains no nvjup cell markers"
	end

	local cells = {}
	for index, entry in ipairs(parsed) do
		local cell = self.cell_store[entry.id]
		if not cell then
			local raw = new_raw_cell(entry.cell_type, entry.id)
			cell = {
				id = entry.id,
				had_id = true,
				is_new = true,
				cell_type = entry.cell_type,
				source = "",
				outputs = raw.outputs or {},
				execution_count = nil,
				raw = raw,
				range = {},
				revision = 0,
				execution_status = "not_executed",
				stale = false,
				display_ids = {},
			}
			self.cell_store[entry.id] = cell
		end

		apply_cell_type(cell, entry.cell_type)
		update_source(cell, util.lines_to_source(entry.lines))
		local next_marker = parsed[index + 1] and parsed[index + 1].marker_row or #lines
		cell.range = {
			marker_row = entry.marker_row,
			start_row = entry.marker_row + 1,
			end_row = math.max(entry.marker_row + 1, next_marker - 1),
			end_exclusive = next_marker,
		}
		table.insert(cells, cell)
	end

	self.cells = cells
	return true
end

function Notebook:cell_index_at(row)
	row = row or (vim.api.nvim_win_get_cursor(0)[1] - 1)
	for index, cell in ipairs(self.cells) do
		if row >= cell.range.marker_row and row < cell.range.end_exclusive then
			return index
		end
	end
	return #self.cells > 0 and #self.cells or nil
end

function Notebook:current_cell()
	local index = self:cell_index_at()
	return self.cells[index], index
end

function Notebook:cell_by_id(id)
	local cell = self.cell_store[id]
	if not cell then
		return nil
	end
	for index, candidate in ipairs(self.cells) do
		if candidate == cell then
			return cell, index
		end
	end
	return nil
end

function Notebook:goto_cell(index)
	index = math.max(1, math.min(index, #self.cells))
	local cell = self.cells[index]
	if not cell then
		return
	end
	vim.cmd("normal! m'")
	vim.api.nvim_win_set_cursor(0, { cell.range.start_row + 1, 0 })
	return index
end

function Notebook:find_cell(from, direction, predicate)
	local index = from + direction
	while index >= 1 and index <= #self.cells do
		if not predicate or predicate(self.cells[index]) then
			return index
		end
		index = index + direction
	end
	return nil
end

function Notebook:insert_cell(index, cell_type)
	assert(self:sync_from_buffer())
	index = math.max(1, math.min(index, #self.cells + 1))
	local cell = create_cell(self, cell_type or "code", "")
	table.insert(self.cells, index, cell)
	self:replace_buffer({ restore_cursor = false })
	vim.bo[self.buf].modified = true
	self:goto_cell(index)
	return cell
end

function Notebook:duplicate_cell(index)
	assert(self:sync_from_buffer())
	local original = assert(self.cells[index], "invalid cell index")
	local raw = vim.deepcopy(original.raw)
	local id = util.new_cell_id(existing_ids(self))
	raw.id = id
	raw.source = original.source
	if original.cell_type == "code" then
		raw.outputs = {}
		raw.execution_count = vim.NIL
	end
	local duplicate = wrap_cell(self, raw)
	duplicate.is_new = true
	table.insert(self.cells, index + 1, duplicate)
	self:replace_buffer({ restore_cursor = false })
	vim.bo[self.buf].modified = true
	self:goto_cell(index + 1)
	return duplicate
end

function Notebook:delete_cell(index)
	assert(self:sync_from_buffer())
	if #self.cells == 1 then
		local cell = self.cells[1]
		update_source(cell, "")
		clear_execution(cell)
		self:replace_buffer({ restore_cursor = false })
		vim.bo[self.buf].modified = true
		self:goto_cell(1)
		return
	end
	table.remove(self.cells, index)
	self:replace_buffer({ restore_cursor = false })
	vim.bo[self.buf].modified = true
	self:goto_cell(math.min(index, #self.cells))
end

function Notebook:move_cell(index, direction)
	assert(self:sync_from_buffer())
	local target = index + direction
	if target < 1 or target > #self.cells then
		return index
	end
	self.cells[index], self.cells[target] = self.cells[target], self.cells[index]
	self:replace_buffer({ restore_cursor = false })
	vim.bo[self.buf].modified = true
	self:goto_cell(target)
	return target
end

function Notebook:set_cell_type(index, cell_type)
	assert(self:sync_from_buffer())
	local cell = assert(self.cells[index], "invalid cell index")
	assert(vim.tbl_contains({ "code", "markdown", "raw" }, cell_type), "invalid cell type")
	apply_cell_type(cell, cell_type)
	if cell_type == "code" and cell.execution_count == nil then
		cell.execution_count = vim.NIL
	end
	self:replace_buffer({ restore_cursor = false })
	vim.bo[self.buf].modified = true
	self:goto_cell(index)
end

function Notebook:split_cell(index, row, column)
	assert(self:sync_from_buffer())
	local cell = assert(self.cells[index], "invalid cell index")
	local lines = util.source_to_lines(cell.source)
	local local_row = math.max(1, math.min(row - cell.range.start_row + 1, #lines))
	local line = lines[local_row]
	column = math.max(0, math.min(column, #line))

	local before = {}
	for line_index = 1, local_row - 1 do
		table.insert(before, lines[line_index])
	end
	table.insert(before, line:sub(1, column))

	local after = { line:sub(column + 1) }
	for line_index = local_row + 1, #lines do
		table.insert(after, lines[line_index])
	end

	update_source(cell, util.lines_to_source(before))
	clear_execution(cell)
	local new_cell = create_cell(self, cell.cell_type, util.lines_to_source(after))
	table.insert(self.cells, index + 1, new_cell)
	self:replace_buffer({ restore_cursor = false })
	vim.bo[self.buf].modified = true
	self:goto_cell(index + 1)
	return new_cell
end

function Notebook:clear_output(index)
	assert(self:sync_from_buffer())
	local cell = assert(self.cells[index], "invalid cell index")
	clear_execution(cell)
	cell.output_collapsed = false
	vim.bo[self.buf].modified = true
	return true
end

function Notebook:clear_all_outputs()
	assert(self:sync_from_buffer())
	for _, cell in ipairs(self.cells) do
		clear_execution(cell)
		cell.output_collapsed = false
	end
	vim.bo[self.buf].modified = true
	return true
end

function Notebook:toggle_output(index)
	local cell = assert(self.cells[index], "invalid cell index")
	cell.output_collapsed = not cell.output_collapsed
	return cell.output_collapsed
end

function Notebook:merge_below(index)
	assert(self:sync_from_buffer())
	if index >= #self.cells then
		return false
	end
	local cell = self.cells[index]
	local below = self.cells[index + 1]
	local separator = (cell.source == "" or below.source == "") and "" or "\n"
	update_source(cell, cell.source .. separator .. below.source)
	clear_execution(cell)
	table.remove(self.cells, index + 1)
	self:replace_buffer({ restore_cursor = false })
	vim.bo[self.buf].modified = true
	self:goto_cell(index)
	return true
end

function Notebook:outline_items()
	assert(self:sync_from_buffer())
	local items = {}
	for index, cell in ipairs(self.cells) do
		local first = cell.source:match("([^\n]+)") or ""
		first = vim.trim(first:gsub("^#+%s*", ""))
		if first == "" then
			first = "<empty>"
		end
		local count = cell.execution_count ~= nil and cell.execution_count ~= vim.NIL and tostring(cell.execution_count)
			or " "
		if cell.stale or cell.execution_status == "stale" then
			count = "*"
		elseif cell.execution_status == "queued" or cell.execution_status == "sent" then
			count = "…"
		elseif cell.execution_status == "running" then
			count = "▶"
		elseif cell.execution_status == "waiting_input" then
			count = "?"
		elseif cell.execution_status == "failed" then
			count = "!"
		elseif cell.execution_status == "cancelled" then
			count = "×"
		end
		table.insert(items, {
			index = index,
			cell = cell,
			label = string.format("%3d  [%s]  %-8s %s", index, count, cell.cell_type, first),
		})
	end
	return items
end

function Notebook:save(path)
	local ok, err = self:sync_from_buffer()
	if not ok then
		return nil, err
	end

	local raw_cells = {}
	for _, cell in ipairs(self.cells) do
		local raw = cell.raw
		raw.cell_type = cell.cell_type
		raw.source = cell.source
		raw.metadata = raw.metadata or {}
		if cell.had_id or cell.is_new then
			raw.id = cell.id
		else
			raw.id = nil
		end
		if cell.cell_type == "code" then
			raw.outputs = cell.outputs or {}
			raw.execution_count = cell.execution_count == nil and vim.NIL or cell.execution_count
		else
			raw.outputs = nil
			raw.execution_count = nil
		end
		table.insert(raw_cells, raw)
	end
	self.document.cells = raw_cells

	local encoded_ok, encoded = pcall(vim.json.encode, self.document)
	if not encoded_ok then
		return nil, encoded
	end
	local written, write_err = util.atomic_write(path or self.path, encoded .. "\n")
	if not written then
		return nil, write_err
	end

	self.path = path or self.path
	vim.bo[self.buf].modified = false
	return true
end

function M.get(buf)
	return notebooks[buf or vim.api.nvim_get_current_buf()]
end

function M.all()
	return notebooks
end

function M.open(buf, path, document)
	local state = setmetatable({
		buf = buf,
		path = path,
		document = document,
		cells = {},
		cell_store = {},
		internal_change = false,
		render_ns = vim.api.nvim_create_namespace("nvjup-render-" .. buf),
		marker_ns = vim.api.nvim_create_namespace("nvjup-markers-" .. buf),
		treesitter_ns = vim.api.nvim_create_namespace("nvjup-treesitter-" .. buf),
		lsp_diagnostic_ns = vim.api.nvim_create_namespace("nvjup-lsp-diagnostics-" .. buf),
		lsp_semantic_ns = vim.api.nvim_create_namespace("nvjup-lsp-semantic-" .. buf),
	}, Notebook)

	document.metadata = document.metadata or {}
	document.cells = document.cells or {}
	for _, raw in ipairs(document.cells) do
		table.insert(state.cells, wrap_cell(state, raw))
	end
	if #state.cells == 0 then
		table.insert(state.cells, create_cell(state, "code", ""))
	end

	notebooks[buf] = state
	state:replace_buffer({ restore_cursor = false })
	return state
end

function M.load(buf, path)
	local content, read_err = util.read_file(path)
	if not content then
		return nil, read_err
	end
	local ok, document = pcall(vim.json.decode, content)
	if not ok then
		return nil, document
	end
	if type(document) ~= "table" or document.nbformat ~= 4 or type(document.cells) ~= "table" then
		return nil, "unsupported or invalid notebook: expected nbformat 4"
	end
	return M.open(buf, path, document)
end

function M.create(buf, path)
	return M.open(buf, path, {
		cells = {},
		metadata = {
			kernelspec = { display_name = "Python 3", language = "python", name = "python3" },
			language_info = { name = "python" },
		},
		nbformat = 4,
		nbformat_minor = 5,
	})
end

function M.detach(buf)
	notebooks[buf] = nil
end

M.Notebook = Notebook
M.parse_marker = parse_marker
M.marker = marker

return M
