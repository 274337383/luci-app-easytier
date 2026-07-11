local M = {}

local function has_control(value)
	return type(value) ~= "string" or value:find("[%z\1-\31\127]") ~= nil
end

function M.valid_ifname(value)
	return not has_control(value)
		and #value >= 1
		and #value <= 15
		and value:match("^[%w_.:%-]+$") ~= nil
end

function M.valid_version(value)
	return not has_control(value)
		and #value <= 64
		and value:match("^v%d+%.%d+%.%d+[%w.%-]*$") ~= nil
end

function M.valid_proxy(value)
	if value == "" then
		return true
	end

	return not has_control(value)
		and #value <= 256
		and value:match("^https://[%w%.:%-]+[%w%._~:/%?#%[%]@!$&'()*+,;=%-]*/$") ~= nil
end

function M.binary_path(value, kind)
	local names = {
		core = "easytier-core",
		web = "easytier-web"
	}
	local name = names[kind]

	if not name or has_control(value) or value:find("..", 1, true) then
		return nil
	end

	for _, root in ipairs({"/usr/bin", "/tmp"}) do
		if value == root .. "/" .. name then
			return value
		end
	end

	return nil
end

function M.cli_path(core_path)
	local path = M.binary_path(core_path, "core")
	return path and path:gsub("easytier%-core$", "easytier-cli") or nil
end

function M.path_under_root(root, value, allow_missing)
	local fs = require "nixio.fs"

	if has_control(root) or has_control(value) or value:find("..", 1, true) then
		return nil, "invalid path"
	end

	local root_real = fs.realpath(root)
	if not root_real or value:sub(1, #root_real + 1) ~= root_real .. "/" then
		return nil, "path is outside the allowed directory"
	end

	local name = fs.basename(value)
	if name == "" or name == "." or name == ".." or name:match("^[%w_.%-]+$") == nil then
		return nil, "invalid filename"
	end

	local candidate = root_real .. "/" .. name
	if candidate ~= value then
		return nil, "nested or non-canonical paths are not allowed"
	end

	local parent_real = fs.realpath(fs.dirname(candidate))
	if parent_real ~= root_real then
		return nil, "path parent is outside the allowed directory"
	end

	local st = fs.lstat(candidate)
	if st then
		if st.type == "lnk" then
			return nil, "symbolic links are not allowed"
		elseif st.type ~= "reg" then
			return nil, "path is not a regular file"
		end
	elseif not allow_missing then
		return nil, "file does not exist"
	end

	return candidate
end

function M.database_path(value, allow_missing)
	return M.path_under_root("/etc/easytier", value, allow_missing)
end

return M
