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
		python_path = false,
		system_python = false,
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
		insert_below = "<leader>nb",
		insert_above = "<leader>na",
		duplicate_cell = "<leader>nyy",
		delete_cell = "<leader>nd",
		move_up = "<leader>nk",
		move_down = "<leader>nj",
		split_cell = "<leader>nq",
		merge_below = "<leader>nM",
		change_type = "<leader>nt",
		to_markdown = "<leader>nm",
		to_code = "<leader>ny",
		toggle_source = "<leader>nz",
		toggle_output = "<leader>no",
		clear_output = "<leader>nc",
		clear_all_outputs = "<leader>nC",
		outline = "<leader>nl",
		refresh = "<leader>nL",
		run_current = "<C-CR>",
		run_and_advance = "<S-CR>",
		run_and_advance_alt = "<leader>nr",
		run_above = "<leader>nA",
		run_below = "<leader>nB",
		run_all = "<leader>nR",
		start = "<leader>ns",
		shutdown = "<leader>nS",
		interrupt = "<leader>ni",
		restart = "<leader>nx",
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
