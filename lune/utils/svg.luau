--!strict
--[[
	Small helpers for writing SVG markup by hand.
]]

export type DocumentOptions = {
	width: number,
	height: number,
	title: string?,
	--- Markup for the `<defs>` block, omitted when empty.
	definitions: string?,
	content: string,
}

local XML_ESCAPES = {
	["&"] = "&amp;",
	["<"] = "&lt;",
	[">"] = "&gt;",
	['"'] = "&quot;",
	["'"] = "&apos;",
}

local function escape(value: string): string
	return (value:gsub("[&<>\"']", XML_ESCAPES))
end

--- Formats a coordinate with just enough precision, without trailing zeroes.
local function number(value: number): string
	if value == math.round(value) then
		return string.format("%d", value)
	end

	return (string.format("%.3f", value):gsub("0+$", ""))
end

--- Wraps content in a root `<svg>` element sized in user units.
local function document(options: DocumentOptions): string
	local width, height = number(options.width), number(options.height)

	local parts = {
		`<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}"`,
		` viewBox="0 0 {width} {height}" role="img">`,
	}

	if options.title then
		table.insert(parts, `<title>{escape(options.title)}</title>`)
	end

	if options.definitions and options.definitions ~= "" then
		table.insert(parts, `<defs>{options.definitions}</defs>`)
	end

	table.insert(parts, options.content)
	table.insert(parts, "</svg>")

	return table.concat(parts)
end

return {
	escape = escape,
	number = number,
	document = document,
}
