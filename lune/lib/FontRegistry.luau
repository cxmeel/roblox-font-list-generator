--!strict
--[[
	Resolves Roblox font content ids to font files on disk.

	Local (`rbxasset://`) fonts come out of the Studio installation, cloud
	(`rbxassetid://`) fonts out of the download registry, downloading them
	through the asset delivery API when they are not already cached.
]]

local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")

local FontFamily = require("../struct/FontFamily")

local logger = require("../utils/logger")
local rbx = require("../utils/rbx")
local ufs = require("../utils/ufs")

type FontFamily = FontFamily.FontFamily

export type FontFileType = "otf" | "ttf" | "woff" | "woff2" | "eot"

type AssetDeliveryBatchItem = {
	locations: { { assetFormat: string, location: string } },
	requestId: string,
	isArchived: boolean,
	assetTypeId: number,
	isRecordable: boolean,
}

local BATCH_ASSET_URL = "https://assetdelivery.roblox.com/v2/assets/batch"

local RBXASSET_PREFIX = "rbxasset://"
local RBXASSETID_PREFIX = "rbxassetid://"

local FONT_FILE_TYPES: { FontFileType } = {
	"otf",
	"ttf",
	"woff",
	"woff2",
	"eot",
}

local function stripPrefix(value: string, prefix: string): string?
	if string.sub(value, 1, #prefix) ~= prefix then
		return nil
	end

	return string.sub(value, #prefix + 1)
end

--- Resolves a path inside the Studio content directory, erroring out if there
--- is no Studio installation to read from.
local function studioContentFile(relativePath: string): string
	local contentPath = rbx.studioContentPath()

	if not contentPath then
		logger.error("No Roblox Studio installation found to read local fonts from")
		process.exit(1)
	end

	return ufs.normalizePath(`{contentPath}/{relativePath}`)
end

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

--- Returns the cached download for an asset, if one of the known file types
--- is already sitting in the registry.
local function findCachedFontFile(pathWithoutExtension: string): string?
	for _, fileType in FONT_FILE_TYPES do
		local candidatePath = `{pathWithoutExtension}.{fileType}`

		if fs.isFile(candidatePath) then
			return candidatePath
		end
	end

	return nil
end

--- Reads the family descriptor behind each font content id.
local function resolveFamilies(fontIds: { string }, registryPath: string): { [string]: FontFamily }
	local families: { [string]: FontFamily } = {}

	for _, fontId in fontIds do
		local cloudAssetId = stripPrefix(fontId, RBXASSETID_PREFIX)
		local localPath = stripPrefix(fontId, RBXASSET_PREFIX)

		local familyPath: string?

		if cloudAssetId then
			familyPath = ufs.normalizePath(`{registryPath}/{cloudAssetId}.json`)
		elseif localPath then
			familyPath = studioContentFile(localPath)
		end

		if not familyPath then
			logger.error(`Invalid font ID: {fontId}`)
			process.exit(1)
			continue
		end

		if not fs.isFile(familyPath) then
			logger.error(`Font not found: {familyPath}`)
			process.exit(1)
			continue
		end

		families[fontId] = serde.decode("json", fs.readFile(familyPath))
	end

	return families
end

--- Downloads the given cloud font assets into the registry, keyed by font id.
local function downloadFontFiles(assetIdsByFontId: { [string]: string }, registryPath: string): { [string]: string }
	local downloadedPaths: { [string]: string } = {}
	local requestBody = {}

	for fontId, assetId in assetIdsByFontId do
		table.insert(requestBody, {
			requestId = fontId,
			assetId = tonumber(assetId),
		})
	end

	logger.info("Downloading remote font files...")

	local response = net.request({
		url = BATCH_ASSET_URL,
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
		local fontId = responseItem.requestId

		if responseItem.isArchived then
			logger.error(`Font asset is archived and cannot be downloaded: {fontId}`)
			process.exit(1)
		end

		if #responseItem.locations == 0 then
			logger.error(`No download locations found for font asset: {fontId}`)
			process.exit(1)
		end

		-- Cached downloads are named after the family id, not the face asset id
		local pathWithoutExtension = ufs.normalizePath(`{registryPath}/fonts/{stripPrefix(fontId, RBXASSETID_PREFIX)}`)
		local cachedPath = findCachedFontFile(pathWithoutExtension)

		if cachedPath then
			logger.debug(`Font asset {fontId} already exists at {cachedPath}, skipping download.`)
			downloadedPaths[fontId] = cachedPath

			continue
		end

		local downloadUrl = responseItem.locations[1].location
		logger.debug(`> Downloading font asset {fontId} from {downloadUrl}`)

		local downloadResponse = net.request({ url = downloadUrl })

		if not downloadResponse.ok then
			logger.error(
				`Failed to download font asset {fontId}: [{downloadResponse.statusCode}] {downloadResponse.statusMessage}`
			)
			process.exit(1)
		end

		local fontFileType = determineFontFileType(downloadResponse.body) or "otf"
		local downloadedPath = `{pathWithoutExtension}.{fontFileType}`

		ufs.writeFile(downloadedPath, downloadResponse.body)
		downloadedPaths[fontId] = downloadedPath

		logger.debug(`> Saved font asset {fontId} to {downloadedPath}`)
	end

	return downloadedPaths
end

--- Resolves each family's regular face to a font file on disk, downloading
--- cloud faces in a single batch.
local function resolveFontFiles(families: { [string]: FontFamily }, registryPath: string): { [string]: string }
	local fontFilePaths: { [string]: string } = {}
	local pendingAssetIds: { [string]: string } = {}

	for fontId, family in families do
		local face = FontFamily.regularFace(family)
		local cloudAssetId = stripPrefix(face.assetId, RBXASSETID_PREFIX)

		if cloudAssetId and cloudAssetId:match("^%d+$") then
			pendingAssetIds[fontId] = cloudAssetId
			continue
		end

		local localPath = stripPrefix(face.assetId, RBXASSET_PREFIX)

		if not localPath then
			logger.error(`Invalid font asset ID for {family.name}: {face.assetId}`)
			process.exit(1)
			continue
		end

		fontFilePaths[fontId] = studioContentFile(localPath)
	end

	if next(pendingAssetIds) then
		for fontId, downloadedPath in downloadFontFiles(pendingAssetIds, registryPath) do
			fontFilePaths[fontId] = downloadedPath
		end
	end

	return fontFilePaths
end

return {
	resolveFamilies = resolveFamilies,
	resolveFontFiles = resolveFontFiles,
	determineFontFileType = determineFontFileType,
}
