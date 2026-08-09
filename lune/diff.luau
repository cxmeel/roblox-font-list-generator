--!strict
--[[
    $ lune -- diff <oldFilePath> <newFilePath>

    Generates a basic diff file between two generated font lists.

    Either file may be the Luau flavour or the JSON one, in either
    position, so a release can be compared against whichever
    artifact happens to be to hand.

    The diff file is written to `build/FontList.diff` and shows
    only the additions and deletions between the two files; it
    does not display modifications to existing fonts at this
    time.
--]]
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local serde = require("@lune/serde")

local colors = require("./utils/colors")
local logger = require("./utils/logger")
local ufs = require("./utils/ufs")

local Font = require("./struct/Font")

local OLD_FILE_ARG = process.args[1]
local NEW_FILE_ARG = process.args[2]

-- Interpolating a missing argument would quietly produce a path ending in
-- "nil", so the arguments have to be checked before the paths are built
if not OLD_FILE_ARG or not NEW_FILE_ARG then
	logger.error("Usage: lune run diff <oldFilePath> <newFilePath>")
	process.exit(1)
end

local OLD_FILE_PATH = ufs.normalizePath(`{process.cwd}/{OLD_FILE_ARG}`)
local NEW_FILE_PATH = ufs.normalizePath(`{process.cwd}/{NEW_FILE_ARG}`)

local function createRecursiveTable(): { [any]: any }
	return setmetatable({}, {
		__index = function()
			return createRecursiveTable()
		end,
	}) :: any
end

local function validateProcessArguments()
	if not fs.isFile(OLD_FILE_PATH) then
		logger.error(`File "{OLD_FILE_PATH}" does not exist`)
		process.exit(1)
	end

	if not fs.isFile(NEW_FILE_PATH) then
		logger.error(`File "{NEW_FILE_PATH}" does not exist`)
		process.exit(1)
	end

	local oldFileMetadata = fs.metadata(OLD_FILE_PATH)
	local newFileMetadata = fs.metadata(NEW_FILE_PATH)

	if oldFileMetadata.modifiedAt > newFileMetadata.modifiedAt then
		logger.warn("The old file is newer than the new file")
	end

	return true
end

--- Runs a generated `FontList.luau` and returns the list it declares. The
--- generated source references `Enum.FontWeight.*`, which does not exist
--- outside Roblox, so the chunk gets an environment that answers to any index.
local function loadLuauFontList(source: string): { Font.IFont }
	local chunk = luau.load(luau.compile(source), {
		environment = {
			Enum = createRecursiveTable(),
		},
	})

	return chunk() :: { Font.IFont }
end

local function loadJsonFontList(source: string): { Font.IFont }
	return serde.decode("json", source)
end

--- Loads a generated font list in either flavour, picked by file extension.
--- A file whose contents do not match its extension is left to error out.
local function loadFontList(path: string): { Font.IFont }
	local source = fs.readFile(path)
	local isJson = path:lower():match("%.json$") ~= nil

	local fontList = if isJson then loadJsonFontList(source) else loadLuauFontList(source)

	if typeof(fontList) ~= "table" or (#fontList > 0 and fontList[1].ContentUri == nil) then
		logger.error(`File "{path}" does not look like a generated font list`)
		process.exit(1)
	end

	return fontList
end

local function generateDiffArrays()
	local oldFontList = loadFontList(OLD_FILE_PATH)
	local newFontList = loadFontList(NEW_FILE_PATH)

	local additions = {} :: { Font.IFont }
	local deletions = {} :: { Font.IFont }

	-- Keyed on ContentUri rather than Name: a handful of families are published
	-- both locally and in the cloud under the same name, and matching on the
	-- name would hide one of them appearing or disappearing
	local oldFontsByUri: { [string]: Font.IFont } = {}
	local newFontsByUri: { [string]: Font.IFont } = {}

	for _, oldFont in oldFontList do
		oldFontsByUri[oldFont.ContentUri] = oldFont
	end

	for _, newFont in newFontList do
		newFontsByUri[newFont.ContentUri] = newFont
	end

	for _, oldFont in oldFontList do
		if not newFontsByUri[oldFont.ContentUri] then
			table.insert(deletions, oldFont)
		end
	end

	for _, newFont in newFontList do
		if not oldFontsByUri[newFont.ContentUri] then
			table.insert(additions, newFont)
		end
	end

	-- ContentUri breaks the tie, since table.sort is not stable and duplicate
	-- names would otherwise shuffle between runs
	local function byName(a: Font.IFont, b: Font.IFont): boolean
		if a.Name == b.Name then
			return a.ContentUri < b.ContentUri
		end

		return a.Name < b.Name
	end

	table.sort(additions, byName)
	table.sort(deletions, byName)

	return {
		additions = additions,
		deletions = deletions,
	}
end

local function main()
	validateProcessArguments()

	local diffs = generateDiffArrays()
	local diffLines = {}

	-- The content uri distinguishes families that share a name, and says at a
	-- glance whether an entry is a local font or a cloud one
	for _, deletion in diffs.deletions do
		table.insert(diffLines, `- {deletion.Name} ({deletion.ContentUri})`)
	end

	-- Separate the two groups, but only when there is something on both sides
	if #diffs.deletions > 0 and #diffs.additions > 0 then
		table.insert(diffLines, "")
	end

	for _, addition in diffs.additions do
		table.insert(diffLines, `+ {addition.Name} ({addition.ContentUri})`)
	end

	local changeCount = #diffs.additions + #diffs.deletions

	if changeCount == 0 then
		logger.log("No changes detected")
		process.exit(0)
	end

	logger.info(`Changes detected: {colors.yellow(changeCount)}`)
	logger.info(`Additions: {colors.green(#diffs.additions)}`)
	logger.info(`Deletions: {colors.red(#diffs.deletions)}`)

	print("Writing diff file to", colors.blue("build/FontList.diff"))
	ufs.writeFile("build/FontList.diff", table.concat(diffLines, "\n"))

	print(colors.green.bold.inverse(" SUCCESS "), "Diff file generated successfully! 🎉")
end

main()
