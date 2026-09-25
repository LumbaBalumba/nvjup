local M = {}

M.defaults = {
	border_width = 88,
	render = {
		outputs = true,
		full_width = true,
		debounce_ms = 30,
		max_output_lines = 12,
		max_html_bytes = 512 * 1024,
		max_text_bytes = 1024 * 1024,
		markdown = true,
		markdown_max_bytes = 2 * 1024 * 1024,
		markdown_latex_font_size = "normalsize",
		right_border = true,
		images = {
			enabled = true,
			backend = "auto", -- auto, kitty, chafa, or text
			max_width = 64,
			max_height = 24,
			max_bytes = 10 * 1024 * 1024,
			max_pixels = 16 * 1024 * 1024,
			conversion_timeout_ms = 10000,
		},
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
		max_message_bytes = 128 * 1024 * 1024,
	},
	interactive = {
		enabled = true,
		command = false,
		awrit_command = { "awrit" },
		awrit_disable_gpu = true,
		width_px = 900,
		height_px = 540,
		interactive_width_px = 720,
		interactive_height_px = 432,
		focus_width = 112,
		focus_height = 40,
		screencast = true,
		adaptive_resolution = true,
		require_trust = true,
		trust_file = false,
		restart_attempts = 2,
		restart_delay_ms = 150,
		max_figures = 8,
		max_fps = 60,
	},
	kernel = {
		default_name = "python3",
		python_path = false,
		system_python = false,
		start_timeout_seconds = 30,
		shutdown_on_close = true,
		remote = false,
	},
	colab = {
		executable = "colab",
		auth = "oauth2",
		state_path = false,
		create_timeout_seconds = 300,
		max_output_bytes = 64 * 1024,
		max_state_bytes = 1024 * 1024,
	},
	execution = {
		trust_local_kernel = true,
		allow_stdin = true,
		clear_before_run = true,
		repeat_policy = "queue",
		stop_on_error = true,
	},
	completion = {
		kernel = false,
		kernel_timeout_seconds = 2,
	},
	inspector = {
		max_variables = 200,
		timeout_seconds = 5,
		width = 88,
		height = 24,
	},
	remote_files = {
		local_root = false,
		remote_root = "",
		show_hidden = false,
		confirm_delete = true,
		max_file_bytes = 64 * 1024 * 1024,
		max_transfer_bytes = 512 * 1024 * 1024,
		max_entries = 10000,
		timeout_seconds = 60,
	},
	integrations = {
		telescope = true,
		render_markdown = true,
		snacks = true,
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
		open_output = "<leader>np",
		plot_focus = "<leader>nF",
		plot_focus_tui = "<leader>nf",
		clear_output = "<leader>nc",
		clear_all_outputs = "<leader>nC",
		outline = "<leader>nl",
		variables = "<leader>nv",
		remote_connection = "<leader>nK",
		remote_files = "<leader>ne",
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
