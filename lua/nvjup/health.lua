local config = require("nvjup.config")
local image = require("nvjup.image")
local remote_api = require("nvjup.remote")
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
	for _, lang in ipairs({ "markdown", "markdown_inline", "latex", "python" }) do
		local ok = pcall(vim.treesitter.language.add, lang)
		if ok then
			vim.health.ok(lang .. " parser is available")
		elseif lang == "python" then
			vim.health.warn("python parser is unavailable; Python cells fall back without Tree-sitter highlighting")
		else
			vim.health.warn(lang .. " parser is unavailable")
		end
	end

	vim.health.start("nvjup Markdown rendering")
	if config.options.integrations.render_markdown == false then
		vim.health.info("render-markdown.nvim integration is disabled")
	elseif pcall(require, "render-markdown") then
		vim.health.ok("render-markdown.nvim is available; notebook Markdown reuses its active configuration")
	else
		vim.health.info("render-markdown.nvim is unavailable; nvjup uses its built-in Markdown fallback")
	end
	if config.options.integrations.snacks == false then
		vim.health.info("Snacks image integration is disabled")
	elseif pcall(require, "snacks") then
		vim.health.ok("Snacks.image is available for inline Markdown images and LaTeX")
	else
		vim.health.info("Snacks.image is unavailable; LaTeX remains text")
	end
	if vim.fn.executable("pdflatex") == 1 then
		vim.health.ok("pdflatex is available for Snacks LaTeX rendering")
	else
		vim.health.warn("pdflatex is unavailable; Snacks cannot rasterize LaTeX")
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
	if config.options.completion.kernel then
		if pcall(require, "cmp") then
			vim.health.ok("optional live-kernel completion is enabled through nvim-cmp")
		else
			vim.health.warn("completion.kernel=true requires nvim-cmp")
		end
	else
		vim.health.info("live-kernel completion is disabled; shadow LSP completion remains primary")
	end

	vim.health.start("nvjup Jupyter sidecar")
	local command = rpc.default_command()
	if config.options.sidecar.command then
		vim.health.ok("custom sidecar command is configured: " .. table.concat(command, " "))
	else
		local result = vim.system({ command[1], "-c", "import aiohttp,jupyter_client" }, { text = true }):wait(5000)
		if result.code == 0 then
			vim.health.ok("jupyter_client and aiohttp are available to " .. command[1])
		else
			vim.health.error(
				"jupyter_client or aiohttp is unavailable to " .. command[1] .. "; configure sidecar.python"
			)
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
	if capabilities.ffmpeg then
		vim.health.ok("ffmpeg is available for Matplotlib animation playback")
	else
		vim.health.info("ffmpeg is unavailable; HTML5/GIF animations use a text fallback")
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
		vim.health.warn("Awrit is unavailable; <leader>nF needs https://github.com/chase/awrit (TUI focus: <leader>nf)")
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

	vim.health.start("nvjup remote and optional integrations")
	local remote_status = remote_api.status()
	local remote_config = (config.options.kernel or {}).remote
	local colab_executable = (config.options.colab or {}).executable or "colab"
	if type(colab_executable) == "string" and vim.fn.executable(colab_executable) == 1 then
		vim.health.ok(
			"Google Colab CLI is available (nvjup supports 0.6.0+): "
				.. (vim.fn.exepath(colab_executable) or colab_executable)
		)
	else
		vim.health.info("google-colab-cli is unavailable; Google Colab provisioning is optional")
	end
	if remote_status.connected then
		if remote_status.url:match("^https://") then
			vim.health.ok("remote Jupyter Server uses HTTPS")
		elseif remote_status.url:match("^http://") then
			vim.health.warn("remote Jupyter Server uses HTTP; use an SSH tunnel or trusted private network")
		else
			vim.health.error("remote Jupyter URL must use http:// or https://")
		end
		if remote_status.verify_ssl == false then
			vim.health.warn("remote TLS certificate verification is disabled")
		end
		if remote_status.provider == "colab" then
			vim.health.ok("nvjup's Colab connection copy is held only in Neovim memory")
			vim.health.info(
				"the official Colab CLI persists OAuth and runtime session credentials in its config/state files"
			)
			vim.health.info("Colab runtime: " .. tostring(remote_status.colab_hardware or "unknown hardware"))
		elseif remote_status.source == "session" then
			vim.health.ok("remote connection was established in the nvjup UI; credentials are memory-only")
		elseif type(remote_config) == "table" and type(remote_config.token_env) == "string" then
			vim.health.ok("remote Jupyter token environment variable is configured")
		else
			vim.health.info("remote Jupyter authentication is configured")
		end
	else
		vim.health.info("remote Jupyter is disconnected; use :NvJupRemoteConnect or <leader>nK")
	end
	if require("nvjup.telescope").available() then
		vim.health.ok("Telescope is available for notebook, variable, and two-panel remote file pickers")
	else
		vim.health.info("Telescope is unavailable or disabled; outline/variables use fallbacks")
		if remote_status.connected then
			vim.health.warn("the remote file manager requires Telescope")
		end
	end
	local files = config.options.remote_files or {}
	vim.health.info(
		string.format(
			"remote file limits: %d bytes/file, %d bytes/transfer",
			files.max_file_bytes or 64 * 1024 * 1024,
			files.max_transfer_bytes or 512 * 1024 * 1024
		)
	)
	vim.health.ok("variable inspector and statusline adapter are available")
	vim.health.info("statusline API: require('nvjup.statusline').component()")
end

return M
