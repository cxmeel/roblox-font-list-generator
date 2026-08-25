local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")

local Font = require("../struct/Font")

local array = require("../utils/array")
local colors = require("../utils/colors")
local logger = require("../utils/logger")
local ufs = require("../utils/ufs")

-- local BACKUP_VERSION_HASH_URL =
-- 	"https://github.com/MaximumADHD/Roblox-Client-Tracker/raw/refs/heads/roblox/version-guid.txt"
local VERSION_HASH_MAP_URL =
	"https://github.com/MaximumADHD/Roblox-Client-Tracker/raw/refs/heads/roblox/version-history.json"
local ROBLOX_DEPLOY_HISTORY_URL = "https://s3.amazonaws.com/setup.roblox.com/DeployHistory.txt"
local FONT_DATA_URL = "https://s3.amazonaws.com/setup.roblox.com/version-%s-content-fonts.zip"

local function fetchCurrentStudioVersionFromGitHub()
	logger.debug("Fetching version history from Max's dump")

	local response = net.request(VERSION_HASH_MAP_URL)
	local versionMap: { [string]: string } = serde.decode("json", response.body)

	local highestKey: string?
	local highestInfo = { 0, 0, 0, 0 }

	for versionNum in versionMap do
		if not versionNum:match("^%d+%.%d+%.0%.%d+$") then
			continue
		end

		local numParts = array.map(versionNum:split("."), function(num)
			return tonumber(num)
		end)

		local isGreater = false

		for idx = 1, 4 do
			if numParts[idx] > highestInfo[idx] then
				isGreater = true
				break
			elseif numParts[idx] < highestInfo[idx] then
				break
			end
		end

		if isGreater then
			highestKey = versionNum
			highestInfo = numParts
		end
	end

	if highestKey then
		local selectedVersion = versionMap[highestKey]:match("(%x+)$")
		logger.debug(`Found v{highestKey} with hash {selectedVersion}`)

		return selectedVersion
	end

	return
end

local function fetchCurrentStudioVersionHash()
	logger.info("Fetching current studio version hash")
	logger.debug("Fetching Roblox deployment history")

	local response = net.request(ROBLOX_DEPLOY_HISTORY_URL)
	local finalEntry = table.remove(response.body:split("\n"))
	local versionHash = finalEntry:match("version%-(%x+)")

	if not versionHash then
		-- logger.warn("Failed to parse version hash from deployment history, falling back to backup URL")

		-- local backupResponse = net.request(BACKUP_VERSION_HASH_URL)
		-- versionHash = backupResponse.body:match("version%-(%x+)")

		logger.warn("Failed to parse version hash from deployment history, falling back to backup method")

		local backupVersionHash = fetchCurrentStudioVersionFromGitHub()
		versionHash = backupVersionHash

		if not versionHash then
			-- error("Failed to parse version hash from backup URL")
			error("Failed to parse version hash from backup method")
		end
	end

	logger.debug("Current studio version hash:", colors.grey(versionHash))

	return versionHash
end

local function fetchFontDataPackage(versionHash: string)
	local url = FONT_DATA_URL:format(versionHash)

	local ZIP_FILE_PATH = `temp/{versionHash}-fonts.zip`
	local EXTRACT_TO_PATH = `temp/{versionHash}-fonts`

	if not fs.isFile(ZIP_FILE_PATH) then
		logger.info("Downloading font data package")
		local httpResponse = net.request(url)

		logger.info("Writing font data package to disk")

		ufs.unlink(ZIP_FILE_PATH, EXTRACT_TO_PATH)
		ufs.writeFile(ZIP_FILE_PATH, httpResponse.body)

		logger.debug("Downloaded font data package to:", colors.blue(ZIP_FILE_PATH))
	else
		logger.info("Font data package already downloaded:", colors.blue(ZIP_FILE_PATH))
	end

	logger.info("Extracting font data package.")

	local extractResult = process.exec("7z", { "x", `-o{EXTRACT_TO_PATH}`, `{process.cwd}{ZIP_FILE_PATH}` })

	if extractResult.code ~= 0 then
		error(`Failed to extract font data package: {extractResult.stderr}`)
	end

	logger.debug("Extracted font data package to:", colors.blue(EXTRACT_TO_PATH))
	return EXTRACT_TO_PATH
end

local function listDirRecursively(dirPath: string, indent: string)
	local result = ""

	for _, entry in fs.readDir(dirPath) do
		local entryPath = `{dirPath}/{entry}`
		result ..= indent .. entry .. "\n"

		if fs.isDir(entryPath) then
			result ..= listDirRecursively(entryPath, indent .. "  ")
		end
	end

	return result
end

local function fetchCurrentLocalFontList()
	local versionHash = fetchCurrentStudioVersionHash()
	local fontsDirPath = fetchFontDataPackage(versionHash)

	local fontList = {}
	logger.info("Parsing font data")

	if not fs.isDir(`{fontsDirPath}/families`) then
		-- local tempDirStructure = listDirRecursively("temp", "")
		-- logger.debug(`Temp directory structure:\n{tempDirStructure}`)

		error("Font data package is missing 'families' directory")
	end

	for _, fileName in fs.readDir(`{fontsDirPath}/families`) do
		local fontFilePath = `{fontsDirPath}/families/{fileName}`

		if not fileName:match("%.json$") or not fs.isFile(fontFilePath) then
			continue
		end

		local font = Font.fromFile(fontFilePath)
		table.insert(fontList, font)

		logger.debug("Found font:", colors.grey(font.Name))
	end

	logger.info("Cleaning up font data")
	ufs.unlink(fontsDirPath)

	return fontList
end

return {
	fetchLocalFonts = fetchCurrentLocalFontList,
}
