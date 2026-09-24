local config = require("nvjup.config")
local kernel = require("nvjup.kernel")
local lsp = require("nvjup.lsp")
local notebook = require("nvjup.notebook")

local M = {}
local registered_source
local registered_kernel_source
local attached = {}

local Source = {}
Source.__index = Source

function Source:is_available()
	return notebook.get() ~= nil
end

function Source:get_debug_name()
	return "nvjup shadow LSP"
end

function Source:get_position_encoding_kind()
	return "utf-8"
end

function Source:get_keyword_pattern()
	return [[\k\+]]
end

function Source:get_trigger_characters()
	return lsp.completion_trigger_characters(vim.api.nvim_get_current_buf())
end

function Source:complete(params, callback)
	local context = params.context
	lsp.complete_at(context.bufnr, context.cursor.row - 1, context.cursor.col - 1, params.completion_context, callback)
end

function Source:resolve(item, callback)
	lsp.resolve_completion(item, callback)
end

function Source:execute(item, callback)
	lsp.execute_completion(item, callback)
end

local KernelSource = {}
KernelSource.__index = KernelSource

function KernelSource:is_available()
	return config.options.completion.kernel == true and notebook.get() ~= nil
end

function KernelSource:get_debug_name()
	return "nvjup live kernel"
end

function KernelSource:get_keyword_pattern()
	return [[\k\+]]
end

function KernelSource:complete(params, callback)
	local context = params.context
	kernel.complete_at(context.bufnr, context.cursor.row - 1, context.cursor.col - 1, function(err, payload)
		if err or not payload then
			callback({ isIncomplete = false, items = {} })
			return
		end
		local items = {}
		for _, match in ipairs(payload.matches or {}) do
			table.insert(items, {
				label = match,
				insertText = match,
				kind = vim.lsp.protocol.CompletionItemKind.Variable,
				detail = "[nvjup kernel]",
			})
		end
		callback({ isIncomplete = false, items = items })
	end)
end

local function source_list(cmp)
	local result = { { name = "nvjup", priority = 1000 } }
	if config.options.completion.kernel == true then
		table.insert(result, { name = "nvjup_kernel", priority = 750 })
	end
	for _, source in ipairs(cmp.get_config().sources or {}) do
		if source.name ~= "nvjup" and source.name ~= "nvjup_kernel" then
			table.insert(result, vim.deepcopy(source))
		end
	end
	return result
end

function M.attach(buf)
	if not vim.api.nvim_buf_is_valid(buf) or not notebook.get(buf) then
		return false
	end
	local ok, cmp = pcall(require, "cmp")
	if not ok then
		return false
	end
	if not registered_source then
		registered_source = cmp.register_source("nvjup", setmetatable({}, Source))
	end
	if config.options.completion.kernel == true and not registered_kernel_source then
		registered_kernel_source = cmp.register_source("nvjup_kernel", setmetatable({}, KernelSource))
	end
	if not attached[buf] then
		vim.api.nvim_buf_call(buf, function()
			cmp.setup.buffer({ sources = source_list(cmp) })
		end)
		attached[buf] = true
	end
	return true
end

function M.detach(buf)
	attached[buf] = nil
end

return M
