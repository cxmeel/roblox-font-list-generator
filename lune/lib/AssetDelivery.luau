--!strict
--[[
	Client for the Roblox asset delivery batch API (v2).

	Takes `{ requestId, assetId }` pairs and answers with a CDN location for
	each. Callers decide what to do about archived assets and assets with no
	location, since the right answer differs: the generator skips them, the
	preview treats them as fatal.
]]

local net = require("@lune/net")
local serde = require("@lune/serde")

local logger = require("../utils/logger")

export type BatchRequest = {
	requestId: string,
	assetId: number,
}

export type BatchResult = {
	locations: { { assetFormat: string, location: string } },
	requestId: string,
	isArchived: boolean,
	assetTypeId: number,
	isRecordable: boolean,
	errors: { { code: number, message: string } }?,
}

local BATCH_ASSET_URL = "https://assetdelivery.roblox.com/v2/assets/batch"

--- The endpoint caps how many assets it will resolve per call.
local MAX_BATCH_SIZE = 255

local REQUEST_HEADERS: { [string]: string } = {
	["Accept"] = "application/json",
	["Content-Type"] = "application/json",
	["Roblox-Place-Id"] = "0",
	["Roblox-Browser-Asset-Request"] = "true",
}

local function requestChunk(requests: { BatchRequest }): { BatchResult }
	local response = net.request({
		url = BATCH_ASSET_URL,
		method = "POST",
		body = serde.encode("json", requests, false),
		headers = REQUEST_HEADERS,
	})

	if not response.ok then
		logger.error(`Asset delivery request failed: [{response.statusCode}] {response.statusMessage}: {response.body}`)
	end

	local parsedOk, parsedData: { BatchResult } = pcall(serde.decode, "json" :: serde.EncodeDecodeFormat, response.body)

	if not parsedOk then
		logger.error(`Failed to parse asset delivery response: {parsedData}`)
	end

	return parsedData
end

--- Resolves a batch of assets, splitting the call up when it exceeds the
--- endpoint's limit.
local function batch(requests: { BatchRequest }): { BatchResult }
	if #requests <= MAX_BATCH_SIZE then
		return requestChunk(requests)
	end

	local results: { BatchResult } = {}

	for start = 1, #requests, MAX_BATCH_SIZE do
		local chunk = table.move(requests, start, math.min(start + MAX_BATCH_SIZE - 1, #requests), 1, {})

		for _, result in requestChunk(chunk) do
			table.insert(results, result)
		end
	end

	return results
end

--- The first CDN location for a result, or nil when there is nothing to
--- download (archived assets, or assets the API returned no location for).
local function locationOf(result: BatchResult): string?
	if result.isArchived or #result.locations == 0 then
		return nil
	end

	return result.locations[1].location
end

return {
	batch = batch,
	locationOf = locationOf,
	MAX_BATCH_SIZE = MAX_BATCH_SIZE,
}
