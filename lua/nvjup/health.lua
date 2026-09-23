local M = {}

function M.check()
	vim.health.start("nvjup")

	local version = vim.version()
	if vim.fn.has("nvim-0.11") == 1 then
		vim.health.ok(string.format("Neovim %d.%d.%d", version.major, version.minor, version.patch))
	else
		vim.health.error("Neovim 0.11 or newer is required")
	end

	if vim.json and vim.json.decode and vim.json.encode then
		vim.health.ok("vim.json encoder and decoder are available")
	else
		vim.health.error("vim.json is unavailable")
	end

	vim.health.start("nvjup Tree-sitter")
	for _, lang in ipairs({ "markdown", "markdown_inline", "python" }) do
		local ok = pcall(vim.treesitter.language.add, lang)
		if ok then
			vim.health.ok(lang .. " parser is available")
		elseif lang == "python" then
			vim.health.warn("python parser is unavailable; Python cells fall back without Tree-sitter highlighting")
		else
			vim.health.warn(lang .. " parser is unavailable")
		end
	end

	vim.health.start("nvjup language servers")
	if vim.fn.executable("pyright-langserver") == 1 then
		vim.health.ok("pyright-langserver is executable")
	else
		vim.health.warn("pyright-langserver was not found; configure lsp.servers or install Pyright")
	end
	if vim.fn.executable("ruff") == 1 then
		vim.health.ok("ruff server is executable")
	else
		vim.health.info("ruff was not found; Ruff LSP integration is optional")
	end

	local term = vim.env.TERM or ""
	local term_program = vim.env.TERM_PROGRAM or ""
	if term:find("kitty", 1, true) or term_program:lower():find("kitty", 1, true) then
		vim.health.ok("Kitty terminal detected")
	else
		vim.health.info("Kitty was not detected; text/extmark rendering remains available")
	end

	vim.health.info("Stage 2 provides notebook editing, projected Tree-sitter highlighting, and shadow-document LSP")
	vim.health.info("Kernel execution and terminal image backends are not active yet")
end

return M
