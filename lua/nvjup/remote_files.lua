local config = require("nvjup.config")
local local_fs = require("nvjup.local_fs")
local notebook = require("nvjup.notebook")
local remote = require("nvjup.remote")
local remote_client = require("nvjup.remote_files_client")

local M = {}
local active_browsers = {}

local function notify(message, level)
	vim.notify("nvjup files: " .. tostring(message), level or vim.log.levels.INFO)
end

local function remote_join(parent, name)
	return parent == "" and name or (parent .. "/" .. name)
end

local function remote_parent(path)
	return path:match("^(.*)/[^/]+$") or ""
end

local function basename(path)
	return path:match("([^/]+)$") or path
end

local function valid_basename(name)
	return name ~= ""
		and name ~= "."
		and name ~= ".."
		and not name:find("/", 1, true)
		and not name:find("\\", 1, true)
		and not name:find("\0", 1, true)
end

local function side_label(side)
	return side == "local" and "Local" or "Remote"
end

local function error_message(err)
	return type(err) == "table" and (err.message or err.code) or tostring(err)
end

local function entry_display(entry)
	local marker = entry.type == "directory" and "d" or entry.type == "link" and "l" or "f"
	local suffix = entry.type == "directory" and "/" or ""
	local size = type(entry.size) == "number" and string.format(" %10d", entry.size) or "           "
	return string.format("%s%s  %s%s", marker, size, entry.name, suffix)
end

local function finder(browser)
	local finders = require("telescope.finders")
	return finders.new_table({
		results = browser[browser.active].entries,
		entry_maker = function(entry)
			return {
				value = entry,
				display = entry_display(entry),
				ordinal = entry.name,
				path = entry.path,
			}
		end,
	})
end

local function panel_lines(browser, side)
	local panel = browser[side]
	local lines = {
		string.format(
			"%s · %s%s",
			side_label(side),
			panel.path == "" and "/" or panel.path,
			side == browser.active and " · active" or ""
		),
		string.rep("─", 72),
	}
	for _, entry in ipairs(panel.entries) do
		table.insert(lines, entry_display(entry))
	end
	if #panel.entries == 0 then
		table.insert(lines, "(empty directory)")
	end
	return lines
end

local function update_title(browser)
	local picker = browser.picker
	if not picker then
		return
	end
	local title = string.format(
		" nvjup files · %s active · local:%s · remote:/%s ",
		side_label(browser.active),
		browser["local"].path,
		browser.remote.path
	)
	picker.prompt_title = title
	if picker.prompt_border and picker.prompt_border.change_title then
		picker.prompt_border:change_title(title)
	end
end

local function redraw(browser, reset_prompt)
	if browser.closed or not browser.picker then
		return
	end
	browser.picker:refresh(finder(browser), { reset_prompt = reset_prompt == true })
	update_title(browser)
end

local function load_local(browser)
	local entries, err = local_fs.list(browser["local"].path, browser.show_hidden)
	if not entries then
		return nil, err
	end
	browser["local"].entries = entries
	return true
end

local function load_remote(browser, callback)
	browser.client:list(browser.remote.path, function(err, payload)
		if err then
			callback(nil, error_message(err))
			return
		end
		local entries = {}
		for _, entry in ipairs(payload.entries or {}) do
			if browser.show_hidden or (entry.name or ""):sub(1, 1) ~= "." then
				entry.side = "remote"
				table.insert(entries, entry)
			end
		end
		browser.remote.entries = entries
		callback(true)
	end)
end

local function refresh(browser, callback)
	local ok, local_err = load_local(browser)
	if not ok then
		if callback then
			callback(nil, local_err)
		end
		return
	end
	load_remote(browser, function(remote_ok, remote_err)
		if remote_ok then
			redraw(browser, false)
		end
		if callback then
			callback(remote_ok, remote_err)
		end
	end)
end

local function selection()
	local ok, state = pcall(require, "telescope.actions.state")
	if not ok then
		return nil
	end
	local selected = state.get_selected_entry()
	return selected and selected.value or nil
end

local function prompt(label, default, callback)
	vim.ui.input({ prompt = label, default = default }, function(value)
		if value and value ~= "" then
			callback(value)
		end
	end)
end

local function confirm(label, callback)
	vim.ui.select({ "No", "Yes" }, { prompt = label }, function(choice)
		callback(choice == "Yes")
	end)
end

local function path_for(browser, side, name)
	return side == "local" and vim.fs.joinpath(browser["local"].path, name) or remote_join(browser.remote.path, name)
end

local function list_side(browser, side, path, callback)
	if side == "local" then
		local entries, err = local_fs.list(path, true)
		callback(entries, err)
	else
		browser.client:list(path, function(err, payload)
			if err then
				callback(nil, error_message(err))
				return
			end
			for _, entry in ipairs(payload.entries or {}) do
				entry.side = "remote"
			end
			callback(payload.entries or {})
		end)
	end
end

local function make_directory(browser, side, path, callback)
	if side == "local" then
		local ok, err = local_fs.mkdir(path)
		callback(ok, err)
	else
		browser.client:mkdir(path, function(err)
			callback(not err, err and error_message(err) or nil)
		end)
	end
end

local function read_file(browser, side, path, callback)
	if side == "local" then
		local content, err = local_fs.read(path, browser.max_file_bytes)
		callback(content, err)
	else
		browser.client:download(path, function(err, content)
			callback(not err and content or nil, err and error_message(err) or nil)
		end)
	end
end

local function write_file(browser, side, path, content, callback)
	if side == "local" then
		local ok, err = local_fs.write(path, content)
		callback(ok, err)
	else
		browser.client:upload(path, content, function(err)
			callback(not err, err and error_message(err) or nil)
		end)
	end
end

local function delete_path(browser, side, path, callback)
	if side == "local" then
		local_fs.delete_async(path, callback)
	else
		browser.client:delete(path, function(err)
			callback(not err, err and error_message(err) or nil)
		end)
	end
end

local function copy_recursive(browser, source_side, entry, target_side, target, budget, callback)
	budget.count = budget.count + 1
	if budget.count > budget.max then
		callback(nil, string.format("transfer exceeds %d entries", budget.max))
		return
	end
	if entry.type ~= "directory" then
		local declared_size = tonumber(entry.size) or 0
		if declared_size > 0 and budget.bytes + declared_size > budget.max_bytes then
			callback(nil, string.format("transfer exceeds %d bytes", budget.max_bytes))
			return
		end
		if source_side == "remote" and target_side == "local" and browser.client.download_to then
			local parent = vim.fs.dirname(target)
			if vim.fn.mkdir(parent, "p", 493) ~= 1 and not vim.uv.fs_stat(parent) then
				callback(nil, "failed to create local destination directory")
				return
			end
			browser.client:download_to(entry.path, target, function(err, payload)
				if err then
					callback(nil, error_message(err))
					return
				end
				budget.bytes = budget.bytes + (tonumber((payload or {}).size) or declared_size)
				callback(true)
			end)
			return
		elseif source_side == "local" and target_side == "remote" and browser.client.upload_from then
			browser.client:upload_from(target, entry.path, function(err)
				if not err then
					budget.bytes = budget.bytes + declared_size
				end
				callback(not err, err and error_message(err) or nil)
			end)
			return
		elseif source_side == "remote" and target_side == "remote" and browser.client.copy then
			browser.client:copy(entry.path, target, function(err)
				if not err then
					budget.bytes = budget.bytes + declared_size
				end
				callback(not err, err and error_message(err) or nil)
			end)
			return
		end
		read_file(browser, source_side, entry.path, function(content, read_err)
			if not content then
				callback(nil, read_err)
				return
			end
			budget.bytes = budget.bytes + #content
			if budget.bytes > budget.max_bytes then
				callback(nil, string.format("transfer exceeds %d bytes", budget.max_bytes))
				return
			end
			write_file(browser, target_side, target, content, callback)
		end)
		return
	end
	make_directory(browser, target_side, target, function(created, create_err)
		if not created then
			callback(nil, create_err)
			return
		end
		local function fail_and_cleanup(message)
			delete_path(browser, target_side, target, function()
				callback(nil, message)
			end)
		end
		list_side(browser, source_side, entry.path, function(children, list_err)
			if not children then
				fail_and_cleanup(list_err)
				return
			end
			local index = 1
			local function next_child(ok, err)
				if not ok then
					fail_and_cleanup(err)
					return
				end
				local child = children[index]
				if not child then
					callback(true)
					return
				end
				index = index + 1
				local child_target = target_side == "local" and vim.fs.joinpath(target, child.name)
					or remote_join(target, child.name)
				copy_recursive(browser, source_side, child, target_side, child_target, budget, next_child)
			end
			next_child(true)
		end)
	end)
end

local function destination_exists(browser, side, path, callback)
	if side == "local" then
		callback(vim.uv.fs_lstat(path) ~= nil)
	else
		browser.client:stat(path, function(err)
			if err and err.code == "remote_files_stat_failed" and tostring(err.message):find("HTTP 404", 1, true) then
				callback(false)
			else
				callback(not err, err and error_message(err) or nil)
			end
		end)
	end
end

local function with_empty_destination(browser, side, path, callback)
	destination_exists(browser, side, path, function(exists, stat_err)
		if stat_err then
			callback(nil, stat_err)
			return
		end
		if not exists then
			callback(true)
			return
		end
		confirm("Replace " .. path .. "?", function(accepted)
			if not accepted then
				callback(nil, "cancelled")
				return
			end
			delete_path(browser, side, path, callback)
		end)
	end)
end

local function transfer(browser, clipboard)
	local target_side = browser.active
	local target = path_for(browser, target_side, clipboard.entry.name)
	if clipboard.side == target_side and clipboard.entry.path == target then
		notify("source and destination are identical", vim.log.levels.WARN)
		return
	end
	if
		clipboard.side == target_side
		and clipboard.entry.type == "directory"
		and target:sub(1, #clipboard.entry.path + 1) == clipboard.entry.path .. "/"
	then
		notify("cannot copy a directory into itself", vim.log.levels.WARN)
		return
	end
	with_empty_destination(browser, target_side, target, function(ready, prepare_err)
		if not ready then
			if prepare_err ~= "cancelled" then
				notify(prepare_err, vim.log.levels.ERROR)
			end
			return
		end
		browser.pending = true
		notify(string.format("%s %s → %s", clipboard.cut and "moving" or "copying", clipboard.entry.path, target))
		local function done(ok, err)
			browser.pending = false
			if not ok then
				notify(err, vim.log.levels.ERROR)
				return
			end
			if clipboard.cut then
				delete_path(browser, clipboard.side, clipboard.entry.path, function(deleted, delete_err)
					if not deleted then
						notify("copied, but source deletion failed: " .. tostring(delete_err), vim.log.levels.WARN)
					end
					browser.clipboard = nil
					refresh(browser)
				end)
			else
				refresh(browser)
			end
		end
		if clipboard.side == "local" and target_side == "local" then
			local operation = clipboard.cut and local_fs.move_async or local_fs.copy_async
			operation(clipboard.entry.path, target, browser.max_entries, function(ok, err)
				if clipboard.cut then
					browser.pending = false
					if not ok then
						notify(err, vim.log.levels.ERROR)
					else
						browser.clipboard = nil
						refresh(browser)
					end
				else
					done(ok, err)
				end
			end)
		elseif clipboard.side == "remote" and target_side == "remote" and clipboard.cut then
			browser.client:rename(clipboard.entry.path, target, function(err)
				browser.pending = false
				if err then
					notify(error_message(err), vim.log.levels.ERROR)
				else
					browser.clipboard = nil
					refresh(browser)
				end
			end)
		else
			copy_recursive(
				browser,
				clipboard.side,
				clipboard.entry,
				target_side,
				target,
				{ count = 0, max = browser.max_entries, bytes = 0, max_bytes = browser.max_transfer_bytes },
				done
			)
		end
	end)
end

local function operate_create(browser)
	prompt("Create file or directory (trailing / creates a directory): ", "", function(name)
		local directory = name:sub(-1) == "/"
		name = name:gsub("/+$", "")
		if not valid_basename(name) then
			notify("enter one basename; use a trailing slash only for directories", vim.log.levels.WARN)
			return
		end
		local target = path_for(browser, browser.active, name)
		local function done(ok, err)
			if not ok then
				notify(error_message(err), vim.log.levels.ERROR)
			else
				refresh(browser)
			end
		end
		if browser.active == "local" then
			local ok, err = directory and local_fs.mkdir(target) or local_fs.touch(target)
			done(ok, err)
		elseif directory then
			browser.client:mkdir(target, function(err)
				done(not err, err)
			end)
		else
			browser.client:touch(target, function(err)
				done(not err, err)
			end)
		end
	end)
end

local function operate_rename(browser)
	local entry = selection()
	if not entry then
		return
	end
	prompt("Rename: ", entry.name, function(name)
		if not valid_basename(name) then
			notify("rename accepts a basename, not a path", vim.log.levels.WARN)
			return
		end
		local target = path_for(browser, browser.active, name)
		local function done(ok, err)
			if not ok then
				notify(error_message(err), vim.log.levels.ERROR)
			else
				refresh(browser)
			end
		end
		if browser.active == "local" then
			local ok, err = local_fs.rename(entry.path, target)
			done(ok, err)
		else
			browser.client:rename(entry.path, target, function(err)
				done(not err, err)
			end)
		end
	end)
end

local function operate_delete(browser)
	local entry = selection()
	if not entry then
		return
	end
	local function perform()
		delete_path(browser, browser.active, entry.path, function(ok, err)
			if not ok then
				notify(error_message(err), vim.log.levels.ERROR)
			else
				refresh(browser)
			end
		end)
	end
	if browser.confirm_delete then
		confirm("Delete " .. entry.path .. "?", function(accepted)
			if accepted then
				perform()
			end
		end)
	else
		perform()
	end
end

local function loaded_buffer(path)
	local normalized = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) then
			local name = vim.api.nvim_buf_get_name(buf)
			if name ~= "" and vim.fs.normalize(vim.fn.fnamemodify(name, ":p")) == normalized then
				return buf
			end
		end
	end
	return nil
end

local function navigate(browser, entry)
	if entry and entry.type == "directory" then
		browser[browser.active].path = entry.path
		refresh(browser, function(ok, err)
			if not ok then
				notify(err, vim.log.levels.ERROR)
			end
		end)
		return
	end
	if not entry then
		return
	end
	if browser.active == "local" then
		local actions = require("telescope.actions")
		actions.close(browser.prompt_bufnr)
		vim.schedule(function()
			local existing = loaded_buffer(entry.path)
			if existing then
				vim.api.nvim_set_current_buf(existing)
			else
				vim.cmd.edit(vim.fn.fnameescape(entry.path))
			end
		end)
		return
	end
	local target = vim.fs.joinpath(browser["local"].path, entry.name)
	if loaded_buffer(target) then
		notify("download target is already open; close it or choose another local directory", vim.log.levels.WARN)
		return
	end
	with_empty_destination(browser, "local", target, function(ready, err)
		if not ready then
			if err ~= "cancelled" then
				notify(err, vim.log.levels.ERROR)
			end
			return
		end
		local function open_download(download_err)
			if download_err then
				notify(error_message(download_err), vim.log.levels.ERROR)
				return
			end
			require("telescope.actions").close(browser.prompt_bufnr)
			vim.schedule(function()
				vim.cmd.edit(vim.fn.fnameescape(target))
			end)
		end
		if browser.client.download_to then
			browser.client:download_to(entry.path, target, open_download)
		else
			read_file(browser, "remote", entry.path, function(content, read_err)
				if not content then
					open_download(read_err)
					return
				end
				local ok, write_err = local_fs.write(target, content)
				open_download(ok and nil or write_err)
			end)
		end
	end)
end

local function navigate_parent(browser)
	if browser.active == "local" then
		browser["local"].path = vim.fs.dirname(browser["local"].path)
	else
		browser.remote.path = remote_parent(browser.remote.path)
	end
	refresh(browser, function(ok, err)
		if not ok then
			notify(err, vim.log.levels.ERROR)
		end
	end)
end

local function switch_side(browser)
	browser.active = browser.active == "local" and "remote" or "local"
	redraw(browser, true)
end

local function copy_path(entry, kind)
	if not entry then
		return
	end
	local value = entry.side == "remote" and ("/" .. entry.path) or entry.path
	if kind == "name" or kind == "relative" then
		value = entry.name
	elseif kind == "basename" then
		value = vim.fn.fnamemodify(basename(entry.path), ":r")
	end
	vim.fn.setreg("+", value)
	vim.fn.setreg('"', value)
	notify("copied path: " .. value)
end

local function show_info(browser)
	local entry = selection()
	if not entry then
		return
	end
	local lines = {
		"side: " .. side_label(browser.active),
		"name: " .. entry.name,
		"path: " .. entry.path,
		"type: " .. entry.type,
		"size: " .. tostring(entry.size or "unknown"),
		"writable: " .. tostring(entry.writable),
		"modified: " .. tostring(entry.last_modified or entry.mtime or "unknown"),
	}
	notify(table.concat(lines, "\n"))
end

local function show_help()
	notify(table.concat({
		"<Tab> switch local/remote panel · <CR>/o open",
		"- / P parent · f filter · R refresh · H hidden files",
		"a create · r/e rename · d/<Del> delete",
		"c copy · x cut · p paste/transfer (c, <Tab>, p copies between filesystems)",
		"y/ge name · Y relative path · gy absolute/API path · <C-k> info",
		"g? help · q close",
	}, "\n"))
end

local function attach(browser, prompt_bufnr, map)
	browser.prompt_bufnr = prompt_bufnr
	local actions = require("telescope.actions")
	local function bind(mode, key, callback)
		if type(mode) == "table" then
			for _, item in ipairs(mode) do
				map(item, key, callback)
			end
		else
			map(mode, key, callback)
		end
	end
	local function open_selected()
		navigate(browser, selection())
	end
	actions.select_default:replace(open_selected)
	bind({ "i", "n" }, "<Tab>", function()
		switch_side(browser)
	end)
	bind("n", "o", open_selected)
	bind("n", "-", function()
		navigate_parent(browser)
	end)
	bind("n", "P", function()
		navigate_parent(browser)
	end)
	bind("n", "<BS>", function()
		navigate_parent(browser)
	end)
	bind("n", "a", function()
		operate_create(browser)
	end)
	bind("n", "r", function()
		operate_rename(browser)
	end)
	bind("n", "e", function()
		operate_rename(browser)
	end)
	bind("n", "d", function()
		operate_delete(browser)
	end)
	bind("n", "<Del>", function()
		operate_delete(browser)
	end)
	bind("n", "c", function()
		local entry = selection()
		if entry then
			browser.clipboard = { side = browser.active, entry = vim.deepcopy(entry), cut = false }
			notify("copied " .. entry.path .. "; switch panel and press p to transfer")
		end
	end)
	local function cut_selected()
		local entry = selection()
		if entry then
			browser.clipboard = { side = browser.active, entry = vim.deepcopy(entry), cut = true }
			notify("cut " .. entry.path .. "; press p to move")
		end
	end
	bind("n", "x", cut_selected)
	bind("n", "gp", cut_selected)
	bind("n", "p", function()
		if browser.pending then
			notify("another transfer is already running", vim.log.levels.WARN)
		elseif browser.clipboard then
			transfer(browser, browser.clipboard)
		else
			notify("clipboard is empty", vim.log.levels.WARN)
		end
	end)
	bind("n", "R", function()
		refresh(browser, function(ok, err)
			if not ok then
				notify(err, vim.log.levels.ERROR)
			end
		end)
	end)
	bind("n", "H", function()
		browser.show_hidden = not browser.show_hidden
		refresh(browser)
	end)
	bind("n", "f", function()
		vim.api.nvim_set_current_win(browser.picker.prompt_win)
		vim.cmd.startinsert()
	end)
	bind("n", "y", function()
		copy_path(selection(), "name")
	end)
	bind("n", "ge", function()
		copy_path(selection(), "basename")
	end)
	bind("n", "Y", function()
		copy_path(selection(), "relative")
	end)
	bind("n", "gy", function()
		copy_path(selection(), "absolute")
	end)
	bind("n", "<C-k>", function()
		show_info(browser)
	end)
	bind("n", "g?", show_help)
	bind("n", "q", function()
		actions.close(prompt_bufnr)
	end)
	bind({ "i", "n" }, "<C-c>", function()
		actions.close(prompt_bufnr)
	end)
	return true
end

local function launch(browser)
	local pickers = require("telescope.pickers")
	local telescope_config = require("telescope.config")
	local previewers = require("telescope.previewers")
	local picker = pickers.new({}, {
		prompt_title = "nvjup files",
		finder = finder(browser),
		sorter = telescope_config.values.generic_sorter({}),
		previewer = previewers.new_buffer_previewer({
			title = "inactive filesystem",
			define_preview = function(self)
				local side = browser.active == "local" and "remote" or "local"
				vim.bo[self.state.bufnr].modifiable = true
				vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, panel_lines(browser, side))
				vim.bo[self.state.bufnr].modifiable = false
			end,
		}),
		layout_strategy = "horizontal",
		layout_config = {
			width = 0.95,
			height = 0.85,
			preview_width = 0.5,
			preview_cutoff = 1,
			prompt_position = "top",
		},
		sorting_strategy = "ascending",
		attach_mappings = function(prompt_bufnr, map)
			return attach(browser, prompt_bufnr, map)
		end,
	})
	browser.picker = picker
	picker:find()
	update_title(browser)
	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = picker.prompt_bufnr,
		once = true,
		callback = function()
			browser.closed = true
			browser.client:shutdown()
			active_browsers[browser.state.buf] = nil
		end,
	})
end

function M.open(state)
	state = state or notebook.get()
	if not state then
		state = {
			buf = vim.api.nvim_get_current_buf(),
			path = vim.api.nvim_buf_get_name(0),
		}
	end
	if not remote.resolve(state) then
		notify("kernel.remote is not configured", vim.log.levels.ERROR)
		return false
	end
	if config.options.integrations.telescope == false or not pcall(require, "telescope") then
		notify("Telescope is required for the remote file manager", vim.log.levels.ERROR)
		return false
	end
	local existing = active_browsers[state.buf]
	if existing and not existing.closed then
		if existing.picker and existing.picker.prompt_win and vim.api.nvim_win_is_valid(existing.picker.prompt_win) then
			vim.api.nvim_set_current_win(existing.picker.prompt_win)
		end
		return true
	end
	local options = config.options.remote_files or {}
	local local_root = options.local_root
	if type(local_root) == "function" then
		local_root = local_root(state.path, state)
	end
	if type(local_root) ~= "string" or local_root == "" then
		local_root = state.path ~= "" and vim.fs.dirname(state.path) or vim.uv.cwd()
	end
	local remote_root = tostring(options.remote_root or ""):gsub("^/+", ""):gsub("/+$", "")
	local browser = {
		state = state,
		client = remote_client.new(state),
		active = "local",
		["local"] = { path = local_fs.absolute(local_root), entries = {} },
		remote = { path = remote_root, entries = {} },
		show_hidden = options.show_hidden == true,
		confirm_delete = options.confirm_delete ~= false,
		max_file_bytes = options.max_file_bytes or 64 * 1024 * 1024,
		max_transfer_bytes = options.max_transfer_bytes or 512 * 1024 * 1024,
		max_entries = options.max_entries or 10000,
		closed = false,
		pending = false,
	}
	active_browsers[state.buf] = browser
	local ok, err = load_local(browser)
	if not ok then
		notify(err, vim.log.levels.ERROR)
		return false
	end
	load_remote(browser, function(remote_ok, remote_err)
		if not remote_ok then
			notify(remote_err, vim.log.levels.ERROR)
			browser.client:shutdown()
			active_browsers[state.buf] = nil
			return
		end
		launch(browser)
	end)
	return true
end

function M.close_all()
	local browsers = {}
	for _, browser in pairs(active_browsers) do
		table.insert(browsers, browser)
	end
	for _, browser in ipairs(browsers) do
		local prompt_bufnr = browser.picker and browser.picker.prompt_bufnr
		if prompt_bufnr and vim.api.nvim_buf_is_valid(prompt_bufnr) then
			local ok, actions = pcall(require, "telescope.actions")
			if ok then
				actions.close(prompt_bufnr)
			else
				vim.api.nvim_buf_delete(prompt_bufnr, { force = true })
			end
		else
			browser.closed = true
			browser.client:shutdown()
			active_browsers[browser.state.buf] = nil
		end
	end
end

M._active = active_browsers
M._launch = launch
M._loaded_buffer = loaded_buffer
M._navigate = navigate
M._copy_recursive = copy_recursive
M._remote_join = remote_join
M._remote_parent = remote_parent

return M
