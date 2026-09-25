local config = require("nvjup.config")

local M = {}
local system = vim.system

local function default_code_reader(prompt, callback, active)
	vim.schedule(function()
		if active and not active() then
			return
		end
		local ok, value = pcall(vim.fn.inputsecret, prompt)
		if active and not active() then
			return
		end
		vim.cmd.redraw()
		callback(ok and value or nil)
	end)
end

local code_reader = default_code_reader

local function error_result(code, message, retryable, details)
	return {
		code = code,
		message = message,
		retryable = retryable == true,
		details = details or {},
	}
end

local function executable_argv(value)
	if type(value) == "string" and value ~= "" and #value <= 4096 and not value:find("[%c]") then
		return { value }
	end
	if type(value) == "table" and #value > 0 and #value <= 16 then
		local result = {}
		for index, argument in ipairs(value) do
			if type(argument) ~= "string" or argument == "" or #argument > 4096 or argument:find("[%c]") then
				return { "colab" }
			end
			result[index] = argument
		end
		return result
	end
	return { "colab" }
end

local function shell_argument(value)
	if value:match("^[%w_@%%+=:,./%-]+$") then
		return value
	end
	return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function display_argv(argv)
	local result = {}
	for index, argument in ipairs(argv) do
		result[index] = shell_argument(argument)
	end
	return table.concat(result, " ")
end

local function recovery_argv(opts, session_id)
	local argv = vim.deepcopy(opts.executable)
	vim.list_extend(argv, { "--auth", opts.auth, "--config", opts.state_path, "stop", "-s", session_id })
	return argv
end

local function bounded_number(value, default, minimum, maximum)
	local number = tonumber(value) or default
	if number ~= number then
		number = default
	end
	return math.floor(math.max(minimum, math.min(number, maximum)))
end

local function options()
	local configured = config.options.colab or {}
	return {
		executable = executable_argv(configured.executable),
		auth = configured.auth == "adc" and "adc" or "oauth2",
		state_path = type(configured.state_path) == "string" and configured.state_path ~= "" and vim.fs.normalize(
			vim.fn.expand(configured.state_path)
		) or vim.fs.joinpath(vim.fn.expand("~"), ".config", "colab-cli", "sessions.json"),
		timeout_ms = bounded_number(configured.create_timeout_seconds, 300, 30, 1800) * 1000,
		max_output_bytes = bounded_number(configured.max_output_bytes, 64 * 1024, 4096, 1024 * 1024),
		max_state_bytes = bounded_number(configured.max_state_bytes, 1024 * 1024, 4096, 8 * 1024 * 1024),
	}
end

local function valid_session_id(value)
	return type(value) == "string" and value:match("^[%w][%w_-]*$") ~= nil and #value <= 64
end

local function valid_url(value)
	return type(value) == "string"
		and #value <= 4096
		and not value:find("[%c%s]")
		and value:match("^https://[^/%s?#]+") ~= nil
		and not value:find("?", 1, true)
		and not value:find("#", 1, true)
		and not value:match("^https://[^/]*@")
end

local function read_file_bounded(path, limit)
	local link = vim.uv.fs_lstat(path)
	if not link or link.type ~= "file" then
		return nil, "Colab CLI did not write a regular session state file"
	end
	if link.size > limit then
		return nil, string.format("Colab CLI session state exceeds %d bytes", limit)
	end
	local fd, open_err = vim.uv.fs_open(path, "r", 0)
	if not fd then
		return nil, "cannot open Colab CLI session state: " .. tostring(open_err)
	end
	local stat, stat_err = vim.uv.fs_fstat(fd)
	if not stat or stat.type ~= "file" or stat.size > limit then
		vim.uv.fs_close(fd)
		return nil,
			stat_err and ("cannot inspect Colab CLI session state: " .. tostring(stat_err)) or string.format(
				"Colab CLI session state exceeds %d bytes",
				limit
			)
	end
	local data, read_err = vim.uv.fs_read(fd, stat.size, 0)
	vim.uv.fs_close(fd)
	if not data then
		return nil, "cannot read Colab CLI session state: " .. tostring(read_err)
	end
	return data
end

local function read_session(path, session_id, limit, recovery)
	if not valid_session_id(session_id) then
		return nil, "invalid Colab session identifier"
	end
	local data, read_err = read_file_bounded(path, limit)
	if not data then
		return nil, read_err
	end
	local ok, decoded = pcall(vim.json.decode, data)
	if not ok or type(decoded) ~= "table" then
		return nil, "Colab CLI session state is invalid JSON"
	end
	local session = decoded[session_id]
	if type(session) ~= "table" or session.name ~= session_id then
		return nil, "Colab CLI did not return the requested session"
	end
	if not valid_url(session.url) then
		return nil, "Colab CLI returned an invalid runtime URL"
	end
	if
		type(session.token) ~= "string"
		or session.token == ""
		or #session.token > 16384
		or session.token:find("[%c]")
	then
		return nil, "Colab CLI returned an invalid runtime proxy token"
	end
	if
		type(session.endpoint) ~= "string"
		or session.endpoint == ""
		or #session.endpoint > 512
		or session.endpoint:find("[%c]")
	then
		return nil, "Colab CLI returned an invalid runtime endpoint"
	end
	local hardware = tostring(session.accelerator or "NONE")
	if hardware == "NONE" then
		hardware = "CPU"
	end
	if tostring(session.machine_shape or "STANDARD") ~= "STANDARD" then
		hardware = hardware .. " high-memory"
	end
	return {
		url = session.url:gsub("/+$", ""),
		token = session.token,
		provider = "colab",
		auth = "proxy_token",
		verify_ssl = true,
		colab_session = session_id,
		colab_endpoint = session.endpoint,
		colab_hardware = hardware,
		colab_recovery_argv = recovery and vim.deepcopy(recovery.argv) or nil,
		colab_recovery_command = recovery and recovery.command or nil,
	}
end

local function bounded_append(current, value, limit)
	if type(value) ~= "string" or value == "" or #current >= limit then
		return current
	end
	return current .. value:sub(1, limit - #current)
end

local function actionable_error(output)
	local compact = vim.trim(output:gsub("https://[^%s]+", "<authorization URL>"):gsub("%s+", " "))
	if #compact > 1200 then
		compact = compact:sub(-1200)
	end
	if compact == "" then
		compact = "Colab CLI failed to create a runtime"
	end
	local lower = compact:lower()
	if
		lower:find("quota", 1, true)
		or lower:find("capacity", 1, true)
		or lower:find("entitlement", 1, true)
		or lower:find("precondition", 1, true)
		or lower:find("too many", 1, true)
		or lower:find("503", 1, true)
	then
		compact = compact .. ". Stop an unused session with `colab stop`, retry later, or choose CPU/T4."
	end
	return compact
end

local function copy_url(url, active)
	if not active() then
		return
	end
	local ok = pcall(vim.fn.setreg, "+", url)
	if not active() then
		return
	end
	vim.notify(
		ok and "nvjup: authorization URL copied to the clipboard"
			or "nvjup: clipboard unavailable; open the authorization URL shown by colab-cli",
		ok and vim.log.levels.INFO or vim.log.levels.WARN
	)
end

local function authorize(url, process, cancel, active)
	vim.schedule(function()
		if not active() then
			return
		end
		vim.ui.select({ "Open authorization URL", "Copy authorization URL" }, {
			prompt = "Google Colab authorization",
		}, function(choice)
			if not active() then
				return
			end
			if not choice then
				cancel("Google Colab authorization cancelled")
				return
			end
			if choice == "Open authorization URL" then
				local ok, opened = false, nil
				if active() and vim.ui.open then
					ok, opened = pcall(vim.ui.open, url)
				end
				if active() and (not ok or opened == nil) then
					copy_url(url, active)
				end
			elseif active() then
				copy_url(url, active)
			end
			if not active() then
				return
			end
			code_reader("Google authorization code (input hidden): ", function(code)
				if not active() then
					return
				end
				code = type(code) == "string" and vim.trim(code) or ""
				if code == "" then
					cancel("Google Colab authorization cancelled")
					return
				end
				if not active() then
					return
				end
				local ok, written = process and pcall(process.write, process, code .. "\n")
				if active() and (not ok or written == false) then
					cancel("failed to send the Google authorization code")
				end
			end, active)
		end)
	end)
end

function M.hardware()
	local result = {}
	local function add(label, kind, accelerator, high_mem)
		table.insert(result, { label = label, kind = kind, accelerator = accelerator, high_mem = high_mem == true })
	end
	add("CPU · standard", "cpu")
	add("CPU · high-memory", "cpu", nil, true)
	for _, gpu in ipairs({ "T4", "L4", "G4", "A100", "H100" }) do
		add("GPU " .. gpu, "gpu", gpu)
		if gpu ~= "L4" then
			add("GPU " .. gpu .. " · high-memory", "gpu", gpu, true)
		end
	end
	add("TPU v5e1", "tpu", "v5e1")
	add("TPU v6e1", "tpu", "v6e1")
	return result
end

function M.provision(hardware, callback)
	local opts = options()
	local gpu = { T4 = true, L4 = true, G4 = true, A100 = true, H100 = true }
	local tpu = { v5e1 = true, v6e1 = true }
	local valid = type(hardware) == "table"
		and ((hardware.kind == "cpu" and hardware.accelerator == nil) or (hardware.kind == "gpu" and gpu[hardware.accelerator]) or (hardware.kind == "tpu" and tpu[hardware.accelerator]))
		and not (hardware.high_mem and (hardware.accelerator == "L4" or hardware.kind == "tpu"))
	if not valid then
		callback(error_result("invalid_hardware", "invalid Google Colab hardware selection"))
		return nil
	end
	local session_id = "nvjup-" .. vim.fn.sha256(tostring(vim.uv.hrtime()) .. tostring(math.random())):sub(1, 12)
	local stop_argv = recovery_argv(opts, session_id)
	local recovery = { argv = stop_argv, command = display_argv(stop_argv) }
	local argv = vim.deepcopy(opts.executable)
	vim.list_extend(argv, { "--auth", opts.auth, "--config", opts.state_path, "new", "-s", session_id })
	if hardware.kind == "gpu" then
		vim.list_extend(argv, { "--gpu", hardware.accelerator })
	elseif hardware.kind == "tpu" then
		vim.list_extend(argv, { "--tpu", hardware.accelerator })
	end
	if hardware.high_mem then
		table.insert(argv, "--high-mem")
	end

	local completed = false
	local process
	local timer = vim.uv.new_timer()
	local output, scan = "", ""
	local auth_started = false
	local function finish(err, profile)
		if completed then
			return
		end
		completed = true
		if timer then
			timer:stop()
			timer:close()
			timer = nil
		end
		vim.schedule(function()
			callback(err, profile)
		end)
	end
	local function cancel(message)
		if completed then
			return
		end
		if process then
			pcall(process.kill, process, 15)
		end
		finish(error_result("colab_cancelled", message, true))
	end
	local function chunk(_, data)
		if completed or not data then
			return
		end
		output = bounded_append(output, data, opts.max_output_bytes)
		scan = (scan .. data:sub(-16384)):sub(-16384)
		if not auth_started and scan:find("Enter the authorization code:", 1, true) then
			local url = scan:match("(https://[^%s]+)")
			if url then
				auth_started = true
				authorize(url, process, cancel, function()
					return not completed
				end)
			end
		end
	end
	local launched, launch_result = pcall(
		system,
		argv,
		{ text = true, stdin = true, stdout = chunk, stderr = chunk },
		function(result)
			if completed then
				return
			end
			if result.code ~= 0 then
				finish(error_result("colab_create_failed", actionable_error(output), true))
				return
			end
			local profile, state_err = read_session(opts.state_path, session_id, opts.max_state_bytes, recovery)
			if not profile then
				finish(error_result("colab_state_invalid", state_err, false, {
					session_id = session_id,
					recovery_argv = vim.deepcopy(recovery.argv),
					recovery_command = recovery.command,
				}))
				return
			end
			finish(nil, profile)
		end
	)
	process = launched and launch_result or nil
	if not process then
		local detail = launched and "failed to launch the Google Colab CLI"
			or ("failed to launch the Google Colab CLI: " .. tostring(launch_result))
		finish(error_result("colab_launch_failed", detail, true))
		return nil
	end
	timer:start(opts.timeout_ms, 0, function()
		vim.schedule(function()
			if completed then
				return
			end
			pcall(process.kill, process, 15)
			finish(error_result("colab_timeout", "Google Colab runtime creation timed out", true))
		end)
	end)
	return {
		cancel = function()
			cancel("Google Colab runtime creation cancelled")
		end,
		session_id = session_id,
		argv = vim.deepcopy(argv),
	}
end

function M.connect(callback)
	local controller = { cancelled = false, completed = false, operation = nil }
	local function complete(err, profile)
		if controller.completed or (controller.cancelled and not profile) then
			return
		end
		controller.completed = true
		callback(err, profile)
	end
	function controller.cancel()
		if controller.cancelled or controller.completed then
			return
		end
		controller.cancelled = true
		if controller.operation then
			controller.operation.cancel()
		end
	end
	vim.ui.select(M.hardware(), {
		prompt = "Google Colab runtime",
		format_item = function(item)
			return item.label
		end,
	}, function(hardware)
		if controller.cancelled or controller.completed then
			return
		end
		if not hardware then
			complete(error_result("colab_cancelled", "Google Colab hardware selection cancelled", true))
			return
		end
		vim.notify("nvjup: creating Google Colab " .. hardware.label .. " runtime…", vim.log.levels.INFO)
		controller.operation = M.provision(hardware, complete)
		if controller.cancelled and controller.operation then
			controller.operation.cancel()
		end
	end)
	return controller
end

function M.available()
	local executable = options().executable[1]
	return vim.fn.executable(executable) == 1
end

function M._read_session(path, session_id, limit)
	return read_session(path, session_id, limit or 1024 * 1024)
end

function M._set_system(value)
	system = value or vim.system
end

function M._set_code_reader(reader)
	code_reader = reader or default_code_reader
end

return M
