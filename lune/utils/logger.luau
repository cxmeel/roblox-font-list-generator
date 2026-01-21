--!strict
local process = require("@lune/process")

local colors = require("./colors")

local args = table.concat(process.args, " ")
local noop = function() end :: any

local isVerbose = args:find("%-%-verbose") or args:find("%-v+")
local verbosity = isVerbose and 1 or 0

if args:find("%-v+") then
	local level = #(args:match("%-v+") :: string) - 1
	verbosity = math.min(level, 2)
end

local function createLogger(prefix: string, verbosityLevel: number?)
	local level = verbosityLevel or 0

	if not isVerbose or verbosity < level then
		return noop
	end

	return function(...)
		print(prefix, ...)
	end
end

return {
	log = print,
	error = error,
	warn = createLogger(colors.bold.yellow.inverse(" WARN "), 1),
	info = createLogger(colors.bold.blue.inverse(" INFO "), 1),
	debug = createLogger(colors.bold.green.inverse(" DEBUG "), 2),
}
