local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")

local Font = require("../struct/Font")

local colors = require("../utils/colors")
local logger = require("../utils/logger")
local ufs = require("../utils/ufs")

local ROBLOX_DEPLOY_HISTORY_URL = "https://s3.amazonaws.com/setup.roblox.com/DeployHistory.txt"
local FONT_DATA_URL = "https://s3.amazonaws.com/setup.roblox.com/version-%s-content-fonts.zip"

local function fetchCurrentStudioVersionHash()
	logger.info("Fetching current studio version hash")
	logger.debug("Fetching Roblox deployment history")

	local response = net.request(ROBLOX_DEPLOY_HISTORY_URL)
	local finalEntry = table.remove(response.body:split("\n"))
	local versionHash = finalEntry:match("version%-(%x+)")

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
	end

	logger.info("Extracting font data package.")
	process.spawn("7z", { "x", `-o{EXTRACT_TO_PATH}`, ZIP_FILE_PATH })

	logger.debug("Extracted font data package to:", colors.blue(EXTRACT_TO_PATH))
	return EXTRACT_TO_PATH
end

local function fetchCurrentLocalFontList()
	local versionHash = fetchCurrentStudioVersionHash()
	local fontsDirPath = fetchFontDataPackage(versionHash)

	local fontList = {}
	logger.info("Parsing font data")

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
