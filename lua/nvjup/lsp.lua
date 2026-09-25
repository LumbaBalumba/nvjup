local config = require("nvjup.config")
local notebook = require("nvjup.notebook")
local shadow = require("nvjup.shadow")

local M = {}
local sessions = {}

local function notify(message, level)
	vim.notify("nvjup LSP: " .. tostring(message), level or vim.log.levels.INFO)
end

local function session_for(state)
	local session = sessions[state.buf]
	if session and session.state ~= state then
		for _, request in pairs(session.outstanding_requests or {}) do
			pcall(request.client.cancel_request, request.client, request.id)
		end
		session = nil
	end
	if not session then
		session = {
			state = state,
			documents = {},
			clients = {},
			outstanding_requests = {},
		}
		sessions[state.buf] = session
	end
	return session
end

local function valid_session(session, state, manager, expected_version)
	return session ~= nil
		and sessions[state.buf] == session
		and vim.api.nvim_buf_is_valid(state.buf)
		and notebook.get(state.buf) == state
		and state.shadow == manager
		and manager.version == expected_version
end

local function cancel_requests(session, predicate)
	for token, request in pairs(session.outstanding_requests or {}) do
		if not predicate or predicate(request) then
			session.outstanding_requests[token] = nil
			pcall(request.client.cancel_request, request.client, request.id)
		end
	end
end

local function tracked_request(session, client, method, params, callback, document_buf, options)
	options = options or {}
	local token = {}
	local completed = false
	local sent, request_id = client:request(method, params, function(err, result)
		completed = true
		session.outstanding_requests[token] = nil
		callback(err, result)
	end, document_buf)
	if sent and request_id and not completed then
		session.outstanding_requests[token] = {
			client = client,
			id = request_id,
			expected_version = options.expected_version,
			kind = options.kind or "ordinary",
		}
	end
	return sent, request_id
end

local function project_root(path)
	local start = path ~= "" and vim.fs.dirname(path) or vim.uv.cwd()
	return vim.fs.root(
		start,
		{ "pyproject.toml", "setup.py", "setup.cfg", "package.json", "go.mod", "Cargo.toml", ".git" }
	) or start
end

local function executable_file(path)
	local stat = path and vim.uv.fs_stat(path) or nil
	return stat ~= nil and stat.type == "file"
end

local function configured_python_path(state, root)
	local configured = config.options.lsp.python_path
	if type(configured) == "function" then
		configured = configured(state, root)
	end
	if type(configured) == "string" and configured ~= "" then
		local is_absolute = configured:match("^/") or configured:match("^%a:[/\\]")
		local absolute = is_absolute and configured or vim.fs.joinpath(root, configured)
		if executable_file(absolute) then
			return absolute
		end
	end

	for _, relative in ipairs({
		".venv/bin/python",
		"venv/bin/python",
		".venv/Scripts/python.exe",
		"venv/Scripts/python.exe",
	}) do
		local candidate = vim.fs.joinpath(root, relative)
		if executable_file(candidate) then
			return candidate
		end
	end

	local active = vim.env.VIRTUAL_ENV
	if type(active) == "string" and active ~= "" then
		for _, relative in ipairs({ "bin/python", "Scripts/python.exe" }) do
			local candidate = vim.fs.joinpath(active, relative)
			if executable_file(candidate) then
				return candidate
			end
		end
	end
	local system = vim.fn.exepath("python3")
	return system ~= "" and system or "python"
end

local function command_available(command)
	if type(command) == "function" then
		return true
	end
	if type(command) ~= "table" or type(command[1]) ~= "string" then
		return false
	end
	if command[1]:find("/", 1, true) then
		return vim.uv.fs_stat(command[1]) ~= nil
	end
	return vim.fn.executable(command[1]) == 1
end

local function configured_servers(lang)
	if type(config.options.lsp.servers) ~= "table" then
		return {}
	end
	local servers = config.options.lsp.servers[lang]
	if not servers or (type(servers) ~= "table" and type(servers) ~= "function") then
		return {}
	end
	if type(servers) == "function" or servers.cmd then
		return { servers }
	end
	return servers
end

local function clients_for(document, method)
	local clients = {}
	for _, client in ipairs(vim.lsp.get_clients({ bufnr = document.buf })) do
		local ok, supported = pcall(client.supports_method, client, method, { bufnr = document.buf })
		if not ok or supported then
			table.insert(clients, client)
		end
	end
	return clients
end

local function schedule_refresh(session, delay)
	if session.refresh_timer and not session.refresh_timer:is_closing() then
		session.refresh_timer:stop()
	else
		session.refresh_timer = vim.uv.new_timer()
	end
	session.refresh_timer:start(delay or 100, 0, function()
		vim.schedule(function()
			if
				sessions[session.state.buf] == session
				and vim.api.nvim_buf_is_valid(session.state.buf)
				and notebook.get(session.state.buf) == session.state
			then
				M.publish_diagnostics(session.state)
				M.refresh_semantic_tokens(session.state)
			end
		end)
	end)
end

local function setup_document_autocmd(session, document)
	if session.documents[document.buf] then
		return
	end
	session.documents[document.buf] = true
	vim.api.nvim_create_autocmd("DiagnosticChanged", {
		buffer = document.buf,
		callback = function()
			schedule_refresh(session, 50)
		end,
	})
	vim.api.nvim_create_autocmd("LspAttach", {
		buffer = document.buf,
		callback = function()
			schedule_refresh(session, 50)
		end,
	})
end

local function start_servers(session, document)
	if not config.options.lsp.auto_start then
		return
	end
	for _, server in ipairs(configured_servers(document.lang)) do
		server = type(server) == "function" and server(session.state, document) or vim.deepcopy(server)
		if server and command_available(server.cmd) then
			server.name = server.name or ("nvjup-" .. document.lang)
			server.root_dir = server.root_dir or project_root(session.state.path)
			if server.name:lower():find("pyright", 1, true) then
				server.settings = server.settings or {}
				server.settings.python = server.settings.python or {}
				server.settings.python.analysis = server.settings.python.analysis or {}
				server.settings.python.pythonPath = server.settings.python.pythonPath
					or configured_python_path(session.state, server.root_dir)
				session.python_paths = session.python_paths or {}
				session.python_paths[document.buf] = server.settings.python.pythonPath
			end
			server.capabilities = server.capabilities or vim.lsp.protocol.make_client_capabilities()
			-- Neovim 0.12 can issue a pull-diagnostic request before replying to
			-- Pyright's dynamic registration request, deadlocking Pyright 1.1.408.
			-- Prefer the mature publishDiagnostics path unless explicitly enabled.
			if not config.options.lsp.pull_diagnostics and server.capabilities.textDocument then
				server.capabilities.textDocument.diagnostic = { dynamicRegistration = false }
			end
			server.handlers = vim.tbl_deep_extend("force", server.handlers or {}, {
				["workspace/applyEdit"] = M.workspace_apply_handler,
			})
			local client_id = vim.lsp.start(server, {
				bufnr = document.buf,
				silent = true,
			})
			if client_id then
				session.clients[client_id] = true
			end
		end
	end
end

function M.update(state, manager, changed)
	if not config.options.lsp.enabled then
		return
	end
	local session = session_for(state)
	manager = manager or shadow.get(state)
	for _, document in pairs(manager.documents) do
		setup_document_autocmd(session, document)
		start_servers(session, document)
	end
	if changed then
		cancel_requests(session, function(request)
			return request.expected_version ~= nil and request.expected_version ~= manager.version
		end)
		for _, document in pairs(manager.documents) do
			vim.diagnostic.reset(nil, document.buf)
		end
		vim.diagnostic.reset(state.lsp_diagnostic_ns, state.buf)
		schedule_refresh(session, 100)
	end
end

function M.publish_diagnostics(state)
	if not config.options.lsp.enabled or not config.options.lsp.diagnostics then
		vim.diagnostic.reset(state.lsp_diagnostic_ns, state.buf)
		return
	end
	local manager = shadow.get(state)
	local mapped = {}
	for _, document in pairs(manager.documents) do
		for _, diagnostic in ipairs(vim.diagnostic.get(document.buf)) do
			local start_position = manager:shadow_to_notebook(document, {
				line = diagnostic.lnum,
				character = diagnostic.col,
			}, "utf-8")
			local end_position = manager:shadow_to_notebook(document, {
				line = diagnostic.end_lnum or diagnostic.lnum,
				character = diagnostic.end_col or diagnostic.col,
			}, "utf-8")
			if start_position and end_position and not start_position.transformed and not end_position.transformed then
				local item = vim.deepcopy(diagnostic)
				item.bufnr = state.buf
				item.lnum = start_position.row
				item.col = start_position.col
				item.end_lnum = end_position.row
				item.end_col = end_position.col
				item.user_data = vim.tbl_deep_extend("force", item.user_data or {}, {
					nvjup = { shadow_uri = document.uri, version = manager.version },
				})
				table.insert(mapped, item)
			end
		end
	end
	vim.diagnostic.set(state.lsp_diagnostic_ns, state.buf, mapped, {
		virtual_text = true,
		signs = true,
		underline = true,
		update_in_insert = false,
	})
end

local function current_state_and_manager()
	local state = notebook.get()
	if not state then
		notify("current buffer is not an nvjup notebook", vim.log.levels.ERROR)
		return nil
	end
	local ok, err = state:sync_from_buffer()
	if not ok then
		notify(err, vim.log.levels.ERROR)
		return nil
	end
	local changed, manager = shadow.update(state)
	M.update(state, manager, changed)
	return state, manager
end

local function request_at_cursor(method, make_params, on_complete)
	local state, manager = current_state_and_manager()
	if not state then
		return
	end
	local cursor = vim.api.nvim_win_get_cursor(0)
	local row, byte_col = cursor[1] - 1, cursor[2]
	local requests = {}
	for _, document in pairs(manager.documents) do
		for _, client in ipairs(clients_for(document, method)) do
			local mapped = manager:notebook_to_shadow(row, byte_col, client.offset_encoding)
			if mapped and mapped.document == document and not mapped.transformed then
				table.insert(requests, { document = document, client = client, mapped = mapped })
			end
		end
	end
	if #requests == 0 then
		notify("no attached language server supports " .. method, vim.log.levels.WARN)
		return
	end

	local session = session_for(state)
	local expected_version = manager.version
	local pending = #requests
	local results = {}
	local finished = false
	local function finish()
		if finished or pending > 0 then
			return
		end
		finished = true
		if valid_session(session, state, manager, expected_version) then
			on_complete(results, state, manager, expected_version)
		end
	end
	for _, request in ipairs(requests) do
		local params = make_params(request.client, request.document, request.mapped)
		local sent = tracked_request(session, request.client, method, params, function(err, result)
			if not valid_session(session, state, manager, expected_version) then
				return
			end
			table.insert(results, {
				err = err,
				result = result,
				client = request.client,
				document = request.document,
			})
			pending = pending - 1
			finish()
		end, request.document.buf, { expected_version = expected_version })
		if not sent then
			pending = pending - 1
		end
	end
	finish()
end

local function text_document_position(document, mapped)
	return {
		textDocument = { uri = document.uri },
		position = mapped.position,
	}
end

local function trim_empty_lines(lines)
	local first, last = 1, #lines
	while first <= last and (lines[first] == nil or lines[first] == "") do
		first = first + 1
	end
	while last >= first and (lines[last] == nil or lines[last] == "") do
		last = last - 1
	end
	local result = {}
	for index = first, last do
		table.insert(result, lines[index])
	end
	return result
end

local function first_result(results)
	for _, response in ipairs(results) do
		if not response.err and response.result then
			return response
		end
	end
	return nil
end

function M.hover()
	request_at_cursor("textDocument/hover", function(_, document, mapped)
		return text_document_position(document, mapped)
	end, function(results)
		local response = first_result(results)
		if not response then
			return
		end
		local lines = vim.lsp.util.convert_input_to_markdown_lines(response.result.contents)
		lines = trim_empty_lines(lines)
		if #lines > 0 then
			vim.lsp.util.open_floating_preview(lines, "markdown", { border = "rounded" })
		end
	end)
end

function M.signature_help()
	request_at_cursor("textDocument/signatureHelp", function(_, document, mapped)
		return text_document_position(document, mapped)
	end, function(results)
		local response = first_result(results)
		if not response or not response.result.signatures or not response.result.signatures[1] then
			return
		end
		local signature = response.result.signatures[(response.result.activeSignature or 0) + 1]
		local lines = { signature.label }
		if signature.documentation then
			vim.list_extend(lines, vim.lsp.util.convert_input_to_markdown_lines(signature.documentation))
		end
		vim.lsp.util.open_floating_preview(lines, "markdown", { border = "rounded" })
	end)
end

local function location_range(location)
	return location.targetSelectionRange or location.targetRange or location.range
end

local function location_uri(location)
	return location.targetUri or location.uri
end

local function flatten_locations(result)
	if not result then
		return {}
	end
	if result.uri or result.targetUri then
		return { result }
	end
	return result
end

local function location_to_item(state, manager, response, location)
	local uri = location_uri(location)
	local range = location_range(location)
	local document = manager:document_for_uri(uri)
	if document then
		local mapped = manager:shadow_to_notebook(document, range.start, response.client.offset_encoding)
		if not mapped then
			return nil
		end
		local line = vim.api.nvim_buf_get_lines(state.buf, mapped.row, mapped.row + 1, false)[1] or ""
		return {
			bufnr = state.buf,
			filename = state.path,
			lnum = mapped.row + 1,
			col = mapped.col + 1,
			text = line,
		}
	end
	local filename = vim.uri_to_fname(uri)
	local bufnr = vim.uri_to_bufnr(uri)
	pcall(vim.fn.bufload, bufnr)
	local line = vim.api.nvim_buf_is_loaded(bufnr)
			and (vim.api.nvim_buf_get_lines(bufnr, range.start.line, range.start.line + 1, false)[1] or "")
		or ""
	local col = shadow.byte_column(line, range.start.character, response.client.offset_encoding)
	return {
		bufnr = bufnr,
		filename = filename,
		lnum = range.start.line + 1,
		col = col + 1,
		text = line,
	}
end

local function show_locations(results, state, manager, always_list)
	local items = {}
	for _, response in ipairs(results) do
		if not response.err then
			for _, location in ipairs(flatten_locations(response.result)) do
				local item = location_to_item(state, manager, response, location)
				if item then
					table.insert(items, item)
				end
			end
		end
	end
	if #items == 0 then
		notify("no locations found")
		return
	end
	if #items == 1 and not always_list then
		local item = items[1]
		vim.cmd("normal! m'")
		if item.bufnr then
			vim.api.nvim_set_current_buf(item.bufnr)
		else
			vim.cmd.edit(vim.fn.fnameescape(item.filename))
		end
		vim.api.nvim_win_set_cursor(0, { item.lnum, math.max(0, item.col - 1) })
		return
	end
	vim.fn.setqflist({}, " ", { title = "nvjup LSP locations", items = items })
	vim.cmd.copen()
end

local function location_request(method, always_list, extra)
	request_at_cursor(method, function(_, document, mapped)
		local params = text_document_position(document, mapped)
		if extra then
			params = vim.tbl_deep_extend("force", params, extra)
		end
		return params
	end, function(results, state, manager)
		show_locations(results, state, manager, always_list)
	end)
end

function M.definition()
	location_request("textDocument/definition", false)
end

function M.declaration()
	location_request("textDocument/declaration", false)
end

function M.implementation()
	location_request("textDocument/implementation", false)
end

function M.type_definition()
	location_request("textDocument/typeDefinition", false)
end

function M.references()
	location_request("textDocument/references", true, { context = { includeDeclaration = true } })
end

local function completion_documentation(documentation)
	if type(documentation) == "string" then
		return documentation
	end
	if type(documentation) == "table" then
		return documentation.value or ""
	end
	return ""
end

local function completion_state(buf)
	local state = notebook.get(buf)
	if not state then
		return nil
	end
	local ok = state:sync_from_buffer()
	if not ok then
		return nil
	end
	local changed, manager = shadow.update(state)
	M.update(state, manager, changed)
	return state, manager
end

local function sanitize_completion_item(item, response, version, notebook_buf)
	local result = vim.deepcopy(item)
	local edit = result.textEdit
	if edit and edit.newText then
		result.insertText = edit.newText
	end
	result.textEdit = nil
	result._nvjup = {
		notebook_buf = notebook_buf,
		client_id = response.client.id,
		document_buf = response.document.buf,
		document_uri = response.document.uri,
		version = version,
		additional_text_edits = result.additionalTextEdits,
		command = result.command,
	}
	-- nvim-cmp would otherwise apply shadow-document ranges directly to the
	-- visible notebook. Additional edits are applied through execute_completion.
	result.additionalTextEdits = nil
	result.command = nil
	return result
end

function M.complete_at(buf, row, byte_col, completion_context, callback)
	local state, manager = completion_state(buf)
	if not state then
		callback({ isIncomplete = false, items = {} })
		return
	end
	local requests = {}
	for _, document in pairs(manager.documents) do
		for _, client in ipairs(clients_for(document, "textDocument/completion")) do
			local mapped = manager:notebook_to_shadow(row, byte_col, client.offset_encoding)
			if mapped and mapped.document == document and not mapped.transformed then
				table.insert(requests, { document = document, client = client, mapped = mapped })
			end
		end
	end
	if #requests == 0 then
		callback({ isIncomplete = false, items = {} })
		return
	end

	local session = session_for(state)
	local expected_version = manager.version
	local pending = #requests
	local responses = {}
	local finished = false
	local function finish()
		if finished or pending > 0 then
			return
		end
		finished = true
		if not valid_session(session, state, manager, expected_version) then
			return
		end
		local items, seen = {}, {}
		local incomplete = false
		for _, response in ipairs(responses) do
			if not response.err and response.result then
				incomplete = incomplete or response.result.isIncomplete == true
				local source_items = response.result.items or response.result
				for _, item in ipairs(source_items) do
					local inserted = item.insertText or (item.textEdit and item.textEdit.newText) or item.label
					local key = table.concat({ item.label or "", inserted or "", tostring(item.kind or "") }, "\0")
					if not seen[key] then
						seen[key] = true
						table.insert(items, sanitize_completion_item(item, response, expected_version, state.buf))
					end
				end
			end
		end
		callback({ isIncomplete = incomplete, items = items })
	end

	for _, request in ipairs(requests) do
		local params = text_document_position(request.document, request.mapped)
		params.context = completion_context or { triggerKind = 1 }
		local sent = tracked_request(session, request.client, "textDocument/completion", params, function(err, result)
			if not valid_session(session, state, manager, expected_version) then
				return
			end
			table.insert(responses, {
				err = err,
				result = result,
				client = request.client,
				document = request.document,
			})
			pending = pending - 1
			finish()
		end, request.document.buf, { expected_version = expected_version })
		if not sent then
			pending = pending - 1
		end
	end
	finish()
end

function M.completion_trigger_characters(buf)
	local state = notebook.get(buf)
	local manager = state and shadow.get(state) or nil
	local characters, seen = {}, {}
	for _, document in pairs(manager and manager.documents or {}) do
		for _, client in ipairs(clients_for(document, "textDocument/completion")) do
			local provider = client.server_capabilities.completionProvider or {}
			for _, character in ipairs(provider.triggerCharacters or {}) do
				if not seen[character] then
					seen[character] = true
					table.insert(characters, character)
				end
			end
		end
	end
	return characters
end

function M.resolve_completion(item, callback)
	local metadata = item and item._nvjup
	local client = metadata and vim.lsp.get_client_by_id(metadata.client_id) or nil
	local state = metadata and metadata.notebook_buf and notebook.get(metadata.notebook_buf) or nil
	local manager = state and shadow.get(state) or nil
	local session = state and sessions[state.buf] or nil
	local supported = client and client:supports_method("completionItem/resolve", { bufnr = metadata.document_buf })
	if not supported or not state or not manager or not valid_session(session, state, manager, metadata.version) then
		callback(item)
		return
	end
	local request = vim.deepcopy(item)
	request._nvjup = nil
	tracked_request(session, client, "completionItem/resolve", request, function(err, result)
		if not valid_session(session, state, manager, metadata.version) then
			return
		end
		if err or not result then
			callback(item)
			return
		end
		if result.textEdit and result.textEdit.newText then
			result.insertText = result.textEdit.newText
		end
		result.textEdit = nil
		metadata.additional_text_edits = result.additionalTextEdits or metadata.additional_text_edits
		metadata.command = result.command or metadata.command
		result._nvjup = metadata
		result.additionalTextEdits = nil
		result.command = nil
		callback(result)
	end, metadata.document_buf, { expected_version = metadata.version })
end

function M.execute_completion(item, callback)
	local metadata = item and item._nvjup
	local client = metadata and vim.lsp.get_client_by_id(metadata.client_id) or nil
	local state = metadata and metadata.notebook_buf and notebook.get(metadata.notebook_buf) or nil
	local manager = state and shadow.get(state) or nil
	local session = state and sessions[state.buf] or nil
	local valid = metadata and manager and valid_session(session, state, manager, metadata.version)
	if client and valid and metadata.additional_text_edits then
		local ok, err = M.apply_workspace_edit(state, manager, {
			changes = { [metadata.document_uri] = metadata.additional_text_edits },
		}, client, metadata.version)
		if not ok then
			notify(err, vim.log.levels.ERROR)
		end
	end
	if client and valid and metadata.command then
		client:exec_cmd(metadata.command, { bufnr = metadata.document_buf })
	end
	callback(item)
end

function M.completion()
	local notebook_buf = vim.api.nvim_get_current_buf()
	local cmp_ok, cmp = pcall(require, "cmp")
	if cmp_ok then
		pcall(require("nvjup.cmp").attach, notebook_buf)
		cmp.complete()
		return
	end

	local cursor = vim.api.nvim_win_get_cursor(0)
	local line = vim.api.nvim_get_current_line()
	local before = line:sub(1, cursor[2])
	local word = before:match("[%w_]*$") or ""
	local start_col = cursor[2] - #word
	M.complete_at(notebook_buf, cursor[1] - 1, cursor[2], { triggerKind = 1 }, function(response)
		if vim.api.nvim_get_current_buf() ~= notebook_buf or vim.fn.mode():sub(1, 1) ~= "i" then
			return
		end
		local matches = {}
		for _, item in ipairs(response.items) do
			local inserted = item.insertText or item.label
			table.insert(matches, {
				word = inserted,
				abbr = item.label,
				menu = item.detail or "",
				info = completion_documentation(item.documentation),
				kind = item.kind and tostring(item.kind) or "",
			})
		end
		if #matches > 0 then
			vim.fn.complete(start_col + 1, matches)
		end
	end)
end

local function collect_text_edits(state, manager, workspace_edit, client, expected_version)
	if manager.version ~= expected_version then
		return nil, nil, "source map changed before the edit could be applied"
	end
	local notebook_edits = {}
	local external = { changes = {}, documentChanges = {} }

	local function handle(uri, edits)
		local document = manager:document_for_uri(uri)
		if not document then
			external.changes[uri] = edits
			return true
		end
		for _, edit in ipairs(edits) do
			local mapped, err = manager:range_to_notebook(document, edit.range, client.offset_encoding)
			if not mapped then
				return nil, err
			end
			table.insert(notebook_edits, {
				range = {
					start = { line = mapped.start.line, character = mapped.start.character },
					["end"] = { line = mapped["end"].line, character = mapped["end"].character },
				},
				newText = edit.newText,
			})
		end
		return true
	end

	for uri, edits in pairs(workspace_edit.changes or {}) do
		local ok, err = handle(uri, edits)
		if not ok then
			return nil, nil, err
		end
	end
	for _, change in ipairs(workspace_edit.documentChanges or {}) do
		if change.textDocument and change.edits then
			local uri = change.textDocument.uri
			local document = manager:document_for_uri(uri)
			if document then
				local ok, err = handle(uri, change.edits)
				if not ok then
					return nil, nil, err
				end
			else
				table.insert(external.documentChanges, change)
			end
		else
			table.insert(external.documentChanges, change)
		end
	end
	if vim.tbl_isempty(external.changes) then
		external.changes = nil
	end
	if #external.documentChanges == 0 then
		external.documentChanges = nil
	end
	return notebook_edits, external
end

function M.apply_workspace_edit(state, manager, workspace_edit, client, expected_version)
	local notebook_edits, external, err = collect_text_edits(state, manager, workspace_edit, client, expected_version)
	if not notebook_edits then
		return nil, err
	end
	if #notebook_edits > 0 then
		vim.lsp.util.apply_text_edits(notebook_edits, state.buf, "utf-8")
	end
	if external and (external.changes or external.documentChanges) then
		vim.lsp.util.apply_workspace_edit(external, client.offset_encoding)
	end
	local ok, sync_error = state:sync_from_buffer()
	if not ok then
		return nil, sync_error
	end
	local changed = manager:update()
	M.update(state, manager, changed)
	return true
end

function M.workspace_apply_handler(err, params, context)
	if err then
		return { applied = false, failureReason = tostring(err) }
	end
	local client = vim.lsp.get_client_by_id(context.client_id)
	if not client then
		return { applied = false, failureReason = "language client no longer exists" }
	end
	for _, session in pairs(sessions) do
		local manager = shadow.get(session.state)
		for uri in pairs((params.edit or {}).changes or {}) do
			if manager:document_for_uri(uri) then
				local ok, apply_error =
					M.apply_workspace_edit(session.state, manager, params.edit, client, manager.version)
				return { applied = ok == true, failureReason = apply_error }
			end
		end
		for _, change in ipairs((params.edit or {}).documentChanges or {}) do
			if change.textDocument and manager:document_for_uri(change.textDocument.uri) then
				local ok, apply_error =
					M.apply_workspace_edit(session.state, manager, params.edit, client, manager.version)
				return { applied = ok == true, failureReason = apply_error }
			end
		end
	end
	vim.lsp.util.apply_workspace_edit(params.edit, client.offset_encoding)
	return { applied = true }
end

function M.rename(new_name)
	local function run(name)
		if not name or name == "" then
			return
		end
		request_at_cursor("textDocument/rename", function(_, document, mapped)
			local params = text_document_position(document, mapped)
			params.newName = name
			return params
		end, function(results, state, manager, version)
			local response = first_result(results)
			if response and response.result then
				local ok, err = M.apply_workspace_edit(state, manager, response.result, response.client, version)
				if not ok then
					notify(err, vim.log.levels.ERROR)
				end
			end
		end)
	end
	if new_name then
		run(new_name)
	else
		vim.ui.input({ prompt = "Rename symbol: " }, run)
	end
end

function M.code_action()
	request_at_cursor("textDocument/codeAction", function(_, document, mapped)
		local params = text_document_position(document, mapped)
		params.range = { start = mapped.position, ["end"] = mapped.position }
		params.context = { diagnostics = {} }
		return params
	end, function(results, state, manager, version)
		local actions = {}
		for _, response in ipairs(results) do
			for _, action in ipairs(response.result or {}) do
				table.insert(actions, { action = action, response = response })
			end
		end
		vim.ui.select(actions, {
			prompt = "Notebook code actions",
			format_item = function(item)
				return item.action.title
			end,
		}, function(selected)
			local session = sessions[state.buf]
			if not selected or not valid_session(session, state, manager, version) then
				return
			end
			if selected.action.edit then
				local ok, err =
					M.apply_workspace_edit(state, manager, selected.action.edit, selected.response.client, version)
				if not ok then
					notify(err, vim.log.levels.ERROR)
					return
				end
			end
			if selected.action.command then
				selected.response.client:exec_cmd(selected.action.command, { bufnr = selected.response.document.buf })
			end
		end)
	end)
end

local function symbol_items(response, symbols, parent, state, manager, items)
	for _, symbol in ipairs(symbols or {}) do
		local range = symbol.selectionRange or symbol.range or (symbol.location and symbol.location.range)
		local uri = symbol.location and symbol.location.uri or response.document.uri
		local document = manager:document_for_uri(uri)
		local mapped = range
			and document
			and manager:shadow_to_notebook(document, range.start, response.client.offset_encoding)
		if mapped then
			table.insert(items, {
				bufnr = state.buf,
				lnum = mapped.row + 1,
				col = mapped.col + 1,
				text = (parent and (parent .. ".") or "") .. symbol.name,
			})
		end
		if symbol.children then
			symbol_items(
				response,
				symbol.children,
				(parent and (parent .. ".") or "") .. symbol.name,
				state,
				manager,
				items
			)
		end
	end
end

function M.document_symbols()
	local state, manager = current_state_and_manager()
	if not state then
		return
	end
	local requests = {}
	for _, document in pairs(manager.documents) do
		for _, client in ipairs(clients_for(document, "textDocument/documentSymbol")) do
			table.insert(requests, { document = document, client = client })
		end
	end
	if #requests == 0 then
		notify("no attached language server supports document symbols", vim.log.levels.WARN)
		return
	end
	local session = session_for(state)
	local pending, version, responses = #requests, manager.version, {}
	local finished = false
	local function finish()
		if finished or pending > 0 then
			return
		end
		finished = true
		if not valid_session(session, state, manager, version) then
			return
		end
		local items = {}
		for _, response in ipairs(responses) do
			if not response.err then
				symbol_items(response, response.result, nil, state, manager, items)
			end
		end
		vim.fn.setqflist({}, " ", { title = "nvjup document symbols", items = items })
		vim.cmd.copen()
	end
	for _, request in ipairs(requests) do
		local sent = tracked_request(session, request.client, "textDocument/documentSymbol", {
			textDocument = { uri = request.document.uri },
		}, function(err, result)
			if not valid_session(session, state, manager, version) then
				return
			end
			table.insert(responses, {
				err = err,
				result = result,
				client = request.client,
				document = request.document,
			})
			pending = pending - 1
			finish()
		end, request.document.buf, { expected_version = version })
		if not sent then
			pending = pending - 1
		end
	end
	finish()
end

local function semantic_highlight(token_type, lang)
	return "@lsp.type." .. token_type .. "." .. lang
end

function M.refresh_semantic_tokens(state)
	if not config.options.lsp.enabled or not vim.api.nvim_buf_is_valid(state.buf) then
		return
	end
	local manager = shadow.get(state)
	local session = session_for(state)
	cancel_requests(session, function(request)
		return request.kind == "semantic"
	end)
	session.semantic_generation = (session.semantic_generation or 0) + 1
	local generation = session.semantic_generation
	local version = manager.version
	local pending = 0
	local issued = 0
	local responses = {}

	local function finish()
		if
			pending ~= 0
			or generation ~= session.semantic_generation
			or not valid_session(session, state, manager, version)
		then
			return
		end
		vim.api.nvim_buf_clear_namespace(state.buf, state.lsp_semantic_ns, 0, -1)
		for _, response in ipairs(responses) do
			local result, document, client = response.result, response.document, response.client
			local provider = client.server_capabilities.semanticTokensProvider or {}
			local token_types = (provider.legend or {}).tokenTypes or {}
			local line, character = 0, 0
			for index = 1, #result.data, 5 do
				local delta_line = result.data[index]
				local delta_start = result.data[index + 1]
				local length = result.data[index + 2]
				local token_type = token_types[(result.data[index + 3] or 0) + 1]
				line = line + delta_line
				character = delta_line == 0 and (character + delta_start) or delta_start
				if token_type then
					local start_position = manager:shadow_to_notebook(
						document,
						{ line = line, character = character },
						client.offset_encoding
					)
					local end_position = manager:shadow_to_notebook(
						document,
						{ line = line, character = character + length },
						client.offset_encoding
					)
					if start_position and end_position and start_position.cell_id == end_position.cell_id then
						vim.api.nvim_buf_set_extmark(
							state.buf,
							state.lsp_semantic_ns,
							start_position.row,
							start_position.col,
							{
								end_row = end_position.row,
								end_col = end_position.col,
								hl_group = semantic_highlight(token_type, document.lang),
								priority = 125,
							}
						)
					end
				end
			end
		end
	end

	for _, document in pairs(manager.documents) do
		for _, client in ipairs(clients_for(document, "textDocument/semanticTokens/full")) do
			pending = pending + 1
			local sent = tracked_request(session, client, "textDocument/semanticTokens/full", {
				textDocument = { uri = document.uri },
			}, function(err, result)
				if not valid_session(session, state, manager, version) or generation ~= session.semantic_generation then
					return
				end
				pending = pending - 1
				if not err and result and result.data then
					table.insert(responses, { result = result, document = document, client = client })
				end
				finish()
			end, document.buf, { expected_version = version, kind = "semantic" })
			if sent then
				issued = issued + 1
			else
				pending = pending - 1
			end
		end
	end
	if issued == 0 then
		if sessions[state.buf] == session and vim.api.nvim_buf_is_valid(state.buf) then
			vim.api.nvim_buf_clear_namespace(state.buf, state.lsp_semantic_ns, 0, -1)
		end
		return
	end
	finish()
end

function M.status(state)
	local manager = state and state.shadow
	local session = state and sessions[state.buf]
	local result = { version = manager and manager.version or 0, documents = {} }
	if not manager then
		return result
	end
	for lang, document in pairs(manager.documents) do
		local clients = vim.lsp.get_clients({ bufnr = document.buf })
		table.insert(result.documents, {
			lang = lang,
			buf = document.buf,
			uri = document.uri,
			segments = #document.segments,
			python_path = session and session.python_paths and session.python_paths[document.buf] or nil,
			clients = vim.tbl_map(function(client)
				return client.name
			end, clients),
		})
	end
	return result
end

function M.detach(state)
	local session = state and sessions[state.buf]
	if not session then
		return
	end
	session.semantic_generation = (session.semantic_generation or 0) + 1
	vim.diagnostic.reset(state.lsp_diagnostic_ns, state.buf)
	vim.api.nvim_buf_clear_namespace(state.buf, state.lsp_semantic_ns, 0, -1)
	if session.refresh_timer and not session.refresh_timer:is_closing() then
		session.refresh_timer:stop()
		session.refresh_timer:close()
	end
	cancel_requests(session)
	sessions[state.buf] = nil
end

M._sessions = sessions
M._collect_text_edits = collect_text_edits
M.find_python_path = configured_python_path
M.project_root = project_root

return M
