-- Hermetic nvjup development configuration.
-- It deliberately does not load the user's init.lua or plugin manager.

local config_path = debug.getinfo(1, "S").source:sub(2)
local inferred_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(config_path)))
local root = vim.env.NVJUP_PROJECT_ROOT or inferred_root

vim.g.nvjup_test_config = 1
vim.g.nvjup_project_root = root
vim.g.nvjup_config = {
	lsp = {
		auto_start = false,
	},
}
vim.g.mapleader = " "
vim.g.maplocalleader = ","

vim.opt.runtimepath:prepend(root)
vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.writebackup = false
vim.opt.undofile = false
vim.opt.shadafile = "NONE"
vim.opt.termguicolors = true
vim.opt.number = true
vim.opt.signcolumn = "yes"
vim.opt.updatetime = 100
vim.opt.timeoutlen = 400

-- Keep the harness independent from host-language providers until a test opts in.
vim.g.loaded_python3_provider = 0
vim.g.loaded_ruby_provider = 0
vim.g.loaded_perl_provider = 0
vim.g.loaded_node_provider = 0

vim.filetype.add({
	extension = {
		ipynb = "json",
	},
})

vim.api.nvim_create_user_command("NvJupTestInfo", function()
	local lines = {
		"nvjup isolated test configuration is active",
		"project: " .. root,
		"config: " .. config_path,
		"data: " .. vim.fn.stdpath("data"),
		"state: " .. vim.fn.stdpath("state"),
		"cache: " .. vim.fn.stdpath("cache"),
		"stage: 2 (shadow-document LSP and projected Tree-sitter highlighting)",
	}
	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "nvjup" })
end, {})

vim.api.nvim_create_user_command("NvJupOpenFixture", function(opts)
	local name = opts.args ~= "" and opts.args or "01_markdown_code.ipynb"
	vim.cmd.edit(vim.fs.joinpath(root, "tests", "fixtures", "notebooks", name))
end, {
	nargs = "?",
	complete = function()
		local fixtures =
			vim.fn.globpath(vim.fs.joinpath(root, "tests", "fixtures", "notebooks"), "*.ipynb", false, true)
		return vim.tbl_map(vim.fs.basename, fixtures)
	end,
})
