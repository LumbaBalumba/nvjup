local config = require("nvjup.config")
local local_fs = require("nvjup.local_fs")
local notebook = require("nvjup.notebook")
local remote = require("nvjup.remote")
local remote_files = require("nvjup.remote_files")
local remote_files_client = require("nvjup.remote_files_client")

local root = assert(vim.g.nvjup_project_root)
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
	vim.cmd.edit(vim.fn.fnameescape(fixture_path(name)))
	return assert(notebook.get())
end

local function close_fixture(state)
	if state and vim.api.nvim_buf_is_valid(state.buf) then
		vim.api.nvim_buf_delete(state.buf, { force = true })
	end
end

test("registers the global remote-files command", function()
	assert(vim.fn.exists(":NvJupRemoteFiles") == 2)
end)

test("performs bounded local filesystem operations", function()
	local base = vim.fn.tempname()
	assert(local_fs.mkdir(base))
	local source = vim.fs.joinpath(base, "source")
	assert(local_fs.mkdir(source))
	assert(local_fs.write(vim.fs.joinpath(source, "data.bin"), "a\0b"))
	assert(local_fs.write(vim.fs.joinpath(source, ".hidden"), "secret"))
	local visible = assert(local_fs.list(source, false))
	assert(#visible == 1 and visible[1].name == "data.bin")
	local all = assert(local_fs.list(source, true))
	assert(#all == 2)
	local copy = vim.fs.joinpath(base, "copy")
	assert(local_fs.copy(source, copy, 10))
	assert(local_fs.read(vim.fs.joinpath(copy, "data.bin"), 32) == "a\0b")
	local moved = vim.fs.joinpath(base, "moved")
	assert(local_fs.move(copy, moved, 10))
	assert(vim.uv.fs_stat(copy) == nil and vim.uv.fs_stat(moved))
	assert(local_fs.rename(vim.fs.joinpath(moved, "data.bin"), vim.fs.joinpath(moved, "renamed.bin")))
	assert(local_fs.delete(base))
	assert(vim.uv.fs_stat(base) == nil)
end)

test("resolves bounded remote file transport options", function()
	vim.env.NVJUP_STAGE8_TOKEN = "stage8-secret"
	config.options.kernel.remote = {
		url = "https://example.test/jupyter",
		token_env = "NVJUP_STAGE8_TOKEN",
		verify_ssl = true,
		reconnect_attempts = 99,
		max_file_bytes = 2048,
		max_entries = 12,
		file_timeout_seconds = 7,
	}
	local resolved = assert(remote.resolve({ path = "/tmp/notebook.ipynb" }))
	config.options.kernel.remote = false
	vim.env.NVJUP_STAGE8_TOKEN = nil
	assert(resolved.token == "stage8-secret")
	assert(resolved.reconnect_attempts == 5)
	assert(resolved.max_file_bytes == 2048)
	assert(resolved.max_entries == 12)
	assert(resolved.file_timeout_seconds == 7)
end)

test("routes remote file RPC without starting a kernel", function()
	local requests = {}
	local fake
	remote_files_client._set_client_factory(function()
		fake = { alive = false }
		function fake:start()
			self.alive = true
			return true
		end
		function fake:request(request_type, payload, _, callback)
			table.insert(requests, { type = request_type, payload = payload })
			if request_type == "sidecar.hello" then
				callback(nil, { capabilities = { requests = { "remote.files.list" } } })
			elseif request_type == "remote.files.list" then
				callback(nil, { path = "", entries = { { name = "remote.txt", path = "remote.txt", type = "file" } } })
			elseif request_type == "remote.files.download" then
				callback(nil, { content = vim.base64.encode("remote bytes"), encoding = "base64", size = 12 })
			elseif request_type == "remote.files.upload" then
				callback(nil, { name = "uploaded.bin", path = payload.path, type = "file" })
			else
				callback(nil, {})
			end
		end
		function fake:shutdown()
			self.alive = false
		end
		return fake
	end)
	config.options.kernel.remote = { url = "https://example.test", token = "secret" }
	local client = remote_files_client.new({ path = "/tmp/test.ipynb" })
	local listed
	client:list("", function(err, payload)
		assert(err == nil)
		listed = payload.entries
	end)
	assert(listed[1].name == "remote.txt")
	local downloaded
	client:download("remote.txt", function(err, content)
		assert(err == nil)
		downloaded = content
	end)
	assert(downloaded == "remote bytes")
	client:upload("uploaded.bin", "a\0b", function(err)
		assert(err == nil)
	end)
	assert(requests[2].type == "remote.files.list")
	assert(requests[2].payload.remote.token == "secret")
	assert(requests[4].payload.content == vim.base64.encode("a\0b"))
	for _, request in ipairs(requests) do
		assert(request.type ~= "kernel.start")
	end
	client:shutdown()
	config.options.kernel.remote = false
	remote_files_client._set_client_factory(nil)
end)

test("recursively transfers a local directory tree to remote storage", function()
	local base = vim.fn.tempname()
	local source = vim.fs.joinpath(base, "tree")
	assert(local_fs.mkdir(vim.fs.joinpath(source, "nested")))
	assert(local_fs.write(vim.fs.joinpath(source, "root.txt"), "root"))
	assert(local_fs.write(vim.fs.joinpath(source, "nested", "leaf.bin"), "leaf\0data"))
	local directories, files = {}, {}
	local browser = {
		max_file_bytes = 1024,
		client = {
			mkdir = function(_, path, callback)
				table.insert(directories, path)
				callback(nil, {})
			end,
			upload = function(_, path, content, callback)
				files[path] = content
				callback(nil, {})
			end,
		},
	}
	local completed, failure
	remote_files._copy_recursive(
		browser,
		"local",
		{ name = "tree", path = source, type = "directory", side = "local" },
		"remote",
		"workspace/tree",
		{ count = 0, max = 20, bytes = 0, max_bytes = 1024 },
		function(ok, err)
			completed, failure = ok, err
		end
	)
	assert(completed, failure)
	assert(directories[1] == "workspace/tree")
	assert(files["workspace/tree/root.txt"] == "root")
	assert(files["workspace/tree/nested/leaf.bin"] == "leaf\0data")
	assert(local_fs.delete(base))
end)

test("builds a two-panel Telescope manager with nvim-tree operations and transfer", function()
	local saved = {}
	for _, name in ipairs({
		"telescope",
		"telescope.pickers",
		"telescope.finders",
		"telescope.config",
		"telescope.previewers",
		"telescope.actions",
		"telescope.actions.state",
	}) do
		saved[name] = package.loaded[name]
	end
	local selected
	local mappings = { i = {}, n = {} }
	local picker_options
	local picker
	local select_default = {}
	function select_default:replace(callback)
		self.callback = callback
	end
	package.loaded["telescope"] = {}
	package.loaded["telescope.finders"] = {
		new_table = function(options)
			return options
		end,
	}
	package.loaded["telescope.config"] = { values = {
		generic_sorter = function()
			return {}
		end,
	} }
	package.loaded["telescope.previewers"] = {
		new_buffer_previewer = function(options)
			return options
		end,
	}
	package.loaded["telescope.actions"] = {
		select_default = select_default,
		close = function() end,
	}
	package.loaded["telescope.actions.state"] = {
		get_selected_entry = function()
			return selected and { value = selected } or nil
		end,
	}
	package.loaded["telescope.pickers"] = {
		new = function(_, options)
			picker_options = options
			picker = {
				prompt_bufnr = vim.api.nvim_create_buf(false, true),
				prompt_win = vim.api.nvim_get_current_win(),
				prompt_border = { change_title = function() end },
				refresh = function(self, new_finder)
					self.finder = new_finder
				end,
				find = function(self)
					options.attach_mappings(self.prompt_bufnr, function(mode, key, callback)
						mappings[mode][key] = callback
					end)
				end,
			}
			return picker
		end,
	}

	local base = vim.fn.tempname()
	assert(local_fs.mkdir(base))
	local local_path = vim.fs.joinpath(base, "send.bin")
	assert(local_fs.write(local_path, "transfer\0data"))
	local uploaded
	local shutdown = false
	local browser = {
		state = { buf = vim.api.nvim_get_current_buf() },
		client = {
			stat = function(_, _, callback)
				callback({ code = "remote_files_stat_failed", message = "HTTP 404" })
			end,
			upload = function(_, path, content, callback)
				uploaded = { path = path, content = content }
				callback(nil, {})
			end,
			list = function(_, path, callback)
				callback(nil, { path = path, entries = {} })
			end,
			shutdown = function()
				shutdown = true
			end,
		},
		active = "local",
		["local"] = {
			path = base,
			entries = { { name = "send.bin", path = local_path, type = "file", side = "local" } },
		},
		remote = { path = "workspace", entries = {} },
		show_hidden = false,
		confirm_delete = false,
		max_file_bytes = 1024,
		max_transfer_bytes = 4096,
		max_entries = 100,
		closed = false,
		pending = false,
	}
	selected = browser["local"].entries[1]
	remote_files._launch(browser)
	assert(picker_options.layout_strategy == "horizontal")
	assert(picker_options.layout_config.preview_width == 0.5)
	for _, key in ipairs({ "a", "c", "d", "e", "r", "x", "gp", "p", "R", "H", "P", "<BS>", "g?", "q" }) do
		assert(mappings.n[key], "missing nvim-tree mapping " .. key)
	end
	mappings.n.c()
	mappings.n["<Tab>"]()
	assert(browser.active == "remote")
	mappings.n.p()
	assert(uploaded.path == "workspace/send.bin")
	assert(uploaded.content == "transfer\0data")
	local preview_buf = vim.api.nvim_create_buf(false, true)
	picker_options.previewer.define_preview({ state = { bufnr = preview_buf } })
	local preview = table.concat(vim.api.nvim_buf_get_lines(preview_buf, 0, -1, false), "\n")
	assert(preview:find("Local", 1, true))
	vim.api.nvim_buf_delete(preview_buf, { force = true })
	vim.api.nvim_buf_delete(picker.prompt_bufnr, { force = true })
	assert(shutdown)
	assert(local_fs.delete(base))
	for name, value in pairs(saved) do
		package.loaded[name] = value
	end
end)

test("registers the remote file command and notebook mapping", function()
	local state = open_fixture("00_minimal.ipynb")
	assert(vim.fn.exists(":NvJupRemoteFiles") == 2)
	local found = false
	for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(state.buf, "n")) do
		if mapping.lhs == "<Space>ne" or mapping.desc == "Local/remote Jupyter file manager" then
			found = true
		end
	end
	close_fixture(state)
	assert(found)
end)

if #failures > 0 then
	error(
		string.format(
			"Stage 8 Lua tests: %d passed, %d failed\n\n%s",
			passed,
			#failures,
			table.concat(failures, "\n\n")
		)
	)
end
print(string.format("Stage 8 Lua tests: %d passed", passed))
vim.cmd.quitall({ bang = true })
