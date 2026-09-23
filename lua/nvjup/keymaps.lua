local actions = require("nvjup.actions")
local config = require("nvjup.config")

local M = {}

local function map(buf, modes, lhs, rhs, description)
	if lhs == false or lhs == nil or lhs == "" then
		return
	end
	vim.keymap.set(modes, lhs, rhs, { buffer = buf, silent = true, desc = description })
end

function M.attach(buf)
	local keys = config.options.keymaps
	map(buf, { "n", "x", "o" }, keys.next_cell, actions.next_cell, "Next notebook cell")
	map(buf, { "n", "x", "o" }, keys.previous_cell, actions.previous_cell, "Previous notebook cell")
	map(buf, { "n", "x", "o" }, keys.next_code_cell, function()
		actions.next_cell({ code_only = true })
	end, "Next code cell")
	map(buf, { "n", "x", "o" }, keys.previous_code_cell, function()
		actions.previous_cell({ code_only = true })
	end, "Previous code cell")
	map(buf, { "x", "o" }, keys.inner_cell, function()
		actions.select_cell(false)
	end, "Inner notebook cell")
	map(buf, { "x", "o" }, keys.around_cell, function()
		actions.select_cell(true)
	end, "Around notebook cell")
	map(buf, "n", keys.insert_below, actions.insert_below, "Insert cell below")
	map(buf, "n", keys.insert_above, actions.insert_above, "Insert cell above")
	map(buf, "n", keys.duplicate_cell, actions.duplicate_cell, "Duplicate cell")
	map(buf, "n", keys.delete_cell, actions.delete_cell, "Delete cell")
	map(buf, "n", keys.move_up, actions.move_up, "Move cell up")
	map(buf, "n", keys.move_down, actions.move_down, "Move cell down")
	map(buf, "n", keys.split_cell, actions.split_cell, "Split cell")
	map(buf, "n", keys.merge_below, actions.merge_below, "Merge cell below")
	map(buf, "n", keys.change_type, actions.change_type, "Change cell type")
	map(buf, "n", keys.toggle_source, actions.toggle_source, "Toggle cell source")
	map(buf, "n", keys.toggle_output, actions.toggle_output, "Toggle cell output")
	map(buf, "n", keys.clear_output, actions.clear_output, "Clear cell output")
	map(buf, "n", keys.outline, actions.outline, "Notebook outline")
end

return M
