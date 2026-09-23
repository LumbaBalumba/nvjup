local config = require("nvjup.config")
local lsp = require("nvjup.lsp")
local notebook = require("nvjup.notebook")
local util = require("nvjup.util")

local root = assert(vim.g.nvjup_project_root)
local fixture = vim.fs.joinpath(root, "tests", "fixtures", "notebooks", "09_lsp_mapping.ipynb")
local original_auto_start = config.options.lsp.auto_start
local state
local clients = {}

local function fail(message)
	print("Real LSP test failed: " .. message)
	vim.cmd("cquit 1")
end

local ok, err = xpcall(function()
	assert(vim.fn.executable("pyright-langserver") == 1, "pyright-langserver is not executable")
	config.options.lsp.auto_start = true
	vim.cmd.edit(vim.fn.fnameescape(fixture))
	state = assert(notebook.get())
	state.cells[5].source = state.cells[5].source .. "missing_name\n"
	state:replace_buffer()
	require("nvjup.render").render(state)
	lsp.update(state, assert(state.shadow), false)
	assert(
		vim.wait(15000, function()
			local document = state.shadow:document("python")
			clients = document and vim.lsp.get_clients({ bufnr = document.buf }) or {}
			for _, client in ipairs(clients) do
				if client.name == "nvjup-pyright" and client.initialized then
					return true
				end
			end
			return false
		end, 50),
		"Pyright did not initialize on the shadow document"
	)

	local expected_python = vim.fs.joinpath(root, ".venv", "bin", "python")
	if vim.uv.fs_stat(expected_python) then
		local pyright
		for _, client in ipairs(clients) do
			if client.name == "nvjup-pyright" then
				pyright = client
				break
			end
		end
		assert(pyright and pyright.config.settings.python.pythonPath == expected_python)
	end

	assert(
		vim.wait(15000, function()
			lsp.publish_diagnostics(state)
			for _, diagnostic in ipairs(vim.diagnostic.get(state.buf, { namespace = state.lsp_diagnostic_ns })) do
				if diagnostic.message:find("missing_name", 1, true) then
					return true
				end
			end
			return false
		end, 50),
		"Pyright/Ruff diagnostics were not mapped into the notebook"
	)

	local reference_cell = state.cells[5]
	local row, col
	for index, line in ipairs(util.source_to_lines(reference_cell.source)) do
		local start = line:find("length", 1, true)
		if start then
			row = reference_cell.range.start_row + index - 1
			col = start - 1
			break
		end
	end
	assert(row and col)
	vim.api.nvim_win_set_cursor(0, { row + 1, col })
	lsp.definition()

	local definition_cell = state.cells[2]
	local expected_row
	for index, line in ipairs(util.source_to_lines(definition_cell.source)) do
		if line:find("def length", 1, true) then
			expected_row = definition_cell.range.start_row + index - 1
			break
		end
	end
	assert(
		vim.wait(10000, function()
			return vim.api.nvim_get_current_buf() == state.buf and vim.api.nvim_win_get_cursor(0)[1] == expected_row + 1
		end, 50),
		"Pyright definition did not map to the earlier code cell"
	)

	local status = lsp.status(state)
	print(
		string.format(
			"Real LSP test passed: %d client(s), Python %s, Pyright cross-cell definition mapped",
			#clients,
			status.documents[1].python_path or "<system>"
		)
	)
end, debug.traceback)

config.options.lsp.auto_start = original_auto_start
for _, client in ipairs(clients) do
	pcall(client.stop, client, true)
end
if state and vim.api.nvim_buf_is_valid(state.buf) then
	pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
end

if not ok then
	fail(err)
else
	vim.cmd("qa!")
end
