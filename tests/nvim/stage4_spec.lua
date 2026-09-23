local root = assert(vim.env.NVJUP_PROJECT_ROOT)
local Notebook = require("nvjup.notebook")
local actions = require("nvjup.actions")
local config = require("nvjup.config")
local image = require("nvjup.image")
local output = require("nvjup.output")
local render = require("nvjup.render")

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

local function open_fixture(name)
	local path = vim.fn.tempname() .. ".ipynb"
	assert(vim.uv.fs_copyfile(fixture_path(name), path))
	vim.cmd("silent edit! " .. vim.fn.fnameescape(path))
	local state = assert(Notebook.get(), "notebook state was not attached")
	assert(state:sync_from_buffer())
	return state
end

local function close_fixture(state)
	local path = state.path
	vim.cmd("silent! bwipeout!")
	os.remove(path)
end

local function contains(lines, fragment)
	for _, line in ipairs(lines) do
		if line:find(fragment, 1, true) then
			return true
		end
	end
	return false
end

local function collect_virtual_text(state)
	local values = {}
	for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(state.buf, state.render_ns, 0, -1, { details = true })) do
		for _, virtual_line in ipairs(mark[4].virt_lines or {}) do
			for _, chunk in ipairs(virtual_line) do
				table.insert(values, chunk[1])
			end
		end
	end
	return values
end

test("renders HTML tables as bounded terminal tables", function()
	local lines = output.render({
		outputs = {
			{
				output_type = "display_data",
				data = {
					["text/html"] = "<table><thead><tr><th></th><th>a</th><th>b</th></tr></thead><tbody><tr><th>0</th><td>1.25</td><td>-2</td></tr></tbody></table>",
				},
				metadata = {},
			},
		},
	})
	assert(lines[1]:find("┌", 1, true))
	assert(contains(lines, " a "))
	assert(contains(lines, " 1.25 "))
	assert(contains(lines, " -2 "))
	assert(lines[#lines]:find("└", 1, true))
end)

test("renders every table row when output limits are disabled", function()
	local rows = { "<tr><th>index</th><th>value</th></tr>" }
	for index = 1, 30 do
		table.insert(rows, string.format("<tr><th>%d</th><td>%d</td></tr>", index, index * 10))
	end
	local cell = {
		outputs = {
			{
				output_type = "display_data",
				data = { ["text/html"] = "<table>" .. table.concat(rows) .. "</table>" },
				metadata = {},
			},
		},
	}
	local limited = output.render(cell)
	local full = output.render(cell, { limit = false })
	assert(#limited == config.options.render.max_output_lines + 1)
	assert(#full == 63)
	assert(contains(full, " 30 "))
	assert(contains(full, " 300 "))
	assert(not contains(full, "more output"))
end)

test("renders only the latest tqdm carriage-return frame", function()
	local cell = {
		outputs = {
			{ output_type = "stream", name = "stderr", text = "first\r\n\r  0%\r 50%\r100%\ncomplete\r" },
		},
	}
	local lines = output.render(cell, { limit = false })
	assert(contains(lines, "first"))
	assert(contains(lines, "100%"))
	assert(contains(lines, "complete"))
	assert(not contains(lines, "  0%"))
	assert(not contains(lines, " 50%"))
	cell.outputs[1].text = cell.outputs[1].text .. "\rnew progress"
	lines = output.render(cell, { limit = false })
	assert(contains(lines, "new progress"))
end)

test("renders live tqdm ipywidget state as a terminal progress bar", function()
	local progress_id = "progress-model"
	local left_id = "left-model"
	local right_id = "right-model"
	local cell = {
		widget_models = {
			root = {
				state = {
					_model_name = "HBoxModel",
					children = {
						"IPY_MODEL_" .. left_id,
						"IPY_MODEL_" .. progress_id,
						"IPY_MODEL_" .. right_id,
					},
				},
			},
			[left_id] = { state = { _model_name = "HTMLModel", value = " 50%" } },
			[progress_id] = {
				state = { _model_name = "FloatProgressModel", min = 0, max = 4, value = 2 },
			},
			[right_id] = { state = { _model_name = "HTMLModel", value = " 2/4 [00:01&lt;00:01]" } },
		},
		outputs = {
			{
				output_type = "display_data",
				data = {
					["text/plain"] = "TqdmHBox(children=(...))",
					["application/vnd.jupyter.widget-view+json"] = { model_id = "root" },
				},
				metadata = {},
			},
		},
	}
	local lines = output.render(cell, { limit = false })
	assert(contains(lines, "50%"))
	assert(contains(lines, "2/4"))
	assert(contains(lines, "██████████░░░░░░░░░░"))
end)

test("sanitizes active HTML instead of executing it", function()
	local lines = output.render({
		outputs = {
			{
				output_type = "display_data",
				data = { ["text/html"] = "<script>\nalert('bad')\n</script><b>safe</b>" },
				metadata = {},
			},
		},
	})
	local text = table.concat(lines, "\n")
	assert(text:find("safe", 1, true))
	assert(not text:find("alert", 1, true))
end)

test("extracts one preferred static image from each MIME bundle", function()
	local descriptors = image.descriptors({
		outputs = {
			{
				output_type = "display_data",
				data = { ["image/png"] = "AAAA", ["image/svg+xml"] = "<svg/>" },
				metadata = {},
			},
			{
				output_type = "execute_result",
				data = { ["application/pdf"] = "AAAA" },
				metadata = {},
			},
		},
	})
	assert(#descriptors == 2)
	assert(descriptors[1].mime == "image/png")
	assert(descriptors[2].mime == "application/pdf")
end)

test("blocks active and externally-referenced SVG content", function()
	assert(image._safe_svg('<svg xmlns="http://www.w3.org/2000/svg"><rect width="2" height="2"/></svg>'))
	assert(not image._safe_svg("<svg><script>alert(1)</script></svg>"))
	assert(not image._safe_svg('<svg><image href="https://example.test/a.png"/></svg>'))
	assert(not image._safe_svg('<svg><rect onclick="alert(1)"/></svg>'))
end)

test("encodes bounded Kitty chunks with an explicit virtual placement", function()
	local encoded = image._encode_transmit(0x123456, string.rep("A", 100000), 12, 40)
	assert(encoded:find("a=t,f=100,i=1193046", 1, true))
	assert(encoded:find("m=1", 1, true))
	assert(encoded:find("m=0", 1, true))
	assert(encoded:find("a=p,U=1,i=1193046,p=1,c=40,r=12", 1, true))
	local chunks = 0
	for command in encoded:gmatch("\27_G.-\27\\") do
		chunks = chunks + 1
		assert(#command < 4096, "Kitty APC command exceeded terminal parser limit: " .. #command)
	end
	assert(chunks > 2)
end)

test("renders PNG through Kitty Unicode placeholders and cleans it up", function()
	local writes = {}
	image._set_test_writer(function(value)
		table.insert(writes, value)
		return true
	end)
	local previous = config.options.render.images.backend
	config.options.render.images.backend = "kitty"
	local state = { buf = vim.api.nvim_get_current_buf() }
	local cell = {
		id = "stage4-image",
		outputs = {
			{
				output_type = "display_data",
				data = {
					["image/png"] = "iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAYAAAC09K7GAAAAEklEQVR42mPwKdrwHxkzEBQAANiRHR2gDahVAAAAAElFTkSuQmCC",
				},
				metadata = { ["image/png"] = { width = 320, height = 240 } },
			},
		},
	}
	local virtual_lines, seen = image.render(state, cell, 80)
	assert(#virtual_lines > 1)
	assert(next(seen) ~= nil)
	assert(table
		.concat(
			vim.tbl_map(function(chunks)
				return chunks[#chunks][1]
			end, virtual_lines),
			""
		)
		:find(vim.fn.nr2char(0x10EEEE), 1, true))
	assert(writes[1]:find("a=t,f=100", 1, true))
	image.finish_render(state, {})
	assert(writes[#writes]:find("a=d,d=I", 1, true))
	config.options.render.images.backend = previous
	image._set_test_writer(nil)
end)

test("keeps the previous Kitty frame until its replacement is painted", function()
	local writes = {}
	image._set_test_writer(function(value)
		table.insert(writes, value)
		return true
	end)
	local previous_backend = config.options.render.images.backend
	config.options.render.images.backend = "kitty"
	local state = { buf = vim.api.nvim_get_current_buf() }
	local cell = {
		id = "stage4-frame-replacement",
		outputs = {
			{
				output_type = "display_data",
				data = {
					["image/png"] = "iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAYAAAC09K7GAAAAEklEQVR42mPwKdrwHxkzEBQAANiRHR2gDahVAAAAAElFTkSuQmCC",
				},
				metadata = {},
			},
		},
	}
	image.render(state, cell, 80)
	cell.outputs[1].data["image/png"] =
		"iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR42mO4Y6T/H4QZYAwAT7YI8XsRX9YAAAAASUVORK5CYII="
	local before = #writes
	image.render(state, cell, 80)
	assert(#writes == before + 1)
	assert(writes[#writes]:find("a=t,f=100", 1, true), "replacement was not transmitted before deletion")
	assert(not table.concat(writes):find("a=d,d=I", 1, true), "old frame was deleted too early")
	assert(vim.wait(500, function()
		return writes[#writes]:find("a=d,d=I", 1, true) ~= nil
	end, 5))
	image.finish_render(state, {})
	config.options.render.images.backend = previous_backend
	image._set_test_writer(nil)
end)

test("rasterizes safe SVG output and transmits the resulting PNG", function()
	assert(vim.fn.executable("magick") == 1 or vim.fn.executable("convert") == 1)
	local writes = {}
	image._set_test_writer(function(value)
		table.insert(writes, value)
		return true
	end)
	local previous = config.options.render.images.backend
	config.options.render.images.backend = "kitty"
	local state = open_fixture("03_rich_outputs.ipynb")
	local function transmissions()
		local count = 0
		for _, value in ipairs(writes) do
			if value:find("a=t,f=100", 1, true) then
				count = count + 1
			end
		end
		return count
	end
	assert(
		vim.wait(15000, function()
			return transmissions() >= 2
		end, 20),
		"timed out waiting for SVG rasterization"
	)
	assert(contains(collect_virtual_text(state), vim.fn.nr2char(0x10EEEE)))
	close_fixture(state)
	config.options.render.images.backend = previous
	image._set_test_writer(nil)
end)

test("uses a visible bounded fallback when graphics are disabled", function()
	local previous = config.options.render.images.backend
	config.options.render.images.backend = "text"
	local state = { buf = vim.api.nvim_get_current_buf() }
	local cell = {
		id = "stage4-fallback",
		outputs = {
			{
				output_type = "display_data",
				data = { ["image/png"] = "AAAA" },
				metadata = { ["image/png"] = { width = 10, height = 5 } },
			},
		},
	}
	local virtual_lines = image.render(state, cell, 80)
	assert(#virtual_lines == 1)
	assert(virtual_lines[1][1][1]:find("image/png", 1, true))
	image.finish_render(state, {})
	config.options.render.images.backend = previous
end)

test("opens full untruncated output in a closeable pager", function()
	local state = open_fixture("08_large_output.ipynb")
	state:goto_cell(1)
	local buffer, window = actions.open_output("float")
	assert(vim.api.nvim_buf_is_valid(buffer))
	assert(vim.api.nvim_win_is_valid(window))
	assert(vim.api.nvim_buf_line_count(buffer) > config.options.render.max_output_lines)
	assert(vim.api.nvim_buf_get_keymap(buffer, "n")[1] ~= nil)
	vim.api.nvim_win_close(window, true)
	close_fixture(state)
end)

test("integrates rich output rendering and pager commands into notebook buffers", function()
	local previous = config.options.render.images.backend
	config.options.render.images.backend = "text"
	local state = open_fixture("03_rich_outputs.ipynb")
	render.render(state)
	local text = collect_virtual_text(state)
	assert(contains(text, "image/png 320x240"))
	assert(contains(text, "┌"))
	local image_index, table_index
	for index, value in ipairs(text) do
		image_index = image_index or (value:find("image/png", 1, true) and index or nil)
		table_index = table_index or (value:find("┌", 1, true) and index or nil)
	end
	assert(image_index and table_index and image_index < table_index)
	local commands = vim.api.nvim_buf_get_commands(state.buf, {})
	assert(commands.NvJupOutputOpen)
	assert(vim.fn.maparg("<leader>np", "n", false, true).buffer == 1)
	close_fixture(state)
	config.options.render.images.backend = previous
end)

image._set_test_writer(nil)

if #failures > 0 then
	print(
		string.format(
			"Stage 4 Lua tests: %d passed, %d failed\n\n%s",
			passed,
			#failures,
			table.concat(failures, "\n\n")
		)
	)
	vim.cmd("cquit 1")
	return
end

print(string.format("Stage 4 Lua tests: %d passed", passed))
vim.cmd("qa!")
