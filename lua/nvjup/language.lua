local M = {}

local aliases = {
	bash = "bash",
	c = "c",
	cpp = "cpp",
	csharp = "csharp",
	cs = "csharp",
	css = "css",
	cxx = "cpp",
	go = "go",
	html = "html",
	java = "java",
	javascript = "javascript",
	js = "javascript",
	julia = "julia",
	kotlin = "kotlin",
	lua = "lua",
	markdown = "markdown",
	perl = "perl",
	python = "python",
	python3 = "python",
	r = "r",
	raw = "text",
	ruby = "ruby",
	rust = "rust",
	sh = "bash",
	shell = "bash",
	sql = "sql",
	typescript = "typescript",
	ts = "typescript",
	zsh = "bash",
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
	bash = { "#", "" },
	c = { "//", "" },
	cpp = { "//", "" },
	csharp = { "//", "" },
	css = { "/*", "*/" },
	go = { "//", "" },
	html = { "<!--", "-->" },
	java = { "//", "" },
	javascript = { "//", "" },
	julia = { "#", "" },
	kotlin = { "//", "" },
	lua = { "--", "" },
	markdown = { "<!--", "-->" },
	perl = { "#", "" },
	python = { "#", "" },
	r = { "#", "" },
	ruby = { "#", "" },
	rust = { "//", "" },
	sql = { "--", "" },
	text = { "#", "" },
	typescript = { "//", "" },
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

function M.comment_parts(lang)
	local parts = comments[M.normalize(lang)] or { "#", "" }
	return parts[1], parts[2]
end

function M.comment(lang)
	local left = M.comment_parts(lang)
	return left
end

function M.commentstring(lang)
	local left, right = M.comment_parts(lang)
	return right ~= "" and (left .. " %s " .. right) or (left .. " %s")
end

return M
