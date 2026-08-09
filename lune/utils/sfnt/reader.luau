--!strict
--[[
	Big-endian binary reader used by the sfnt parsers.

	Font files are a soup of fixed-width big-endian integers, so every parser
	in this directory walks the file through one of these instead of juggling
	offsets by hand.
]]

export type Reader = {
	data: string,
	cursor: number,

	seek: (self: Reader, position: number) -> (),
	skip: (self: Reader, count: number) -> (),
	remaining: (self: Reader) -> number,

	uint8: (self: Reader) -> number,
	int8: (self: Reader) -> number,
	uint16: (self: Reader) -> number,
	int16: (self: Reader) -> number,
	uint24: (self: Reader) -> number,
	uint32: (self: Reader) -> number,
	int32: (self: Reader) -> number,

	--- Reads an unsigned integer of an arbitrary byte width (1-4).
	uintN: (self: Reader, width: number) -> number,
	--- Reads a signed 2.14 fixed point number, used by composite glyph transforms.
	f2dot14: (self: Reader) -> number,

	tag: (self: Reader) -> string,
	bytes: (self: Reader, count: number) -> string,
}

local Reader = {}
local ReaderMeta = { __index = Reader }

local function readFormat(self: Reader, format: string): number
	local value, nextCursor = string.unpack(format, self.data, self.cursor)
	self.cursor = nextCursor
	return value
end

function Reader.seek(self: Reader, position: number)
	-- Font offsets are zero-based, Luau strings are one-based
	self.cursor = position + 1
end

function Reader.skip(self: Reader, count: number)
	self.cursor += count
end

function Reader.remaining(self: Reader): number
	return #self.data - self.cursor + 1
end

function Reader.uint8(self: Reader): number
	return readFormat(self, ">I1")
end

function Reader.int8(self: Reader): number
	return readFormat(self, ">i1")
end

function Reader.uint16(self: Reader): number
	return readFormat(self, ">I2")
end

function Reader.int16(self: Reader): number
	return readFormat(self, ">i2")
end

function Reader.uint24(self: Reader): number
	return readFormat(self, ">I3")
end

function Reader.uint32(self: Reader): number
	return readFormat(self, ">I4")
end

function Reader.int32(self: Reader): number
	return readFormat(self, ">i4")
end

function Reader.uintN(self: Reader, width: number): number
	return readFormat(self, `>I{width}`)
end

function Reader.f2dot14(self: Reader): number
	return readFormat(self, ">i2") / 16384
end

function Reader.tag(self: Reader): string
	local value = string.sub(self.data, self.cursor, self.cursor + 3)
	self.cursor += 4
	return value
end

function Reader.bytes(self: Reader, count: number): string
	local value = string.sub(self.data, self.cursor, self.cursor + count - 1)
	self.cursor += count
	return value
end

--- Creates a reader over `data`, optionally starting at a zero-based `offset`.
local function new(data: string, offset: number?): Reader
	local reader = setmetatable({
		data = data,
		cursor = (offset or 0) + 1,
	}, ReaderMeta)

	return reader :: any
end

return {
	new = new,
}
