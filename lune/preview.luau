--!strict
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local FontPreview = require("./lib/FontPreview")
local FontRegistry = require("./lib/FontRegistry")

local args = require("./utils/args")
local logger = require("./utils/logger")
local ufs = require("./utils/ufs")

local DEFAULT_REGISTRY_PATH = "./temp/downloads"
local DEFAULT_OUTPUT_PATH = "./temp/preview"
local DEFAULT_PREVIEW_TEXT = "The quick brown fox jumps over the lazy dog."
local DEFAULT_IMAGE_WIDTH = 1024

local FONT_IDS = args.value("--fonts")
local PREVIEW_TEXT = args.valueOr("--text", DEFAULT_PREVIEW_TEXT)
local IMAGE_WIDTH = args.numberOr("--width", DEFAULT_IMAGE_WIDTH)

if not FONT_IDS then
	logger.error("Missing --fonts argument")
	process.exit(1)
end

local REGISTRY_PATH = ufs.normalizePath(`{process.cwd}/{args.valueOr("--registry", DEFAULT_REGISTRY_PATH)}`)

-- Without an override, local fonts are read from the Roblox Studio install
local CONTENT_ARG = args.value("--content")
local CONTENT_PATH = if CONTENT_ARG then ufs.normalizePath(`{process.cwd}/{CONTENT_ARG}`) else nil

-- Validate registry
if not fs.isDir(REGISTRY_PATH) then
	if args.has("--registry") then
		logger.error(`Registry path does not exist: {REGISTRY_PATH}`)
		process.exit(1)
	end

	logger.info(`Registry path does not exist, downloading registry to: {REGISTRY_PATH}`)
	process.exec("lune", { "run", "generate" })
end

-- Locate a font file for every requested font, downloading cloud fonts as needed
local resolveOptions: FontRegistry.ResolveOptions = {
	registryPath = REGISTRY_PATH,
	contentPath = CONTENT_PATH,
}

local fontIdList = (FONT_IDS :: string):split(",")
local families = FontRegistry.resolveFamilies(fontIdList, resolveOptions)
local fontFilePaths = FontRegistry.resolveFontFiles(families, resolveOptions)

-- Fonts are laid out alphabetically, so the order here only decides which
-- duplicate ids get dropped
local previewFonts: { FontPreview.PreviewFont } = {}
local seenFontIds: { [string]: boolean } = {}
local hashParts: { string } = {}

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

	table.insert(previewFonts, {
		name = families[fontId].name,
		filePath = fontFilePath,
	})

	table.insert(hashParts, fontId)
end

-- Name the output after everything that went into it, so a cached pair is only
-- reused when it would be byte for byte identical anyway. Font ids rather than
-- file paths, which are absolute and so differ between machines.
table.sort(hashParts)

table.insert(hashParts, PREVIEW_TEXT)
table.insert(hashParts, tostring(IMAGE_WIDTH))

local FONTS_HASH = serde.hash("md5", table.concat(hashParts, ","))
local OUTPUT_FILE_NAME =
	ufs.normalizePath(`{args.valueOr("--output", `{process.cwd}/{DEFAULT_OUTPUT_PATH}`)}/{FONTS_HASH}`)

local SVG_PATH_BLACK = `{OUTPUT_FILE_NAME}_black.svg`
local SVG_PATH_WHITE = `{OUTPUT_FILE_NAME}_white.svg`

-- Two files with identical geometry and a different fill, for use with a
-- `<picture>` element keyed on `prefers-color-scheme`
local composition = FontPreview.compose(previewFonts, {
	text = PREVIEW_TEXT,
	maxWidth = IMAGE_WIDTH,
})

ufs.writeFile(SVG_PATH_BLACK, FontPreview.render(composition, "#000000"))
ufs.writeFile(SVG_PATH_WHITE, FontPreview.render(composition, "#ffffff"))

logger.log(`Wrote {composition.count} font previews:`)
logger.log(`  {SVG_PATH_BLACK}`)
logger.log(`  {SVG_PATH_WHITE}`)
