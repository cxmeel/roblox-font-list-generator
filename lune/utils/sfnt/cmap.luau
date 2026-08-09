--!strict
--[[
	`cmap` table parsing: maps unicode codepoints to glyph indices.

	Only the subtable formats that show up in real desktop fonts are handled:
	0 (byte table), 4 (segmented BMP), 6 (trimmed table) and 12 (segmented
	full range). Anything else is skipped when picking a subtable.
]]

local reader = require("./reader")

type Reader = reader.Reader

export type CharacterMap = {
	--- Zero-based offset of the chosen subtable within the font data.
	offset: number,
	format: number,
	--- True for (3, 0) symbol subtables, which live in the 0xF000 private range.
	isSymbol: boolean,
}

local SUPPORTED_FORMATS = { [0] = true, [4] = true, [6] = true, [12] = true }

--- Ranked platform/encoding preferences; earlier entries win.
local ENCODING_PREFERENCE = {
	{ platform = 3, encoding = 10 }, -- Windows, UCS-4
	{ platform = 0, encoding = 6 }, -- Unicode, full repertoire
	{ platform = 0, encoding = 4 }, -- Unicode 2.0+, full repertoire
	{ platform = 3, encoding = 1 }, -- Windows, BMP
	{ platform = 0, encoding = 3 }, -- Unicode 2.0+, BMP
	{ platform = 0, encoding = 2 },
	{ platform = 0, encoding = 1 },
	{ platform = 0, encoding = 0 },
	{ platform = 3, encoding = 0 }, -- Windows symbol
	{ platform = 1, encoding = 0 }, -- Macintosh Roman
}

--- Picks the most capable usable subtable out of a `cmap` table.
local function parse(data: string, tableOffset: number): CharacterMap?
	local stream = reader.new(data, tableOffset)

	stream:skip(2) -- version
	local numTables = stream:uint16()

	local candidates: { { platform: number, encoding: number, offset: number, format: number } } = {}

	for _ = 1, numTables do
		local platform = stream:uint16()
		local encoding = stream:uint16()
		local subtableOffset = tableOffset + stream:uint32()

		if subtableOffset + 2 > #data then
			continue
		end

		local format = reader.new(data, subtableOffset):uint16()

		if SUPPORTED_FORMATS[format] then
			table.insert(candidates, {
				platform = platform,
				encoding = encoding,
				offset = subtableOffset,
				format = format,
			})
		end
	end

	for _, preference in ENCODING_PREFERENCE do
		for _, candidate in candidates do
			if candidate.platform == preference.platform and candidate.encoding == preference.encoding then
				return {
					offset = candidate.offset,
					format = candidate.format,
					isSymbol = candidate.platform == 3 and candidate.encoding == 0,
				}
			end
		end
	end

	-- Nothing matched the preference list, fall back to whatever we can read
	local fallback = candidates[1]

	if not fallback then
		return nil
	end

	return {
		offset = fallback.offset,
		format = fallback.format,
		isSymbol = false,
	}
end

local function lookupFormat0(data: string, offset: number, codepoint: number): number
	if codepoint > 255 then
		return 0
	end

	local stream = reader.new(data, offset + 6 + codepoint)
	return stream:uint8()
end

local function lookupFormat4(data: string, offset: number, codepoint: number): number
	if codepoint > 0xFFFF then
		return 0
	end

	local header = reader.new(data, offset + 6)
	local segCount = header:uint16() // 2

	local endCodes = offset + 14
	local startCodes = endCodes + segCount * 2 + 2
	local idDeltas = startCodes + segCount * 2
	local idRangeOffsets = idDeltas + segCount * 2

	-- Segments are sorted by endCode, so binary search for the first one that
	-- can contain the codepoint
	local low, high, segment = 0, segCount - 1, -1

	while low <= high do
		local middle = (low + high) // 2
		local endCode = reader.new(data, endCodes + middle * 2):uint16()

		if codepoint > endCode then
			low = middle + 1
		else
			segment = middle
			high = middle - 1
		end
	end

	if segment < 0 then
		return 0
	end

	local startCode = reader.new(data, startCodes + segment * 2):uint16()

	if codepoint < startCode then
		return 0
	end

	local idDelta = reader.new(data, idDeltas + segment * 2):int16()
	local idRangeOffsetAddress = idRangeOffsets + segment * 2
	local idRangeOffset = reader.new(data, idRangeOffsetAddress):uint16()

	if idRangeOffset == 0 then
		return (codepoint + idDelta) % 0x10000
	end

	local glyphAddress = idRangeOffsetAddress + idRangeOffset + (codepoint - startCode) * 2

	if glyphAddress + 2 > #data then
		return 0
	end

	local glyphId = reader.new(data, glyphAddress):uint16()

	if glyphId == 0 then
		return 0
	end

	return (glyphId + idDelta) % 0x10000
end

local function lookupFormat6(data: string, offset: number, codepoint: number): number
	local stream = reader.new(data, offset + 6)
	local firstCode = stream:uint16()
	local entryCount = stream:uint16()

	if codepoint < firstCode or codepoint >= firstCode + entryCount then
		return 0
	end

	stream:skip((codepoint - firstCode) * 2)
	return stream:uint16()
end

local function lookupFormat12(data: string, offset: number, codepoint: number): number
	local groupCount = reader.new(data, offset + 12):uint32()
	local groups = offset + 16

	local low, high = 0, groupCount - 1

	while low <= high do
		local middle = (low + high) // 2
		local group = reader.new(data, groups + middle * 12)

		local startCharCode = group:uint32()
		local endCharCode = group:uint32()
		local startGlyphId = group:uint32()

		if codepoint < startCharCode then
			high = middle - 1
		elseif codepoint > endCharCode then
			low = middle + 1
		else
			return startGlyphId + (codepoint - startCharCode)
		end
	end

	return 0
end

--- Resolves a codepoint to a glyph index, or 0 (`.notdef`) when unmapped.
local function lookup(characterMap: CharacterMap, data: string, codepoint: number): number
	local offset = characterMap.offset
	local format = characterMap.format

	local glyphId = 0

	if format == 0 then
		glyphId = lookupFormat0(data, offset, codepoint)
	elseif format == 4 then
		glyphId = lookupFormat4(data, offset, codepoint)
	elseif format == 6 then
		glyphId = lookupFormat6(data, offset, codepoint)
	elseif format == 12 then
		glyphId = lookupFormat12(data, offset, codepoint)
	end

	-- Symbol fonts remap ASCII into the 0xF000 private use range
	if glyphId == 0 and characterMap.isSymbol and codepoint < 0x100 then
		return lookup({ offset = offset, format = format, isSymbol = false }, data, 0xF000 + codepoint)
	end

	return glyphId
end

return {
	parse = parse,
	lookup = lookup,
}
