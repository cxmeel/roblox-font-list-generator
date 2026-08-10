--!strict
--[[
	Wrapper around the resvg command line renderer.

	resvg is optional. Previews are SVG by default, and rasterising only matters
	where SVGs will not render at all -- GitHub release notes being the case
	that prompted this. There is no prebuilt Windows binary in current releases,
	but `cargo install resvg` builds one.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

export type RenderOptions = {
	--- Path to the resvg binary. Defaults to whatever is on PATH.
	command: string?,
	--- Multiplies the SVG's own dimensions, so a preview stays sharp on a high
	--- density screen when displayed at its nominal width.
	scale: number?,
	--- Font to use for anything the SVG left as text, and the family name
	--- inside it. Without one, resvg falls back to the fonts installed on the
	--- machine, which a CI runner may not have.
	fontFile: string?,
	fontFamily: string?,
}

local DEFAULT_COMMAND = "resvg"

--- True when the given resvg command can actually be run.
local function isAvailable(command: string?): boolean
	local ok, result = pcall(process.exec, command or DEFAULT_COMMAND, { "--version" })

	return ok and result.ok
end

--- Renders an SVG file to PNG, returning false and a reason on failure.
local function render(svgPath: string, pngPath: string, options: RenderOptions?): (boolean, string?)
	local renderOptions: RenderOptions = options or {}
	local command = renderOptions.command or DEFAULT_COMMAND

	local commandArgs: { string } = {}

	if renderOptions.fontFile and renderOptions.fontFamily and fs.isFile(renderOptions.fontFile) then
		-- The labels ask for a font stack ending in sans-serif, and
		-- --sans-serif-family is the option that generic resolves through.
		-- --font-family only applies when no font-family is present at all, so
		-- on its own it renders every glyph and silently drops every label.
		table.insert(commandArgs, "--skip-system-fonts")
		table.insert(commandArgs, "--use-font-file")
		table.insert(commandArgs, renderOptions.fontFile)
		table.insert(commandArgs, "--font-family")
		table.insert(commandArgs, renderOptions.fontFamily)
		table.insert(commandArgs, "--sans-serif-family")
		table.insert(commandArgs, renderOptions.fontFamily)
	end

	if renderOptions.scale then
		table.insert(commandArgs, "--zoom")
		table.insert(commandArgs, tostring(renderOptions.scale))
	end

	table.insert(commandArgs, svgPath)
	table.insert(commandArgs, pngPath)

	local ok, result = pcall(process.exec, command, commandArgs)

	if not ok then
		return false, `could not run "{command}": {result}`
	end

	if not result.ok then
		return false, `"{command}" exited with code {result.code}: {result.stderr}`
	end

	return true
end

return {
	isAvailable = isAvailable,
	render = render,
	DEFAULT_COMMAND = DEFAULT_COMMAND,
}
