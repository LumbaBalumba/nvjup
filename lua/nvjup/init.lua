local config = require("nvjup.config")
local notebook = require("nvjup.notebook")
local render = require("nvjup.render")
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
	command("NvJupCellClearOutput", actions.clear_output)
	command("NvJupOutline", actions.outline)
end

local function attach_buffer(state)
	local buf = state.buf
	vim.bo[buf].buftype = "acwrite"
	vim.bo[buf].buflisted = true
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "nvjup"

	local language = (((state.document or {}).metadata or {}).language_info or {}).name
		or (((state.document or {}).metadata or {}).kernelspec or {}).language
	if language == "python" then
		vim.bo[buf].syntax = "python"
	end

	keymaps.attach(buf)
	define_buffer_commands(buf)

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

	vim.api.nvim_create_autocmd("WinResized", {
		group = group,
		callback = function()
			for _, state in pairs(notebook.all()) do
				render.render(state)
			end
		end,
	})

	return config.options
end

M.actions = actions
M.notebook = notebook
M.render = render

return M
