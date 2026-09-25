local config = require("nvjup.config")

local M = {}

local states = {}
local snacks_inline = {}
local language_registered = false
local snacks_layout_installed = false
local snacks_inline_factory_installed = false

local function enabled()
	return config.options.render.markdown ~= false
end

local function rendered_regions(state)
	local regions = {}
	local signature = {}
	for _, cell in ipairs(state.cells or {}) do
		if cell.cell_type == "markdown" and cell.markdown_rendered ~= false then
			local range = cell.range or {}
			local start_row = range.start_row
			local end_row = range.end_exclusive
			if type(start_row) == "number" and type(end_row) == "number" and end_row > start_row then
				regions[#regions + 1] = { { start_row, 0, end_row, 0 } }
				signature[#signature + 1] = string.format("%s:%d:%d", cell.id, start_row, end_row)
			end
		end
	end
	return regions, table.concat(signature, "|")
end

local function register_language()
	if language_registered then
		return true
	end
	if not pcall(vim.treesitter.language.add, "markdown") then
		return false
	end
	pcall(vim.treesitter.language.add, "markdown_inline")
	pcall(vim.treesitter.language.add, "latex")
	vim.treesitter.language.register("markdown", "nvjup")
	language_registered = true
	return true
end

local function attach_render_markdown(state)
	if config.options.integrations.render_markdown == false then
		return false
	end
	-- Requiring the public module first lets lazy.nvim load and configure an
	-- otherwise Markdown-filetype-lazy installation before we reuse its state.
	if not pcall(require, "render-markdown") then
		return false
	end
	local ok_state, render_state = pcall(require, "render-markdown.state")
	local ok_manager, manager = pcall(require, "render-markdown.core.manager")
	if not ok_state or not ok_manager or type(render_state.file_types) ~= "table" then
		return false
	end
	local added_filetype = not vim.tbl_contains(render_state.file_types, "nvjup")
	if added_filetype then
		render_state.file_types[#render_state.file_types + 1] = "nvjup"
	end
	-- Keep nvjup's concealed structural marker and rendered LaTeX hidden on
	-- the cursor line; the user's remaining render-markdown config is reused.
	local ok_config, buffer_config = pcall(render_state.get, state.buf, {
		win_options = {
			concealcursor = { default = "nc", rendered = "nc" },
		},
	})
	if ok_config and buffer_config then
		buffer_config.win_options.concealcursor = { default = "nc", rendered = "nc" }
	end
	local ok = pcall(manager.attach, state.buf)
	if added_filetype then
		table.remove(render_state.file_types, #render_state.file_types)
	end
	state.markdown_render_markdown = ok and manager.attached(state.buf)
	return state.markdown_render_markdown
end

local function install_snacks_layout()
	if snacks_layout_installed then
		return
	end
	local ok, placement = pcall(require, "snacks.image.placement")
	if not ok or type(placement._render) ~= "function" then
		return
	end
	local original_render = placement._render
	placement._render = function(self, extmarks)
		if
			self.opts
			and self.opts.type == "math"
			and vim.api.nvim_buf_is_valid(self.buf)
			and vim.bo[self.buf].filetype == "nvjup"
		then
			for _, extmark in ipairs(extmarks) do
				if type(extmark.virt_text_win_col) == "number" then
					extmark.virt_text_win_col = extmark.virt_text_win_col + 2
				end
				for _, virtual_line in ipairs(extmark.virt_lines or {}) do
					if virtual_line[1] then
						virtual_line[1][1] = "  " .. virtual_line[1][1]
					else
						table.insert(virtual_line, 1, { "  " })
					end
				end
			end
		end
		return original_render(self, extmarks)
	end
	snacks_layout_installed = true
end

local function install_snacks_inline_factory()
	if snacks_inline_factory_installed then
		return
	end
	local ok, inline = pcall(require, "snacks.image.inline")
	if not ok or type(inline.new) ~= "function" then
		return
	end
	local original_new = inline.new
	inline.new = function(buf, ...)
		local instance = original_new(buf, ...)
		snacks_inline[buf] = instance
		local state = states[buf]
		if state then
			state.markdown_snacks_inline = instance
		end
		return instance
	end
	snacks_inline_factory_installed = true
end

local function attach_snacks(state)
	if config.options.integrations.snacks == false then
		return false
	end
	if snacks_inline[state.buf] then
		state.markdown_snacks_inline = snacks_inline[state.buf]
		state.markdown_snacks = true
		return true
	end
	local ok_snacks, snacks = pcall(require, "snacks")
	if not ok_snacks or not snacks.image or snacks.image.config.enabled == false then
		return false
	end
	install_snacks_layout()
	install_snacks_inline_factory()
	pcall(snacks.image.doc.attach, state.buf)
	state.markdown_snacks = true
	return true
end

local function update_integrations(state, force)
	if state.markdown_render_markdown then
		local ok_ui, ui = pcall(require, "render-markdown.core.ui")
		if ok_ui then
			for _, win in ipairs(vim.fn.win_findbuf(state.buf)) do
				pcall(ui.update, state.buf, win, "NvJupMarkdown", force == true)
			end
		end
	end
	if state.markdown_snacks_inline and force then
		vim.schedule(function()
			if states[state.buf] == state and state.markdown_snacks_inline then
				pcall(state.markdown_snacks_inline.update, state.markdown_snacks_inline)
			end
		end)
	end
end

function M.attach(state)
	if not enabled() or not state or not vim.api.nvim_buf_is_valid(state.buf) then
		return false
	end
	states[state.buf] = state
	if not register_language() then
		return false
	end

	local ok, parser = pcall(vim.treesitter.get_parser, state.buf, "markdown")
	if not ok or not parser then
		return false
	end
	state.markdown_parser = parser
	M.refresh(state, true)
	pcall(vim.treesitter.start, state.buf, "markdown")
	attach_render_markdown(state)
	attach_snacks(state)
	update_integrations(state, true)
	return true
end

function M.refresh(state, force)
	if not enabled() or not state or not vim.api.nvim_buf_is_valid(state.buf) then
		return false
	end
	local parser = state.markdown_parser
	if not parser then
		return false
	end
	local regions, signature = rendered_regions(state)
	local changed = signature ~= state.markdown_region_signature
	if changed or force then
		-- LanguageTree keeps injected children when the root is projected to an
		-- empty/different region set. Remove them first so Markdown source mode
		-- cannot retain stale image, inline-markup, or LaTeX matches.
		local child_languages = {}
		if type(parser.children) == "function" and type(parser.remove_child) == "function" then
			for child_language in pairs(parser:children()) do
				child_languages[#child_languages + 1] = child_language
			end
			for _, child_language in ipairs(child_languages) do
				pcall(parser.remove_child, parser, child_language)
			end
		end
		local ok = pcall(parser.set_included_regions, parser, regions)
		if not ok then
			return false
		end
		state.markdown_region_signature = signature
		pcall(parser.parse, parser)
	end
	update_integrations(state, changed or force)
	return true
end

function M.detach(state)
	if not state then
		return
	end
	local buf = state.buf
	states[buf] = nil
	state.markdown_parser = nil
	state.markdown_snacks_inline = nil
	vim.schedule(function()
		if not vim.api.nvim_buf_is_valid(buf) then
			snacks_inline[buf] = nil
		end
	end)
end

function M.set_rendered(state, cell, value)
	if not cell or cell.cell_type ~= "markdown" then
		return false
	end
	local rendered = value ~= false
	local changed = cell.markdown_rendered ~= rendered
	cell.markdown_rendered = rendered
	if changed then
		M.refresh(state, true)
	end
	return rendered
end

function M.toggle(state, cell)
	return M.set_rendered(state, cell, cell.markdown_rendered == false)
end

function M.enabled()
	return enabled()
end

function M.external_active(state)
	return state and state.markdown_render_markdown == true
end

function M.regions(state)
	return rendered_regions(state)
end

return M
