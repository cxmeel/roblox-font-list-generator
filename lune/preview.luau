--!strict
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local FontPreview = require("./lib/FontPreview")
local FontRegistry = require("./lib/FontRegistry")

local args = require("./utils/args")
local logger = require("./utils/logger")
local rbx = require("./utils/rbx")
local resvg = require("./utils/resvg")
local ufs = require("./utils/ufs")

local DEFAULT_REGISTRY_PATH = "./temp/downloads"
local DEFAULT_OUTPUT_PATH = "./temp/preview"
local DEFAULT_PREVIEW_TEXT = "The quick brown fox jumps over the lazy dog."
local DEFAULT_IMAGE_WIDTH = 1024
local DEFAULT_PREVIEW_SCALE = 2

-- resvg needs a real font for the labels, which are the only part of the SVG
-- left as text. Roblox ships Arimo, a neutral sans, in both a Studio install
-- and the fonts package, so the family name is known alongside the file name.
local LABEL_FONT_FILE = "fonts/Arimo-Regular.ttf"
local LABEL_FONT_FAMILY = "Arimo"

local FONT_IDS = args.value("--fonts")
local PREVIEW_TEXT = args.valueOr("--text", DEFAULT_PREVIEW_TEXT)
local IMAGE_WIDTH = args.numberOr("--width", DEFAULT_IMAGE_WIDTH)

-- `--resvg` on its own rasterises with whatever is on PATH; give it a path to
-- use a binary that is not
local RASTERIZE, RESVG_COMMAND = args.optionalValue("--resvg")
local PREVIEW_SCALE = args.numberOr("--scale", DEFAULT_PREVIEW_SCALE)

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

local writtenPaths = { SVG_PATH_BLACK, SVG_PATH_WHITE }

--- Finds a font for resvg to set the labels in. Checked in the same order the
--- fonts themselves are resolved: an explicit content directory first, then a
--- Studio installation, which is absent on platforms Studio does not run on.
local function resolveLabelFont(): string?
	local roots: { string } = {}

	if CONTENT_PATH then
		table.insert(roots, CONTENT_PATH)
	end

	local studioOk, studioContent = pcall(rbx.studioContentPath)

	if studioOk and studioContent then
		table.insert(roots, studioContent)
	end

	for _, root in roots do
		local candidatePath = ufs.normalizePath(`{root}/{LABEL_FONT_FILE}`)

		if fs.isFile(candidatePath) then
			return candidatePath
		end
	end

	return nil
end

if RASTERIZE then
	if not resvg.isAvailable(RESVG_COMMAND) then
		logger.error(
			`Could not run "{RESVG_COMMAND or resvg.DEFAULT_COMMAND}". Install it with `
				.. `"cargo install resvg", or point --resvg at an existing binary.`
		)
		process.exit(1)
	end

	local labelFontFile = resolveLabelFont()

	-- Losing the labels is silent otherwise: resvg renders every glyph, drops
	-- the text it has no font for, and says so only on stderr
	if not labelFontFile then
		logger.warn(`No {LABEL_FONT_FILE} found to set labels in; falling back to the fonts installed here`)
	end

	for _, svgPath in { SVG_PATH_BLACK, SVG_PATH_WHITE } do
		local pngPath = `{svgPath:sub(1, -5)}.png`

		local renderOk, reason = resvg.render(svgPath, pngPath, {
			command = RESVG_COMMAND,
			scale = PREVIEW_SCALE,
			fontFile = labelFontFile,
			fontFamily = LABEL_FONT_FAMILY,
		})

		if not renderOk then
			logger.error(`Failed to rasterise {svgPath}: {reason}`)
			process.exit(1)
		end

		table.insert(writtenPaths, pngPath)
	end
end

logger.log(`Wrote {composition.count} font previews:`)

for _, writtenPath in writtenPaths do
	logger.log(`  {writtenPath}`)
end
