local config = require("nvjup.config")
local image = require("nvjup.image")
local rpc = require("nvjup.rpc")

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

	vim.health.start("nvjup Jupyter sidecar")
	local command = rpc.default_command()
	if config.options.sidecar.command then
		vim.health.ok("custom sidecar command is configured: " .. table.concat(command, " "))
	else
		local result = vim.system({ command[1], "-c", "import jupyter_client" }, { text = true }):wait(5000)
		if result.code == 0 then
			vim.health.ok("jupyter_client is available to " .. command[1])
		else
			vim.health.error("jupyter_client is unavailable to " .. command[1] .. "; configure sidecar.python")
		end
		if vim.uv.fs_stat(command[2]) then
			vim.health.ok("sidecar entry point is available")
		else
			vim.health.error("sidecar entry point is missing: " .. tostring(command[2]))
		end
	end

	vim.health.start("nvjup rich output")
	local capabilities = image.capabilities()
	if capabilities.kitty then
		vim.health.ok("Kitty-compatible graphics terminal detected; Unicode-placeholder images are enabled")
	elseif capabilities.chafa then
		vim.health.ok("Kitty graphics unavailable; chafa image fallback is enabled")
	else
		vim.health.info("Kitty graphics and chafa are unavailable; image outputs use text fallbacks")
	end
	if capabilities.imagemagick then
		vim.health.ok("ImageMagick is available for JPEG, SVG, and PDF rasterization")
	else
		vim.health.warn("ImageMagick is unavailable; native Kitty rendering is limited to PNG")
	end
	vim.health.info("selected image backend: " .. capabilities.backend)

	vim.health.info("Stage 4 provides static rich MIME rendering, terminal images, and a full-output pager")
	vim.health.info("Interactive Plotly/Bokeh rendering remains scheduled for Stages 5 and 6")
end

return M
