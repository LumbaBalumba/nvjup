local M = {}

M.defaults = {
	border_width = 88,
	render = {
		outputs = true,
		max_output_lines = 12,
		markdown = true,
		right_border = true,
	},
	keymaps = {
		next_cell = "]c",
		previous_cell = "[c",
		next_code_cell = "]C",
		previous_code_cell = "[C",
		inner_cell = "ic",
		around_cell = "ac",
		insert_below = "<localleader>jo",
		insert_above = "<localleader>jO",
		duplicate_cell = "<localleader>jy",
		delete_cell = "<localleader>jd",
		move_up = "<localleader>jk",
		move_down = "<localleader>jj",
		split_cell = "<localleader>js",
		merge_below = "<localleader>jm",
		change_type = "<localleader>jt",
		toggle_source = "<localleader>jz",
		toggle_output = "<localleader>jx",
		clear_output = "<localleader>jc",
		outline = "<localleader>jl",
	},
}

M.options = vim.deepcopy(M.defaults)

function M.setup(options)
	M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), options or {})
	return M.options
end

return M
