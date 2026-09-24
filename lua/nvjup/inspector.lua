local config = require("nvjup.config")
local kernel = require("nvjup.kernel")
local notebook = require("nvjup.notebook")

local M = {}
local views = {}

local function bounded(value, limit)
	value = tostring(value or ""):gsub("[\r\n]+", " ")
	if vim.fn.strdisplaywidth(value) <= limit then
		return value
	end
	return vim.fn.strcharpart(value, 0, math.max(1, limit - 1)) .. "…"
end

local function close(buf)
	local view = views[buf]
	views[buf] = nil
	if view and vim.api.nvim_win_is_valid(view.win) then
		vim.api.nvim_win_close(view.win, true)
	elseif vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_delete(buf, { force = true })
	end
end

local function detail(state, variable)
	kernel.inspect(variable.name, vim.str_utfindex(variable.name), function(err, payload)
		if err then
			vim.notify("nvjup variable inspection: " .. tostring(err.message or err), vim.log.levels.WARN)
			return
		end
		local data = payload and payload.data or {}
		local value = data["text/plain"] or data["text/markdown"] or variable.value or ""
		local lines = vim.split(tostring(value), "\n", { plain = true })
		local buf = vim.api.nvim_create_buf(false, true)
		vim.bo[buf].buftype = "nofile"
		vim.bo[buf].bufhidden = "wipe"
		vim.bo[buf].filetype = data["text/markdown"] and "markdown" or "text"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].modifiable = false
		local width =
			math.max(1, math.min(math.max(1, vim.o.columns - 4), (config.options.inspector or {}).width or 88))
		local height = math.max(
			1,
			math.min(math.max(1, vim.o.lines - 4), #lines + 2, (config.options.inspector or {}).height or 24)
		)
		local win = vim.api.nvim_open_win(buf, true, {
			relative = "editor",
			row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
			col = math.max(0, math.floor((vim.o.columns - width) / 2)),
			width = width,
			height = height,
			style = "minimal",
			border = "rounded",
			title = " " .. variable.name .. " · " .. (variable.type or "unknown") .. " ",
		})
		vim.keymap.set("n", "q", function()
			if vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_win_close(win, true)
			end
		end, { buffer = buf, silent = true })
		vim.keymap.set("n", "<Esc>", "q", { buffer = buf, remap = true, silent = true })
	end, state)
end

local function show_float(state, variables)
	local width = math.max(1, math.min(math.max(1, vim.o.columns - 4), (config.options.inspector or {}).width or 88))
	local max_height =
		math.max(1, math.min(math.max(1, vim.o.lines - 4), (config.options.inspector or {}).height or 24))
	local height = math.max(1, math.min(max_height, #variables + 2))
	local buf = vim.api.nvim_create_buf(false, true)
	local lines = { string.format("%-24s %-18s %s", "Name", "Type", "Value") }
	for _, variable in ipairs(variables) do
		table.insert(
			lines,
			string.format(
				"%-24s %-18s %s",
				bounded(variable.name, 24),
				bounded(variable.type, 18),
				bounded(variable.value, math.max(8, width - 46))
			)
		)
	end
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "nvjup-variables"
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
		col = math.max(0, math.floor((vim.o.columns - width) / 2)),
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " nvjup variables · <CR> inspect · r refresh · q close ",
	})
	views[buf] = { win = win, state = state, variables = variables }
	vim.keymap.set("n", "q", function()
		close(buf)
	end, { buffer = buf, silent = true })
	vim.keymap.set("n", "<Esc>", function()
		close(buf)
	end, { buffer = buf, silent = true })
	vim.keymap.set("n", "r", function()
		close(buf)
		M.open(state)
	end, { buffer = buf, silent = true })
	vim.keymap.set("n", "<CR>", function()
		local row = vim.api.nvim_win_get_cursor(win)[1] - 1
		local variable = variables[row]
		if variable then
			detail(state, variable)
		end
	end, { buffer = buf, silent = true })
	return buf, win
end

function M.open(state)
	state = state or notebook.get()
	if not state then
		return nil
	end
	kernel.variables(state, function(err, payload)
		if err then
			vim.notify("nvjup variables: " .. tostring(err.message or err), vim.log.levels.ERROR)
			return
		end
		local variables = payload and payload.variables or {}
		local telescope = require("nvjup.telescope")
		if telescope.variables(state, variables, function(variable)
			detail(state, variable)
		end) then
			return
		end
		show_float(state, variables)
	end)
	return true
end

M._show_float = show_float
M._close = close

return M
