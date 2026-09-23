if vim.g.loaded_nvjup == 1 then
	return
end
vim.g.loaded_nvjup = 1

require("nvjup").setup(vim.g.nvjup_config or {})
