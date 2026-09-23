local M = {}

local aliases = {
	bash = "bash",
	c = "c",
	cpp = "cpp",
	cxx = "cpp",
	go = "go",
	javascript = "javascript",
	js = "javascript",
	julia = "julia",
	lua = "lua",
	markdown = "markdown",
	python = "python",
	python3 = "python",
	r = "r",
	raw = "text",
	rust = "rust",
	typescript = "typescript",
	ts = "typescript",
}

local extensions = {
	bash = "sh",
	c = "c",
	cpp = "cpp",
	go = "go",
	javascript = "js",
	julia = "jl",
	lua = "lua",
	python = "py",
	r = "r",
	rust = "rs",
	typescript = "ts",
}

local comments = {
	bash = "#",
	c = "//",
	cpp = "//",
	go = "//",
	javascript = "//",
	julia = "#",
	lua = "--",
	python = "#",
	r = "#",
	rust = "//",
	typescript = "//",
}

function M.normalize(value)
	if type(value) ~= "string" or value == "" then
		return "text"
	end
	local lowered = value:lower():gsub("[%s_-]", "")
	return aliases[lowered] or value:lower()
end

function M.primary(state)
	local metadata = (state.document or {}).metadata or {}
	local value = (metadata.language_info or {}).name or (metadata.kernelspec or {}).language or "python"
	return M.normalize(value)
end

local function metadata_language(metadata)
	metadata = metadata or {}
	local nvjup = type(metadata.nvjup) == "table" and metadata.nvjup or {}
	local vscode = type(metadata.vscode) == "table" and metadata.vscode or {}
	return metadata.language or metadata.languageId or nvjup.language or vscode.languageId
end

function M.for_cell(state, cell)
	if cell.cell_type == "markdown" then
		return "markdown"
	end
	if cell.cell_type ~= "code" then
		return "text"
	end
	return M.normalize(metadata_language(cell.raw.metadata) or M.primary(state))
end

function M.extension(lang)
	return extensions[M.normalize(lang)] or M.normalize(lang)
end

function M.comment(lang)
	return comments[M.normalize(lang)] or "#"
end

return M
