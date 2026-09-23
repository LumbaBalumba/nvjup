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
		vim.health.ok("ImageMagick is available for JPEG and PDF rasterization")
	else
		vim.health.warn("ImageMagick is unavailable; JPEG/PDF use a fallback")
	end
	if capabilities.rsvg then
		vim.health.ok("rsvg-convert is available for bounded SVG rasterization")
	elseif capabilities.imagemagick then
		vim.health.info("rsvg-convert is unavailable; safe SVG falls back to ImageMagick")
	else
		vim.health.warn("no SVG rasterizer is available")
	end
	vim.health.info("selected image backend: " .. capabilities.backend)

	vim.health.start("nvjup interactive renderer")
	local renderer_python = rpc.default_command()[1]
	local renderer_imports = vim.system({ renderer_python, "-c", "import bokeh, playwright, plotly" }, { text = true })
		:wait(5000)
	if renderer_imports.code == 0 then
		vim.health.ok("Playwright, Plotly.js, and BokehJS assets are available to " .. renderer_python)
	else
		vim.health.warn("Playwright, Plotly, or Bokeh is unavailable; interactive outputs use safe text fallbacks")
	end
	local chromium = vim.env.NVJUP_CHROMIUM
	if chromium and vim.uv.fs_stat(chromium) then
		vim.health.ok("Chromium configured by NVJUP_CHROMIUM: " .. chromium)
	elseif
		vim.fn.executable("chromium") == 1
		or vim.fn.executable("chromium-browser") == 1
		or vim.fn.executable("google-chrome-stable") == 1
		or vim.fn.executable("google-chrome") == 1
	then
		vim.health.ok("system Chromium is available")
	else
		vim.health.warn("Chromium was not found; install it or set NVJUP_CHROMIUM")
	end
	local awrit = config.options.interactive.awrit_command
	if type(awrit) == "function" then
		local ok, command = pcall(awrit)
		awrit = ok and command or nil
	end
	awrit = type(awrit) == "table" and awrit[1] or awrit
	local awrit_path = type(awrit) == "string" and vim.fn.exepath(awrit) or ""
	if awrit_path == "" and awrit == "awrit" then
		local candidate = vim.fs.joinpath(vim.fn.expand("~/.local/bin"), "awrit")
		awrit_path = vim.fn.executable(candidate) == 1 and candidate or ""
	end
	if awrit_path ~= "" then
		vim.health.ok("Awrit is available for zero-screenshot interactive focus: " .. awrit_path)
	else
		vim.health.warn(
			"Awrit is unavailable; <leader>nf needs https://github.com/chase/awrit (TUI fallback: <leader>nF)"
		)
	end
	if vim.env.KITTY_LISTEN_ON and vim.env.KITTY_LISTEN_ON ~= "" then
		vim.health.ok("Kitty remote control is available for a separate Awrit OS window")
	else
		vim.health.warn("KITTY_LISTEN_ON is unset; external Awrit windows require Kitty remote control")
	end
	vim.health.info(
		"Stage 6 provides trusted Plotly/Bokeh rendering, CDP screencast frames, Awrit focus, and crash recovery"
	)
	if config.options.interactive.require_trust == false then
		vim.health.warn("interactive.require_trust=false bypasses notebook content-identity trust checks")
	else
		vim.health.ok("interactive notebook trust is required")
	end
end

return M
