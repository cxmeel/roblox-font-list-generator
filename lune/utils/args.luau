--!strict
--[[
	Reads flags out of `process.args`.

	Flags are `--name value` pairs; nothing in this project uses a combined
	`--name=value` form, so neither does this.
]]

local process = require("@lune/process")

--- True when the flag was passed at all, regardless of its value. Useful when
--- an absent flag and an explicit one should behave differently.
local function has(name: string): boolean
	return table.find(process.args, name) ~= nil
end

--- The value following `name`, or nil when the flag is absent.
local function value(name: string): string?
	local position = table.find(process.args, name)

	if not position then
		return nil
	end

	return process.args[position + 1]
end

local function valueOr(name: string, default: string): string
	return value(name) or default
end

--- Reads a flag whose value is optional, returning whether it was passed at all
--- and the value if it carried one. Anything starting with a dash is taken to
--- be the next flag rather than this one's value, so `--name` on its own reads
--- as present with no value.
local function optionalValue(name: string): (boolean, string?)
	local position = table.find(process.args, name)

	if not position then
		return false, nil
	end

	local candidate = process.args[position + 1]

	if not candidate or candidate:sub(1, 1) == "-" then
		return true, nil
	end

	return true, candidate
end

local function numberOr(name: string, default: number): number
	local raw = value(name)

	return (raw and tonumber(raw)) or default
end

return {
	has = has,
	value = value,
	valueOr = valueOr,
	optionalValue = optionalValue,
	numberOr = numberOr,
}
