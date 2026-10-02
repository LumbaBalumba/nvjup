local config = require("nvjup.config")
local language = require("nvjup.language")
local render = require("nvjup.render")
local util = require("nvjup.util")

local M = {}

local indent_options = {
	"autoindent",
	"cindent",
	"cinoptions",
	"expandtab",
	"indentexpr",
	"indentkeys",
	"shiftwidth",
	"smartindent",
	"softtabstop",
	"tabstop",
}

local function cell_filetype(state, cell)
	return language.filetype(language.for_cell(state, cell))
end

local function option_for_filetype(filetype, name)
	if not vim.filetype or not vim.filetype.get_option then
		return nil
	end
	local ok, value = pcall(vim.filetype.get_option, filetype, name)
	return ok and value or nil
end

function M.update_options(state, force)
	if not state or not vim.api.nvim_buf_is_valid(state.buf) then
		return false
	end
	local cell = state:current_cell()
	if not cell then
		return false
	end
	local filetype = cell_filetype(state, cell)
	if not force and state.cell_option_filetype == filetype then
		return true
	end
	for _, name in ipairs(indent_options) do
		local value = option_for_filetype(filetype, name)
		if value ~= nil then
			vim.bo[state.buf][name] = value
		end
	end
	state.cell_option_filetype = filetype
	vim.b[state.buf].nvjup_cell_filetype = filetype
	return true
end

local function scratch_source(source)
	local has_eol = source:sub(-1) == "\n"
	local lines = util.source_to_lines(source)
	if has_eol and #lines > 1 and lines[#lines] == "" then
		table.remove(lines)
	end
	if #lines == 0 then
		lines = { "" }
	end
	return lines, has_eol
end

local function source_from_scratch(buf)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local source = table.concat(lines, "\n")
	if vim.bo[buf].endofline and not (#lines == 1 and lines[1] == "") then
		source = source .. "\n"
	end
	return source
end

local function scratch_name(state, cell, filetype)
	local directory = state.path ~= "" and vim.fs.dirname(state.path) or vim.uv.cwd()
	local base = state.path ~= "" and vim.fn.fnamemodify(state.path, ":t:r") or "notebook"
	local extension = language.extension(filetype)
	return vim.fs.joinpath(directory, string.format(".%s.nvjup-%s.%s", base, cell.id, extension))
end

local function has_notebook_only_syntax(filetype, source)
	if filetype ~= "python" then
		return false
	end
	for line in (source .. "\n"):gmatch("([^\n]*)\n") do
		if line:match("^%s*[!%%?]") or line:match("<[%u][^>]*>") or line:match("<%.+>") then
			return true
		end
	end
	return false
end

local function format_cell(state, cell, options)
	local filetype = cell_filetype(state, cell)
	if has_notebook_only_syntax(filetype, cell.source) then
		return nil
	end
	local ok, conform = pcall(require, "conform")
	if not ok or type(conform.format) ~= "function" then
		return nil
	end
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].undolevels = -1
	pcall(vim.api.nvim_buf_set_name, buf, scratch_name(state, cell, filetype))
	local lines, has_eol = scratch_source(cell.source)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].endofline = has_eol
	vim.bo[buf].filetype = filetype
	local format_error
	local attempted = conform.format({
		bufnr = buf,
		async = false,
		timeout_ms = options.timeout_ms,
		lsp_format = "never",
		quiet = true,
	}, function(err)
		format_error = err
	end)
	local source = attempted and not format_error and source_from_scratch(buf) or nil
	if vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_delete(buf, { force = true })
	end
	if format_error then
		return nil, tostring(format_error)
	end
	if not attempted then
		return nil
	end
	return source
end

function M.format(state, options)
	options = options or {}
	if not state or not vim.api.nvim_buf_is_valid(state.buf) then
		return 0, { "current buffer is not an nvjup notebook" }
	end
	assert(state:sync_from_buffer())
	local formatting = config.options.formatting or {}
	local timeout_ms = math.max(100, tonumber(options.timeout_ms or formatting.timeout_ms) or 2000)
	local current = options.current and state:current_cell() or nil
	local updates, errors = {}, {}
	local attempted = 0
	for _, cell in ipairs(state.cells) do
		local selected = cell.cell_type == "code" and (not current or current == cell)
		local dirty = options.all or options.current or cell.format_revision ~= cell.revision
		if selected and dirty then
			local source, err = format_cell(state, cell, { timeout_ms = timeout_ms })
			attempted = attempted + 1
			if err then
				table.insert(errors, string.format("cell %d: %s", cell.index, err))
			elseif source and source ~= cell.source then
				updates[cell.id] = source
			end
			cell.format_revision = cell.revision
		end
	end
	local changed = state:update_sources(updates)
	for id in pairs(changed) do
		local cell = state.cell_store[id]
		if cell then
			cell.format_revision = cell.revision
		end
	end
	if next(changed) then
		render.render(state, { sync = false })
	end
	return attempted, errors, changed
end

function M.format_and_notify(state, options)
	local attempted, errors, changed = M.format(state, options)
	local formatting = config.options.formatting or {}
	if #errors > 0 and formatting.notify_errors ~= false then
		local signature = table.concat(errors, "\n")
		if not options or not options.on_save or state.format_error_signature ~= signature then
			vim.notify("nvjup formatting: " .. signature, vim.log.levels.WARN)
		end
		state.format_error_signature = signature
	elseif #errors == 0 then
		state.format_error_signature = nil
	end
	return attempted, errors, changed
end

function M.attach(state)
	for _, cell in ipairs(state.cells) do
		cell.format_revision = cell.revision
	end
	M.update_options(state, true)
end

return M
