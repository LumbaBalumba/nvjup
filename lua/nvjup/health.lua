local M = {}

function M.check()
	vim.health.start("nvjup")

	if vim.fn.has("nvim-0.11") == 1 then
		vim.health.ok("Neovim " .. tostring(vim.version()))
	else
		vim.health.error("Neovim 0.11 or newer is required")
	end

	if vim.json and vim.json.decode and vim.json.encode then
		vim.health.ok("vim.json encoder and decoder are available")
	else
		vim.health.error("vim.json is unavailable")
	end

	local term = vim.env.TERM or ""
	local term_program = vim.env.TERM_PROGRAM or ""
	if term:find("kitty", 1, true) or term_program:lower():find("kitty", 1, true) then
		vim.health.ok("Kitty terminal detected")
	else
		vim.health.info("Kitty was not detected; Stage 1 text/extmark rendering remains available")
	end

	vim.health.info(
		"Stage 1 provides notebook editing and saved-output previews; kernel and image backends are not active yet"
	)
end

return M
