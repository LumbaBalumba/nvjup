local config = require("nvjup.config")
local lsp = require("nvjup.lsp")
local notebook = require("nvjup.notebook")
local render = require("nvjup.render")
local util = require("nvjup.util")

local root = assert(vim.g.nvjup_project_root)
local fixture = vim.fs.joinpath(root, "tests", "fixtures", "notebooks", "09_lsp_mapping.ipynb")
local server_path = vim.fs.joinpath(root, "tests", "lsp", "mock_server.py")
local original_lsp = vim.deepcopy(config.options.lsp)
local original_select = vim.ui.select
local state
local client_ids = {}
local passed = 0
local failures = {}

local function wait_for(predicate, message, timeout)
	assert(vim.wait(timeout or 5000, predicate, 20), message)
end

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

local function local_source_row(cell, fragment)
	for index, line in ipairs(util.source_to_lines(cell.source)) do
		if line:find(fragment, 1, true) then
			return cell.range.start_row + index - 1, line:find(fragment, 1, true) - 1
		end
	end
	error("fragment not found: " .. fragment)
end

local function cleanup()
	vim.ui.select = original_select
	config.options.lsp = original_lsp
	for _, client_id in ipairs(client_ids) do
		local client = vim.lsp.get_client_by_id(client_id)
		if client then
			pcall(client.stop, client, true)
		end
	end
	if state and vim.api.nvim_buf_is_valid(state.buf) then
		pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
	end
end

local setup_ok, setup_error = xpcall(function()
	vim.cmd.edit(vim.fn.fnameescape(fixture))
	state = assert(notebook.get())
	state.cells[5].source = state.cells[5].source .. "missing_name\n"
	state:replace_buffer()
	render.render(state)

	config.options.lsp.auto_start = true
	config.options.lsp.servers = {
		python = {
			{
				name = "nvjup-mock-lsp",
				cmd = { assert(vim.fn.exepath("python3")), server_path },
				root_dir = root,
			},
		},
	}
	lsp.update(state, assert(state.shadow), false)
	wait_for(function()
		local document = state.shadow:document("python")
		local clients = document and vim.lsp.get_clients({ bufnr = document.buf }) or {}
		for _, client in ipairs(clients) do
			if client.name == "nvjup-mock-lsp" and client.initialized then
				client_ids = { client.id }
				return true
			end
		end
		return false
	end, "mock LSP did not initialize")
end, debug.traceback)

if not setup_ok then
	table.insert(failures, "setup\n" .. setup_error)
else
	test("starts a real Neovim LSP client on the Python shadow buffer", function()
		local status = lsp.status(state)
		assert(#status.documents == 1)
		assert(vim.tbl_contains(status.documents[1].clients, "nvjup-mock-lsp"))
		assert(status.documents[1].segments == 3)
	end)

	test("maps asynchronously published diagnostics into the notebook", function()
		wait_for(function()
			lsp.publish_diagnostics(state)
			for _, diagnostic in ipairs(vim.diagnostic.get(state.buf, { namespace = state.lsp_diagnostic_ns })) do
				if diagnostic.message:find("missing_name", 1, true) then
					return true
				end
			end
			return false
		end, "mapped diagnostic was not published")
	end)

	test("returns asynchronous completion items from the shadow document", function()
		local row, col = local_source_row(state.cells[5], "length")
		local response
		lsp.complete_at(state.buf, row, col + #"length", { triggerKind = 1 }, function(result)
			response = result
		end)
		wait_for(function()
			return response ~= nil
		end, "completion response was not returned")
		assert(#response.items >= 1)
		assert(response.items[1].label == "length")
		assert(response.items[1].insertText == "length")
		assert(response.items[1].textEdit == nil)
	end)

	test("references and document symbols map into notebook quickfix entries", function()
		local row, col = local_source_row(state.cells[5], "length")
		vim.api.nvim_set_current_buf(state.buf)
		vim.api.nvim_win_set_cursor(0, { row + 1, col })
		lsp.references()
		wait_for(function()
			return #vim.fn.getqflist() >= 2
		end, "references were not mapped into the quickfix list")
		vim.cmd.cclose()
		vim.api.nvim_set_current_buf(state.buf)
		lsp.document_symbols()
		wait_for(function()
			for _, item in ipairs(vim.fn.getqflist()) do
				if item.text:find("length", 1, true) then
					return true
				end
			end
			return false
		end, "document symbols were not mapped")
		vim.cmd.cclose()
		vim.api.nvim_set_current_buf(state.buf)
	end)

	test("go-to-definition jumps from a later cell to an earlier cell", function()
		local row, col = local_source_row(state.cells[5], "length")
		vim.api.nvim_set_current_buf(state.buf)
		vim.api.nvim_win_set_cursor(0, { row + 1, col })
		lsp.definition()
		local expected_row = local_source_row(state.cells[2], "def length")
		wait_for(function()
			return vim.api.nvim_get_current_buf() == state.buf and vim.api.nvim_win_get_cursor(0)[1] == expected_row + 1
		end, "definition did not map back to the defining cell")
	end)

	test("hover and signature help use shadow responses in notebook UI", function()
		local before = #vim.api.nvim_list_wins()
		lsp.hover()
		wait_for(function()
			return #vim.api.nvim_list_wins() > before
		end, "hover floating window did not open")
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			if vim.api.nvim_win_get_config(win).relative ~= "" then
				pcall(vim.api.nvim_win_close, win, true)
			end
		end
		vim.api.nvim_set_current_buf(state.buf)
		lsp.signature_help()
		wait_for(function()
			for _, win in ipairs(vim.api.nvim_list_wins()) do
				if vim.api.nvim_win_get_config(win).relative ~= "" then
					return true
				end
			end
			return false
		end, "signature floating window did not open")
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			if vim.api.nvim_win_get_config(win).relative ~= "" then
				pcall(vim.api.nvim_win_close, win, true)
			end
		end
	end)

	test("projects semantic tokens back into code cells", function()
		lsp.refresh_semantic_tokens(state)
		wait_for(function()
			return #vim.api.nvim_buf_get_extmarks(state.buf, state.lsp_semantic_ns, 0, -1, {}) >= 2
		end, "semantic tokens were not projected")
	end)

	test("rename safely edits every code-cell occurrence", function()
		local row, col = local_source_row(state.cells[2], "length")
		vim.api.nvim_set_current_buf(state.buf)
		vim.api.nvim_win_set_cursor(0, { row + 1, col })
		lsp.rename("measure")
		wait_for(function()
			state:sync_from_buffer()
			return state.cells[2].source:find("def measure", 1, true)
				and state.cells[5].source:find("measure(point)", 1, true)
		end, "rename edits were not mapped across cells")
	end)

	test("code actions apply only through safe notebook mappings", function()
		local row, col = local_source_row(state.cells[5], "point")
		vim.api.nvim_set_current_buf(state.buf)
		vim.api.nvim_win_set_cursor(0, { row + 1, col })
		vim.ui.select = function(items, _, callback)
			callback(items[1])
		end
		lsp.code_action()
		wait_for(function()
			state:sync_from_buffer()
			return state.cells[5].source:find("measure(renamed_point)", 1, true) ~= nil
		end, "safe code action was not applied")
	end)
end

cleanup()

if #failures > 0 then
	print(table.concat(failures, "\n\n"))
	vim.cmd("cquit " .. math.min(255, #failures))
else
	print(string.format("Stage 2 LSP integration tests: %d passed", passed))
	vim.cmd("qa!")
end
