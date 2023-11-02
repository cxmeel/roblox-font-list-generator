--!strict
local Colors = {}

local function init(open: number, close: number): any
	local self = setmetatable({}, Colors)
	self.__chain = { { open, close } }
	return self
end

function Colors:__index(key: string)
	local chain = self.__chain

	if Colors[key] then
		table.insert(chain, Colors[key].__chain[1])
	end

	return self
end

function Colors:__call(input: string)
	local chain, start, finish = self.__chain, "", ""

	for i = 1, #chain do
		start ..= `\27[{chain[i][1]}m`
		finish = `\27[{chain[i][2]}m{finish}`
	end

	local output = `{start}{input}{finish}`
	self.__chain = { chain[1] }

	return output
end

Colors.reset = init(0, 0)
Colors.bold = init(1, 22)
Colors.dim = init(2, 22)
Colors.italic = init(3, 23)
Colors.underline = init(4, 24)
Colors.inverse = init(7, 27)
Colors.hidden = init(8, 28)
Colors.strikethrough = init(9, 29)

Colors.black = init(30, 39)
Colors.red = init(31, 39)
Colors.green = init(32, 39)
Colors.yellow = init(33, 39)
Colors.blue = init(34, 39)
Colors.magenta = init(35, 39)
Colors.cyan = init(36, 39)
Colors.white = init(37, 39)
Colors.gray = init(90, 39)
Colors.grey = init(90, 39)

Colors.bgBlack = init(40, 49)
Colors.bgRed = init(41, 49)
Colors.bgGreen = init(42, 49)
Colors.bgYellow = init(43, 49)
Colors.bgBlue = init(44, 49)
Colors.bgMagenta = init(45, 49)
Colors.bgCyan = init(46, 49)
Colors.bgWhite = init(47, 49)

return Colors
