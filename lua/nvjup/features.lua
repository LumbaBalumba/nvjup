local lsp = require("nvjup.lsp")
local shadow = require("nvjup.shadow")
local treesitter = require("nvjup.treesitter")

local M = {}

function M.update(state)
	if not state or state.internal_change then
		return
	end
	treesitter.update(state)
	local changed, manager = shadow.update(state)
	lsp.update(state, manager, changed)
end

function M.detach(state)
	if not state then
		return
	end
	lsp.detach(state)
	treesitter.detach(state)
	shadow.detach(state)
end

return M
