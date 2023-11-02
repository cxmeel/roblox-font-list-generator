--!strict
local fs = require("@lune/fs")

local function normalizePath(path: string)
	local output = path:gsub("\\", "/")
	return output
end

local function getPathSegments(path: string)
	local segments = {}

	for _, segment in normalizePath(path):split("/") do
		table.insert(segments, segment)
	end

	return segments
end

local function writeFile(path: string, contents: string)
	local segments = getPathSegments(path)

	if #segments < 2 then
		fs.writeFile(path, contents)
		return path
	end

	for index = 1, #segments - 1 do
		local currentPath = table.concat(segments, "/", 1, index)

		if not fs.isDir(currentPath) then
			fs.writeDir(currentPath)
		end
	end

	fs.writeFile(path, contents)
	return path
end

local function unlink(...: string)
	for _, path in { ... } do
		if fs.isDir(path) then
			fs.removeDir(path)
		elseif fs.isFile(path) then
			fs.removeFile(path)
		end
	end
end

return {
	normalizePath = normalizePath,
	writeFile = writeFile,
	unlink = unlink,
}
