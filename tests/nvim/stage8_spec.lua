local config = require("nvjup.config")
local local_fs = require("nvjup.local_fs")
local notebook = require("nvjup.notebook")
local remote = require("nvjup.remote")
local remote_connection = require("nvjup.remote_connection")
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

test("registers the global remote UI commands", function()
	assert(vim.fn.exists(":NvJupRemoteConnect") == 2)
	assert(vim.fn.exists(":NvJupRemoteDisconnect") == 2)
	assert(vim.fn.exists(":NvJupRemoteStatus") == 2)
	assert(vim.fn.exists(":NvJupRemoteFiles") == 2)
end)

test("reuses an already loaded notebook during local file navigation", function()
	local state = open_fixture("00_minimal.ipynb")
	assert(remote_files._loaded_buffer(state.path) == state.buf)
	local original_actions = package.loaded["telescope.actions"]
	package.loaded["telescope.actions"] = { close = function() end }
	local scratch = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_current_buf(scratch)
	remote_files._navigate({ active = "local", prompt_bufnr = 0 }, {
		name = vim.fs.basename(state.path),
		path = state.path,
		type = "file",
		side = "local",
	})
	assert(vim.wait(1000, function()
		return vim.api.nvim_get_current_buf() == state.buf
	end, 10))
	assert(notebook.get(state.buf) == state)
	package.loaded["telescope.actions"] = original_actions
	vim.api.nvim_buf_delete(scratch, { force = true })
	close_fixture(state)
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

test("runs recursive local copies and deletion asynchronously", function()
	local base = vim.fn.tempname()
	local source = vim.fs.joinpath(base, "source")
	assert(local_fs.mkdir(source))
	for index = 1, 50 do
		assert(local_fs.write(vim.fs.joinpath(source, "file-" .. index), tostring(index)))
	end
	local target = vim.fs.joinpath(base, "target")
	local copied, copy_error
	local_fs.copy_async(source, target, 100, function(ok, err)
		copied, copy_error = ok, err
	end)
	assert(
		vim.wait(5000, function()
			return copied ~= nil or copy_error ~= nil
		end, 5),
		copy_error
	)
	assert(copied and local_fs.read(vim.fs.joinpath(target, "file-50"), 32) == "50")
	local deleted, delete_error
	local_fs.delete_async(base, function(ok, err)
		deleted, delete_error = ok, err
	end)
	assert(
		vim.wait(5000, function()
			return deleted ~= nil or delete_error ~= nil
		end, 5),
		delete_error
	)
	assert(deleted and not vim.uv.fs_stat(base))
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

test("keeps UI connection credentials in a session-only override", function()
	config.options.kernel.remote = { url = "https://configured.test", token = "configured" }
	remote.set_session({
		url = "https://session.test/jupyter/",
		token = "session-secret",
		verify_ssl = true,
		kernel_name = "python-ui",
	})
	local resolved = assert(remote.resolve({ path = "/tmp/notebook.ipynb" }))
	assert(resolved.url == "https://session.test/jupyter")
	assert(resolved.token == "session-secret")
	assert(remote.kernel_name() == "python-ui")
	assert(remote.status().source == "session")
	remote.disconnect()
	assert(remote.resolve() == nil)
	remote.reset_session()
	assert(remote.resolve().url == "https://configured.test")
	config.options.kernel.remote = false
end)

test("activates a probed UI profile and starts the selected kernel", function()
	local state = open_fixture("00_minimal.ipynb")
	local calls = { shutdown_remote = 0, shutdown = 0, start = 0 }
	remote_connection._set_kernel({
		shutdown_remote_sessions = function()
			calls.shutdown_remote = calls.shutdown_remote + 1
		end,
		shutdown = function(shutdown_state)
			assert(shutdown_state == state)
			calls.shutdown = calls.shutdown + 1
		end,
		start = function(start_state, callback)
			assert(start_state == state)
			calls.start = calls.start + 1
			callback(nil, { state = "idle", transport = "remote" })
		end,
	})
	local completed
	remote_connection.activate(
		state,
		{
			url = "https://ui.test/jupyter",
			token = "ui-secret",
			verify_ssl = true,
		},
		"python-ui",
		function(err, status)
			assert(err == nil)
			completed = status
		end
	)
	assert(calls.shutdown_remote == 1 and calls.shutdown == 1 and calls.start == 1)
	assert(completed.transport == "remote")
	assert(remote.resolve(state).kernel_name == "python-ui")
	remote.disconnect()
	remote.reset_session()
	remote_connection._set_kernel(nil)
	close_fixture(state)
end)

test("runs the complete remote connection wizard through Neovim UI", function()
	local state = open_fixture("00_minimal.ipynb")
	local original_input, original_select = vim.ui.input, vim.ui.select
	local inputs = { "https://wizard.test/jupyter/", "https://origin.test" }
	local probed
	vim.ui.input = function(_, callback)
		callback(table.remove(inputs, 1))
	end
	vim.ui.select = function(items, options, callback)
		if options.prompt == "Jupyter authentication" then
			callback("Enter token")
		elseif options.prompt == "TLS policy" then
			callback(items[1])
		elseif options.prompt:match("^Kernel on ") then
			callback(items[1])
		else
			error("unexpected prompt: " .. tostring(options.prompt))
		end
	end
	remote_connection._set_secret_reader(function(_, callback)
		callback("wizard-secret")
	end)
	remote_connection._set_client_factory(function(_, options)
		probed = options
		return {
			probe = function(_, callback)
				callback(nil, {
					url = options.url,
					kernels = { { name = "python3", display_name = "Python 3", language = "python" } },
				})
			end,
			shutdown = function() end,
		}
	end)
	local started
	remote_connection._set_kernel({
		shutdown_remote_sessions = function() end,
		shutdown = function() end,
		start = function(_, callback)
			started = true
			callback(nil, { state = "idle", transport = "remote" })
		end,
	})
	assert(remote_connection.connect(state))
	assert(started)
	assert(probed.url == "https://wizard.test/jupyter")
	assert(probed.token == "wizard-secret")
	assert(probed.verify_ssl == true)
	assert(probed.origin == "https://origin.test")
	assert(remote.resolve(state).kernel_name == "python3")
	vim.ui.input, vim.ui.select = original_input, original_select
	remote.disconnect()
	remote.reset_session()
	remote_connection._set_secret_reader(nil)
	remote_connection._set_client_factory(nil)
	remote_connection._set_kernel(nil)
	close_fixture(state)
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
				callback(nil, { capabilities = { requests = { "remote.server.probe", "remote.files.list" } } })
			elseif request_type == "remote.server.probe" then
				callback(nil, {
					url = "https://example.test",
					version = "2.17.0",
					kernels = { { name = "python3", display_name = "Python 3", language = "python" } },
				})
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
	local probe
	client:probe(function(err, payload)
		assert(err == nil)
		probe = payload
	end)
	assert(probe.kernels[1].name == "python3")
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
	client:download_to("large.bin", "/tmp/nvjup-large.bin", function(err)
		assert(err == nil)
	end)
	client:upload_from("large-upload.bin", "/tmp/nvjup-source.bin", function(err)
		assert(err == nil)
	end)
	client:copy("large.bin", "large-copy.bin", function(err)
		assert(err == nil)
	end)
	local by_type = {}
	for _, request in ipairs(requests) do
		by_type[request.type] = request
	end
	assert(by_type["remote.files.list"].payload.remote.token == "secret")
	assert(by_type["remote.files.upload"].payload.content == vim.base64.encode("a\0b"))
	assert(by_type["remote.files.download_to"].payload.content == nil)
	assert(by_type["remote.files.download_to"].payload.local_path == "/tmp/nvjup-large.bin")
	assert(by_type["remote.files.upload_from"].payload.local_path == "/tmp/nvjup-source.bin")
	assert(by_type["remote.files.copy"].payload.new_path == "large-copy.bin")
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

test("rejects malicious direct and recursive remote entry responses", function()
	for _, entry in ipairs({
		{ name = "..", path = "workspace/.." },
		{ name = "escape/file", path = "workspace/escape/file" },
		{ name = "file", path = "other/file" },
	}) do
		local entries, err = remote_files._validate_remote_entries("workspace", { entry })
		assert(entries == nil and err)
	end
	local deleted, failure
	local browser = {
		client = {
			mkdir = function(_, _, callback)
				callback(nil, {})
			end,
			list = function(_, _, callback)
				callback(nil, { entries = { { name = "../escape", path = "tree/../escape", type = "file" } } })
			end,
			delete = function(_, path, callback)
				deleted = path
				callback(nil)
			end,
		},
	}
	remote_files._copy_recursive(
		browser,
		"remote",
		{ name = "tree", path = "tree", type = "directory" },
		"remote",
		"copy",
		{ count = 0, max = 10, bytes = 0, max_bytes = 100 },
		function(ok, err)
			assert(not ok)
			failure = err
		end
	)
	assert(failure and failure:find("invalid", 1, true))
	assert(deleted == "copy")
end)

test("enforces cumulative actual bytes for direct directory transfers", function()
	local created, failure = {}, nil
	local original_list = local_fs.list
	local_fs.list = function(path)
		assert(path == "/local/tree")
		return {
			{ name = "one", path = "/local/tree/one", type = "file", size = 1, side = "local" },
			{ name = "two", path = "/local/tree/two", type = "file", side = "local" },
		}
	end
	local browser = {
		client = {
			mkdir = function(_, path, callback)
				created[path] = "directory"
				callback(nil, {})
			end,
			list = function(_, _, callback)
				callback(nil, {
					entries = {
						{ name = "one", path = "tree/one", type = "file", size = 1 },
						{ name = "two", path = "tree/two", type = "file" },
					},
				})
			end,
			upload_from = function(_, remote_path, _, remaining, callback)
				local actual = remote_path:find("one", 1, true) and 6 or 5
				assert(remaining == (remote_path:find("one", 1, true) and 10 or 4))
				callback(nil, { size = actual })
			end,
			delete = function(_, path, callback)
				created[path] = nil
				callback(nil)
			end,
		},
	}
	remote_files._copy_recursive(
		browser,
		"local",
		{ name = "tree", path = "/local/tree", type = "directory" },
		"remote",
		"tree",
		{ count = 0, max = 10, bytes = 0, max_bytes = 10 },
		function(ok, err)
			assert(not ok)
			failure = err
		end
	)
	local_fs.list = original_list
	assert(failure and failure:find("10 bytes", 1, true))
	assert(created.tree == nil, "partial destination directory was not cleaned up")

	local target = vim.fn.tempname()
	local download_calls = 0
	failure = nil
	local download_browser = {
		client = {
			list = function(_, path, callback)
				assert(path == "tree")
				callback(nil, {
					entries = {
						{ name = "one", path = "tree/one", type = "file", size = 1 },
						{ name = "two", path = "tree/two", type = "file" },
					},
				})
			end,
			download_to = function(_, _, local_path, remaining, callback)
				download_calls = download_calls + 1
				local actual = download_calls == 1 and 6 or 5
				assert(remaining == (download_calls == 1 and 10 or 4))
				assert(local_fs.write(local_path, string.rep("x", actual)))
				callback(nil, { size = actual })
			end,
		},
	}
	remote_files._copy_recursive(
		download_browser,
		"remote",
		{ name = "tree", path = "tree", type = "directory" },
		"local",
		target,
		{ count = 0, max = 10, bytes = 0, max_bytes = 10 },
		function(ok, err)
			assert(not ok)
			failure = err
		end
	)
	assert(vim.wait(1000, function()
		return failure ~= nil and vim.uv.fs_lstat(target) == nil
	end))
	assert(failure:find("10 bytes", 1, true))
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
