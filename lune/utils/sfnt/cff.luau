--!strict
--[[
	CFF (`OTTO`) outline extraction.

	Roughly a sixth of the fonts Roblox ships are PostScript flavoured -- the
	whole Builder family among them -- so a Type 2 charstring interpreter is
	not optional. Charstrings are indexed by glyph id, which is what `cmap`
	hands us, so the charset table is never needed.
]]

local path = require("./path")
local reader = require("./reader")

type Path = path.Path
type Reader = reader.Reader

export type Index = {
	--- Zero-based start offsets into the font data, one per entry.
	offsets: { number },
	--- Zero-based end offsets (exclusive), one per entry.
	ends: { number },
	--- Zero-based offset of the first byte after the index.
	endOffset: number,
}

export type PrivateContext = {
	subrs: Index?,
	subrsBias: number,
}

export type Context = {
	data: string,
	charStrings: Index,
	globalSubrs: Index?,
	globalSubrsBias: number,
	--- Private context for non-CID fonts.
	private: PrivateContext,
	--- Per-FD private contexts for CID keyed fonts.
	fdPrivate: { PrivateContext }?,
	--- Maps a glyph id to a 1-based index into `fdPrivate`.
	fdSelect: ((glyphId: number) -> number)?,
}

local MAX_SUBR_DEPTH = 10

local function subrBias(count: number): number
	if count < 1240 then
		return 107
	elseif count < 33900 then
		return 1131
	end

	return 32768
end

--- Reads a CFF INDEX structure starting at the stream cursor.
local function readIndex(stream: Reader): Index
	local count = stream:uint16()

	if count == 0 then
		return {
			offsets = {},
			ends = {},
			endOffset = stream.cursor - 1,
		}
	end

	local offsetSize = stream:uint8()
	local rawOffsets = table.create(count + 1)

	for _ = 1, count + 1 do
		table.insert(rawOffsets, stream:uintN(offsetSize))
	end

	-- Offsets are relative to the byte before the data block, and are 1-based
	local dataStart = (stream.cursor - 1) - 1

	local offsets = table.create(count)
	local ends = table.create(count)

	for index = 1, count do
		table.insert(offsets, dataStart + rawOffsets[index])
		table.insert(ends, dataStart + rawOffsets[index + 1])
	end

	local endOffset = dataStart + rawOffsets[count + 1]

	-- Leave the cursor past the data block so sequential indexes chain
	stream:seek(endOffset)

	return {
		offsets = offsets,
		ends = ends,
		endOffset = endOffset,
	}
end

local function indexCount(index: Index?): number
	return if index then #index.offsets else 0
end

local function indexEntry(data: string, index: Index, position: number): string?
	local start = index.offsets[position]
	local finish = index.ends[position]

	if not start or not finish then
		return nil
	end

	return string.sub(data, start + 1, finish)
end

--- Parses a DICT into a map of operator key to operand list. Two byte
--- operators are keyed as `12 <operator>`.
local function parseDict(data: string): { [string]: { number } }
	local entries: { [string]: { number } } = {}
	local operands: { number } = {}

	local position = 1
	local length = #data

	while position <= length do
		local byte = string.byte(data, position)

		if byte <= 21 then
			local key = tostring(byte)
			position += 1

			if byte == 12 then
				key = `12 {string.byte(data, position)}`
				position += 1
			end

			entries[key] = operands
			operands = {}
		elseif byte == 28 then
			table.insert(operands, (string.unpack(">i2", data, position + 1)))
			position += 3
		elseif byte == 29 then
			table.insert(operands, (string.unpack(">i4", data, position + 1)))
			position += 5
		elseif byte == 30 then
			-- Real numbers are packed as nibbles terminated by 0xF
			local text = {}
			position += 1

			local finished = false

			while position <= length and not finished do
				local packed = string.byte(data, position)
				position += 1

				for _, nibble in { bit32.rshift(packed, 4), bit32.band(packed, 0x0F) } do
					if nibble <= 9 then
						table.insert(text, tostring(nibble))
					elseif nibble == 0x0A then
						table.insert(text, ".")
					elseif nibble == 0x0B then
						table.insert(text, "E")
					elseif nibble == 0x0C then
						table.insert(text, "E-")
					elseif nibble == 0x0E then
						table.insert(text, "-")
					elseif nibble == 0x0F then
						finished = true
						break
					end
				end
			end

			table.insert(operands, tonumber(table.concat(text)) or 0)
		elseif byte >= 32 and byte <= 246 then
			table.insert(operands, byte - 139)
			position += 1
		elseif byte >= 247 and byte <= 250 then
			table.insert(operands, (byte - 247) * 256 + string.byte(data, position + 1) + 108)
			position += 2
		elseif byte >= 251 and byte <= 254 then
			table.insert(operands, -(byte - 251) * 256 - string.byte(data, position + 1) - 108)
			position += 2
		else
			-- Reserved byte, skip it rather than derailing the whole DICT
			position += 1
		end
	end

	return entries
end

local function readPrivate(data: string, operands: { number }?): PrivateContext
	if not operands or #operands < 2 then
		return { subrs = nil, subrsBias = 0 }
	end

	local size = operands[1]
	local offset = operands[2]

	local dict = parseDict(string.sub(data, offset + 1, offset + size))
	local subrsOperands = dict["19"]

	if not subrsOperands or #subrsOperands < 1 then
		return { subrs = nil, subrsBias = 0 }
	end

	-- The Subrs offset is relative to the start of the Private DICT
	local subrs = readIndex(reader.new(data, offset + subrsOperands[1]))

	return {
		subrs = subrs,
		subrsBias = subrBias(indexCount(subrs)),
	}
end

local function readFdSelect(data: string, offset: number, numGlyphs: number): (glyphId: number) -> number
	local stream = reader.new(data, offset)
	local format = stream:uint8()

	if format == 0 then
		local mapping = table.create(numGlyphs)

		for _ = 1, numGlyphs do
			table.insert(mapping, stream:uint8() + 1)
		end

		return function(glyphId: number): number
			return mapping[glyphId + 1] or 1
		end
	end

	if format == 3 then
		local rangeCount = stream:uint16()
		local firsts = table.create(rangeCount)
		local indices = table.create(rangeCount)

		for _ = 1, rangeCount do
			table.insert(firsts, stream:uint16())
			table.insert(indices, stream:uint8() + 1)
		end

		local sentinel = stream:uint16()

		return function(glyphId: number): number
			if glyphId >= sentinel then
				return 1
			end

			for position = rangeCount, 1, -1 do
				if glyphId >= firsts[position] then
					return indices[position]
				end
			end

			return 1
		end
	end

	return function(): number
		return 1
	end
end

--- Parses the `CFF ` table into everything needed to run charstrings.
local function parse(data: string, tableOffset: number, numGlyphs: number): Context?
	local header = reader.new(data, tableOffset)

	header:skip(2) -- major, minor
	local headerSize = header:uint8()

	local stream = reader.new(data, tableOffset + headerSize)

	readIndex(stream) -- Name INDEX
	local topDicts = readIndex(stream)
	readIndex(stream) -- String INDEX
	local globalSubrs = readIndex(stream)

	local topDictData = indexEntry(data, topDicts, 1)

	if not topDictData then
		return nil
	end

	local topDict = parseDict(topDictData)
	local charStringsOperands = topDict["17"]

	if not charStringsOperands or #charStringsOperands < 1 then
		return nil
	end

	local charStrings = readIndex(reader.new(data, tableOffset + charStringsOperands[1]))

	local context: Context = {
		data = data,
		charStrings = charStrings,
		globalSubrs = globalSubrs,
		globalSubrsBias = subrBias(indexCount(globalSubrs)),
		private = readPrivate(data, topDict["18"] and {
			topDict["18"][1],
			tableOffset + topDict["18"][2],
		}),
		fdPrivate = nil,
		fdSelect = nil,
	}

	-- CID keyed fonts split their private dicts across an FDArray
	local fdArrayOperands = topDict["12 36"]
	local fdSelectOperands = topDict["12 37"]

	if fdArrayOperands and fdSelectOperands then
		local fdArray = readIndex(reader.new(data, tableOffset + fdArrayOperands[1]))
		local fdPrivate: { PrivateContext } = {}

		for position = 1, indexCount(fdArray) do
			local fontDictData = indexEntry(data, fdArray, position)
			local privateOperands = fontDictData and parseDict(fontDictData)["18"]

			table.insert(
				fdPrivate,
				readPrivate(data, privateOperands and { privateOperands[1], tableOffset + privateOperands[2] })
			)
		end

		context.fdPrivate = fdPrivate
		context.fdSelect = readFdSelect(data, tableOffset + fdSelectOperands[1], numGlyphs)
	end

	return context
end

--- Runs a Type 2 charstring, appending its outline to `target`.
local function buildPath(context: Context, glyphId: number): string
	local target = path.new()
	local charString = indexEntry(context.data, context.charStrings, glyphId + 1)

	if not charString then
		return target:build()
	end

	local private = context.private

	if context.fdPrivate and context.fdSelect then
		private = context.fdPrivate[context.fdSelect(glyphId)] or private
	end

	local stack: { number } = {}
	local stemCount = 0
	local haveWidth = false
	local x, y = 0, 0

	local function clear()
		table.clear(stack)
	end

	--- The first stack clearing operator may carry a leading width operand.
	local function takeWidth(expectedArguments: number)
		if not haveWidth and #stack > expectedArguments then
			table.remove(stack, 1)
		end

		haveWidth = true
	end

	local function countStems()
		if not haveWidth and #stack % 2 == 1 then
			table.remove(stack, 1)
		end

		haveWidth = true
		stemCount += #stack // 2
		clear()
	end

	local run

	function run(code: string, depth: number)
		if depth > MAX_SUBR_DEPTH then
			return
		end

		local position = 1
		local length = #code

		while position <= length do
			local byte = string.byte(code, position)
			position += 1

			-- Operands
			if byte == 28 then
				table.insert(stack, (string.unpack(">i2", code, position)))
				position += 2
				continue
			elseif byte >= 32 then
				if byte <= 246 then
					table.insert(stack, byte - 139)
				elseif byte <= 250 then
					table.insert(stack, (byte - 247) * 256 + string.byte(code, position) + 108)
					position += 1
				elseif byte <= 254 then
					table.insert(stack, -(byte - 251) * 256 - string.byte(code, position) - 108)
					position += 1
				else
					table.insert(stack, (string.unpack(">i4", code, position)) / 65536)
					position += 4
				end

				continue
			end

			-- Operators
			if byte == 1 or byte == 3 or byte == 18 or byte == 23 then
				countStems()
			elseif byte == 19 or byte == 20 then
				-- hintmask / cntrmask carry an implicit vstem
				countStems()
				position += (stemCount + 7) // 8
			elseif byte == 21 then
				takeWidth(2)
				x += stack[1] or 0
				y += stack[2] or 0
				target:moveTo(x, y)
				clear()
			elseif byte == 22 then
				takeWidth(1)
				x += stack[1] or 0
				target:moveTo(x, y)
				clear()
			elseif byte == 4 then
				takeWidth(1)
				y += stack[1] or 0
				target:moveTo(x, y)
				clear()
			elseif byte == 5 then
				for index = 1, #stack - 1, 2 do
					x += stack[index]
					y += stack[index + 1]
					target:lineTo(x, y)
				end

				clear()
			elseif byte == 6 or byte == 7 then
				local horizontal = byte == 6

				for index = 1, #stack do
					if horizontal then
						x += stack[index]
					else
						y += stack[index]
					end

					target:lineTo(x, y)
					horizontal = not horizontal
				end

				clear()
			elseif byte == 8 then
				for index = 1, #stack - 5, 6 do
					local c1x = x + stack[index]
					local c1y = y + stack[index + 1]
					local c2x = c1x + stack[index + 2]
					local c2y = c1y + stack[index + 3]

					x = c2x + stack[index + 4]
					y = c2y + stack[index + 5]

					target:curveTo(c1x, c1y, c2x, c2y, x, y)
				end

				clear()
			elseif byte == 24 then
				-- rcurveline: curves, then a closing line
				local index = 1

				while #stack - index >= 5 do
					local c1x = x + stack[index]
					local c1y = y + stack[index + 1]
					local c2x = c1x + stack[index + 2]
					local c2y = c1y + stack[index + 3]

					x = c2x + stack[index + 4]
					y = c2y + stack[index + 5]

					target:curveTo(c1x, c1y, c2x, c2y, x, y)
					index += 6
				end

				x += stack[index] or 0
				y += stack[index + 1] or 0
				target:lineTo(x, y)
				clear()
			elseif byte == 25 then
				-- rlinecurve: lines, then a closing curve
				local index = 1

				while #stack - index >= 7 do
					x += stack[index]
					y += stack[index + 1]
					target:lineTo(x, y)
					index += 2
				end

				local c1x = x + (stack[index] or 0)
				local c1y = y + (stack[index + 1] or 0)
				local c2x = c1x + (stack[index + 2] or 0)
				local c2y = c1y + (stack[index + 3] or 0)

				x = c2x + (stack[index + 4] or 0)
				y = c2y + (stack[index + 5] or 0)

				target:curveTo(c1x, c1y, c2x, c2y, x, y)
				clear()
			elseif byte == 26 or byte == 27 then
				-- vvcurveto / hhcurveto, with an optional leading odd delta
				local index = 1
				local odd = 0

				if #stack % 4 == 1 then
					odd = stack[1]
					index = 2
				end

				while index + 3 <= #stack do
					local c1x, c1y

					if byte == 26 then
						c1x = x + odd
						c1y = y + stack[index]
					else
						c1x = x + stack[index]
						c1y = y + odd
					end

					local c2x = c1x + stack[index + 1]
					local c2y = c1y + stack[index + 2]

					if byte == 26 then
						x = c2x
						y = c2y + stack[index + 3]
					else
						x = c2x + stack[index + 3]
						y = c2y
					end

					target:curveTo(c1x, c1y, c2x, c2y, x, y)

					odd = 0
					index += 4
				end

				clear()
			elseif byte == 30 or byte == 31 then
				-- vhcurveto / hvcurveto alternate direction each curve
				local horizontal = byte == 31
				local index = 1

				while index + 3 <= #stack do
					local isLast = #stack - index == 4
					local c1x, c1y

					if horizontal then
						c1x = x + stack[index]
						c1y = y
					else
						c1x = x
						c1y = y + stack[index]
					end

					local c2x = c1x + stack[index + 1]
					local c2y = c1y + stack[index + 2]

					if horizontal then
						y = c2y + stack[index + 3]
						x = c2x + (if isLast then stack[index + 4] else 0)
					else
						x = c2x + stack[index + 3]
						y = c2y + (if isLast then stack[index + 4] else 0)
					end

					target:curveTo(c1x, c1y, c2x, c2y, x, y)

					horizontal = not horizontal
					index += 4
				end

				clear()
			elseif byte == 10 or byte == 29 then
				local isGlobal = byte == 29
				local index = table.remove(stack)

				local subrs = if isGlobal then context.globalSubrs else private.subrs
				local bias = if isGlobal then context.globalSubrsBias else private.subrsBias

				if index and subrs then
					local subrCode = indexEntry(context.data, subrs, index + bias + 1)

					if subrCode then
						run(subrCode, depth + 1)
					end
				end
			elseif byte == 11 then
				return
			elseif byte == 14 then
				takeWidth(0)
				target:close()
				clear()
				return
			elseif byte == 12 then
				local operator = string.byte(code, position)
				position += 1

				if operator == 35 then
					-- flex
					local c1x = x + stack[1]
					local c1y = y + stack[2]
					local c2x = c1x + stack[3]
					local c2y = c1y + stack[4]
					local jx = c2x + stack[5]
					local jy = c2y + stack[6]

					target:curveTo(c1x, c1y, c2x, c2y, jx, jy)

					local c3x = jx + stack[7]
					local c3y = jy + stack[8]
					local c4x = c3x + stack[9]
					local c4y = c3y + stack[10]

					x = c4x + stack[11]
					y = c4y + stack[12]

					target:curveTo(c3x, c3y, c4x, c4y, x, y)
				elseif operator == 34 then
					-- hflex
					local startY = y

					local c1x = x + stack[1]
					local c1y = y
					local c2x = c1x + stack[2]
					local c2y = c1y + stack[3]
					local jx = c2x + stack[4]
					local jy = c2y

					target:curveTo(c1x, c1y, c2x, c2y, jx, jy)

					local c3x = jx + stack[5]
					local c3y = jy
					local c4x = c3x + stack[6]
					local c4y = startY

					x = c4x + stack[7]
					y = startY

					target:curveTo(c3x, c3y, c4x, c4y, x, y)
				elseif operator == 36 then
					-- hflex1
					local startY = y

					local c1x = x + stack[1]
					local c1y = y + stack[2]
					local c2x = c1x + stack[3]
					local c2y = c1y + stack[4]
					local jx = c2x + stack[5]
					local jy = c2y

					target:curveTo(c1x, c1y, c2x, c2y, jx, jy)

					local c3x = jx + stack[6]
					local c3y = jy
					local c4x = c3x + stack[7]
					local c4y = c3y + stack[8]

					x = c4x + stack[9]
					y = startY

					target:curveTo(c3x, c3y, c4x, c4y, x, y)
				elseif operator == 37 then
					-- flex1
					local startX, startY = x, y

					local deltaX = stack[1] + stack[3] + stack[5] + stack[7] + stack[9]
					local deltaY = stack[2] + stack[4] + stack[6] + stack[8] + stack[10]

					local c1x = x + stack[1]
					local c1y = y + stack[2]
					local c2x = c1x + stack[3]
					local c2y = c1y + stack[4]
					local jx = c2x + stack[5]
					local jy = c2y + stack[6]

					target:curveTo(c1x, c1y, c2x, c2y, jx, jy)

					local c3x = jx + stack[7]
					local c3y = jy + stack[8]
					local c4x = c3x + stack[9]
					local c4y = c3y + stack[10]

					if math.abs(deltaX) > math.abs(deltaY) then
						x = c4x + stack[11]
						y = startY
					else
						x = startX
						y = c4y + stack[11]
					end

					target:curveTo(c3x, c3y, c4x, c4y, x, y)
				end

				clear()
			else
				-- Unknown operator; drop its operands and keep going
				clear()
			end
		end
	end

	run(charString, 0)

	return target:build()
end

return {
	parse = parse,
	buildPath = buildPath,
}
