--!strict
--[[
	Lays out a column of font samples and renders it as an SVG.

	Each font gets a block: the family name in a small generic sans-serif, and
	the preview text below it rendered in the font itself. Blocks are ordered
	by family name, whatever order the caller passed them in.

	GitHub serves README images through Camo and renders them as `<img>`, which
	is a sandbox with no access to external or embedded webfonts. So the preview
	text cannot be `<text>` -- every glyph is emitted as an outline `<path>`
	instead, defined once per unique glyph and placed with `<use>`.

	A composition holds the geometry, and can be rendered at any fill colour, so
	light and dark variants come out identical apart from that colour.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

local logger = require("../utils/logger")
local sfnt = require("../utils/sfnt")
local svg = require("../utils/svg")

export type PreviewFont = {
	name: string,
	filePath: string,
}

export type PreviewOptions = {
	text: string,
	--- Upper bound on the rendered width, in SVG user units. The sample size
	--- shrinks to fit rather than the text being clipped or wrapped.
	maxWidth: number,
}

export type Composition = {
	width: number,
	height: number,
	definitions: string,
	content: string,
	title: string,
	--- How many fonts made it into the composition.
	count: number,
}

type ShapedFont = {
	name: string,
	font: sfnt.Font,
	glyphs: { sfnt.Glyph },
	--- Advance width of the preview text, in ems.
	emWidth: number,
}

-- Layout constants, in SVG user units
local PADDING = 24
local LABEL_SIZE = 13
local LABEL_GAP = 10
local BLOCK_GAP = 22
local MAX_SAMPLE_SIZE = 32
local LABEL_FONT_FAMILY = "-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif"
local LABEL_OPACITY = "0.55"

--- Orders fonts by name so a preview is scannable, with the file path as a
--- tiebreak because `table.sort` is not stable and two families can share a
--- name (a font hosted both locally and in the cloud, for instance).
local function byName(a: PreviewFont, b: PreviewFont): boolean
	local aName, bName = a.name:lower(), b.name:lower()

	if aName == bName then
		return a.filePath < b.filePath
	end

	return aName < bName
end

--- Parses each font file and shapes the preview text through it.
local function shapeFonts(previewFonts: { PreviewFont }, text: string): { ShapedFont }
	local shaped: { ShapedFont } = {}

	for _, previewFont in previewFonts do
		local parsedFont = sfnt.parse(fs.readFile(previewFont.filePath))

		if not parsedFont then
			logger.error(`Could not parse font file: {previewFont.filePath}`)
			process.exit(1)
			continue
		end

		local glyphs = parsedFont:shape(text)
		local advance = 0

		for _, glyph in glyphs do
			advance += glyph.advance
		end

		logger.debug(`> Shaped {#glyphs} glyphs for {previewFont.name} from {previewFont.filePath}`)

		table.insert(shaped, {
			name = previewFont.name,
			font = parsedFont,
			glyphs = glyphs,
			emWidth = advance / parsedFont.unitsPerEm,
		})
	end

	return shaped
end

--- Lays the samples out into reusable geometry, with no colour applied yet.
local function compose(previewFonts: { PreviewFont }, options: PreviewOptions): Composition
	local orderedFonts = table.clone(previewFonts)
	table.sort(orderedFonts, byName)

	local shapedFonts = shapeFonts(orderedFonts, options.text)

	if #shapedFonts == 0 then
		logger.error("No fonts left to preview")
		process.exit(1)
	end

	-- One sample size shared by every font keeps the comparison fair; shrink it
	-- if the widest line would otherwise overflow the target width
	local widestEm = 0

	for _, shaped in shapedFonts do
		widestEm = math.max(widestEm, shaped.emWidth)
	end

	local sampleSize = MAX_SAMPLE_SIZE

	if widestEm > 0 then
		sampleSize = math.min(MAX_SAMPLE_SIZE, (options.maxWidth - PADDING * 2) / widestEm)
	end

	local glyphDefinitions: { string } = {}
	local definedGlyphs: { [string]: boolean } = {}
	local bodyElements: { string } = {}

	local cursorY = PADDING

	for index, shaped in shapedFonts do
		local font = shaped.font
		local scale = sampleSize / font.unitsPerEm

		local labelBaseline = cursorY + LABEL_SIZE
		local sampleBaseline = labelBaseline + LABEL_GAP + font.ascender * scale

		table.insert(
			bodyElements,
			`<text x="{PADDING}" y="{svg.number(labelBaseline)}" font-family="{LABEL_FONT_FAMILY}"`
				.. ` font-size="{LABEL_SIZE}" opacity="{LABEL_OPACITY}">{svg.escape(shaped.name)}</text>`
		)

		local placements: { string } = {}
		local penX = 0

		for _, glyph in shaped.glyphs do
			-- Whitespace and unmapped glyphs still advance the pen, but draw nothing
			if glyph.pathData ~= "" then
				local glyphKey = `f{index}g{glyph.glyphId}`

				if not definedGlyphs[glyphKey] then
					definedGlyphs[glyphKey] = true
					table.insert(glyphDefinitions, `<path id="{glyphKey}" d="{glyph.pathData}"/>`)
				end

				table.insert(placements, `<use href="#{glyphKey}" x="{svg.number(penX)}"/>`)
			end

			penX += glyph.advance
		end

		-- Font units are Y up and SVG is Y down, hence the negative vertical scale
		table.insert(
			bodyElements,
			`<g transform="translate({PADDING} {svg.number(sampleBaseline)})`
				.. ` scale({svg.number(scale)} -{svg.number(scale)})">{table.concat(placements)}</g>`
		)

		cursorY = sampleBaseline - font.descender * scale + BLOCK_GAP
	end

	return {
		width = math.ceil(math.min(options.maxWidth, widestEm * sampleSize + PADDING * 2)),
		height = math.ceil(cursorY - BLOCK_GAP + PADDING),
		definitions = table.concat(glyphDefinitions),
		content = table.concat(bodyElements),
		title = `Font preview: {options.text}`,
		count = #shapedFonts,
	}
end

--- Renders a composition with every glyph and label in a single colour.
local function render(composition: Composition, fill: string): string
	return svg.document({
		width = composition.width,
		height = composition.height,
		title = composition.title,
		definitions = composition.definitions,
		content = `<g fill="{fill}">{composition.content}</g>`,
	})
end

return {
	compose = compose,
	render = render,
}
