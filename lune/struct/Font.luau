--!strict
local fs = require("@lune/fs")
local net = require("@lune/net")

local Aliases = require("../data/Aliases")

local colors = require("../utils/colors")
local strings = require("../utils/strings")
local ufs = require("../utils/ufs")

type Set<T> = { [T]: boolean }

export type IFont = {
    ContentUri: string,
    Name: string,
    Aliases: { string },
    Weights: { Enum.FontWeight },
    Styles: { Enum.FontStyle },
}

local Font = {}
Font.__index = Font

local FONT_WEIGHT_MAP = table.freeze({
	[100] = "Enum.FontWeight.Thin",
	[200] = "Enum.FontWeight.ExtraLight",
	[300] = "Enum.FontWeight.Light",
	[400] = "Enum.FontWeight.Regular",
	[500] = "Enum.FontWeight.Medium",
	[600] = "Enum.FontWeight.SemiBold",
	[700] = "Enum.FontWeight.Bold",
	[800] = "Enum.FontWeight.ExtraBold",
	[900] = "Enum.FontWeight.Heavy",
})

local FONT_STYLE_MAP = table.freeze({
	normal = "Enum.FontStyle.Normal",
	italic = "Enum.FontStyle.Italic",
})

Font.WEIGHT = FONT_WEIGHT_MAP
Font.STYLE = FONT_STYLE_MAP

function Font.new(contentUri: string, fontData: any)
	local self = setmetatable({}, Font)
	local fileName = ufs.normalizePath(contentUri):match("/*(.+)$")

	self.ContentUri = contentUri
	self.Name = strings.trim(fontData.name)
	self.SafeName = strings.fileNamify(self.Name):lower()
	self.Aliases = fileName and Aliases[fileName] or {}
	self.Weights = {}
	self.Styles = {}

	local weightSet: Set<number> = {}
	local styleSet: Set<string> = {}

	for _, fontFace in ipairs(fontData.faces) do
		weightSet[fontFace.weight] = true
		styleSet[fontFace.style] = true
	end

	for weight in weightSet do
		table.insert(self.Weights, FONT_WEIGHT_MAP[weight])
	end

	for style in styleSet do
		table.insert(self.Styles, FONT_STYLE_MAP[style])
	end

	return self
end

function Font.fromURL(assetId: number, url: string)
	local filePath = `temp/downloads/{assetId}.json`
	local fontFile = {}

	local isReusedFromDisk = false

	if fs.isFile(filePath) then
		local fontFileContent = fs.readFile(filePath)
		fontFile = net.jsonDecode(fontFileContent)
		isReusedFromDisk = true
	else
		local cdnAssetResponse = net.request(url)
		ufs.writeFile(filePath, cdnAssetResponse.body)

		fontFile = net.jsonDecode(cdnAssetResponse.body)
	end

	return Font.new(`rbxassetid://{assetId}`, fontFile), isReusedFromDisk, isReusedFromDisk and filePath or url
end

function Font.fromFile(fullPath: string)
	local fontFileName = table.remove(fullPath:split("/"))
	assert(fontFileName, `{colors.bold("Invalid font file path:")} {fullPath}`)

	local fontFileContents = fs.readFile(fullPath)
	local fontFile = net.jsonDecode(fontFileContents)

	return Font.new(`rbxasset://fonts/families/{fontFileName}`, fontFile)
end

function Font:ToString()
	return table.concat({
		`\{ Name = "{self.Name}"`,
		`SafeName = "{self.SafeName}"`,
		`Aliases = \{{#self.Aliases > 0 and ` {table.concat(self.Aliases, ", ")} ` or ""}}`,
		`ContentUri = "{self.ContentUri}"`,
		`Weights = \{ {table.concat(self.Weights, ", ")} }`,
		`Styles = \{ {table.concat(self.Styles, ", ")} } }`,
	}, ", ")
end

return Font
