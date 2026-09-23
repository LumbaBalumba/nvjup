local config = require("nvjup.config")

local M = {}

local function strip_ansi(value)
	return value:gsub("\27%[[0-?]*[ -/]*[@-~]", "")
end

local function split_text(value)
	if type(value) == "table" then
		value = table.concat(value)
	end
	if type(value) ~= "string" then
		value = vim.inspect(value)
	end
	return vim.split(strip_ansi(value), "\n", { plain = true, trimempty = true })
end

local function strip_html(value)
	local text = value:gsub("<br%s*/?>", "\n"):gsub("</tr>", "\n"):gsub("</t[dh]>", "\t")
	text = text:gsub("<[^>]+>", "")
	text = text:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&"):gsub("&nbsp;", " ")
	return text
end

local function dimensions(metadata, mime)
	local values = type(metadata) == "table" and metadata[mime] or nil
	if type(values) ~= "table" then
		return ""
	end
	if values.width and values.height then
		return string.format(" %sx%s", values.width, values.height)
	end
	if values.width then
		return string.format(" width=%s", values.width)
	end
	if values.height then
		return string.format(" height=%s", values.height)
	end
	return ""
end

local function render_bundle(data, metadata)
	if type(data) ~= "table" then
		return { "[invalid MIME bundle]" }, "error"
	end

	if data["application/vnd.plotly.v1+json"] then
		local lines = { "[Plotly interactive output · renderer planned for v0.2]" }
		vim.list_extend(lines, split_text(data["text/plain"] or "Plotly figure"))
		return lines, "interactive"
	end

	if data["application/vnd.bokehjs_exec.v0+json"] or data["application/vnd.bokehjs_load.v0+json"] then
		local lines = { "[Bokeh interactive output · renderer planned for v0.3]" }
		vim.list_extend(lines, split_text(data["text/plain"] or "Bokeh document"))
		return lines, "interactive"
	end

	for _, mime in ipairs({ "image/png", "image/jpeg", "image/svg+xml", "application/pdf" }) do
		if data[mime] then
			local lines = {
				string.format(
					"[%s%s · terminal image renderer planned for Stage 4]",
					mime,
					dimensions(metadata, mime)
				),
			}
			if data["text/plain"] then
				vim.list_extend(lines, split_text(data["text/plain"]))
			end
			return lines, "image"
		end
	end

	if data["text/markdown"] then
		return split_text(data["text/markdown"]), "markdown"
	end
	if data["text/html"] then
		return split_text(strip_html(data["text/html"])), "html"
	end
	if data["text/latex"] then
		return split_text(data["text/latex"]), "latex"
	end
	if data["text/plain"] then
		return split_text(data["text/plain"]), "text"
	end

	local mime_types = vim.tbl_keys(data)
	table.sort(mime_types)
	return { "[unsupported MIME bundle: " .. table.concat(mime_types, ", ") .. "]" }, "unsupported"
end

function M.render(cell)
	local rendered = {}
	local kinds = {}

	for _, output in ipairs(cell.outputs or {}) do
		local lines
		local kind
		if output.output_type == "stream" then
			lines = split_text(output.text or "")
			kind = output.name == "stderr" and "stderr" or "stdout"
		elseif output.output_type == "error" then
			lines = output.traceback and vim.deepcopy(output.traceback)
				or { string.format("%s: %s", output.ename or "Error", output.evalue or "") }
			for index, line in ipairs(lines) do
				lines[index] = strip_ansi(line)
			end
			kind = "error"
		elseif output.output_type == "execute_result" or output.output_type == "display_data" then
			lines, kind = render_bundle(output.data, output.metadata)
		else
			lines = { "[unsupported output type: " .. tostring(output.output_type) .. "]" }
			kind = "unsupported"
		end

		for _, line in ipairs(lines) do
			table.insert(rendered, line)
			table.insert(kinds, kind)
		end
	end

	local maximum = config.options.render.max_output_lines
	if #rendered > maximum then
		local omitted = #rendered - maximum
		while #rendered > maximum do
			table.remove(rendered)
			table.remove(kinds)
		end
		table.insert(rendered, string.format("… %d more output line%s", omitted, omitted == 1 and "" or "s"))
		table.insert(kinds, "truncated")
	end

	return rendered, kinds
end

return M
