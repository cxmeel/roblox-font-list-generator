--!strict
--[[
	Client for the Roblox asset delivery batch API.

	Takes `{ requestId, assetId }` pairs and answers with a CDN location for
	each. Callers decide what to do about archived assets and assets with no
	location, since the right answer differs: the generator skips them, the
	preview treats them as fatal.

	The endpoint rate limits aggressively against datacenter addresses, which is
	exactly where CI runs, so requests are kept small, paced apart, and retried
	with backoff on a 429.
]]

local net = require("@lune/net")
local serde = require("@lune/serde")
local task = require("@lune/task")

local logger = require("../utils/logger")

export type BatchRequest = {
	requestId: string,
	assetId: number,
}

export type BatchResult = {
	requestId: string,
	isArchived: boolean?,
	assetTypeId: number?,
	isRecordable: boolean?,
	--- Present on v2 responses.
	locations: { { assetFormat: string, location: string } }?,
	--- Present on v1 responses.
	location: string?,
	errors: { { code: number, message: string } }?,
}

local BATCH_ASSET_URL = "https://assetdelivery.roblox.com/v2/assets/batch"

--- Deliberately small. The endpoint accepts far more per call, but large
--- batches draw a 429 from a runner, where v1 was happy with thirty at a time.
local MAX_BATCH_SIZE = 30

--- Seconds between chunks, so a long run does not arrive as a burst.
local CHUNK_INTERVAL = 1

local MAX_ATTEMPTS = 5
local INITIAL_BACKOFF = 5
local MAX_BACKOFF = 60

local RETRYABLE_STATUS_CODES: { [number]: boolean } = {
	[408] = true, -- Request Timeout
	[425] = true, -- Too Early
	[429] = true, -- Too Many Requests
	[500] = true, -- Internal Server Error
	[502] = true, -- Bad Gateway
	[503] = true, -- Service Unavailable
	[504] = true, -- Gateway Timeout
}

local REQUEST_HEADERS: { [string]: string } = {
	["Accept"] = "application/json",
	["Content-Type"] = "application/json",
	["Roblox-Place-Id"] = "0",
	["Roblox-Browser-Asset-Request"] = "true",
}

--- How long to wait before retrying. `Retry-After` wins when the response
--- carries one as a plain delay; a date-formatted value falls through to the
--- exponential backoff rather than being parsed.
local function backoffSeconds(response: net.FetchResponse, attempt: number): number
	local headers = response.headers
	local retryAfter = tonumber(headers["retry-after"] or headers["Retry-After"])

	if retryAfter then
		return math.clamp(retryAfter, 1, MAX_BACKOFF)
	end

	return math.min(INITIAL_BACKOFF * 2 ^ (attempt - 1), MAX_BACKOFF)
end

local function requestChunk(requests: { BatchRequest }): { BatchResult }
	local body = serde.encode("json", requests, false)

	for attempt = 1, MAX_ATTEMPTS do
		local response = net.request({
			url = BATCH_ASSET_URL,
			method = "POST",
			body = body,
			headers = REQUEST_HEADERS,
		})

		if response.ok then
			local parsedOk, parsedData: { BatchResult } =
				pcall(serde.decode, "json" :: serde.EncodeDecodeFormat, response.body)

			if not parsedOk then
				logger.error(`Failed to parse asset delivery response: {parsedData}`)
			end

			return parsedData
		end

		-- Out of attempts, or a failure that retrying cannot help with
		if not RETRYABLE_STATUS_CODES[response.statusCode] or attempt == MAX_ATTEMPTS then
			logger.error(
				`Asset delivery request failed: [{response.statusCode}] {response.statusMessage}: {response.body}`
			)
		end

		local delay = backoffSeconds(response, attempt)

		logger.warn(
			`Asset delivery returned {response.statusCode}, retrying in {delay}s (attempt {attempt} of {MAX_ATTEMPTS})`
		)

		task.wait(delay)
	end

	-- Unreachable: the last attempt either returns or raises
	return {}
end

--- Resolves a batch of assets, splitting the call up to stay under the size
--- the endpoint is willing to serve without throttling.
local function batch(requests: { BatchRequest }): { BatchResult }
	local results: { BatchResult } = {}

	for start = 1, #requests, MAX_BATCH_SIZE do
		if start > 1 then
			task.wait(CHUNK_INTERVAL)
		end

		local finish = math.min(start + MAX_BATCH_SIZE - 1, #requests)
		local chunk = table.move(requests, start, finish, 1, {})

		logger.debug(`> Resolving assets {start} to {finish} of {#requests}`)

		for _, result in requestChunk(chunk) do
			table.insert(results, result)
		end
	end

	return results
end

--- The CDN location for a result, or nil when there is nothing to download
--- (archived assets, or assets the API returned no location for).
local function locationOf(result: BatchResult): string?
	if result.isArchived then
		return nil
	end

	-- v1 answers with a single location and v2 with a list of them, so this
	-- reads either shape and BATCH_ASSET_URL can be pointed at either version
	if result.location then
		return result.location
	end

	local locations = result.locations

	if not locations or #locations == 0 then
		return nil
	end

	return locations[1].location
end

return {
	batch = batch,
	locationOf = locationOf,
	MAX_BATCH_SIZE = MAX_BATCH_SIZE,
}
