local language = require("nvjup.language")
local markdown = require("nvjup.markdown")
local notebook = require("nvjup.notebook")
local render = require("nvjup.render")

local M = {}

local function state()
	return assert(notebook.get(), "current buffer is not an nvjup notebook")
end

local function refresh(value)
	render.render(state())
	return value
end

function M.next_cell(options)
	options = options or {}
	local nb = state()
	assert(nb:sync_from_buffer())
	local _, index = nb:current_cell()
	local direction = options.direction or 1
	local count = options.count or vim.v.count1
	local predicate = options.code_only and function(cell)
		return cell.cell_type == "code"
	end or nil
	local target = index
	for _ = 1, count do
		local found = nb:find_cell(target, direction, predicate)
		if not found then
			break
		end
		target = found
	end
	if target ~= index then
		nb:goto_cell(target)
	end
	return refresh(target)
end

function M.previous_cell(options)
	options = options or {}
	options.direction = -1
	return M.next_cell(options)
end

local function line_last_column(row)
	local line = vim.api.nvim_buf_get_lines(0, row, row + 1, false)[1] or ""
	local characters = vim.fn.strchars(line)
	return characters > 0 and vim.fn.byteidx(line, characters - 1) or 0
end

local function cursor_column(row, column)
	return math.min(column, line_last_column(row))
end

function M.cursor_vertical(direction)
	direction = direction < 0 and -1 or 1
	local nb = state()
	local count = vim.v.count1
	for _ = 1, count do
		local cursor = vim.api.nvim_win_get_cursor(0)
		local row, column = cursor[1] - 1, cursor[2]
		local index = nb:cell_index_at(row)
		local cell = index and nb.cells[index] or nil
		if not cell then
			return
		end
		local target_row
		if direction > 0 and row >= cell.range.end_row then
			local target = nb.cells[index + 1]
			target_row = target and target.range.start_row or nil
		elseif direction < 0 and row <= cell.range.start_row then
			local target = nb.cells[index - 1]
			target_row = target and target.range.end_row or nil
		else
			target_row = row + direction
		end
		if not target_row then
			return
		end
		vim.api.nvim_win_set_cursor(0, { target_row + 1, cursor_column(target_row, column) })
	end
end

function M.cursor_horizontal(direction)
	direction = direction < 0 and -1 or 1
	local nb = state()
	for _ = 1, vim.v.count1 do
		local cursor = vim.api.nvim_win_get_cursor(0)
		local row, column = cursor[1] - 1, cursor[2]
		local index = nb:cell_index_at(row)
		local cell = index and nb.cells[index] or nil
		if not cell then
			return
		end
		if direction < 0 then
			if column > 0 then
				vim.cmd("normal! h")
			elseif row > cell.range.start_row then
				vim.api.nvim_win_set_cursor(0, { row, line_last_column(row - 1) })
			else
				return
			end
		else
			if column < line_last_column(row) then
				vim.cmd("normal! l")
			elseif row < cell.range.end_row then
				vim.api.nvim_win_set_cursor(0, { row + 2, 0 })
			else
				return
			end
		end
	end
end

local function escaped(value)
	return vim.pesc and vim.pesc(value) or value:gsub("([^%w])", "%%%1")
end

local function commented(line, left, right)
	if line:match("^%s*$") then
		return nil
	end
	local body = line:match("^%s*(.*)$") or line
	if not body:match("^" .. escaped(left)) then
		return false
	end
	return right == "" or body:match(escaped(right) .. "%s*$") ~= nil
end

local function comment_line(line, left, right, remove)
	if line:match("^%s*$") then
		return line
	end
	local indent, body = line:match("^(%s*)(.*)$")
	if remove then
		body = body:gsub("^" .. escaped(left) .. "%s?", "", 1)
		if right ~= "" then
			body = body:gsub("%s?" .. escaped(right) .. "%s*$", "", 1)
		end
		return indent .. body
	end
	return indent .. left .. " " .. body .. (right ~= "" and (" " .. right) or "")
end

function M.toggle_comment(start_row, end_row)
	local nb = state()
	assert(nb:sync_from_buffer())
	start_row = math.max(0, start_row or (vim.api.nvim_win_get_cursor(0)[1] - 1))
	end_row = math.min(vim.api.nvim_buf_line_count(nb.buf) - 1, end_row or start_row)
	if start_row > end_row then
		start_row, end_row = end_row, start_row
	end
	local lines = vim.api.nvim_buf_get_lines(nb.buf, start_row, end_row + 1, false)
	local groups = {}
	for row = start_row, end_row do
		local index = nb:cell_index_at(row)
		local cell = index and nb.cells[index] or nil
		if cell and row >= cell.range.start_row and row <= cell.range.end_row then
			local group = groups[index]
			if not group then
				local left, right = language.comment_parts(language.for_cell(nb, cell))
				group = { left = left, right = right, rows = {} }
				groups[index] = group
			end
			table.insert(group.rows, row)
		end
	end
	local changed = 0
	for _, group in pairs(groups) do
		local remove = true
		local content = false
		for _, row in ipairs(group.rows) do
			local status = commented(lines[row - start_row + 1], group.left, group.right)
			if status ~= nil then
				content = true
				remove = remove and status
			end
		end
		if content then
			for _, row in ipairs(group.rows) do
				local offset = row - start_row + 1
				local updated = comment_line(lines[offset], group.left, group.right, remove)
				if updated ~= lines[offset] then
					lines[offset] = updated
					changed = changed + 1
				end
			end
		end
	end
	if changed == 0 then
		return 0
	end
	nb.internal_change = true
	vim.api.nvim_buf_set_lines(nb.buf, start_row, end_row + 1, false, lines)
	nb.internal_change = false
	local ok, changed_cells, structural = nb:sync_from_buffer()
	assert(ok)
	render.request_source(nb, changed_cells, structural, 0)
	return changed
end

function M.update_commentstring()
	local nb = notebook.get()
	if not nb then
		return
	end
	local cell = nb:current_cell()
	if cell then
		vim.bo[nb.buf].commentstring = language.commentstring(language.for_cell(nb, cell))
	end
end

function M.comment_current_line()
	local row = vim.api.nvim_win_get_cursor(0)[1] - 1
	return M.toggle_comment(row, row)
end

function M.comment_visual()
	local anchor = vim.fn.getpos("v")[2] - 1
	local cursor = vim.api.nvim_win_get_cursor(0)[1] - 1
	vim.cmd.normal({ args = { vim.keycode("<Esc>") }, bang = true })
	return M.toggle_comment(math.min(anchor, cursor), math.max(anchor, cursor))
end

function M.insert_below(cell_type)
	local nb = state()
	local _, index = nb:current_cell()
	local cell = nb:insert_cell(index + 1, cell_type or "code")
	return refresh(cell)
end

function M.insert_above(cell_type)
	local nb = state()
	local _, index = nb:current_cell()
	local cell = nb:insert_cell(index, cell_type or "code")
	return refresh(cell)
end

function M.duplicate_cell()
	local nb = state()
	local _, index = nb:current_cell()
	return refresh(nb:duplicate_cell(index))
end

function M.delete_cell()
	local nb = state()
	local _, index = nb:current_cell()
	nb:delete_cell(index)
	refresh()
end

function M.move_up()
	local nb = state()
	local _, index = nb:current_cell()
	return refresh(nb:move_cell(index, -1))
end

function M.move_down()
	local nb = state()
	local _, index = nb:current_cell()
	return refresh(nb:move_cell(index, 1))
end

function M.change_type(cell_type)
	local nb = state()
	local cell, index = nb:current_cell()
	if not cell_type or cell_type == "" then
		local next_type = { code = "markdown", markdown = "raw", raw = "code" }
		cell_type = next_type[cell.cell_type]
	end
	nb:set_cell_type(index, cell_type)
	return refresh(cell_type)
end

function M.split_cell()
	local nb = state()
	local _, index = nb:current_cell()
	local cursor = vim.api.nvim_win_get_cursor(0)
	local cell = nb:split_cell(index, cursor[1] - 1, cursor[2])
	return refresh(cell)
end

function M.merge_below()
	local nb = state()
	local _, index = nb:current_cell()
	return refresh(nb:merge_below(index))
end

function M.clear_output()
	local nb = state()
	local cell, index = nb:current_cell()
	require("nvjup.kernel").forget_displays(nb, cell.id)
	return refresh(nb:clear_output(index))
end

function M.clear_all_outputs()
	local nb = state()
	require("nvjup.kernel").forget_displays(nb)
	return refresh(nb:clear_all_outputs())
end

function M.toggle_output()
	local nb = state()
	local _, index = nb:current_cell()
	return refresh(nb:toggle_output(index))
end

function M.open_output(mode)
	local cell = state():current_cell()
	return require("nvjup.output").open(cell, mode)
end

function M.plot_focus()
	local nb = state()
	local cell = nb:current_cell()
	return require("nvjup.interactive").open_external(nb, cell)
end

function M.plot_focus_tui()
	local nb = state()
	local cell = nb:current_cell()
	return require("nvjup.interactive").open_focus(nb, cell)
end

function M.toggle_source()
	local nb = state()
	assert(nb:sync_from_buffer())
	local cell = nb:current_cell()
	if cell.cell_type == "markdown" and markdown.enabled() then
		local rendered = markdown.toggle(nb, cell)
		render.render(nb)
		return rendered
	end
	local start_line = cell.range.start_row + 1
	local end_line = cell.range.end_row + 1
	if vim.fn.foldclosed(start_line) >= 0 then
		vim.cmd(string.format("%dfoldopen", start_line))
		return false
	end
	vim.wo.foldmethod = "manual"
	vim.wo.foldenable = true
	vim.cmd(string.format("%d,%dfold", start_line, end_line))
	vim.cmd(string.format("%dfoldclose", start_line))
	return true
end

function M.select_cell(around)
	local nb = state()
	assert(nb:sync_from_buffer())
	local cell = nb:current_cell()
	local start_row = around and cell.range.marker_row or cell.range.start_row
	local end_row = cell.range.end_row
	vim.api.nvim_win_set_cursor(0, { start_row + 1, 0 })
	vim.cmd("normal! V")
	vim.api.nvim_win_set_cursor(0, { end_row + 1, 0 })
end

function M.outline()
	local nb = state()
	local items = nb:outline_items()
	if require("nvjup.telescope").outline(nb, items) then
		return
	end
	vim.ui.select(items, {
		prompt = "Notebook cells",
		format_item = function(item)
			return item.label
		end,
	}, function(item)
		if item then
			nb:goto_cell(item.index)
			render.render(nb)
		end
	end)
end

function M.variables()
	return require("nvjup.inspector").open(state())
end

function M.remote_connection()
	return require("nvjup.remote_connection").open(state())
end

function M.remote_files()
	return require("nvjup.remote_files").open(state())
end

function M.refresh()
	local nb = state()
	local ok, err = nb:sync_from_buffer()
	if not ok then
		vim.notify("nvjup: " .. err, vim.log.levels.ERROR)
		return nil, err
	end
	render.render(nb)
	return true
end

return M
