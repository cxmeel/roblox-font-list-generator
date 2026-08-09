--!strict
--[[
	TrueType outline extraction from the `glyf` and `loca` tables.

	Glyphs are decoded into contours of on/off curve points first so that
	composite glyphs can apply their transform before anything is converted
	into path commands.
]]

local path = require("./path")
local reader = require("./reader")

type Path = path.Path

export type Point = {
	x: number,
	y: number,
	onCurve: boolean,
}

export type Contour = { Point }

export type Context = {
	data: string,
	--- Zero-based offsets into `data` for each glyph, with a trailing sentinel.
	locations: { number },
	glyphOffset: number,
}

local FLAG_ON_CURVE = 0x01
local FLAG_X_SHORT = 0x02
local FLAG_Y_SHORT = 0x04
local FLAG_REPEAT = 0x08
local FLAG_X_SAME = 0x10
local FLAG_Y_SAME = 0x20

local COMPONENT_ARGS_ARE_WORDS = 0x0001
local COMPONENT_ARGS_ARE_XY = 0x0002
local COMPONENT_HAS_SCALE = 0x0008
local COMPONENT_MORE = 0x0020
local COMPONENT_HAS_XY_SCALE = 0x0040
local COMPONENT_HAS_2X2 = 0x0080

local MAX_COMPONENT_DEPTH = 8

--- Reads the `loca` table into zero-based glyph offsets.
local function parseLocations(
	data: string,
	locaOffset: number,
	locaLength: number,
	numGlyphs: number,
	longFormat: boolean
): { number }
	local stream = reader.new(data, locaOffset)
	local locations = {}

	local entrySize = longFormat and 4 or 2
	local available = math.min(numGlyphs + 1, locaLength // entrySize)

	for _ = 1, available do
		if longFormat then
			table.insert(locations, stream:uint32())
		else
			-- Short format stores offsets divided by two
			table.insert(locations, stream:uint16() * 2)
		end
	end

	return locations
end

local function parseSimpleGlyph(stream: reader.Reader, numberOfContours: number): { Contour }
	local endPoints = table.create(numberOfContours)

	for _ = 1, numberOfContours do
		table.insert(endPoints, stream:uint16())
	end

	local pointCount = numberOfContours > 0 and endPoints[numberOfContours] + 1 or 0

	local instructionLength = stream:uint16()
	stream:skip(instructionLength)

	-- Flags are run-length encoded
	local flags = table.create(pointCount)

	while #flags < pointCount do
		local flag = stream:uint8()
		table.insert(flags, flag)

		if bit32.band(flag, FLAG_REPEAT) ~= 0 then
			local repeats = stream:uint8()

			for _ = 1, repeats do
				if #flags >= pointCount then
					break
				end

				table.insert(flags, flag)
			end
		end
	end

	local xCoordinates = table.create(pointCount)
	local x = 0

	for index = 1, pointCount do
		local flag = flags[index]

		if bit32.band(flag, FLAG_X_SHORT) ~= 0 then
			local delta = stream:uint8()
			x += if bit32.band(flag, FLAG_X_SAME) ~= 0 then delta else -delta
		elseif bit32.band(flag, FLAG_X_SAME) == 0 then
			x += stream:int16()
		end

		table.insert(xCoordinates, x)
	end

	local yCoordinates = table.create(pointCount)
	local y = 0

	for index = 1, pointCount do
		local flag = flags[index]

		if bit32.band(flag, FLAG_Y_SHORT) ~= 0 then
			local delta = stream:uint8()
			y += if bit32.band(flag, FLAG_Y_SAME) ~= 0 then delta else -delta
		elseif bit32.band(flag, FLAG_Y_SAME) == 0 then
			y += stream:int16()
		end

		table.insert(yCoordinates, y)
	end

	local contours: { Contour } = {}
	local startIndex = 1

	for _, endPoint in endPoints do
		local contour: Contour = {}

		for index = startIndex, endPoint + 1 do
			table.insert(contour, {
				x = xCoordinates[index],
				y = yCoordinates[index],
				onCurve = bit32.band(flags[index], FLAG_ON_CURVE) ~= 0,
			})
		end

		if #contour > 0 then
			table.insert(contours, contour)
		end

		startIndex = endPoint + 2
	end

	return contours
end

local parseGlyphContours

local function parseCompositeGlyph(context: Context, stream: reader.Reader, depth: number): { Contour }
	local contours: { Contour } = {}

	repeat
		local flags = stream:uint16()
		local glyphIndex = stream:uint16()

		local argument1, argument2

		if bit32.band(flags, COMPONENT_ARGS_ARE_WORDS) ~= 0 then
			argument1 = stream:int16()
			argument2 = stream:int16()
		else
			argument1 = stream:int8()
			argument2 = stream:int8()
		end

		-- Point matching placement is vanishingly rare in text fonts; treat it
		-- as no offset rather than bailing out of the whole glyph
		local dx, dy = 0, 0

		if bit32.band(flags, COMPONENT_ARGS_ARE_XY) ~= 0 then
			dx, dy = argument1, argument2
		end

		local a, b, c, d = 1, 0, 0, 1

		if bit32.band(flags, COMPONENT_HAS_SCALE) ~= 0 then
			a = stream:f2dot14()
			d = a
		elseif bit32.band(flags, COMPONENT_HAS_XY_SCALE) ~= 0 then
			a = stream:f2dot14()
			d = stream:f2dot14()
		elseif bit32.band(flags, COMPONENT_HAS_2X2) ~= 0 then
			a = stream:f2dot14()
			b = stream:f2dot14()
			c = stream:f2dot14()
			d = stream:f2dot14()
		end

		local componentContours = parseGlyphContours(context, glyphIndex, depth + 1)

		for _, contour in componentContours do
			local transformed: Contour = table.create(#contour)

			for _, point in contour do
				table.insert(transformed, {
					x = a * point.x + c * point.y + dx,
					y = b * point.x + d * point.y + dy,
					onCurve = point.onCurve,
				})
			end

			table.insert(contours, transformed)
		end
	until bit32.band(flags, COMPONENT_MORE) == 0

	return contours
end

--- Decodes a glyph into contours, recursing through composite components.
function parseGlyphContours(context: Context, glyphId: number, depth: number): { Contour }
	if depth > MAX_COMPONENT_DEPTH then
		return {}
	end

	local locations = context.locations
	local start = locations[glyphId + 1]
	local finish = locations[glyphId + 2]

	-- Missing or empty (whitespace) glyphs have no outline
	if not start or not finish or finish <= start then
		return {}
	end

	local stream = reader.new(context.data, context.glyphOffset + start)
	local numberOfContours = stream:int16()

	stream:skip(8) -- xMin, yMin, xMax, yMax

	if numberOfContours >= 0 then
		return parseSimpleGlyph(stream, numberOfContours)
	end

	return parseCompositeGlyph(context, stream, depth)
end

local function midpoint(first: Point, second: Point): Point
	return {
		x = (first.x + second.x) / 2,
		y = (first.y + second.y) / 2,
		onCurve = true,
	}
end

local function emitContour(target: Path, contour: Contour)
	local count = #contour

	if count == 0 then
		return
	end

	-- The contour may start on an off-curve point, in which case the real
	-- start is either the final on-curve point or an implied midpoint
	local start: Point
	local firstIndex: number

	if contour[1].onCurve then
		start = contour[1]
		firstIndex = 2
	elseif contour[count].onCurve then
		start = contour[count]
		firstIndex = 1
		count -= 1
	else
		start = midpoint(contour[1], contour[count])
		firstIndex = 1
	end

	target:moveTo(start.x, start.y)

	local index = firstIndex

	while index <= count do
		local point = contour[index]

		if point.onCurve then
			target:lineTo(point.x, point.y)
			index += 1
			continue
		end

		-- Consecutive off-curve points imply an on-curve point between them
		local nextPoint = if index < count then contour[index + 1] else start

		if nextPoint.onCurve then
			target:quadTo(point.x, point.y, nextPoint.x, nextPoint.y)
			index += 2
		else
			local implied = midpoint(point, nextPoint)
			target:quadTo(point.x, point.y, implied.x, implied.y)
			index += 1
		end
	end

	target:close()
end

--- Builds the SVG path data for a glyph, in font units.
local function buildPath(context: Context, glyphId: number): string
	local contours = parseGlyphContours(context, glyphId, 0)
	local target = path.new()

	for _, contour in contours do
		emitContour(target, contour)
	end

	return target:build()
end

return {
	parseLocations = parseLocations,
	buildPath = buildPath,
}
