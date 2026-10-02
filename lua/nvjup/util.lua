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
	local uv = vim.uv
	local stat = uv.fs_lstat(path)
	if stat and stat.type == "link" then
		local resolved, err = uv.fs_realpath(path)
		if not resolved then
			return nil, err
		end
		path = resolved
		stat = uv.fs_stat(path)
	end
	-- mkstemp creates a private, exclusive file in the destination directory.
	local fd, temporary = uv.fs_mkstemp(path .. ".nvjup.XXXXXX")
	if not fd then
		return nil, temporary
	end
	local function fail(err)
		uv.fs_close(fd)
		uv.fs_unlink(temporary)
		return nil, err
	end
	local offset = 0
	while offset < #content do
		local written, err = uv.fs_write(fd, content:sub(offset + 1), offset)
		if not written or written == 0 then
			return fail(err or "failed to write notebook")
		end
		offset = offset + written
	end
	if stat then
		local ok, err = uv.fs_fchmod(fd, bit.band(stat.mode, 511))
		if not ok then
			return fail(err)
		end
	end
	local closed, close_err = uv.fs_close(fd)
	if not closed then
		uv.fs_unlink(temporary)
		return nil, close_err
	end
	local renamed, rename_err = uv.fs_rename(temporary, path)
	if not renamed then
		uv.fs_unlink(temporary)
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
