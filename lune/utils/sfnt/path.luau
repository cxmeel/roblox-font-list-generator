--!strict
--[[
	Accumulates glyph outlines as SVG path data.

	Coordinates are kept in font units (Y up); the caller is expected to flip
	and scale them with a transform when placing the glyph.

	Output is written as relative commands with implicit repetition and minimal
	separators, which is worth the bookkeeping: outline deltas are small numbers
	even in a 2048 unit em, where absolute coordinates are not. Everything is
	rounded to whole font units -- well under a pixel at any preview size -- and
	deltas are taken between *rounded* points so the error cannot accumulate.
]]

export type Path = {
	parts: { string },
	currentX: number,
	currentY: number,
	startX: number,
	startY: number,
	lastCommand: string,
	needsSeparator: boolean,
	isOpen: boolean,

	moveTo: (self: Path, x: number, y: number) -> (),
	lineTo: (self: Path, x: number, y: number) -> (),
	--- Quadratic bezier, used by TrueType `glyf` outlines.
	quadTo: (self: Path, cx: number, cy: number, x: number, y: number) -> (),
	--- Cubic bezier, used by CFF charstring outlines.
	curveTo: (
		self: Path,
		c1x: number,
		c1y: number,
		c2x: number,
		c2y: number,
		x: number,
		y: number
	) -> (),
	close: (self: Path) -> (),

	isEmpty: (self: Path) -> boolean,
	build: (self: Path) -> string,
}

local Path = {}
local PathMeta = { __index = Path }

local function pushCommand(self: Path, command: string)
	-- A repeated command letter can be left out entirely; "m" is the exception,
	-- since implicit repetition after a moveto means lineto
	if self.lastCommand == command and command ~= "m" then
		return
	end

	table.insert(self.parts, command)
	self.lastCommand = command
	self.needsSeparator = false
end

local function pushNumber(self: Path, value: number)
	local text = string.format("%d", value)

	-- A leading minus sign already separates the number from the previous one
	if self.needsSeparator and string.sub(text, 1, 1) ~= "-" then
		table.insert(self.parts, " ")
	end

	table.insert(self.parts, text)
	self.needsSeparator = true
end

function Path.moveTo(self: Path, x: number, y: number)
	if self.isOpen then
		self:close()
	end

	local targetX, targetY = math.round(x), math.round(y)

	pushCommand(self, "m")
	pushNumber(self, targetX - self.currentX)
	pushNumber(self, targetY - self.currentY)

	self.currentX, self.currentY = targetX, targetY
	self.startX, self.startY = targetX, targetY
	self.isOpen = true
end

function Path.lineTo(self: Path, x: number, y: number)
	local targetX, targetY = math.round(x), math.round(y)

	pushCommand(self, "l")
	pushNumber(self, targetX - self.currentX)
	pushNumber(self, targetY - self.currentY)

	self.currentX, self.currentY = targetX, targetY
end

function Path.quadTo(self: Path, cx: number, cy: number, x: number, y: number)
	local targetX, targetY = math.round(x), math.round(y)

	pushCommand(self, "q")
	pushNumber(self, math.round(cx) - self.currentX)
	pushNumber(self, math.round(cy) - self.currentY)
	pushNumber(self, targetX - self.currentX)
	pushNumber(self, targetY - self.currentY)

	self.currentX, self.currentY = targetX, targetY
end

function Path.curveTo(self: Path, c1x: number, c1y: number, c2x: number, c2y: number, x: number, y: number)
	local targetX, targetY = math.round(x), math.round(y)

	pushCommand(self, "c")
	pushNumber(self, math.round(c1x) - self.currentX)
	pushNumber(self, math.round(c1y) - self.currentY)
	pushNumber(self, math.round(c2x) - self.currentX)
	pushNumber(self, math.round(c2y) - self.currentY)
	pushNumber(self, targetX - self.currentX)
	pushNumber(self, targetY - self.currentY)

	self.currentX, self.currentY = targetX, targetY
end

function Path.close(self: Path)
	if not self.isOpen then
		return
	end

	table.insert(self.parts, "z")
	self.lastCommand = "z"
	self.needsSeparator = false
	self.isOpen = false

	-- Closing a subpath returns the pen to where the subpath started
	self.currentX, self.currentY = self.startX, self.startY
end

function Path.isEmpty(self: Path): boolean
	return #self.parts == 0
end

function Path.build(self: Path): string
	self:close()
	return table.concat(self.parts)
end

local function new(): Path
	local path = setmetatable({
		parts = {},
		currentX = 0,
		currentY = 0,
		startX = 0,
		startY = 0,
		lastCommand = "",
		needsSeparator = false,
		isOpen = false,
	}, PathMeta)

	return path :: any
end

return {
	new = new,
}
