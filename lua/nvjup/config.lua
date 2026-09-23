local M = {}

M.defaults = {
	border_width = 88,
	render = {
		outputs = true,
		max_output_lines = 12,
		markdown = true,
		right_border = true,
	},
	treesitter = {
		enabled = true,
		priority = 105,
	},
	sidecar = {
		command = false,
		python = false,
		request_timeout_ms = 60000,
		stderr_limit = 16384,
	},
	kernel = {
		default_name = "python3",
		start_timeout_seconds = 30,
		shutdown_on_close = true,
	},
	execution = {
		allow_stdin = true,
		clear_before_run = true,
		repeat_policy = "queue",
		stop_on_error = true,
	},
	lsp = {
		enabled = true,
		auto_start = true,
		diagnostics = true,
		pull_diagnostics = false,
		python_path = false,
		servers = {
			python = {
				{
					name = "nvjup-pyright",
					cmd = { "pyright-langserver", "--stdio" },
					-- Pyright 1.1.408 requires an initial didChangeConfiguration
					-- notification when workspace folders are advertised.
					settings = { python = { analysis = {} } },
				},
				{
					name = "nvjup-ruff",
					cmd = { "ruff", "server" },
				},
			},
		},
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
		clear_all_outputs = "<localleader>jC",
		outline = "<localleader>jl",
		run_current = "<localleader>jr",
		run_and_advance = "<localleader>jn",
		run_above = "<localleader>ju",
		run_below = "<localleader>jb",
		run_all = "<localleader>ja",
		interrupt = "<localleader>ji",
		restart = "<localleader>jR",
		lsp_definition = "gd",
		lsp_declaration = "gD",
		lsp_implementation = "gi",
		lsp_type_definition = "<leader>D",
		lsp_references = "gr",
		lsp_hover = "K",
		lsp_signature = "<leader>ls",
		lsp_completion = "<C-Space>",
		lsp_rename = "<leader>ra",
		lsp_code_action = "<leader>ca",
		lsp_symbols = "<localleader>ls",
	},
}

M.options = vim.deepcopy(M.defaults)

function M.setup(options)
	options = options or {}
	M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), options)
	-- Server lists are ordered and should be replaced, not index-merged, when
	-- users provide their own language configuration.
	if options.lsp and options.lsp.servers ~= nil then
		M.options.lsp.servers = vim.deepcopy(options.lsp.servers)
	end
	return M.options
end

return M
