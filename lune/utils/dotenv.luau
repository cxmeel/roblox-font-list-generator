--!strict
--[[
	Minimal `.env` reader, for keeping credentials off the command line.

	Real environment variables win over the file, so a shell export or a CI
	secret overrides whatever is sitting in `.env` locally. Nothing read here is
	written back into the environment.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

local ENV_FILE_PATH = ".env"

local fileValues: { [string]: string }? = nil

local function parse(contents: string): { [string]: string }
	local values: { [string]: string } = {}

	for _, rawLine in contents:split("\n") do
		local line = rawLine:gsub("\r$", "")

		-- Blank lines and comments
		if line:match("^%s*$") or line:match("^%s*#") then
			continue
		end

		local assignment = line:gsub("^%s*export%s+", "")
		local key, value = assignment:match("^%s*([%a_][%w_]*)%s*=%s*(.-)%s*$")

		if not key or not value then
			continue
		end

		-- Strip one layer of matching quotes, if present
		local unquoted = value:match('^"(.*)"$') or value:match("^'(.*)'$") or value
		values[key] = unquoted
	end

	return values
end

--- Reads a variable from the environment, falling back to `.env` in the
--- working directory. Returns nil when it is unset or empty.
local function get(name: string): string?
	local fromEnvironment = process.env[name]

	if fromEnvironment and fromEnvironment ~= "" then
		return fromEnvironment
	end

	if not fileValues then
		fileValues = if fs.isFile(ENV_FILE_PATH) then parse(fs.readFile(ENV_FILE_PATH)) else {}
	end

	local value = (fileValues :: { [string]: string })[name]

	if value == "" then
		return nil
	end

	return value
end

return {
	get = get,
	parse = parse,
	ENV_FILE_PATH = ENV_FILE_PATH,
}
