local M = {}

function M.read_file(path)
	local file, err = io.open(path, "rb")
	if not file then
		return nil, err
	end
	local content = file:read("*a")
	file:close()
	return content
end

function M.atomic_write(path, content)
	local temporary = string.format("%s.nvjup.%d.tmp", path, vim.uv.hrtime())
	local file, err = io.open(temporary, "wb")
	if not file then
		return nil, err
	end

	local ok, write_err = file:write(content)
	if not ok then
		file:close()
		os.remove(temporary)
		return nil, write_err
	end

	file:flush()
	file:close()

	local renamed, rename_err = os.rename(temporary, path)
	if not renamed then
		os.remove(temporary)
		return nil, rename_err
	end
	return true
end

function M.source_to_string(source)
	if type(source) == "string" then
		return source
	end
	if type(source) == "table" then
		return table.concat(source)
	end
	return ""
end

function M.source_to_lines(source)
	local text = M.source_to_string(source)
	if text == "" then
		return { "" }
	end
	return vim.split(text, "\n", { plain = true, trimempty = false })
end

function M.lines_to_source(lines)
	if #lines == 1 and lines[1] == "" then
		return ""
	end
	return table.concat(lines, "\n")
end

function M.new_cell_id(existing)
	existing = existing or {}
	for _ = 1, 20 do
		local seed =
			table.concat({ tostring(vim.uv.hrtime()), tostring(math.random()), tostring(vim.fn.getpid()) }, ":")
		local candidate = vim.fn.sha256(seed):sub(1, 12)
		if not existing[candidate] then
			return candidate
		end
	end
	error("failed to generate a unique cell id")
end

function M.display_width(text)
	return vim.fn.strdisplaywidth(text)
end

function M.fit_border(prefix, width, fill, suffix)
	suffix = suffix or ""
	local remaining = math.max(1, width - M.display_width(prefix) - M.display_width(suffix))
	return prefix .. string.rep(fill or "─", remaining) .. suffix
end

return M
