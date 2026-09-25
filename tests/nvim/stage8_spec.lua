local colab = require("nvjup.colab")
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
	assert(vim.fn.exists(":NvJupColabConnect") == 2)
	assert(vim.fn.exists(":NvJupRemoteDisconnect") == 2)
	assert(vim.fn.exists(":NvJupRemoteStatus") == 2)
	assert(vim.fn.exists(":NvJupRemoteFiles") == 2)
end)

test("opens with a Jupyter Lab or Google Colab provider menu", function()
	local original_select = vim.ui.select
	local selected_items, selected_prompt
	remote.disconnect()
	vim.ui.select = function(items, options)
		selected_items = items
		selected_prompt = options.prompt
	end
	assert(remote_connection.open({ buf = vim.api.nvim_get_current_buf(), path = "" }))
	vim.ui.select = original_select
	remote.reset_session()
	assert(vim.deep_equal(selected_items, { "Jupyter Lab", "Google Colab" }))
	assert(selected_prompt == "Remote Jupyter provider")
end)

local function colab_state(path, session_id, overrides)
	local value = vim.tbl_extend("force", {
		name = session_id,
		url = "https://runtime.example.test",
		token = "proxy-secret",
		endpoint = "assignments/example",
		variant = "GPU",
		accelerator = "T4",
		machine_shape = "STANDARD",
	}, overrides or {})
	vim.fn.mkdir(vim.fs.dirname(path), "p")
	vim.fn.writefile({ vim.json.encode({ [session_id] = value }) }, path, "b")
end

local function managed_colab_profile(session_id, url)
	local state_path = "/tmp/nvjup colab sessions.json"
	return {
		url = url or "https://runtime.example.test",
		token = "proxy-secret",
		provider = "colab",
		verify_ssl = true,
		colab_session = session_id,
		colab_hardware = "T4",
		colab_recovery_argv = {
			"colab",
			"--auth",
			"oauth2",
			"--config",
			state_path,
			"stop",
			"-s",
			session_id,
		},
		colab_recovery_command = "colab --auth oauth2 --config '" .. state_path .. "' stop -s " .. session_id,
	}
end

local function with_colab_options(callback)
	local previous = vim.deepcopy(config.options.colab)
	local path = vim.fn.tempname()
	config.options.colab = {
		executable = "colab",
		auth = "oauth2",
		state_path = path,
		create_timeout_seconds = 30,
		max_output_bytes = 4096,
		max_state_bytes = 4096,
	}
	local ok, err = xpcall(function()
		callback(path)
	end, debug.traceback)
	colab._set_system(nil)
	colab._set_code_reader(nil)
	config.options.colab = previous
	pcall(vim.fn.delete, path)
	if not ok then
		error(err)
	end
end

test("offers Colab 0.6 CPU GPU and TPU choices by default", function()
	with_colab_options(function()
		local labels = {}
		for _, item in ipairs(colab.hardware()) do
			labels[item.label] = true
		end
		for _, label in ipairs({
			"CPU",
			"GPU T4",
			"GPU L4",
			"GPU G4",
			"GPU A100",
			"GPU H100",
			"TPU v5e1",
			"TPU v6e1",
		}) do
			assert(labels[label], label)
		end
		assert(not labels["CPU · high-memory"])

		config.options.colab.high_memory = true
		labels = {}
		for _, item in ipairs(colab.hardware()) do
			labels[item.label] = true
		end
		assert(labels["CPU · high-memory"])
		assert(labels["GPU T4 · high-memory"])
		assert(not labels["GPU L4 · high-memory"])
	end)
end)

test("requires explicit CLI 0.7 opt-in for Colab high-memory", function()
	with_colab_options(function()
		local received
		local operation = colab.provision({ kind = "cpu", high_mem = true }, function(err)
			received = err
		end)
		assert(operation == nil)
		assert(received and received.code == "invalid_hardware")
	end)
end)

test("provisions Colab with cached OAuth credentials and bounded argv", function()
	with_colab_options(function(path)
		local seen
		colab._set_system(function(argv, _, on_exit)
			seen = vim.deepcopy(argv)
			local handle = { write = function() end, kill = function() end }
			vim.schedule(function()
				local session_id = argv[8]
				colab_state(path, session_id)
				on_exit({ code = 0, signal = 0 })
			end)
			return handle
		end)
		local err, profile
		colab.provision({ kind = "gpu", accelerator = "T4" }, function(value, result)
			err, profile = value, result
		end)
		assert(vim.wait(1000, function()
			return profile ~= nil or err ~= nil
		end, 5))
		assert(err == nil and profile.provider == "colab")
		assert(profile.token == "proxy-secret" and profile.colab_hardware == "T4")
		assert(vim.deep_equal(seen, {
			"colab",
			"--auth",
			"oauth2",
			"--config",
			path,
			"new",
			"-s",
			profile.colab_session,
			"--gpu",
			"T4",
		}))
	end)
end)

test("reports orphan recovery when Colab state import fails after allocation", function()
	with_colab_options(function()
		colab._set_system(function(_, _, on_exit)
			local handle = { write = function() end, kill = function() end }
			vim.schedule(function()
				on_exit({ code = 0, signal = 0 })
			end)
			return handle
		end)
		local received
		local operation = assert(colab.provision({ kind = "cpu" }, function(err)
			received = err
		end))
		assert(vim.wait(1000, function()
			return received ~= nil
		end, 5))
		assert(received.code == "colab_state_invalid")
		assert(received.details.session_id == operation.session_id)
		assert(vim.deep_equal(received.details.recovery_argv, {
			"colab",
			"--auth",
			"oauth2",
			"--config",
			config.options.colab.state_path,
			"stop",
			"-s",
			operation.session_id,
		}))
		assert(received.details.recovery_command:find(" stop -s " .. operation.session_id, 1, true))
		assert(received.message:find("session state", 1, true))
	end)
end)

test("builds Colab recovery argv with the allocation auth and custom state", function()
	with_colab_options(function()
		local state_path = vim.fn.tempname() .. " state/sessions.json"
		config.options.colab.executable = { "uv", "tool", "run", "colab" }
		config.options.colab.auth = "adc"
		config.options.colab.state_path = state_path
		colab._set_system(function(argv, _, on_exit)
			assert(vim.deep_equal(vim.list_slice(argv, 1, 9), {
				"uv",
				"tool",
				"run",
				"colab",
				"--auth",
				"adc",
				"--config",
				state_path,
				"new",
			}))
			local handle = { write = function() end, kill = function() end }
			vim.schedule(function()
				on_exit({ code = 0, signal = 0 })
			end)
			return handle
		end)
		local received
		local operation = assert(colab.provision({ kind = "cpu" }, function(err)
			received = err
		end))
		assert(vim.wait(1000, function()
			return received ~= nil
		end, 5))
		assert(vim.deep_equal(received.details.recovery_argv, {
			"uv",
			"tool",
			"run",
			"colab",
			"--auth",
			"adc",
			"--config",
			state_path,
			"stop",
			"-s",
			operation.session_id,
		}))
		assert(received.details.recovery_command:find("--auth adc", 1, true))
		assert(received.details.recovery_command:find("'" .. state_path .. "'", 1, true))
	end)
end)

test("shows structured Colab orphan recovery without exposing secrets", function()
	local original_notify = vim.notify
	local notices = {}
	vim.notify = function(message)
		table.insert(notices, message)
	end
	local fake_colab = {
		available = function()
			return true
		end,
		connect = function(callback)
			local operation = { cancel = function() end }
			vim.schedule(function()
				callback({
					code = "colab_state_invalid",
					message = "Colab CLI session state is invalid JSON",
					details = {
						session_id = "nvjup-safe",
						recovery_argv = {
							"colab",
							"--auth",
							"oauth2",
							"--config",
							"/tmp/colab state.json",
							"stop",
							"-s",
							"nvjup-safe",
						},
					},
				})
			end)
			return operation
		end,
	}
	remote_connection._set_colab(fake_colab)
	local started = remote_connection.connect_colab()
	local completed = vim.wait(1000, function()
		return #notices > 0 and not remote_connection._has_pending_colab()
	end, 5)
	remote_connection._set_colab(nil)
	vim.notify = original_notify
	assert(started and completed)
	local message = table.concat(notices, "\n")
	assert(message:find("`colab --auth oauth2 --config '/tmp/colab state.json' stop -s nvjup-safe`", 1, true))
	assert(not message:find("proxy-secret", 1, true))
end)

test("handles interactive Colab OAuth without exposing the proxy token", function()
	with_colab_options(function(path)
		local original_select, original_input = vim.ui.select, vim.ui.input
		local written, killed, secret_prompt
		vim.ui.select = function(_, options, callback)
			assert(options.prompt == "Google Colab authorization")
			callback("Copy authorization URL")
		end
		vim.ui.input = function()
			error("OAuth authorization codes must not use visible vim.ui.input")
		end
		colab._set_code_reader(function(prompt, callback)
			secret_prompt = prompt
			callback("one-time-code")
		end)
		colab._set_system(function(argv, options, on_exit)
			local handle = {}
			function handle:write(value)
				written = value
				colab_state(path, argv[8])
				vim.schedule(function()
					on_exit({ code = 0, signal = 0 })
				end)
			end
			function handle:kill()
				killed = true
			end
			vim.schedule(function()
				options.stderr(nil, "To authorize, visit https://accounts.example/auth?state=test\n")
				options.stderr(nil, "Enter the authorization code: ")
			end)
			return handle
		end)
		local err, profile
		colab.provision({ kind = "cpu" }, function(value, result)
			err, profile = value, result
		end)
		assert(vim.wait(1000, function()
			return profile ~= nil or err ~= nil
		end, 5))
		vim.ui.select, vim.ui.input = original_select, original_input
		assert(err == nil and profile.token == "proxy-secret")
		assert(secret_prompt == "Google authorization code (input hidden): ")
		assert(written == "one-time-code\n" and not killed)
	end)
end)

test("surfaces actionable Colab capacity failures", function()
	with_colab_options(function()
		colab._set_system(function(_, options, on_exit)
			local handle = { write = function() end, kill = function() end }
			vim.schedule(function()
				options.stderr(nil, "Allocation refused: temporary GPU capacity limit")
				on_exit({ code = 1, signal = 0 })
			end)
			return handle
		end)
		local received
		colab.provision({ kind = "gpu", accelerator = "A100" }, function(err)
			received = err
		end)
		assert(vim.wait(1000, function()
			return received ~= nil
		end, 5))
		assert(received.code == "colab_create_failed")
		assert(received.message:find("choose CPU/T4", 1, true))
		assert(not received.message:find("proxy-secret", 1, true))
	end)
end)

test("cancels interactive Colab OAuth exactly once", function()
	with_colab_options(function()
		local original_select = vim.ui.select
		local killed, calls = false, 0
		vim.ui.select = function(_, _, callback)
			callback(nil)
		end
		colab._set_system(function(_, options, _)
			local handle = { write = function() end }
			function handle:kill()
				killed = true
			end
			vim.schedule(function()
				options.stderr(nil, "https://accounts.example/auth\nEnter the authorization code: ")
			end)
			return handle
		end)
		local received
		colab.provision({ kind = "cpu" }, function(err)
			calls = calls + 1
			received = err
		end)
		assert(vim.wait(1000, function()
			return received ~= nil
		end, 5))
		vim.ui.select = original_select
		assert(killed and calls == 1 and received.code == "colab_cancelled")
	end)
end)

test("suppresses OAuth selector and code writes after external cancellation", function()
	with_colab_options(function()
		local original_select = vim.ui.select
		local select_callback, received
		local code_reads, writes = 0, 0
		vim.ui.select = function(_, _, callback)
			select_callback = callback
		end
		colab._set_code_reader(function()
			code_reads = code_reads + 1
		end)
		colab._set_system(function(_, options, _)
			local handle = {}
			function handle:write()
				writes = writes + 1
			end
			function handle:kill() end
			vim.schedule(function()
				options.stderr(nil, "https://accounts.example/auth\nEnter the authorization code: ")
			end)
			return handle
		end)
		local operation = assert(colab.provision({ kind = "cpu" }, function(err)
			received = err
		end))
		assert(vim.wait(1000, function()
			return select_callback ~= nil
		end, 5))
		operation.cancel()
		select_callback("Copy authorization URL")
		assert(vim.wait(1000, function()
			return received ~= nil
		end, 5))
		vim.ui.select = original_select
		assert(received.code == "colab_cancelled" and code_reads == 0 and writes == 0)
	end)
end)

test("suppresses OAuth process writes when cancelled after the hidden prompt", function()
	with_colab_options(function()
		local original_select = vim.ui.select
		local code_callback, received
		local writes = 0
		vim.ui.select = function(_, _, callback)
			callback("Copy authorization URL")
		end
		colab._set_code_reader(function(_, callback)
			code_callback = callback
		end)
		colab._set_system(function(_, options, _)
			local handle = {}
			function handle:write()
				writes = writes + 1
			end
			function handle:kill() end
			vim.schedule(function()
				options.stderr(nil, "https://accounts.example/auth\nEnter the authorization code: ")
			end)
			return handle
		end)
		local operation = assert(colab.provision({ kind = "cpu" }, function(err)
			received = err
		end))
		assert(vim.wait(1000, function()
			return code_callback ~= nil
		end, 5))
		operation.cancel()
		code_callback("stale-code")
		assert(vim.wait(1000, function()
			return received ~= nil
		end, 5))
		vim.ui.select = original_select
		assert(received.code == "colab_cancelled" and writes == 0)
	end)
end)

test("cancels Colab allocation handles exactly once", function()
	with_colab_options(function()
		local exit_callback, killed, calls = nil, false, 0
		colab._set_system(function(_, _, on_exit)
			exit_callback = on_exit
			return {
				write = function() end,
				kill = function()
					killed = true
				end,
			}
		end)
		local received
		local operation = assert(colab.provision({ kind = "cpu" }, function(err)
			calls = calls + 1
			received = err
		end))
		operation.cancel()
		assert(vim.wait(1000, function()
			return received ~= nil
		end, 5))
		exit_callback({ code = 1, signal = 15 })
		vim.wait(20)
		assert(killed and calls == 1 and received.code == "colab_cancelled")
	end)
end)

test("rejects unsafe and oversized Colab CLI state", function()
	local path = vim.fn.tempname()
	vim.fn.writefile({ string.rep("x", 128) }, path, "b")
	local profile, err = colab._read_session(path, "nvjup-safe", 64)
	assert(profile == nil and err:find("exceeds", 1, true))
	vim.fn.writefile({
		vim.json.encode({
			["nvjup-safe"] = {
				name = "nvjup-safe",
				url = "https://user@runtime.example",
				token = "secret",
				endpoint = "endpoint",
			},
		}),
	}, path, "b")
	profile, err = colab._read_session(path, "nvjup-safe", 4096)
	assert(profile == nil and err:find("invalid runtime URL", 1, true))

	-- google-colab-cli 0.6 session records do not include machine_shape.
	vim.fn.writefile({
		vim.json.encode({
			["nvjup-safe"] = {
				name = "nvjup-safe",
				url = "https://runtime.example.test",
				token = "secret",
				endpoint = "endpoint",
				variant = "GPU",
				accelerator = "T4",
			},
		}),
	}, path, "b")
	profile, err = colab._read_session(path, "nvjup-safe", 4096)
	assert(err == nil and profile.colab_hardware == "T4")
	vim.fn.delete(path)
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

test("bounds and yields while scanning an over-budget wide directory", function()
	local base = vim.fn.tempname()
	local source = vim.fs.joinpath(base, "wide-source")
	assert(local_fs.mkdir(source))
	for index = 1, 200 do
		assert(local_fs.write(vim.fs.joinpath(source, string.format("file-%03d", index)), tostring(index)))
	end

	local original_copyfile = vim.uv.fs_copyfile
	local original_schedule = vim.schedule
	local copied_files, scheduled = 0, 0
	vim.uv.fs_copyfile = function(...)
		copied_files = copied_files + 1
		return original_copyfile(...)
	end
	vim.schedule = function(callback)
		scheduled = scheduled + 1
		return original_schedule(callback)
	end

	local done, operation_error
	local_fs.copy_async(source, vim.fs.joinpath(base, "target"), 70, function(ok, err)
		done, operation_error = ok, err
	end)
	assert(vim.wait(5000, function()
		return done ~= nil or operation_error ~= nil
	end, 5))
	vim.uv.fs_copyfile = original_copyfile
	vim.schedule = original_schedule

	assert(done == nil and operation_error:find("copy exceeds 70 entries", 1, true))
	assert(copied_files == 69, "the root plus 69 children must exhaust the entry budget")
	assert(scheduled >= 2, "wide scans must yield after bounded batches")
	assert(vim.uv.fs_lstat(vim.fs.joinpath(base, "target")) == nil, "failed copies must be cleaned up")
	assert(local_fs.delete(base))
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

test("normalizes Colab provider metadata for kernel and file transports", function()
	remote.set_session({
		url = "https://runtime.example.test/",
		token = "proxy-secret",
		provider = "colab",
		auth = "proxy_token",
		colab_session = "nvjup-session",
		colab_endpoint = "assignments/one",
		colab_hardware = "GPU T4",
		colab_recovery_argv = {
			"colab",
			"--auth",
			"oauth2",
			"--config",
			"/tmp/state.json",
			"stop",
			"-s",
			"nvjup-session",
		},
		colab_recovery_command = "colab --auth oauth2 --config /tmp/state.json stop -s nvjup-session",
	})
	local resolved = assert(remote.resolve())
	assert(resolved.provider == "colab" and resolved.auth == "proxy_token")
	assert(resolved.colab_session == "nvjup-session" and resolved.colab_hardware == "GPU T4")
	assert(resolved.colab_recovery_argv[#resolved.colab_recovery_argv] == "nvjup-session")
	assert(remote.status().provider == "colab")
	assert(remote.status().colab_recovery_command:find("--auth oauth2", 1, true))
	remote.disconnect()
	remote.reset_session()
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

test("dismissed Colab hardware selection clears remote connection ownership", function()
	with_colab_options(function()
		local original_select = vim.ui.select
		config.options.colab.executable = "true"
		vim.ui.select = function(_, options, callback)
			assert(options.prompt == "Google Colab runtime")
			callback(nil)
		end
		remote_connection._set_colab(colab)
		assert(remote_connection.connect_colab())
		vim.ui.select = original_select
		assert(not remote_connection._has_pending_colab())
		remote_connection._set_colab(nil)
	end)
end)

test("disconnect during Colab probe reports recovery and rejects stale activation", function()
	local original_notify = vim.notify
	local notices, probe_callback = {}, nil
	vim.notify = function(message)
		table.insert(notices, message)
	end
	local candidate = managed_colab_profile("nvjup-probe-disconnect")
	remote_connection._set_colab({
		available = function()
			return true
		end,
		connect = function(callback)
			vim.schedule(function()
				callback(nil, candidate)
			end)
			return { cancel = function() end }
		end,
	})
	remote_connection._set_client_factory(function()
		return {
			probe = function(_, callback)
				probe_callback = callback
			end,
			shutdown = function() end,
		}
	end)
	remote_connection._set_kernel({ shutdown_remote_sessions = function() end })
	assert(remote_connection.connect_colab())
	assert(vim.wait(1000, function()
		return probe_callback ~= nil and remote_connection._has_pending_colab()
	end, 5))
	remote_connection.disconnect()
	local recovery_count = 0
	for _, message in ipairs(notices) do
		if message:find("nvjup-probe-disconnect", 1, true) then
			recovery_count = recovery_count + 1
			assert(message:find("--auth oauth2", 1, true) and message:find(" stop -s nvjup-probe-disconnect", 1, true))
		end
	end
	assert(recovery_count == 1 and not remote_connection._has_pending_colab())
	probe_callback(nil, {
		url = candidate.url,
		kernels = { { name = "python3", display_name = "Python 3", language = "python" } },
	})
	assert(not remote.enabled())
	remote_connection._set_colab(nil)
	remote_connection._set_client_factory(nil)
	remote_connection._set_kernel(nil)
	remote.reset_session()
	vim.notify = original_notify
end)

test("dismissing the Colab kernel picker reports exact recovery", function()
	local original_notify, original_select = vim.notify, vim.ui.select
	local notices = {}
	vim.notify = function(message)
		table.insert(notices, message)
	end
	vim.ui.select = function(_, options, callback)
		assert(options.prompt:match("^Kernel on "))
		callback(nil)
	end
	local candidate = managed_colab_profile("nvjup-picker-dismissed")
	remote_connection._set_colab({
		available = function()
			return true
		end,
		connect = function(callback)
			vim.schedule(function()
				callback(nil, candidate)
			end)
			return { cancel = function() end }
		end,
	})
	remote_connection._set_client_factory(function()
		return {
			probe = function(_, callback)
				callback(nil, {
					url = candidate.url,
					kernels = { { name = "julia", display_name = "Julia", language = "julia" } },
				})
			end,
			shutdown = function() end,
		}
	end)
	assert(remote_connection.connect_colab())
	assert(vim.wait(1000, function()
		return not remote_connection._has_pending_colab()
	end, 5))
	local message = table.concat(notices, "\n")
	assert(message:find("kernel selection was dismissed", 1, true))
	assert(message:find("nvjup-picker-dismissed", 1, true))
	assert(message:find("--config '/tmp/nvjup colab sessions.json' stop -s nvjup-picker-dismissed", 1, true))
	assert(not remote.enabled())
	remote_connection._set_colab(nil)
	remote_connection._set_client_factory(nil)
	remote.reset_session()
	vim.notify, vim.ui.select = original_notify, original_select
end)

test("Colab probe failure reports exact recovery once", function()
	local original_notify = vim.notify
	local notices = {}
	vim.notify = function(message)
		table.insert(notices, message)
	end
	local candidate = managed_colab_profile("nvjup-probe-error")
	remote_connection._set_colab({
		available = function()
			return true
		end,
		connect = function(callback)
			vim.schedule(function()
				callback(nil, candidate)
			end)
			return { cancel = function() end }
		end,
	})
	remote_connection._set_client_factory(function()
		return {
			probe = function(_, callback)
				callback({ code = "remote_probe_failed", message = "HTTP 503" })
			end,
			shutdown = function() end,
		}
	end)
	assert(remote_connection.connect_colab())
	assert(vim.wait(1000, function()
		return not remote_connection._has_pending_colab()
	end, 5))
	local recovery_count = 0
	for _, message in ipairs(notices) do
		if message:find("nvjup-probe-error", 1, true) then
			recovery_count = recovery_count + 1
			assert(message:find("server probe failed: HTTP 503", 1, true))
		end
	end
	assert(recovery_count == 1 and not remote.enabled())
	remote_connection._set_colab(nil)
	remote_connection._set_client_factory(nil)
	remote.reset_session()
	vim.notify = original_notify
end)

test("Colab commands cancel replacement and disconnect provisioning without stale activation", function()
	local callbacks, operations, probes = {}, {}, 0
	local fake_colab = {
		available = function()
			return true
		end,
		connect = function(callback)
			table.insert(callbacks, callback)
			local operation = { cancelled = false }
			function operation.cancel()
				operation.cancelled = true
			end
			table.insert(operations, operation)
			return operation
		end,
	}
	remote_connection._set_colab(fake_colab)
	remote_connection._set_kernel({
		shutdown_remote_sessions = function() end,
	})
	remote_connection._set_client_factory(function(_, candidate)
		return {
			probe = function(_, callback)
				probes = probes + 1
				callback(nil, {
					url = candidate.url,
					kernels = { { name = "python3", display_name = "Python 3", language = "python" } },
				})
			end,
			shutdown = function() end,
		}
	end)

	vim.cmd("NvJupColabConnect")
	assert(remote_connection._has_pending_colab() and not operations[1].cancelled)
	vim.cmd("NvJupColabConnect")
	assert(operations[1].cancelled and remote_connection._has_pending_colab())
	callbacks[1](nil, {
		url = "https://stale.runtime.test",
		token = "stale",
		provider = "colab",
		colab_session = "stale",
	})
	assert(probes == 0 and not remote.enabled())
	callbacks[2](nil, {
		url = "https://current.runtime.test",
		token = "current",
		provider = "colab",
		colab_session = "current",
	})
	assert(probes == 1 and remote.status().url == "https://current.runtime.test")

	vim.cmd("NvJupColabConnect")
	assert(remote_connection._has_pending_colab())
	vim.cmd("NvJupRemoteDisconnect")
	assert(operations[3].cancelled and not remote_connection._has_pending_colab())
	callbacks[3](nil, {
		url = "https://cancelled.runtime.test",
		token = "cancelled",
		provider = "colab",
		colab_session = "cancelled",
	})
	assert(probes == 1 and not remote.enabled())

	remote_connection._set_colab(nil)
	remote_connection._set_client_factory(nil)
	remote_connection._set_kernel(nil)
	remote.reset_session()
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
