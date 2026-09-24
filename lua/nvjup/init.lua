local config = require("nvjup.config")
local features = require("nvjup.features")
local image = require("nvjup.image")
local inspector = require("nvjup.inspector")
local interactive = require("nvjup.interactive")
local kernel = require("nvjup.kernel")
local lsp = require("nvjup.lsp")
local notebook = require("nvjup.notebook")
local output = require("nvjup.output")
local render = require("nvjup.render")
local shadow = require("nvjup.shadow")
local treesitter = require("nvjup.treesitter")
local trust = require("nvjup.trust")
local actions = require("nvjup.actions")
local keymaps = require("nvjup.keymaps")

local M = {}
local group

local function notify_error(message)
	vim.notify("nvjup: " .. tostring(message), vim.log.levels.ERROR)
end

local function define_buffer_commands(buf)
	local function command(name, callback, options)
		options = options or {}
		options.desc = options.desc or name
		vim.api.nvim_buf_create_user_command(buf, name, callback, options)
	end

	command("NvJupWrite", function()
		vim.cmd.write()
	end)
	command("NvJupRefresh", actions.refresh)
	command("NvJupCellNext", actions.next_cell, { count = 1 })
	command("NvJupCellPrevious", actions.previous_cell, { count = 1 })
	command("NvJupCellInsertBelow", function(args)
		actions.insert_below(args.args ~= "" and args.args or "code")
	end, {
		nargs = "?",
		complete = function()
			return { "code", "markdown", "raw" }
		end,
	})
	command("NvJupCellInsertAbove", function(args)
		actions.insert_above(args.args ~= "" and args.args or "code")
	end, {
		nargs = "?",
		complete = function()
			return { "code", "markdown", "raw" }
		end,
	})
	command("NvJupCellDuplicate", actions.duplicate_cell)
	command("NvJupCellDelete", actions.delete_cell)
	command("NvJupCellMoveUp", actions.move_up)
	command("NvJupCellMoveDown", actions.move_down)
	command("NvJupCellSplit", actions.split_cell)
	command("NvJupCellMergeBelow", actions.merge_below)
	command("NvJupCellType", function(args)
		actions.change_type(args.args)
	end, {
		nargs = "?",
		complete = function()
			return { "code", "markdown", "raw" }
		end,
	})
	command("NvJupCellToggleSource", actions.toggle_source)
	command("NvJupCellToggleOutput", actions.toggle_output)
	command("NvJupOutputOpen", function(args)
		actions.open_output(args.args ~= "" and args.args or "float")
	end, {
		nargs = "?",
		complete = function()
			return { "float", "split", "vsplit", "tab" }
		end,
	})
	command("NvJupPlotFocus", actions.plot_focus)
	command("NvJupPlotFocusTui", actions.plot_focus_tui)
	command("NvJupPlotStatus", interactive.show_status)
	command("NvJupTrustInteractive", function()
		interactive.trust_interactive(assert(notebook.get(buf)))
	end)
	command("NvJupTrustRevoke", function()
		interactive.revoke_trust(assert(notebook.get(buf)))
	end)
	command("NvJupTrustStatus", function()
		vim.notify(
			vim.inspect(interactive.trust_status(assert(notebook.get(buf)))),
			vim.log.levels.INFO,
			{ title = "nvjup trust" }
		)
	end)
	command("NvJupCellClearOutput", actions.clear_output)
	command("NvJupClearAllOutputs", actions.clear_all_outputs)
	command("NvJupOutline", actions.outline)
	command("NvJupVariables", actions.variables)
	command("NvJupRunCurrent", kernel.run_current)
	command("NvJupRunAndAdvance", kernel.run_and_advance)
	command("NvJupRunAbove", kernel.run_above)
	command("NvJupRunBelow", kernel.run_below)
	command("NvJupRunAll", kernel.run_all)
	command("NvJupRunRange", function(args)
		kernel.run_range(args.line1, args.line2)
	end, { range = true })
	command("NvJupKernelInterrupt", kernel.interrupt)
	command("NvJupKernelRestart", kernel.restart)
	command("NvJupKernelRestartRunAll", kernel.restart_and_run_all)
	command("NvJupKernelShutdown", function()
		kernel.shutdown(assert(notebook.get(buf)))
	end)
	command("NvJupKernelStatus", function()
		vim.notify(
			vim.inspect(kernel.status(assert(notebook.get(buf)))),
			vim.log.levels.INFO,
			{ title = "nvjup kernel" }
		)
	end)
	command("NvJupLspDefinition", lsp.definition)
	command("NvJupLspDeclaration", lsp.declaration)
	command("NvJupLspImplementation", lsp.implementation)
	command("NvJupLspTypeDefinition", lsp.type_definition)
	command("NvJupLspReferences", lsp.references)
	command("NvJupLspHover", lsp.hover)
	command("NvJupLspSignature", lsp.signature_help)
	command("NvJupLspCompletion", lsp.completion)
	command("NvJupLspRename", function(args)
		lsp.rename(args.args ~= "" and args.args or nil)
	end, { nargs = "?" })
	command("NvJupLspCodeAction", lsp.code_action)
	command("NvJupLspSymbols", lsp.document_symbols)
	command("NvJupLspSemanticTokens", function()
		lsp.refresh_semantic_tokens(assert(notebook.get(buf)))
	end)
	command("NvJupLspStatus", function()
		vim.notify(vim.inspect(lsp.status(assert(notebook.get(buf)))), vim.log.levels.INFO, { title = "nvjup LSP" })
	end)
end

local function attach_buffer(state)
	local buf = state.buf
	vim.bo[buf].buftype = "acwrite"
	vim.bo[buf].buflisted = true
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "nvjup"

	vim.bo[buf].syntax = ""

	keymaps.attach(buf)
	define_buffer_commands(buf)

	vim.api.nvim_create_autocmd("InsertEnter", {
		group = group,
		buffer = buf,
		callback = function()
			vim.schedule(function()
				if vim.api.nvim_buf_is_valid(buf) then
					require("nvjup.cmp").attach(buf)
				end
			end)
		end,
	})
	if package.loaded.cmp then
		vim.schedule(function()
			require("nvjup.cmp").attach(buf)
		end)
	end

	vim.api.nvim_create_autocmd("BufWriteCmd", {
		group = group,
		buffer = buf,
		callback = function()
			local current = notebook.get(buf)
			if not current then
				return
			end
			local ok, err = current:save(vim.api.nvim_buf_get_name(buf))
			if not ok then
				notify_error(err)
			end
		end,
	})

	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufWinEnter" }, {
		group = group,
		buffer = buf,
		callback = function()
			local current = notebook.get(buf)
			if current then
				render.render(current)
			end
		end,
	})

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = group,
		buffer = buf,
		callback = function()
			local current = notebook.get(buf)
			if not current or current.internal_change then
				return
			end
			vim.schedule(function()
				if not vim.api.nvim_buf_is_valid(buf) then
					return
				end
				local ok, err = current:sync_from_buffer()
				if ok then
					render.render(current)
				else
					notify_error(err)
				end
			end)
		end,
	})

	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		buffer = buf,
		once = true,
		callback = function()
			local current = notebook.get(buf)
			kernel.detach(current)
			interactive.detach(current)
			image.detach(current)
			if package.loaded["nvjup.cmp"] then
				require("nvjup.cmp").detach(buf)
			end
			features.detach(notebook.get(buf))
			notebook.detach(buf)
		end,
	})

	render.render(state)
	vim.bo[buf].modified = false
	local undo_levels = vim.bo[buf].undolevels
	vim.bo[buf].undolevels = -1
	vim.bo[buf].undolevels = undo_levels
	vim.api.nvim_exec_autocmds("User", { pattern = "NvJupNotebookOpened", modeline = false, data = { buf = buf } })
end

local function open_buffer(args)
	local buf = args.buf
	local path = vim.api.nvim_buf_get_name(buf)
	local state
	local err

	if vim.uv.fs_stat(path) then
		state, err = notebook.load(buf, path)
	else
		state = notebook.create(buf, path)
	end
	if not state then
		notify_error(err)
		return
	end
	attach_buffer(state)
end

function M.setup(options)
	config.setup(options)
	group = vim.api.nvim_create_augroup("NvJup", { clear = true })
	for _, name in ipairs({ "NvJupRemoteConnect", "NvJupRemoteDisconnect", "NvJupRemoteStatus", "NvJupRemoteFiles" }) do
		pcall(vim.api.nvim_del_user_command, name)
	end
	vim.api.nvim_create_user_command("NvJupRemoteConnect", function()
		require("nvjup.remote_connection").open()
	end, { desc = "Connect to or manage a remote Jupyter Server" })
	vim.api.nvim_create_user_command("NvJupRemoteDisconnect", function()
		require("nvjup.remote_connection").disconnect()
	end, { desc = "Disconnect the in-memory remote Jupyter session" })
	vim.api.nvim_create_user_command("NvJupRemoteStatus", function()
		require("nvjup.remote_connection").status()
	end, { desc = "Show the remote Jupyter connection status" })
	vim.api.nvim_create_user_command("NvJupRemoteFiles", function()
		require("nvjup.remote_files").open()
	end, { desc = "Open the local/remote Jupyter file manager" })

	vim.api.nvim_create_autocmd("BufReadCmd", {
		group = group,
		pattern = "*.ipynb",
		callback = open_buffer,
	})

	vim.api.nvim_create_autocmd("BufNewFile", {
		group = group,
		pattern = "*.ipynb",
		callback = open_buffer,
	})

	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = interactive.shutdown,
	})

	vim.api.nvim_create_autocmd("WinResized", {
		group = group,
		callback = function()
			for _, state in pairs(notebook.all()) do
				render.render(state)
			end
			interactive.resize_focus()
		end,
	})

	return config.options
end

M.actions = actions
M.image = image
M.inspector = inspector
M.interactive = interactive
M.kernel = kernel
M.lsp = lsp
M.notebook = notebook
M.output = output
M.remote = require("nvjup.remote")
M.remote_connection = require("nvjup.remote_connection")
M.remote_files = require("nvjup.remote_files")
M.render = render
M.shadow = shadow
M.statusline = require("nvjup.statusline")
M.telescope = require("nvjup.telescope")
M.treesitter = treesitter
M.trust = trust

return M
