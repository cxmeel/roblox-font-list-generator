local net = require("@lune/net")
local serde = require("@lune/serde")
local task = require("@lune/task")

local AssetDelivery = require("./AssetDelivery")
local Font = require("../struct/Font")

local colors = require("../utils/colors")
local logger = require("../utils/logger")

local FONT_TOOLBOX_URL = "https://apis.roblox.com/toolbox-service/v1/marketplace/73?limit=30&pageNumber=%d"

local MAX_NET_REQUESTS = 5
local BATCH_SIZE = 30
local RATE_LIMIT_INTERVAL = 15

local function fetchCurrentRemoteFontIds()
	local pageNumber, numberRequests = 0, 0
	local fontIdSet = {}

	logger.info("Fetching current cloud font ids")

	while true do
		local response = net.request(FONT_TOOLBOX_URL:format(pageNumber))
		local data = serde.decode("json", response.body)

		pageNumber += 1
		numberRequests += 1

		for _, assetResult in ipairs(data.data) do
			fontIdSet[assetResult.id] = true
		end

		if not data.nextPageCursor then
			break
		end

		if numberRequests % MAX_NET_REQUESTS == 0 then
			logger.warn("Batch limit reached, waiting", colors.bold(RATE_LIMIT_INTERVAL), "seconds")
			task.wait(RATE_LIMIT_INTERVAL)
		end
	end

	local fontIds = {}

	for fontId in fontIdSet do
		table.insert(fontIds, fontId)
	end

	logger.debug("Found", colors.bold(#fontIds), "available cloud fonts")

	return fontIds
end

local function fetchFontsFromServer(fontIds: { number })
	-- Fetch CDN download URLs for each font
	local assetRequestItems: { AssetDelivery.BatchRequest } = {}
	local fontCdnUrls = {}

	logger.info("Fetching cloud font CDN download URLs")

	for _, fontId in fontIds do
		table.insert(assetRequestItems, {
			requestId = tostring(fontId),
			assetId = fontId,
		})
	end

	for _, result in AssetDelivery.batch(assetRequestItems) do
		local location = AssetDelivery.locationOf(result)

		-- An archived or otherwise unavailable font is simply not listed
		if not location then
			logger.warn("Skipping unavailable cloud font", colors.bold(result.requestId))
			continue
		end

		fontCdnUrls[tonumber(result.requestId)] = location
	end

	-- Download each font as necessary
	local fontList, numberRequests = {}, 0
	local quantityReusedFromDisk = 0

	logger.info("Downloading required cloud font metadata")

	for fontId, cdnUrl in fontCdnUrls do
		local font, isReusedFromDisk, fileLocation = Font.fromURL(fontId, cdnUrl)

		if not isReusedFromDisk then
			numberRequests += 1
		end

		if not isReusedFromDisk then
			logger.debug("Downloaded", colors.bold(font.Name), "from", colors.blue(fileLocation))
		else
			logger.debug("Reused", colors.bold(font.Name), "from disk:", colors.blue(fileLocation))
			quantityReusedFromDisk += 1
		end

		table.insert(fontList, font)

		if numberRequests > 0 and numberRequests % BATCH_SIZE == 0 then
			logger.warn("Batch limit reached, waiting", colors.bold(RATE_LIMIT_INTERVAL), "seconds")
			task.wait(RATE_LIMIT_INTERVAL)
		end
	end

	logger.debug("Downloaded", colors.bold(numberRequests), "cloud fonts")
	logger.debug("Reused", colors.bold(quantityReusedFromDisk), "cloud fonts from disk")

	return fontList
end

local function fetchCloudFonts()
	local fontIds = fetchCurrentRemoteFontIds()
	local fontList = fetchFontsFromServer(fontIds)

	logger.debug("Found", colors.bold(#fontList), "cloud fonts")

	return fontList
end

return {
	fetchCloudFonts = fetchCloudFonts,
}
