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
