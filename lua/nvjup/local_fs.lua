local M = {}
local uv = vim.uv

local function absolute(path)
	path = vim.fs.normalize(path)
	if path:match("^/") or path:match("^%a:[/\\]") then
		return path
	end
	return vim.fs.normalize(vim.fs.joinpath(assert(uv.cwd()), path))
end

local function lstat(path)
	local stat, err = uv.fs_lstat(path)
	if not stat then
		return nil, err
	end
	return stat
end

local function remove(path)
	local stat, err = lstat(path)
	if not stat then
		return nil, err
	end
	if stat.type == "directory" then
		local scan, scan_err = uv.fs_scandir(path)
		if not scan then
			return nil, scan_err
		end
		while true do
			local name = uv.fs_scandir_next(scan)
			if not name then
				break
			end
			local ok, child_err = remove(vim.fs.joinpath(path, name))
			if not ok then
				return nil, child_err
			end
		end
		return uv.fs_rmdir(path)
	end
	return uv.fs_unlink(path)
end

local function copy(source, target, budget)
	budget.count = budget.count + 1
	if budget.count > budget.max_entries then
		return nil, string.format("copy exceeds %d entries", budget.max_entries)
	end
	local stat, err = lstat(source)
	if not stat then
		return nil, err
	end
	if uv.fs_lstat(target) then
		return nil, "target already exists: " .. target
	end
	if stat.type == "directory" then
		if target:sub(1, #source + 1) == source .. "/" then
			return nil, "cannot copy a directory into itself"
		end
		local ok, mkdir_err = uv.fs_mkdir(target, stat.mode or 493)
		if not ok then
			return nil, mkdir_err
		end
		local scan, scan_err = uv.fs_scandir(source)
		if not scan then
			remove(target)
			return nil, scan_err
		end
		while true do
			local name = uv.fs_scandir_next(scan)
			if not name then
				break
			end
			local copied, child_err = copy(vim.fs.joinpath(source, name), vim.fs.joinpath(target, name), budget)
			if not copied then
				remove(target)
				return nil, child_err
			end
		end
		return true
	end
	if stat.type == "link" then
		local link, link_err = uv.fs_readlink(source)
		if not link then
			return nil, link_err
		end
		return uv.fs_symlink(link, target)
	end
	if stat.type ~= "file" then
		return nil, "unsupported local filesystem entry: " .. stat.type
	end
	return uv.fs_copyfile(source, target)
end

function M.absolute(path)
	return absolute(path)
end

function M.list(path, show_hidden)
	path = absolute(path)
	local scan, err = uv.fs_scandir(path)
	if not scan then
		return nil, err
	end
	local entries = {}
	while true do
		local name, entry_type = uv.fs_scandir_next(scan)
		if not name then
			break
		end
		if show_hidden or name:sub(1, 1) ~= "." then
			local child = vim.fs.joinpath(path, name)
			local stat = uv.fs_lstat(child) or {}
			table.insert(entries, {
				name = name,
				path = child,
				type = entry_type or stat.type or "file",
				size = stat.size,
				mtime = stat.mtime and stat.mtime.sec or nil,
				writable = vim.fn.filewritable(child) ~= 0,
				side = "local",
			})
		end
	end
	table.sort(entries, function(left, right)
		local left_dir = left.type == "directory"
		local right_dir = right.type == "directory"
		if left_dir ~= right_dir then
			return left_dir
		end
		local folded_left, folded_right = left.name:lower(), right.name:lower()
		return folded_left == folded_right and left.name < right.name or folded_left < folded_right
	end)
	return entries
end

function M.stat(path)
	path = absolute(path)
	local stat, err = lstat(path)
	if not stat then
		return nil, err
	end
	return {
		name = vim.fs.basename(path),
		path = path,
		type = stat.type,
		size = stat.size,
		mtime = stat.mtime and stat.mtime.sec or nil,
		mode = stat.mode,
		writable = vim.fn.filewritable(path) ~= 0,
		side = "local",
	}
end

function M.mkdir(path)
	path = absolute(path)
	if uv.fs_lstat(path) then
		return nil, "target already exists: " .. path
	end
	local ok = vim.fn.mkdir(path, "p", 493)
	return ok == 1 and true or nil, ok == 1 and nil or "failed to create directory"
end

function M.touch(path)
	path = absolute(path)
	local handle, err = uv.fs_open(path, "wx", 420)
	if not handle then
		return nil, err
	end
	uv.fs_close(handle)
	return true
end

function M.rename(source, target)
	return uv.fs_rename(absolute(source), absolute(target))
end

function M.delete(path)
	return remove(absolute(path))
end

function M.copy(source, target, max_entries)
	return copy(absolute(source), absolute(target), { count = 0, max_entries = max_entries or 10000 })
end

function M.move(source, target, max_entries)
	source, target = absolute(source), absolute(target)
	local ok = uv.fs_rename(source, target)
	if ok then
		return true
	end
	local copied, err = copy(source, target, { count = 0, max_entries = max_entries or 10000 })
	if not copied then
		return nil, err
	end
	return remove(source)
end

function M.read(path, max_bytes)
	path = absolute(path)
	local stat, err = uv.fs_stat(path)
	if not stat then
		return nil, err
	end
	if stat.type ~= "file" then
		return nil, "not a regular file: " .. path
	end
	if stat.size > max_bytes then
		return nil, string.format("file exceeds %d bytes", max_bytes)
	end
	local handle, open_err = uv.fs_open(path, "r", 438)
	if not handle then
		return nil, open_err
	end
	local chunks = {}
	local offset = 0
	while offset < stat.size do
		local chunk, read_err = uv.fs_read(handle, math.min(1024 * 1024, stat.size - offset), offset)
		if not chunk then
			uv.fs_close(handle)
			return nil, read_err
		end
		if chunk == "" then
			break
		end
		table.insert(chunks, chunk)
		offset = offset + #chunk
	end
	uv.fs_close(handle)
	if offset ~= stat.size then
		return nil, string.format("short read: expected %d bytes, received %d", stat.size, offset)
	end
	return table.concat(chunks)
end

function M.write(path, content)
	path = absolute(path)
	local parent = vim.fs.dirname(path)
	if vim.fn.mkdir(parent, "p", 493) ~= 1 and not uv.fs_stat(parent) then
		return nil, "failed to create parent directory: " .. parent
	end
	local handle, err = uv.fs_open(path, "w", 420)
	if not handle then
		return nil, err
	end
	local offset = 0
	while offset < #content do
		local chunk = content:sub(offset + 1, math.min(#content, offset + 1024 * 1024))
		local written, write_err = uv.fs_write(handle, chunk, offset)
		if not written or written <= 0 then
			uv.fs_close(handle)
			return nil, write_err or "short write"
		end
		offset = offset + written
	end
	uv.fs_close(handle)
	return true
end

local ASYNC_BATCH_SIZE = 32

local function continue_batched(work, callback)
	work.steps = (work.steps or 0) + 1
	if work.steps % ASYNC_BATCH_SIZE == 0 then
		vim.schedule(callback)
	else
		callback()
	end
end

local function async_remove(path, callback, work)
	work = work or { steps = 0 }
	uv.fs_lstat(path, function(stat_err, stat)
		if stat_err or not stat then
			callback(nil, stat_err or "path does not exist")
			return
		end
		if stat.type ~= "directory" then
			uv.fs_unlink(path, function(err)
				callback(not err or nil, err)
			end)
			return
		end
		uv.fs_scandir(path, function(scan_err, scan)
			if scan_err or not scan then
				callback(nil, scan_err)
				return
			end
			local function next_child(ok, err)
				if not ok then
					callback(nil, err)
					return
				end
				local name = uv.fs_scandir_next(scan)
				if not name then
					uv.fs_rmdir(path, function(remove_err)
						callback(not remove_err or nil, remove_err)
					end)
					return
				end
				continue_batched(work, function()
					async_remove(vim.fs.joinpath(path, name), next_child, work)
				end)
			end
			next_child(true)
		end)
	end)
end

local function async_copy(source, target, budget, callback)
	budget.count = budget.count + 1
	if budget.count > budget.max_entries then
		callback(nil, string.format("copy exceeds %d entries", budget.max_entries))
		return
	end
	uv.fs_lstat(source, function(stat_err, stat)
		if stat_err or not stat then
			callback(nil, stat_err)
			return
		end
		uv.fs_lstat(target, function(_, existing)
			if existing then
				callback(nil, "target already exists: " .. target)
				return
			end
			if stat.type == "directory" then
				if target:sub(1, #source + 1) == source .. "/" then
					callback(nil, "cannot copy a directory into itself")
					return
				end
				uv.fs_mkdir(target, stat.mode or 493, function(mkdir_err)
					if mkdir_err then
						callback(nil, mkdir_err)
						return
					end
					uv.fs_scandir(source, function(scan_err, scan)
						if scan_err or not scan then
							async_remove(target, function()
								callback(nil, scan_err)
							end, budget.work)
							return
						end
						local function next_child(ok, err)
							if not ok then
								async_remove(target, function()
									callback(nil, err)
								end, budget.work)
								return
							end
							local name = uv.fs_scandir_next(scan)
							if not name then
								callback(true)
								return
							end
							if budget.count >= budget.max_entries then
								async_remove(target, function()
									callback(nil, string.format("copy exceeds %d entries", budget.max_entries))
								end, budget.work)
								return
							end
							continue_batched(budget.work, function()
								async_copy(
									vim.fs.joinpath(source, name),
									vim.fs.joinpath(target, name),
									budget,
									next_child
								)
							end)
						end
						next_child(true)
					end)
				end)
			elseif stat.type == "link" then
				uv.fs_readlink(source, function(link_err, link)
					if link_err then
						callback(nil, link_err)
						return
					end
					uv.fs_symlink(link, target, function(err)
						callback(not err or nil, err)
					end)
				end)
			elseif stat.type == "file" then
				uv.fs_copyfile(source, target, function(err)
					callback(not err or nil, err)
				end)
			else
				callback(nil, "unsupported local filesystem entry: " .. stat.type)
			end
		end)
	end)
end

function M.copy_async(source, target, max_entries, callback)
	async_copy(
		absolute(source),
		absolute(target),
		{ count = 0, max_entries = max_entries or 10000, work = { steps = 0 } },
		vim.schedule_wrap(callback)
	)
end

function M.move_async(source, target, max_entries, callback)
	source, target = absolute(source), absolute(target)
	uv.fs_rename(source, target, function(err)
		if not err then
			vim.schedule(function()
				callback(true)
			end)
			return
		end
		async_copy(
			source,
			target,
			{ count = 0, max_entries = max_entries or 10000, work = { steps = 0 } },
			function(ok, copy_err)
				if not ok then
					vim.schedule(function()
						callback(nil, copy_err)
					end)
					return
				end
				async_remove(source, vim.schedule_wrap(callback))
			end
		)
	end)
end

function M.delete_async(path, callback)
	async_remove(absolute(path), vim.schedule_wrap(callback))
end

M._async_batch_size = ASYNC_BATCH_SIZE

return M
