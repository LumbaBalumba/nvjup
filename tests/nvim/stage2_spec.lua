local config = require("nvjup.config")
local lsp = require("nvjup.lsp")
local notebook = require("nvjup.notebook")
local render = require("nvjup.render")
local shadow = require("nvjup.shadow")
local treesitter = require("nvjup.treesitter")
local util = require("nvjup.util")

local root = assert(vim.g.nvjup_project_root)
local failures = {}
local passed = 0

local function test(name, callback)
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		passed = passed + 1
		print("ok - " .. name)
	else
		table.insert(failures, name .. "\n" .. err)
		print("not ok - " .. name)
	end
end

local function fixture_path(name)
	return vim.fs.joinpath(root, "tests", "fixtures", "notebooks", name)
end

local function open_fixture(name)
	vim.cmd.edit(vim.fn.fnameescape(fixture_path(name)))
	local state = assert(notebook.get())
	assert(state:sync_from_buffer())
	render.render(state)
	return state
end

local function close_fixture(state)
	if state and vim.api.nvim_buf_is_valid(state.buf) then
		vim.api.nvim_buf_delete(state.buf, { force = true })
	end
end

local function shadow_lines(document)
	return vim.api.nvim_buf_get_lines(document.buf, 0, -1, false)
end

test("builds one logical Python shadow document across code cells", function()
	local state = open_fixture("09_lsp_mapping.ipynb")
	local manager = assert(state.shadow)
	local document = assert(manager:document("python"))
	assert(#document.segments == 3)
	local text = table.concat(shadow_lines(document), "\n")
	assert(text:find("class Точка", 1, true))
	assert(text:find("length(point)", 1, true))
	assert(not text:find("Markdown between code cells", 1, true))
	assert(document.version == manager.version)
	close_fixture(state)
end)

test("maps notebook and shadow positions with UTF-16 columns", function()
	local state = open_fixture("09_lsp_mapping.ipynb")
	local manager = assert(state.shadow)
	local cell = state.cells[2]
	local lines = util.source_to_lines(cell.source)
	local local_row
	for index, line in ipairs(lines) do
		if line:find("class Точка", 1, true) then
			local_row = index - 1
			break
		end
	end
	assert(local_row)
	local notebook_row = cell.range.start_row + local_row
	local byte_col = #"class Т"
	local mapped = assert(manager:notebook_to_shadow(notebook_row, byte_col, "utf-16"))
	assert(mapped.position.character == #"class " + 1)
	local reversed = assert(manager:shadow_to_notebook(mapped.document, mapped.position, "utf-16"))
	assert(reversed.row == notebook_row)
	assert(reversed.col == byte_col)
	assert(reversed.cell_id == cell.id)
	close_fixture(state)
end)

test("replaces IPython magics with same-width syntax-safe placeholders", function()
	local state = open_fixture("09_lsp_mapping.ipynb")
	local document = assert(state.shadow:document("python"))
	local segment = document.segments[2]
	local lines = shadow_lines(document)
	local first = lines[segment.shadow_start_row + 1]
	local second = lines[segment.shadow_start_row + 2]
	assert(first:sub(1, 1) == "#")
	assert(second:sub(1, 1) == "#")
	assert(#first == #"%matplotlib inline")
	assert(#second == #"!echo ignored-by-lsp")
	assert(segment.transformed_lines[1])
	assert(segment.transformed_lines[2])
	assert(not segment.transformed_lines[3])
	close_fixture(state)
end)

test("preserves Python expressions inside %time while protecting the magic prefix", function()
	local state = open_fixture("09_lsp_mapping.ipynb")
	state.cells[2].source = "env = object()\nfor _ in range(1):\n    %time result = env\nprint(result)"
	state:replace_buffer()
	render.render(state)
	local document = assert(state.shadow:document("python"))
	local segment = document.segments[1]
	local shadow_line = shadow_lines(document)[segment.shadow_start_row + 3]
	assert(shadow_line == "    pass; result = env")
	assert(#shadow_line == #"    %time result = env")
	local row = state.cells[2].range.start_row + 2
	local prefix = assert(state.shadow:notebook_to_shadow(row, #"    %t", "utf-8"))
	local identifier = assert(state.shadow:notebook_to_shadow(row, #"    %time result = ", "utf-8"))
	assert(prefix.transformed)
	assert(not identifier.transformed)
	local mapped = assert(state.shadow:range_to_notebook(document, {
		start = { line = segment.shadow_start_row + 2, character = #"    pass; result = " },
		["end"] = { line = segment.shadow_start_row + 2, character = #"    pass; result = env" },
	}, "utf-8"))
	assert(mapped.start.line == row)
	assert(mapped.start.character == #"    %time result = ")

	state.cells[2].source = "%%time\nvalue = env\nprint(value)"
	state:replace_buffer()
	render.render(state)
	document = assert(state.shadow:document("python"))
	segment = document.segments[1]
	local cell_magic_lines = shadow_lines(document)
	assert(cell_magic_lines[segment.shadow_start_row + 1]:sub(1, 1) == "#")
	assert(cell_magic_lines[segment.shadow_start_row + 2] == "value = env")
	assert(segment.transformed_lines[1])
	assert(not segment.transformed_lines[2])
	close_fixture(state)
end)

test("creates independent shadow documents for per-cell languages", function()
	local state = open_fixture("09_lsp_mapping.ipynb")
	state.cells[2].raw.metadata.language = "lua"
	state.cells[2].source = "local shared_value = 42"
	state:replace_buffer()
	render.render(state)
	local python = assert(state.shadow:document("python"))
	local lua = assert(state.shadow:document("lua"))
	assert(#python.segments == 2)
	assert(#lua.segments == 1)
	assert(lua.segments[1].cell_id == state.cells[2].id)
	close_fixture(state)
end)

test("projects Tree-sitter captures from Markdown and Lua cells", function()
	local state = open_fixture("09_lsp_mapping.ipynb")
	state.cells[2].raw.metadata.language = "lua"
	state.cells[2].source = "local shared_value = 42\nprint(shared_value)"
	state:replace_buffer()
	render.render(state)
	local status = assert(treesitter.status(state))
	assert(status.languages.markdown and status.languages.markdown.available)
	assert(status.languages.lua and status.languages.lua.available)
	assert(status.capture_count > 0)
	local marks = vim.api.nvim_buf_get_extmarks(state.buf, state.treesitter_ns, 0, -1, { details = true })
	assert(#marks > 0)
	local has_lua = false
	for _, mark in ipairs(marks) do
		local group = mark[4].hl_group or ""
		if group:find(".lua", 1, true) then
			has_lua = true
			break
		end
	end
	assert(has_lua)
	close_fixture(state)
end)

test("falls back cleanly when a Tree-sitter parser is unavailable", function()
	local state = open_fixture("09_lsp_mapping.ipynb")
	state.cells[2].raw.metadata.language = "definitely_missing_nvjuplang"
	state.cells[2].source = "anything"
	state:replace_buffer()
	render.render(state)
	local status = assert(treesitter.status(state))
	assert(status.languages.definitely_missing_nvjuplang)
	assert(status.languages.definitely_missing_nvjuplang.available == false)
	close_fixture(state)
end)

test("maps shadow diagnostics back into the visible notebook", function()
	local state = open_fixture("09_lsp_mapping.ipynb")
	local manager = assert(state.shadow)
	local document = assert(manager:document("python"))
	local segment = document.segments[3]
	local namespace = vim.api.nvim_create_namespace("nvjup-stage2-test-diagnostics")
	vim.diagnostic.set(namespace, document.buf, {
		{
			lnum = segment.shadow_start_row,
			col = 0,
			end_lnum = segment.shadow_start_row,
			end_col = 6,
			severity = vim.diagnostic.severity.ERROR,
			message = "mapped diagnostic",
			source = "mock-lsp",
		},
	})
	lsp.publish_diagnostics(state)
	local diagnostics = vim.diagnostic.get(state.buf, { namespace = state.lsp_diagnostic_ns })
	assert(#diagnostics == 1)
	assert(diagnostics[1].lnum == state.cells[5].range.start_row)
	assert(diagnostics[1].message == "mapped diagnostic")
	vim.diagnostic.reset(namespace, document.buf)
	close_fixture(state)
end)

test("applies safe notebook WorkspaceEdits and rejects synthetic separators", function()
	local state = open_fixture("09_lsp_mapping.ipynb")
	local manager = assert(state.shadow)
	local document = assert(manager:document("python"))
	local segment = document.segments[3]
	local client = { offset_encoding = "utf-16" }
	local edit = {
		changes = {
			[document.uri] = {
				{
					range = {
						start = { line = segment.shadow_start_row, character = 0 },
						["end"] = { line = segment.shadow_start_row, character = 6 },
					},
					newText = "norm",
				},
			},
		},
	}
	assert(lsp.apply_workspace_edit(state, manager, edit, client, manager.version))
	assert(state.cells[5].source:find("norm(point)", 1, true))

	local current_document = assert(manager:document("python"))
	local invalid = {
		changes = {
			[current_document.uri] = {
				{
					range = {
						start = { line = current_document.segments[1].separator_row, character = 0 },
						["end"] = { line = current_document.segments[1].separator_row, character = 1 },
					},
					newText = "x",
				},
			},
		},
	}
	local ok, err = lsp.apply_workspace_edit(state, manager, invalid, client, manager.version)
	assert(not ok)
	assert(err:find("synthetic", 1, true))
	close_fixture(state)
end)

test("rejects WorkspaceEdits produced for an obsolete source-map version", function()
	local state = open_fixture("09_lsp_mapping.ipynb")
	local manager = assert(state.shadow)
	local document = assert(manager:document("python"))
	local segment = document.segments[1]
	local ok, err = lsp.apply_workspace_edit(state, manager, {
		changes = {
			[document.uri] = {
				{
					range = {
						start = { line = segment.shadow_start_row, character = 0 },
						["end"] = { line = segment.shadow_start_row, character = 0 },
					},
					newText = "stale",
				},
			},
		},
	}, { offset_encoding = "utf-16" }, manager.version - 1)
	assert(not ok)
	assert(err:find("source map changed", 1, true))
	close_fixture(state)
end)

test("selects a project-local Python environment for Pyright", function()
	local directory = vim.fn.tempname()
	assert(vim.fn.mkdir(vim.fs.joinpath(directory, ".venv", "bin"), "p") == 1)
	local python = vim.fs.joinpath(directory, ".venv", "bin", "python")
	local file = assert(io.open(python, "wb"))
	file:write("#!/bin/sh\n")
	file:close()
	local old = config.options.lsp.python_path
	config.options.lsp.python_path = false
	assert(lsp.find_python_path({}, directory) == python)
	config.options.lsp.python_path = ".venv/bin/python"
	assert(lsp.find_python_path({}, directory) == python)
	config.options.lsp.python_path = old
	vim.fs.rm(directory, { recursive = true, force = true })
end)

test("registers a notebook-aware nvim-cmp source without removing existing sources", function()
	local state = open_fixture("09_lsp_mapping.ipynb")
	local registered_name, registered_source, buffer_config
	local setup = setmetatable({
		buffer = function(options)
			buffer_config = options
		end,
	}, {
		__call = function() end,
	})
	package.loaded.cmp = {
		get_config = function()
			return { sources = { { name = "buffer" }, { name = "path" } } }
		end,
		register_source = function(name, source)
			registered_name, registered_source = name, source
			return 1
		end,
		setup = setup,
	}
	package.loaded["nvjup.cmp"] = nil
	local bridge = require("nvjup.cmp")
	assert(bridge.attach(state.buf))
	assert(registered_name == "nvjup")
	assert(registered_source:is_available())
	assert(buffer_config.sources[1].name == "nvjup")
	assert(buffer_config.sources[2].name == "buffer")
	assert(buffer_config.sources[3].name == "path")
	bridge.detach(state.buf)
	package.loaded["nvjup.cmp"] = nil
	package.loaded.cmp = nil
	close_fixture(state)
end)

test("uses the same LSP bindings as ordinary code buffers", function()
	local state = open_fixture("09_lsp_mapping.ipynb")
	local expected = {
		{ "n", "gd" },
		{ "n", "gD" },
		{ "n", "gi" },
		{ "n", "gr" },
		{ "n", "K" },
		{ "n", "<leader>D" },
		{ "n", "<leader>ra" },
		{ "n", "<leader>ca" },
		{ "x", "<leader>ca" },
		{ "n", "<leader>ls" },
	}
	for _, mapping in ipairs(expected) do
		local details = vim.fn.maparg(mapping[2], mapping[1], false, true)
		assert(details.buffer == 1, mapping[1] .. " " .. mapping[2])
	end
	close_fixture(state)
end)

if #failures > 0 then
	print(table.concat(failures, "\n\n"))
	vim.cmd("cquit " .. math.min(255, #failures))
else
	print(string.format("Stage 2 Lua tests: %d passed", passed))
	vim.cmd("qa!")
end
