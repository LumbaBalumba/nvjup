local kernel = require("nvjup.kernel")
local notebook = require("nvjup.notebook")

local M = {}

local symbols = {
	busy = "●",
	dead = "×",
	error = "×",
	idle = "○",
	interrupting = "◐",
	restarting = "◐",
	starting = "◐",
	stopped = "○",
}

function M.get(buf)
	buf = buf or vim.api.nvim_get_current_buf()
	local state = notebook.get(buf)
	if not state then
		return nil
	end
	local status = kernel.status(state)
	local cell
	if buf == vim.api.nvim_get_current_buf() then
		cell = state:current_cell()
	end
	return {
		kernel = status.state or "stopped",
		kernel_name = status.kernel_name,
		queued = status.queued or 0,
		cell = cell and cell.execution_status or nil,
		modified = vim.bo[buf].modified,
	}
end

function M.component(buf)
	local status = M.get(buf)
	if not status then
		return ""
	end
	local parts = {
		string.format("%s %s", symbols[status.kernel] or "?", status.kernel_name or "kernel"),
	}
	if status.queued > 0 then
		table.insert(parts, "q:" .. status.queued)
	end
	if status.cell and status.cell ~= "idle" then
		table.insert(parts, status.cell)
	end
	if status.modified then
		table.insert(parts, "+")
	end
	return table.concat(parts, " ")
end

return M
