--!strict
--[[
	Client for the Roblox asset delivery batch API.

	Takes `{ requestId, assetId }` pairs and answers with a CDN location for
	each. Callers decide what to do about archived assets and assets with no
	location, since the right answer differs: the generator skips them, the
	preview treats them as fatal.

	The endpoint rate limits aggressively against datacenter addresses, which is
	exactly where CI runs, so requests are kept small, paced apart, and worked
	through a ladder of endpoints:

	1. v2 with whatever credential is configured, retried five times with
	   exponential backoff reaching a minute.
	2. v1 with no credential at all, on the same ladder. This generator ran
	   against v1 unauthenticated for a long time without trouble, so it is
	   worth one genuinely different-looking attempt before giving up.

	Whichever rung answers is remembered for the rest of the run, so a later
	chunk does not walk a ladder that has already been shown to fail.
]]

local net = require("@lune/net")
local serde = require("@lune/serde")
local task = require("@lune/task")

local auth = require("../utils/auth")
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

type Endpoint = {
	url: string,
	--- Whether the configured credential is attached to the request.
	authenticated: boolean,
}

local ENDPOINTS: { Endpoint } = {
	{ url = "https://assetdelivery.roblox.com/v2/assets/batch", authenticated = true },
	{ url = "https://assetdelivery.roblox.com/v1/assets/batch", authenticated = false },
}

--- Deliberately small. The endpoint accepts far more per call, but large
--- batches draw a 429 from a runner, where v1 was happy with thirty at a time.
local MAX_BATCH_SIZE = 30

--- Seconds between chunks, so a long run does not arrive as a burst.
local CHUNK_INTERVAL = 1

--- Attempts per endpoint. The backoff doubles from INITIAL_BACKOFF and is
--- capped, so the waits run 5, 10, 20, 40, 60 seconds.
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

--- The rung that last answered, so the ladder is not walked again per chunk.
local preferredEndpoint = 1

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

--- Base headers, plus the configured credential when the endpoint takes one.
local function buildHeaders(authenticated: boolean): { [string]: string }
	local headers = table.clone(REQUEST_HEADERS)

	if not authenticated then
		return headers
	end

	for key, value in auth.headers() do
		headers[key] = value
	end

	return headers
end

--- Works through one endpoint's attempts. Returns nil when they are all spent
--- and the caller should drop to the next rung; `isLastRung` decides whether
--- running out is fatal instead.
local function attemptEndpoint(endpoint: Endpoint, body: string, isLastRung: boolean): { BatchResult }?
	local headers = buildHeaders(endpoint.authenticated)

	for attempt = 1, MAX_ATTEMPTS do
		local response = net.request({
			url = endpoint.url,
			method = "POST",
			body = body,
			headers = headers,
		})

		if response.ok then
			local parsedOk, parsedData: { BatchResult } =
				pcall(serde.decode, "json" :: serde.EncodeDecodeFormat, response.body)

			if not parsedOk then
				logger.error(`Failed to parse asset delivery response: {parsedData}`)
			end

			return parsedData
		end

		local isRetryable = RETRYABLE_STATUS_CODES[response.statusCode] == true
		local isSpent = attempt == MAX_ATTEMPTS

		-- Nothing left to fall back to, so the failure is the run's failure
		if isLastRung and (isSpent or not isRetryable) then
			logger.error(
				`Asset delivery request failed: [{response.statusCode}] {response.statusMessage}: {response.body}`
			)
		end

		if not isRetryable then
			logger.warn(`{endpoint.url} answered [{response.statusCode}]; retrying will not help, dropping down`)

			return nil
		end

		-- The wait after the final attempt still runs, giving the rate limiter
		-- the same breathing room before the next rung as between attempts
		local delay = backoffSeconds(response, attempt)

		logger.warn(
			`{endpoint.url} answered [{response.statusCode}]; waiting {delay}s `
				.. `(attempt {attempt} of {MAX_ATTEMPTS})`
		)

		task.wait(delay)

		if isSpent then
			return nil
		end
	end

	return nil
end

local function requestChunk(requests: { BatchRequest }): { BatchResult }
	local body = serde.encode("json", requests, false)

	for index = preferredEndpoint, #ENDPOINTS do
		local endpoint = ENDPOINTS[index]
		local results = attemptEndpoint(endpoint, body, index == #ENDPOINTS)

		if results then
			if index ~= preferredEndpoint then
				logger.warn(`Falling back to {endpoint.url} for the rest of this run`)
				preferredEndpoint = index
			end

			return results
		end
	end

	-- Unreachable: the last rung either returns or raises
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
	-- reads either shape and the ladder can drop between the two versions
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
