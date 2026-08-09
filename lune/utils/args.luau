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

local function numberOr(name: string, default: number): number
	local raw = value(name)

	return (raw and tonumber(raw)) or default
end

return {
	has = has,
	value = value,
	valueOr = valueOr,
	numberOr = numberOr,
}
