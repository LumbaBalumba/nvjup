local config = require("nvjup.config")

local M = {}

local function pick(title, items, entry_maker, on_select)
	if config.options.integrations.telescope == false then
		return false
	end
	local ok_pickers, pickers = pcall(require, "telescope.pickers")
	local ok_finders, finders = pcall(require, "telescope.finders")
	local ok_config, telescope_config = pcall(require, "telescope.config")
	local ok_actions, telescope_actions = pcall(require, "telescope.actions")
	local ok_state, action_state = pcall(require, "telescope.actions.state")
	if not (ok_pickers and ok_finders and ok_config and ok_actions and ok_state) then
		return false
	end
	pickers
		.new({}, {
			prompt_title = title,
			finder = finders.new_table({ results = items, entry_maker = entry_maker }),
			sorter = telescope_config.values.generic_sorter({}),
			attach_mappings = function(prompt_bufnr)
				telescope_actions.select_default:replace(function()
					local selection = action_state.get_selected_entry()
					telescope_actions.close(prompt_bufnr)
					if selection then
						on_select(selection.value)
					end
				end)
				return true
			end,
		})
		:find()
	return true
end

function M.outline(notebook, items)
	return pick("Notebook cells", items, function(item)
		return {
			value = item,
			display = item.label,
			ordinal = item.label,
			lnum = item.row and item.row + 1 or nil,
		}
	end, function(item)
		notebook:goto_cell(item.index)
		require("nvjup.render").render(notebook)
	end)
end

function M.variables(state, variables, on_select)
	return pick("Kernel variables", variables, function(item)
		local display = string.format("%-24s %-18s %s", item.name or "", item.type or "", item.value or "")
		return { value = item, display = display, ordinal = table.concat({ item.name or "", item.type or "" }, " ") }
	end, on_select)
end

function M.available()
	if config.options.integrations.telescope == false then
		return false
	end
	return pcall(require, "telescope")
end

return M
