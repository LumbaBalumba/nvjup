local root = assert(vim.env.NVJUP_PROJECT_ROOT)
local Notebook = require("nvjup.notebook")
local actions = require("nvjup.actions")
local config = require("nvjup.config")
local interactive = require("nvjup.interactive")
local kernel = require("nvjup.kernel")
local markdown = require("nvjup.markdown")
local output = require("nvjup.output")
local render = require("nvjup.render")
local shadow = require("nvjup.shadow")

local passed = 0
local failures = {}

local function test(name, callback)
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		passed = passed + 1
	else
		table.insert(failures, name .. ":\n" .. err)
	end
end

local function fixture_path(name)
	return vim.fs.joinpath(root, "tests", "fixtures", "notebooks", name)
end

local function temporary_fixture(name)
	local path = vim.fn.tempname() .. ".ipynb"
	assert(vim.uv.fs_copyfile(fixture_path(name), path))
	return path
end

local function open_path(path)
	vim.cmd("silent edit! " .. vim.fn.fnameescape(path))
	local state = assert(Notebook.get(), "notebook state was not attached")
	assert(state:sync_from_buffer())
	return state
end

local function open_fixture(name)
	return open_path(temporary_fixture(name))
end

local function close_fixture(state)
	local path = state.path
	vim.cmd("silent! bwipeout!")
	os.remove(path)
end

local function details(state, namespace)
	return vim.api.nvim_buf_get_extmarks(state.buf, namespace, 0, -1, { details = true })
end

local function count_where(items, predicate)
	local count = 0
	for _, item in ipairs(items) do
		if predicate(item[4]) then
			count = count + 1
		end
	end
	return count
end

local function find_line(lines, fragment)
	for _, line in ipairs(lines) do
		if line:find(fragment, 1, true) then
			return true
		end
	end
	return false
end

test("uses the isolated Neovim configuration and XDG roots", function()
	assert(vim.g.nvjup_test_config == 1)
	local config_home = assert(vim.env.XDG_CONFIG_HOME)
	assert(vim.fn.stdpath("config"):sub(1, #config_home) == config_home)
	assert(vim.fn.stdpath("data"):sub(1, #assert(vim.env.XDG_DATA_HOME)) == vim.env.XDG_DATA_HOME)
	assert(vim.fn.stdpath("state"):sub(1, #assert(vim.env.XDG_STATE_HOME)) == vim.env.XDG_STATE_HOME)
	assert(vim.fn.stdpath("cache"):sub(1, #assert(vim.env.XDG_CACHE_HOME)) == vim.env.XDG_CACHE_HOME)
end)

test("opens nbformat as notebook cells instead of JSON", function()
	local state = open_fixture("01_markdown_code.ipynb")
	assert(#state.cells == 4)
	assert(state.cells[1].cell_type == "markdown")
	assert(state.cells[2].cell_type == "code")
	assert(vim.bo[state.buf].filetype == "nvjup")
	assert(vim.bo[state.buf].buftype == "acwrite")
	assert(vim.api.nvim_buf_get_lines(state.buf, 0, 1, false)[1]:find(Notebook.MARKER_PREFIX, 1, true))
	close_fixture(state)
end)

test("renders loaded Markdown and returns edited cells to source mode", function()
	local state = open_fixture("01_markdown_code.ipynb")
	state:goto_cell(1)
	local cell = state.cells[1]
	assert(cell.markdown_rendered == true)
	assert(#markdown.regions(state) == 1)
	if state.markdown_parser then
		assert(#state.markdown_parser:included_regions() == 1)
	end

	assert(actions.toggle_source() == false)
	assert(#markdown.regions(state) == 0)
	if state.markdown_parser then
		assert(#state.markdown_parser:included_regions() == 0)
		assert(next(state.markdown_parser:children()) == nil)
	end
	local _, queued = kernel.run_current()
	assert(queued == 0)
	assert(cell.markdown_rendered == true)
	assert(#markdown.regions(state) == 1)
	if state.markdown_parser then
		assert(#state.markdown_parser:included_regions() == 1)
	end

	vim.api.nvim_buf_set_lines(state.buf, cell.range.start_row, cell.range.start_row + 1, false, { "# Edited" })
	assert(state:sync_from_buffer())
	assert(cell.markdown_rendered == false)
	assert(#markdown.regions(state) == 0)
	close_fixture(state)
end)

test("reuses an existing shadow buffer after notebook state reattachment", function()
	local state = open_fixture("01_markdown_code.ipynb")
	local original = assert(state.shadow:document("python"))
	state.shadow = nil
	local changed, manager = shadow.update(state)
	assert(changed)
	local adopted = assert(manager:document("python"))
	assert(adopted.buf == original.buf)
	assert(vim.api.nvim_buf_get_name(adopted.buf) == vim.api.nvim_buf_get_name(original.buf))
	close_fixture(state)
end)

test("reopening a loaded notebook does not collide with its shadow buffer", function()
	local state = open_fixture("01_markdown_code.ipynb")
	local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(state.path))
	assert(ok, err)
	local reopened = assert(Notebook.get(state.buf))
	local document = assert(reopened.shadow:document("python"))
	assert(vim.api.nvim_buf_is_valid(document.buf))
	local shadows = 0
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].nvjup_notebook_buf == reopened.buf then
			shadows = shadows + 1
		end
	end
	assert(shadows == 1)
	close_fixture(reopened)
end)

test("renders full-width unbroken cell borders", function()
	local state = open_fixture("01_markdown_code.ipynb")
	render.render(state)
	local marker_marks = details(state, state.marker_ns)
	local render_marks = details(state, state.render_ns)
	assert(#marker_marks == #state.cells)
	assert(count_where(marker_marks, function(item)
		return item.virt_text_pos == "overlay"
	end) == #state.cells)
	assert(count_where(render_marks, function(item)
		return item.virt_lines_above == true
	end) == #state.cells)
	assert(count_where(render_marks, function(item)
		return item.virt_lines and not item.virt_lines_above
	end) >= #state.cells)

	local source_rows = 0
	for _, cell in ipairs(state.cells) do
		source_rows = source_rows + cell.range.end_row - cell.range.start_row + 1
	end
	assert(count_where(render_marks, function(item)
		return item.virt_text_pos == "right_align" and item.virt_text_repeat_linebreak
	end) == source_rows)

	local expected_width = render.content_width(state.buf)
	for _, mark in ipairs(render_marks) do
		local item = mark[4]
		if item.virt_lines then
			local border = item.virt_lines[1]
			local text = table.concat(vim.tbl_map(function(chunk)
				return chunk[1]
			end, border))
			if text:find("╭", 1, true) or text:find("╰", 1, true) then
				assert(vim.fn.strdisplaywidth(text) == expected_width)
			end
		end
	end

	local formula_line = { { "math", "SnacksImageMath" } }
	markdown.frame_virtual_line(state.buf, formula_line)
	assert(formula_line[1][1] == "│ ")
	assert(formula_line[#formula_line][1] == "│")
	local formula_text = table.concat(vim.tbl_map(function(chunk)
		return chunk[1]
	end, formula_line))
	assert(vim.fn.strdisplaywidth(formula_text) == expected_width)
	close_fixture(state)
end)

test("wraps long source lines and repeats both borders on visual rows", function()
	local state = open_fixture("00_minimal.ipynb")
	local row = state.cells[1].range.start_row
	local long_line = string.rep("long notebook text ", 30)
	vim.api.nvim_buf_set_lines(state.buf, row, row + 1, false, { long_line })
	assert(state:sync_from_buffer())
	render.render(state)

	assert(vim.wo.wrap)
	assert(vim.wo.linebreak)
	assert(vim.wo.breakindent)
	assert(vim.wo.breakindentopt:find("min:2", 1, true))
	assert(vim.wo.showbreak == "  ")

	local repeated_left = false
	local repeated_right = false
	for _, mark in ipairs(details(state, state.render_ns)) do
		local item = mark[4]
		if item.virt_text_repeat_linebreak and item.virt_text_win_col == 0 then
			repeated_left = true
		end
		if item.virt_text_repeat_linebreak and item.virt_text_pos == "right_align" then
			repeated_right = true
		end
	end
	assert(repeated_left)
	assert(repeated_right)

	vim.api.nvim_win_set_cursor(0, { row + 1, #long_line })
	assert(vim.fn.winsaveview().leftcol == 0)
	close_fixture(state)
end)

test("renders jupynvim-style cell, language, and execution labels", function()
	local state = open_fixture("01_markdown_code.ipynb")
	state:goto_cell(3)
	render.render(state)
	local headers, footers = {}, {}
	for _, mark in ipairs(details(state, state.render_ns)) do
		local item = mark[4]
		if item.virt_lines_above and item.virt_lines then
			table.insert(headers, item.virt_lines[1][1][1])
		elseif item.virt_lines then
			table.insert(footers, item.virt_lines[1][1][1])
		end
	end
	assert(find_line(headers, "#3"))
	assert(find_line(footers, "[1] ✓"))
	assert(find_line(footers, "Python"))
	close_fixture(state)
end)

test("renders Markdown heading highlights", function()
	local state = open_fixture("01_markdown_code.ipynb")
	render.render(state)
	local heading_marks = count_where(details(state, state.render_ns), function(item)
		return item.hl_group == "NvJupMarkdownH1"
	end)
	assert(heading_marks >= 1)
	close_fixture(state)
end)

test("renders stream and error output while stripping ANSI", function()
	local state = open_fixture("02_stream_error.ipynb")
	local stream_lines, stream_kinds = output.render(state.cells[1])
	assert(find_line(stream_lines, "first"))
	assert(find_line(stream_lines, "warning"))
	assert(stream_kinds[#stream_kinds] == "stderr")

	local error_lines, error_kinds = output.render(state.cells[2])
	assert(find_line(error_lines, "ValueError"))
	assert(not table.concat(error_lines, "\n"):find("\27", 1, true))
	assert(error_kinds[1] == "error")
	close_fixture(state)
end)

test("renders rich MIME placeholders and text fallbacks", function()
	local state = open_fixture("03_rich_outputs.ipynb")
	local lines, kinds = output.render(state.cells[1])
	assert(find_line(lines, "image/png 320x240"))
	assert(find_line(lines, "image/svg+xml"))
	assert(vim.tbl_contains(kinds, "image"))
	close_fixture(state)
end)

test("renders Plotly and Bokeh interactive placeholders", function()
	local plotly = open_fixture("05_plotly.ipynb")
	local plotly_lines, plotly_kinds = output.render(plotly.cells[1])
	assert(find_line(plotly_lines, "Plotly interactive output · <leader>nf TUI · <leader>nF Awrit"))
	assert(plotly_kinds[1] == "interactive")
	close_fixture(plotly)

	local bokeh = open_fixture("06_bokeh.ipynb")
	local bokeh_lines, bokeh_kinds = output.render(bokeh.cells[1])
	assert(find_line(bokeh_lines, "Bokeh interactive output · <leader>nf TUI · <leader>nF Awrit"))
	assert(bokeh_kinds[1] == "interactive")
	close_fixture(bokeh)
end)

test("truncates large output deterministically", function()
	local state = open_fixture("08_large_output.ipynb")
	local lines, kinds = output.render(state.cells[1])
	assert(#lines == 13)
	assert(lines[#lines]:find("more output lines", 1, true))
	assert(kinds[#kinds] == "truncated")
	close_fixture(state)
end)

test("navigates between all cells and only code cells", function()
	local state = open_fixture("01_markdown_code.ipynb")
	state:goto_cell(1)
	assert(actions.next_cell() == 2)
	assert(state:cell_index_at(vim.api.nvim_win_get_cursor(0)[1] - 1) == 2)
	state:goto_cell(1)
	assert(actions.next_cell({ code_only = true }) == 2)
	assert(actions.next_cell({ code_only = true }) == 3)
	assert(actions.previous_cell({ code_only = true }) == 2)
	close_fixture(state)
end)

test("inserts deletes and changes cell types", function()
	local state = open_fixture("00_minimal.ipynb")
	state:goto_cell(1)
	local inserted = actions.insert_below("markdown")
	assert(#state.cells == 2)
	assert(inserted.cell_type == "markdown")
	assert(state.cells[2].id == inserted.id)
	actions.change_type("raw")
	assert(state.cells[2].cell_type == "raw")
	actions.delete_cell()
	assert(#state.cells == 1)
	close_fixture(state)
end)

test("moves cells while preserving stable ids", function()
	local state = open_fixture("01_markdown_code.ipynb")
	local first = state.cells[1].id
	local second = state.cells[2].id
	state:goto_cell(2)
	actions.move_up()
	assert(state.cells[1].id == second)
	assert(state.cells[2].id == first)
	actions.move_down()
	assert(state.cells[1].id == first)
	close_fixture(state)
end)

test("splits and merges a cell around the cursor", function()
	local state = open_fixture("00_minimal.ipynb")
	state:goto_cell(1)
	local original_id = state.cells[1].id
	local row = state.cells[1].range.start_row + 1
	vim.api.nvim_win_set_cursor(0, { row, 6 })
	actions.split_cell()
	assert(#state.cells == 2)
	assert(state.cells[1].id == original_id)
	assert(state.cells[2].id ~= original_id)
	assert(state.cells[1].source:find("answer", 1, true))
	actions.previous_cell()
	assert(actions.merge_below())
	assert(#state.cells == 1)
	assert(state.cells[1].id == original_id)
	close_fixture(state)
end)

test("structural edits remain recoverable through Neovim undo", function()
	local state = open_fixture("00_minimal.ipynb")
	state:goto_cell(1)
	actions.insert_below("code")
	assert(#state.cells == 2)
	vim.cmd.undo()
	assert(state:sync_from_buffer())
	assert(#state.cells == 1)
	render.render(state)
	close_fixture(state)
end)

test("outline exposes stable ordered labels", function()
	local state = open_fixture("01_markdown_code.ipynb")
	local items = state:outline_items()
	assert(#items == 4)
	assert(items[1].label:find("markdown", 1, true))
	assert(items[1].label:find("Анализ данных", 1, true))
	assert(items[3].label:find("[1]", 1, true))
	close_fixture(state)
end)

test("saving source edits preserves unknown metadata and MIME bundles", function()
	local state = open_fixture("07_unknown_metadata.ipynb")
	local cell = state.cells[2]
	vim.api.nvim_buf_set_lines(state.buf, cell.range.start_row, cell.range.start_row + 1, false, { "changed_result" })
	assert(state:save())

	local file = assert(io.open(state.path, "rb"))
	local saved = vim.json.decode(file:read("*a"))
	file:close()
	assert(saved.metadata["vendor.example/notebook"].version == 9)
	assert(saved.cells[1].metadata["vendor.example/cell"].enabled == true)
	assert(saved.cells[2].source:find("changed_result", 1, true))
	assert(saved.cells[2].outputs[1].data["application/vnd.example.widget+json"].state.value == 7)
	assert(vim.bo[state.buf].modified == false)
	close_fixture(state)
end)

test("no-op save does not synthesize a missing cell id", function()
	local path = vim.fn.tempname() .. ".ipynb"
	local file = assert(io.open(path, "wb"))
	file:write(
		'{"cells":[{"cell_type":"code","execution_count":null,"metadata":{},"outputs":[],"source":"x = 1"}],"metadata":{},"nbformat":4,"nbformat_minor":4}\n'
	)
	file:close()
	local state = open_path(path)
	assert(state.cells[1].had_id == false)
	assert(state:save())
	local saved_file = assert(io.open(path, "rb"))
	local saved = vim.json.decode(saved_file:read("*a"))
	saved_file:close()
	assert(saved.cells[1].id == nil)
	close_fixture(state)
end)

test("invalid marker edits are rejected without overwriting the file", function()
	local state = open_fixture("00_minimal.ipynb")
	local before_file = assert(io.open(state.path, "rb"))
	local before = before_file:read("*a")
	before_file:close()
	vim.api.nvim_buf_set_lines(state.buf, 0, 1, false, { "marker removed" })
	local ok, err = state:save()
	assert(not ok)
	assert(err:find("before the first", 1, true))
	local after_file = assert(io.open(state.path, "rb"))
	local after = after_file:read("*a")
	after_file:close()
	assert(after == before)
	close_fixture(state)
end)

test("creates a new notebook buffer with one code cell", function()
	local path = vim.fn.tempname() .. ".ipynb"
	os.remove(path)
	local state = open_path(path)
	assert(#state.cells == 1)
	assert(state.cells[1].cell_type == "code")
	assert(state.cells[1].is_new == true)
	assert(state:save())
	assert(vim.uv.fs_stat(path))
	close_fixture(state)
end)

test("attaches an existing empty ipynb and reserves the leader-n prefix", function()
	vim.keymap.set("n", "<leader>n", "<cmd>set number!<cr>", { nowait = true })
	local path = vim.fn.tempname() .. ".ipynb"
	local file = assert(io.open(path, "wb"))
	file:write("\n")
	file:close()
	local state = open_path(path)
	assert(#state.cells == 1)
	assert(state.cells[1].cell_type == "code")
	local prefix = vim.fn.maparg("<leader>n", "n", false, true)
	local insert_below = vim.fn.maparg("<leader>nb", "n", false, true)
	assert(prefix.buffer == 1)
	assert(prefix.nowait == 0)
	assert(insert_below.buffer == 1)
	assert(type(insert_below.callback) == "function")
	insert_below.callback()
	assert(#state.cells == 2)
	close_fixture(state)
	vim.keymap.del("n", "<leader>n")
end)

test("renders every notebook fixture without losing cell anchors", function()
	local fixture_files = vim.fn.globpath(fixture_path(""), "*.ipynb", false, true)
	assert(#fixture_files == 10)
	for _, source in ipairs(fixture_files) do
		local path = vim.fn.tempname() .. ".ipynb"
		assert(vim.uv.fs_copyfile(source, path))
		local state = open_path(path)
		render.render(state)
		local marker_marks = details(state, state.marker_ns)
		local render_marks = details(state, state.render_ns)
		assert(#marker_marks == #state.cells, source)
		assert(#render_marks >= #state.cells * 2, source)
		close_fixture(state)
	end
end)

test("undoing a type change restores code outputs", function()
	local state = open_fixture("01_markdown_code.ipynb")
	state:goto_cell(3)
	assert(#state.cells[3].outputs == 1)
	actions.change_type("markdown")
	assert(state.cells[3].cell_type == "markdown")
	vim.cmd.undo()
	assert(state:sync_from_buffer())
	assert(state.cells[3].cell_type == "code")
	assert(#state.cells[3].outputs == 1)
	close_fixture(state)
end)

test("duplicates source and metadata with a new id and cleared execution", function()
	local state = open_fixture("01_markdown_code.ipynb")
	state:goto_cell(3)
	local original = state.cells[3]
	local duplicate = actions.duplicate_cell()
	assert(#state.cells == 5)
	assert(duplicate.id ~= original.id)
	assert(duplicate.source == original.source)
	assert(duplicate.cell_type == "code")
	assert(#duplicate.outputs == 0)
	assert(duplicate.execution_count == vim.NIL)
	close_fixture(state)
end)

test("expands truncated output and clears saved output", function()
	local state = open_fixture("08_large_output.ipynb")
	state:goto_cell(1)
	assert(actions.toggle_output() == true)
	assert(state.cells[1].output_expanded == true)
	local virtual_text = {}
	for _, mark in ipairs(details(state, state.render_ns)) do
		for _, virtual_line in ipairs(mark[4].virt_lines or {}) do
			for _, chunk in ipairs(virtual_line) do
				table.insert(virtual_text, chunk[1])
			end
		end
	end
	assert(find_line(virtual_text, "full output"))
	assert(not find_line(virtual_text, "more output lines"))
	assert(actions.toggle_output() == false)
	assert(state.cells[1].output_expanded == false)
	assert(actions.clear_output())
	assert(#state.cells[1].outputs == 0)
	assert(state.cells[1].execution_count == nil)
	assert(vim.bo[state.buf].modified)
	close_fixture(state)
end)

test("toggles a manual fold for cell source", function()
	local state = open_fixture("00_minimal.ipynb")
	state:goto_cell(1)
	local source_line = state.cells[1].range.start_row + 1
	assert(actions.toggle_source() == true)
	assert(vim.fn.foldclosed(source_line) >= 0)
	assert(actions.toggle_source() == false)
	assert(vim.fn.foldclosed(source_line) == -1)
	close_fixture(state)
end)

test("no-op Lua load and save preserves every fixture semantically", function()
	for _, source in ipairs(vim.fn.globpath(fixture_path(""), "*.ipynb", false, true)) do
		local path = vim.fn.tempname() .. ".ipynb"
		assert(vim.uv.fs_copyfile(source, path))
		local original_file = assert(io.open(path, "rb"))
		local original = vim.json.decode(original_file:read("*a"))
		original_file:close()
		local state = open_path(path)
		assert(state:save())
		local saved_file = assert(io.open(path, "rb"))
		local saved = vim.json.decode(saved_file:read("*a"))
		saved_file:close()
		assert(vim.deep_equal(saved, original), source)
		close_fixture(state)
	end
end)

test("source lines that resemble structural markers round-trip safely", function()
	local path = vim.fn.tempname() .. ".ipynb"
	local source_line = "# %%[nvjup:cell id=looks-real type=code]"
	local document = {
		cells = {
			{
				cell_type = "code",
				execution_count = vim.NIL,
				id = "real-cell",
				metadata = {},
				outputs = {},
				source = source_line,
			},
		},
		metadata = {},
		nbformat = 4,
		nbformat_minor = 5,
	}
	local file = assert(io.open(path, "wb"))
	file:write(vim.json.encode(document))
	file:close()
	local state = open_path(path)
	assert(#state.cells == 1)
	assert(state.cells[1].source == source_line)
	assert(state:save())
	local saved_file = assert(io.open(path, "rb"))
	local saved = vim.json.decode(saved_file:read("*a"))
	saved_file:close()
	assert(saved.cells[1].source == source_line)
	close_fixture(state)
end)

test("bounds and caches large HTML output before sanitization", function()
	local previous = config.options.render.max_html_bytes
	config.options.render.max_html_bytes = 64
	local cell = {
		output_revision = 0,
		outputs = {
			{
				output_type = "display_data",
				data = {
					["text/html"] = "<script>" .. string.rep("base64-frame", 64) .. "</script>",
					["text/plain"] = "animation fallback",
				},
				metadata = {},
			},
		},
	}
	local first = output.segments(cell, { include_images = false })
	local second = output.segments(cell, { include_images = false })
	assert(first == second)
	assert(find_line(first[1].lines, "animation fallback"))
	assert(find_line(first[1].lines, "HTML output omitted"))
	assert(find_line(first[1].lines, "payload retained in notebook"))

	cell.outputs[1].data["text/html"] = "<b>small</b>"
	Notebook.touch_outputs(cell)
	local third = output.segments(cell, { include_images = false })
	assert(third ~= second)
	assert(find_line(third[1].lines, "small"))
	local border_width = config.options.border_width
	config.options.border_width = border_width + 1
	local resized = output.segments(cell, { include_images = false })
	config.options.border_width = border_width
	assert(resized ~= third)
	config.options.render.max_html_bytes = previous
end)

test("avoids copying cells without interactive MIME", function()
	local cell = {
		outputs = {
			{ output_type = "display_data", data = { ["text/plain"] = "plain" }, metadata = {} },
		},
	}
	local prepared, seen = interactive.prepare_cell({}, cell)
	assert(prepared == cell)
	assert(next(seen) == nil)
end)

test("skips collapsed output preprocessing", function()
	local state = open_fixture("08_large_output.ipynb")
	state.cells[1].output_collapsed = true
	local original = output.segments
	local calls = 0
	output.segments = function(...)
		calls = calls + 1
		return original(...)
	end
	render.render(state)
	output.segments = original
	assert(calls == 0)
	close_fixture(state)
end)

test("uses lightweight cursor updates and coalesces text renders", function()
	local state = open_fixture("01_markdown_code.ipynb")
	local original_render = render.render
	local original_active = render.active
	local original_cell = render.render_cell
	local full_calls, active_calls, cell_calls = 0, 0, 0
	render.render = function(...)
		full_calls = full_calls + 1
		return true
	end
	render.active = function(...)
		active_calls = active_calls + 1
		return true
	end
	render.render_cell = function(_, _, options)
		assert(options.source == true)
		cell_calls = cell_calls + 1
		return true
	end
	vim.api.nvim_exec_autocmds("CursorMoved", { buffer = state.buf, modeline = false })
	assert(full_calls == 0)
	assert(active_calls == 1)

	local changed = { [state.cells[1].id] = true }
	for _ = 1, 5 do
		render.request_source(state, changed, false, 10)
	end
	assert(vim.wait(500, function()
		return cell_calls == 1
	end, 5))
	vim.wait(50)
	render.render = original_render
	render.active = original_active
	render.render_cell = original_cell
	assert(full_calls == 0)
	close_fixture(state)
end)

test("updates edited cell chrome without rebuilding untouched cells", function()
	local state = open_fixture("01_markdown_code.ipynb")
	local edited = state.cells[1]
	local untouched = state.cells[2]
	local untouched_header = untouched.render_header_mark
	local insert_row = edited.range.end_exclusive
	state.internal_change = true
	vim.api.nvim_buf_set_lines(state.buf, insert_row, insert_row, false, { "new paragraph" })
	state.internal_change = false
	local ok, changed, structural = state:sync_from_buffer()
	assert(ok and not structural and changed[edited.id])
	render.request_source(state, changed, structural, 5)
	assert(vim.wait(500, function()
		return state.render_request_cells and next(state.render_request_cells) == nil
	end, 5))
	assert(untouched.render_header_mark == untouched_header)
	local marks = vim.api.nvim_buf_get_extmarks(
		state.buf,
		state.render_ns,
		{ edited.range.end_row, 0 },
		{ edited.range.end_row, -1 },
		{ details = true }
	)
	local border = false
	for _, mark in ipairs(marks) do
		local virtual = mark[4].virt_text or {}
		if virtual[1] and virtual[1][1] == "│ " then
			border = true
		end
	end
	assert(border, "new source row did not receive notebook borders")
	close_fixture(state)
end)

test("uses one timer and targeted cell renders for output bursts", function()
	local state = open_fixture("01_markdown_code.ipynb")
	local cell = state.cells[#state.cells]
	local original_render = render.render
	local original_cell = render.render_cell
	local full_calls, cell_calls = 0, 0
	render.render = function(...)
		full_calls = full_calls + 1
		return true
	end
	render.render_cell = function(_, id)
		assert(id == cell.id)
		cell_calls = cell_calls + 1
		return true
	end
	for _ = 1, 1000 do
		render.request_cell(state, cell, 10)
	end
	local timer = state.render_request_timer
	assert(timer and not timer:is_closing())
	assert(vim.wait(500, function()
		return cell_calls == 1
	end, 5))
	assert(state.render_request_timer == timer)
	assert(full_calls == 0)
	render.render = original_render
	render.render_cell = original_cell
	close_fixture(state)
end)

test("renders every planned MIME family with an explicit semantic fallback", function()
	local cases = {
		{ "text/plain", "plain", "text" },
		{ "text/markdown", "**markdown**", "markdown" },
		{ "text/html", "<b>html</b>", "html" },
		{ "text/latex", "x^2", "latex" },
		{ "image/png", "AAAA", "image" },
		{ "image/jpeg", "AAAA", "image" },
		{ "image/svg+xml", "<svg/>", "image" },
		{ "application/pdf", "AAAA", "image" },
		{ "application/x-unknown", { opaque = true }, "unsupported" },
	}
	for _, case in ipairs(cases) do
		local lines, kinds = output.render({
			outputs = {
				{ output_type = "display_data", data = { [case[1]] = case[2] }, metadata = {} },
			},
		})
		assert(#lines >= 1, case[1])
		assert(kinds[1] == case[3], case[1])
	end
end)

if #failures > 0 then
	print(
		string.format(
			"Stage 1 Lua tests: %d passed, %d failed\n\n%s",
			passed,
			#failures,
			table.concat(failures, "\n\n")
		)
	)
	vim.cmd("cquit 1")
	return
end

print(string.format("Stage 1 Lua tests: %d passed", passed))
vim.cmd("qa!")
