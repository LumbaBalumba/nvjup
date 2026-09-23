local actions = require("nvjup.actions")
local config = require("nvjup.config")
local kernel = require("nvjup.kernel")
local lsp = require("nvjup.lsp")

local M = {}

local function map(buf, modes, lhs, rhs, description)
	if lhs == false or lhs == nil or lhs == "" then
		return
	end
	vim.keymap.set(modes, lhs, rhs, { buffer = buf, silent = true, desc = description })
end

function M.attach(buf)
	local keys = config.options.keymaps
	-- NvChad maps <leader>n with nowait to line-number toggling. A local
	-- non-nowait prefix prevents that global mapping from consuming jupynvim's
	-- <leader>n… notebook mappings before their final key is entered.
	map(buf, "n", "<leader>n", "<Nop>", "Notebook actions")
	map(buf, { "n", "x", "o" }, keys.next_cell, actions.next_cell, "Next notebook cell")
	map(buf, { "n", "x", "o" }, keys.previous_cell, actions.previous_cell, "Previous notebook cell")
	map(buf, { "n", "x", "o" }, keys.next_code_cell, function()
		actions.next_cell({ code_only = true })
	end, "Next code cell")
	map(buf, { "n", "x", "o" }, keys.previous_code_cell, function()
		actions.previous_cell({ code_only = true })
	end, "Previous code cell")
	map(buf, { "x", "o" }, keys.inner_cell, function()
		actions.select_cell(false)
	end, "Inner notebook cell")
	map(buf, { "x", "o" }, keys.around_cell, function()
		actions.select_cell(true)
	end, "Around notebook cell")
	map(buf, "n", keys.insert_below, actions.insert_below, "Insert cell below")
	map(buf, "n", keys.insert_above, actions.insert_above, "Insert cell above")
	map(buf, "n", keys.duplicate_cell, actions.duplicate_cell, "Duplicate cell")
	map(buf, "n", keys.delete_cell, actions.delete_cell, "Delete cell")
	map(buf, "n", keys.move_up, actions.move_up, "Move cell up")
	map(buf, "n", keys.move_down, actions.move_down, "Move cell down")
	map(buf, "n", keys.split_cell, actions.split_cell, "Split cell")
	map(buf, "n", keys.merge_below, actions.merge_below, "Merge cell below")
	map(buf, "n", keys.change_type, actions.change_type, "Change cell type")
	map(buf, "n", keys.to_markdown, function()
		actions.change_type("markdown")
	end, "Convert to Markdown cell")
	map(buf, "n", keys.to_code, function()
		actions.change_type("code")
	end, "Convert to code cell")
	map(buf, "n", keys.toggle_source, actions.toggle_source, "Toggle cell source")
	map(buf, "n", keys.toggle_output, actions.toggle_output, "Expand/collapse truncated cell output")
	map(buf, "n", keys.open_output, actions.open_output, "Open full cell output")
	map(buf, "n", keys.plot_focus, actions.plot_focus, "Open interactive output focus")
	map(buf, "n", keys.clear_output, actions.clear_output, "Clear cell output")
	map(buf, "n", keys.clear_all_outputs, actions.clear_all_outputs, "Clear all notebook outputs")
	map(buf, "n", keys.outline, actions.outline, "Notebook outline")
	map(buf, "n", keys.refresh, actions.refresh, "Refresh notebook display")
	map(buf, { "n", "i" }, keys.run_current, kernel.run_current, "Run current notebook cell")
	map(buf, { "n", "i" }, keys.run_and_advance, kernel.run_and_advance, "Run current cell and advance")
	map(buf, "n", keys.run_and_advance_alt, kernel.run_and_advance, "Run current cell and advance")
	map(buf, "n", keys.run_above, kernel.run_above, "Run notebook cells above")
	map(buf, "n", keys.run_below, kernel.run_below, "Run notebook cells below")
	map(buf, "n", keys.run_all, kernel.run_all, "Run all notebook cells")
	map(buf, "n", keys.start, kernel.start, "Start notebook kernel")
	map(buf, "n", keys.shutdown, kernel.shutdown, "Stop notebook kernel")
	map(buf, "n", keys.interrupt, kernel.interrupt, "Interrupt notebook kernel")
	map(buf, "n", keys.restart, kernel.restart, "Restart notebook kernel")

	-- Mirror the normal-code LSP bindings. These are buffer-local proxies to
	-- per-language shadow documents rather than clients attached to notebook text.
	map(buf, "n", keys.lsp_definition, lsp.definition, "LSP definition")
	map(buf, "n", keys.lsp_declaration, lsp.declaration, "LSP declaration")
	map(buf, "n", keys.lsp_implementation, lsp.implementation, "LSP implementation")
	map(buf, "n", keys.lsp_type_definition, lsp.type_definition, "LSP type definition")
	map(buf, "n", keys.lsp_references, lsp.references, "LSP references")
	map(buf, "n", keys.lsp_hover, lsp.hover, "LSP hover")
	map(buf, "n", keys.lsp_signature, lsp.signature_help, "LSP signature help")
	map(buf, "i", keys.lsp_completion, lsp.completion, "LSP completion")
	map(buf, "n", keys.lsp_rename, lsp.rename, "LSP rename")
	map(buf, { "n", "x" }, keys.lsp_code_action, lsp.code_action, "LSP code action")
	map(buf, "n", keys.lsp_symbols, lsp.document_symbols, "LSP document symbols")
end

return M
