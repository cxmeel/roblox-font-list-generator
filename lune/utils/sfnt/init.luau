--!strict
--[[
	Minimal sfnt (TrueType / OpenType) reader.

	Just enough of the format to turn a string of text into positioned glyph
	outlines: the table directory, `head`, `hmtx`, `cmap`, and then either
	`glyf` or `CFF ` depending on the outline flavour. No shaping, no hinting,
	no kerning -- Latin preview text does not need any of it.
]]

-- Inside an init.luau, "./" resolves to the directory *containing* this
-- module's directory, hence the "sfnt/" prefix on these sibling requires
local cff = require("./sfnt/cff")
local cmap = require("./sfnt/cmap")
local glyf = require("./sfnt/glyf")
local reader = require("./sfnt/reader")

export type Glyph = {
	glyphId: number,
	--- Horizontal advance, in font units.
	advance: number,
	--- SVG path data in font units, Y up. Empty for whitespace.
	pathData: string,
}

export type Font = {
	--- Design units per em; every metric above is expressed in these.
	unitsPerEm: number,
	ascender: number,
	descender: number,
	lineGap: number,
	numGlyphs: number,

	--- Resolves a codepoint to a glyph id, 0 when the font has no mapping.
	glyphIdFor: (self: Font, codepoint: number) -> number,
	--- Decodes a glyph, memoised per glyph id.
	glyph: (self: Font, glyphId: number) -> Glyph,
	--- Splits UTF-8 text into glyphs, in order.
	shape: (self: Font, text: string) -> { Glyph },
	--- Total advance width of `text`, in font units.
	measure: (self: Font, text: string) -> number,
}

type FontInternal = Font & {
	data: string,
	characterMap: cmap.CharacterMap?,
	advances: { number },
	glyfContext: glyf.Context?,
	cffContext: cff.Context?,
	cache: { [number]: Glyph },
}

local TAG_TRUETYPE_COLLECTION = "ttcf"

local Font = {}
local FontMeta = { __index = Font }

function Font.glyphIdFor(self: Font, codepoint: number): number
	local font = self :: FontInternal

	if not font.characterMap then
		return 0
	end

	return cmap.lookup(font.characterMap, font.data, codepoint)
end

function Font.glyph(self: Font, glyphId: number): Glyph
	local font = self :: FontInternal
	local cached = font.cache[glyphId]

	if cached then
		return cached
	end

	local pathData = ""

	if font.cffContext then
		pathData = cff.buildPath(font.cffContext, glyphId)
	elseif font.glyfContext then
		pathData = glyf.buildPath(font.glyfContext, glyphId)
	end

	-- `hmtx` only stores an advance for the first `numberOfHMetrics` glyphs;
	-- everything after that reuses the final advance (monospaced tails)
	local advance = font.advances[glyphId + 1] or font.advances[#font.advances] or 0

	local result: Glyph = {
		glyphId = glyphId,
		advance = advance,
		pathData = pathData,
	}

	font.cache[glyphId] = result
	return result
end

function Font.shape(self: Font, text: string): { Glyph }
	local glyphs: { Glyph } = {}

	for _, codepoint in utf8.codes(text) do
		glyphs[#glyphs + 1] = self:glyph(self:glyphIdFor(codepoint))
	end

	return glyphs
end

function Font.measure(self: Font, text: string): number
	local total = 0

	for _, glyph in self:shape(text) do
		total += glyph.advance
	end

	return total
end

local function readTableDirectory(data: string): { [string]: { offset: number, length: number } }
	local stream = reader.new(data)
	local version = stream:tag()

	-- Font collections point at several fonts; use the first
	if version == TAG_TRUETYPE_COLLECTION then
		stream:skip(4) -- version
		local fontCount = stream:uint32()

		if fontCount < 1 then
			return {}
		end

		stream:seek(stream:uint32())
		stream:skip(4) -- sfnt version of the nested font
	end

	local numTables = stream:uint16()
	stream:skip(6) -- searchRange, entrySelector, rangeShift

	local tables = {}

	for _ = 1, numTables do
		local tag = stream:tag()
		stream:skip(4) -- checksum

		tables[tag] = {
			offset = stream:uint32(),
			length = stream:uint32(),
		}
	end

	return tables
end

local function readAdvances(data: string, hmtxOffset: number, numberOfHMetrics: number): { number }
	local stream = reader.new(data, hmtxOffset)
	local advances = table.create(numberOfHMetrics)

	for _ = 1, numberOfHMetrics do
		table.insert(advances, stream:uint16())
		stream:skip(2) -- leftSideBearing
	end

	return advances
end

--- Parses a font file. Returns nil if the file is not a usable sfnt font.
local function parse(data: string): Font?
	if #data < 12 then
		return nil
	end

	local tables = readTableDirectory(data)
	local head = tables.head
	local maxp = tables.maxp
	local hhea = tables.hhea
	local hmtx = tables.hmtx

	if not head or not maxp then
		return nil
	end

	local headStream = reader.new(data, head.offset + 18)
	local unitsPerEm = headStream:uint16()

	headStream:seek(head.offset + 50)
	local indexToLocFormat = headStream:int16()

	local numGlyphs = reader.new(data, maxp.offset + 4):uint16()

	local ascender, descender, lineGap = unitsPerEm, 0, 0
	local numberOfHMetrics = 0

	if hhea then
		local hheaStream = reader.new(data, hhea.offset + 4)
		ascender = hheaStream:int16()
		descender = hheaStream:int16()
		lineGap = hheaStream:int16()

		hheaStream:seek(hhea.offset + 34)
		numberOfHMetrics = hheaStream:uint16()
	end

	local advances = if hmtx and numberOfHMetrics > 0
		then readAdvances(data, hmtx.offset, math.min(numberOfHMetrics, numGlyphs))
		else {}

	local glyfContext: glyf.Context? = nil
	local cffContext: cff.Context? = nil

	local cffTable = tables["CFF "]

	if cffTable then
		cffContext = cff.parse(data, cffTable.offset, numGlyphs)
	elseif tables.glyf and tables.loca then
		local loca = tables.loca

		glyfContext = {
			data = data,
			locations = glyf.parseLocations(data, loca.offset, loca.length, numGlyphs, indexToLocFormat ~= 0),
			glyphOffset = tables.glyf.offset,
		}
	end

	if not glyfContext and not cffContext then
		return nil
	end

	local font = setmetatable({
		unitsPerEm = if unitsPerEm > 0 then unitsPerEm else 1000,
		ascender = ascender,
		descender = descender,
		lineGap = lineGap,
		numGlyphs = numGlyphs,

		data = data,
		characterMap = if tables.cmap then cmap.parse(data, tables.cmap.offset) else nil,
		advances = advances,
		glyfContext = glyfContext,
		cffContext = cffContext,
		cache = {},
	}, FontMeta)

	return font :: any
end

return {
	parse = parse,
}
