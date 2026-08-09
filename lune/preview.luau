--!strict
local font = require("./struct/Font")
local fs = require("@lune/fs")
local logger = require("./utils/logger")
local luau = require("@lune/luau")
local net = require("@lune/net")
local process = require("@lune/process")
local rbx = require("./utils/rbx")
local serde = require("@lune/serde")
local sfnt = require("./utils/sfnt")
local ufs = require("./utils/ufs")

local REGISTRY_ARG_POS = table.find(process.args, "--registry")
local FONT_IDS_ARG_POS = table.find(process.args, "--fonts")

type IFont = font.IFont

export type RobloxFontStyle = "normal" | "italic"

export type RobloxFontFace = {
	name: string,
	weight: number,
	style: RobloxFontStyle,
	assetId: string,
}

export type RobloxFont = {
	name: string,
	faces: { RobloxFontFace },
}

if not FONT_IDS_ARG_POS then
	logger.error("Missing --fonts argument")
	process.exit(1)
end

local REGISTRY_PATH =
	ufs.normalizePath(`{process.cwd}/{REGISTRY_ARG_POS and process.args[REGISTRY_ARG_POS + 1] or "./temp/downloads"}`)
local FONT_IDS = process.args[(FONT_IDS_ARG_POS :: number) + 1]

-- Validate registry
if not fs.isDir(REGISTRY_PATH) then
	if REGISTRY_ARG_POS then
		logger.error(`Registry path does not exist: {REGISTRY_PATH}`)
		process.exit(1)
	end

	logger.info(`Registry path does not exist, downloading registry to: {REGISTRY_PATH}`)
	process.exec("lune", { "run", "generate" })
end

-- Locate fonts in the registry or local Studio installation
local fontIdList = FONT_IDS:split(",")
local fontContentIds: { [string]: RobloxFont } = {}

for _, fontId in fontIdList do
	local fontPath: string

	if fontId:match("^rbxasset://") then
		-- Local font, extract from Studio installation
		local localFontPath = ufs.normalizePath(`{rbx.studioContentPath()}/{fontId:sub(12)}`)
		fontPath = localFontPath
	elseif fontId:match("^rbxassetid://") then
		-- Remote font, fetch from downloads directory
		local assetPath = ufs.normalizePath(`{REGISTRY_PATH}/{fontId:sub(14)}.json`)
		fontPath = assetPath
	end

	if not fontPath then
		logger.error(`Invalid font ID: {fontId}`)
		process.exit(1)
	elseif not fs.isFile(fontPath) then
		logger.error(`Font not found: {fontPath}`)
		process.exit(1)
	end

	local fontContent = fs.readFile(fontPath)
	local fontData: RobloxFont = serde.decode("json", fontContent)

	fontContentIds[fontId] = fontData
end

-- Batch download remote font otf/ttf files
local remoteFontIds: { [string]: string } = {}
local fontFilePaths: { [string]: string } = {}

for fontId, fontData in fontContentIds do
	-- Default to the first face if no match is found
	local targetFace = fontData.faces[1]

	-- Find the first face matching "normal" style with weight 400 (regular)
	for _, face in fontData.faces do
		if face.style == "normal" and face.weight == 400 then
			targetFace = face
			break
		end
	end

	local remoteAssetId = targetFace.assetId:match("^rbxassetid://(%d+)$")

	if remoteAssetId then
		remoteFontIds[fontId] = remoteAssetId
	else
		fontFilePaths[fontId] = ufs.normalizePath(`{rbx.studioContentPath()}/{targetFace.assetId:sub(12)}`)
	end
end

-- Batch download remote font files
type AssetDeliveryBatchItem = {
	locations: { { assetFormat: string, location: string } },
	requestId: string,
	isArchived: boolean,
	assetTypeId: number,
	isRecordable: boolean,
}

type FontFileType = "otf" | "ttf" | "woff" | "woff2" | "eot"

local FONT_FILE_TYPES = {
	"otf",
	"ttf",
	"woff",
	"woff2",
	"eot",
}

local function determineFontFileType(fontContent: string): FontFileType?
	local len = #fontContent

	-- All standard font formats require at least 4 bytes for their signature.
	if len < 4 then
		return nil
	end

	-- Extract the first 4 bytes for standard magic number comparison
	local magic = string.sub(fontContent, 1, 4)

	if magic == "OTTO" then
		return "otf"
	elseif magic == string.char(0, 1, 0, 0) or magic == "true" then
		-- OpenType specifies \x00\x01\x00\x00 for TrueType, but older Apple fonts use 'true'
		return "ttf"
	elseif magic == "wOFF" then
		return "woff"
	elseif magic == "wOF2" then
		return "woff2"
	end

	-- EOT is an exception: its magic number ("LP") is located at byte offset 34.
	-- In Lua's 1-based indexing, this corresponds to bytes 35 and 36.
	if len >= 36 and string.sub(fontContent, 35, 36) == "LP" then
		return "eot"
	end

	-- If no signatures match, return nil
	return nil
end

if next(remoteFontIds) then
	logger.info("Downloading remote font files...")

	local requestBody = {}

	for fontId, assetId in remoteFontIds do
		table.insert(requestBody, {
			requestId = fontId,
			assetId = tonumber(assetId),
		})
	end

	local response = net.request({
		url = "https://assetdelivery.roblox.com/v2/assets/batch",
		method = "POST",
		body = serde.encode("json", requestBody, false),
		headers = {
			["Content-Type"] = "application/json",
		},
	})

	if not response.ok then
		logger.error(
			`Failed to download remote font files: [{response.statusCode}] {response.statusMessage}: {response.body}`
		)
		process.exit(1)
	end

	local parsedOk, parsedData: { AssetDeliveryBatchItem } =
		pcall(serde.decode, "json" :: serde.EncodeDecodeFormat, response.body)

	if not parsedOk then
		logger.error(`Failed to parse response JSON: {parsedData}`)
		process.exit(1)
	end

	for _, responseItem in parsedData do
		if responseItem.isArchived then
			logger.error(`Font asset is archived and cannot be downloaded: {responseItem.requestId}`)
			process.exit(1)
		end

		if #responseItem.locations == 0 then
			logger.error(`No download locations found for font asset: {responseItem.requestId}`)
			process.exit(1)
		end

		local downloadUrl = responseItem.locations[1].location

		local fontFilePathName = ufs.normalizePath(`{REGISTRY_PATH}/fonts/{responseItem.requestId:sub(14)}`)
		local fontFilePath: string?

		for _, fileType in FONT_FILE_TYPES do
			local potentialPath = `{fontFilePathName}.{fileType}`

			if fs.isFile(potentialPath) then
				fontFilePath = potentialPath
				break
			end
		end

		if fontFilePath then
			logger.debug(`Font asset {responseItem.requestId} already exists at {fontFilePath}, skipping download.`)
			fontFilePaths[responseItem.requestId] = fontFilePath

			continue
		end

		logger.debug(`> Downloading font asset {responseItem.requestId} from {downloadUrl}`)

		local downloadResponse = net.request({ url = downloadUrl })

		if not downloadResponse.ok then
			logger.error(
				`Failed to download font asset {responseItem.requestId}: [{downloadResponse.statusCode}] {downloadResponse.statusMessage}`
			)
			process.exit(1)
		end

		local fontFileType = determineFontFileType(downloadResponse.body) or "otf"
		local downloadedFilePath = `{fontFilePathName}.{fontFileType}`

		ufs.writeFile(downloadedFilePath, downloadResponse.body)
		fontFilePaths[responseItem.requestId] = downloadedFilePath

		logger.debug(`> Saved font asset {responseItem.requestId} to {downloadedFilePath}`)
	end
end

-- Generate preview images for each font
local PREVIEW_TEXT_ARG_POS = table.find(process.args, "--text")
local PREVIEW_TEXT = PREVIEW_TEXT_ARG_POS and process.args[PREVIEW_TEXT_ARG_POS + 1]
	or "The quick brown fox jumps over the lazy dog."

local IMAGE_WIDTH_ARG_POS = table.find(process.args, "--width")
local IMAGE_WIDTH = IMAGE_WIDTH_ARG_POS and tonumber(process.args[IMAGE_WIDTH_ARG_POS + 1]) or 1024

local FONT_HASH_RAW_CONTENT = {}

for fontId in fontFilePaths do
	table.insert(FONT_HASH_RAW_CONTENT, fontId)
end

table.sort(FONT_HASH_RAW_CONTENT)

-- The text and width change the output, so they have to change the file name too
table.insert(FONT_HASH_RAW_CONTENT, PREVIEW_TEXT)
table.insert(FONT_HASH_RAW_CONTENT, tostring(IMAGE_WIDTH))

local FONTS_HASH = serde.hash("md5", table.concat(FONT_HASH_RAW_CONTENT, ","))

local OUTPUT_DIR_ARG_POS = table.find(process.args, "--output")
local OUTPUT_FILE_NAME = ufs.normalizePath(
	`{OUTPUT_DIR_ARG_POS and process.args[OUTPUT_DIR_ARG_POS + 1] or `{process.cwd}/temp/preview`}/{FONTS_HASH}`
)

local SVG_PATH_BLACK = `{OUTPUT_FILE_NAME}_black.svg`
local SVG_PATH_WHITE = `{OUTPUT_FILE_NAME}_white.svg`

--[[
	Generate a preview image of all the specified fonts using the preview text.

	Each font gets a block in a single column: the family name in a small generic
	sans-serif, and the preview text below it rendered in the font itself.

	GitHub serves README images through Camo and renders them as `<img>`, which is
	a sandbox with no access to external or embedded webfonts. So the preview text
	cannot be `<text>` -- every glyph is emitted as an outline `<path>` instead,
	defined once per unique glyph and placed with `<use>`.

	Two files are written with identical geometry and a different fill, for use
	with a `<picture>` element keyed on `prefers-color-scheme`.
]]

-- Layout constants, in SVG user units
local PADDING = 24
local LABEL_SIZE = 13
local LABEL_GAP = 10
local BLOCK_GAP = 22
local MAX_SAMPLE_SIZE = 32
local LABEL_FONT_FAMILY = "-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif"
local LABEL_OPACITY = "0.55"

local XML_ESCAPES = {
	["&"] = "&amp;",
	["<"] = "&lt;",
	[">"] = "&gt;",
	['"'] = "&quot;",
	["'"] = "&apos;",
}

local function escapeXml(value: string): string
	return (value:gsub("[&<>\"']", XML_ESCAPES))
end

--- Formats a coordinate with just enough precision, without trailing zeroes.
local function number(value: number): string
	if value == math.round(value) then
		return string.format("%d", value)
	end

	return (string.format("%.3f", value):gsub("0+$", ""))
end

type PreviewEntry = {
	name: string,
	font: sfnt.Font,
	glyphs: { sfnt.Glyph },
	--- Advance width of the preview text, in ems.
	emWidth: number,
}

-- Parse each font file and shape the preview text, keeping CLI argument order
local previewEntries: { PreviewEntry } = {}
local seenFontIds: { [string]: boolean } = {}

for _, fontId in fontIdList do
	if seenFontIds[fontId] then
		continue
	end

	seenFontIds[fontId] = true

	local fontFilePath = fontFilePaths[fontId]

	if not fontFilePath then
		logger.error(`No font file resolved for: {fontId}`)
		process.exit(1)
	end

	local parsedFont = sfnt.parse(fs.readFile(fontFilePath))

	if not parsedFont then
		logger.error(`Could not parse font file: {fontFilePath}`)
		process.exit(1)
		continue
	end

	local glyphs = parsedFont:shape(PREVIEW_TEXT)
	local advance = 0

	for _, glyph in glyphs do
		advance += glyph.advance
	end

	logger.debug(`> Shaped {#glyphs} glyphs for {fontContentIds[fontId].name} from {fontFilePath}`)

	table.insert(previewEntries, {
		name = fontContentIds[fontId].name,
		font = parsedFont,
		glyphs = glyphs,
		emWidth = advance / parsedFont.unitsPerEm,
	})
end

if #previewEntries == 0 then
	logger.error("No fonts left to preview")
	process.exit(1)
end

-- Pick one sample size shared by every font, so the comparison is fair, and
-- shrink it if the widest line would otherwise overflow the target width
local widestEm = 0

for _, entry in previewEntries do
	widestEm = math.max(widestEm, entry.emWidth)
end

local sampleSize = MAX_SAMPLE_SIZE

if widestEm > 0 then
	sampleSize = math.min(MAX_SAMPLE_SIZE, (IMAGE_WIDTH - PADDING * 2) / widestEm)
end

local glyphDefinitions: { string } = {}
local definedGlyphs: { [string]: boolean } = {}
local bodyElements: { string } = {}

local cursorY = PADDING

for index, entry in previewEntries do
	local entryFont = entry.font
	local scale = sampleSize / entryFont.unitsPerEm

	local labelBaseline = cursorY + LABEL_SIZE
	local sampleBaseline = labelBaseline + LABEL_GAP + entryFont.ascender * scale

	table.insert(
		bodyElements,
		`<text x="{PADDING}" y="{number(labelBaseline)}" font-family="{LABEL_FONT_FAMILY}"`
			.. ` font-size="{LABEL_SIZE}" opacity="{LABEL_OPACITY}">{escapeXml(entry.name)}</text>`
	)

	local placements: { string } = {}
	local penX = 0

	for _, glyph in entry.glyphs do
		-- Whitespace and unmapped glyphs still advance the pen, but draw nothing
		if glyph.pathData ~= "" then
			local glyphKey = `f{index}g{glyph.glyphId}`

			if not definedGlyphs[glyphKey] then
				definedGlyphs[glyphKey] = true
				table.insert(glyphDefinitions, `<path id="{glyphKey}" d="{glyph.pathData}"/>`)
			end

			table.insert(placements, `<use href="#{glyphKey}" x="{number(penX)}"/>`)
		end

		penX += glyph.advance
	end

	-- Font units are Y up and SVG is Y down, hence the negative vertical scale
	table.insert(
		bodyElements,
		`<g transform="translate({PADDING} {number(sampleBaseline)}) scale({number(scale)} -{number(scale)})">`
			.. `{table.concat(placements)}</g>`
	)

	cursorY = sampleBaseline - entryFont.descender * scale + BLOCK_GAP
end

local imageWidth = math.ceil(math.min(IMAGE_WIDTH, widestEm * sampleSize + PADDING * 2))
local imageHeight = math.ceil(cursorY - BLOCK_GAP + PADDING)

local svgDefinitions = table.concat(glyphDefinitions)
local svgBody = table.concat(bodyElements)
local svgTitle = escapeXml(`Font preview: {PREVIEW_TEXT}`)

local function buildSvg(fill: string): string
	return `<svg xmlns="http://www.w3.org/2000/svg" width="{imageWidth}" height="{imageHeight}"`
		.. ` viewBox="0 0 {imageWidth} {imageHeight}" role="img">`
		.. `<title>{svgTitle}</title>`
		.. `<defs>{svgDefinitions}</defs>`
		.. `<g fill="{fill}">{svgBody}</g>`
		.. `</svg>`
end

ufs.writeFile(SVG_PATH_BLACK, buildSvg("#000000"))
ufs.writeFile(SVG_PATH_WHITE, buildSvg("#ffffff"))

logger.log(`Wrote {#previewEntries} font previews:`)
logger.log(`  {SVG_PATH_BLACK}`)
logger.log(`  {SVG_PATH_WHITE}`)
