--!strict
--[[
	Optional authentication for Roblox web requests.

	Asset delivery has required authentication since April 2025 and throttles
	unauthenticated traffic, which is what a CI runner looks like from the
	outside. Two credentials are supported:

	- `--auth` on its own reads the `.ROBLOSECURITY` cookie from a Roblox
	  installation on this machine. This is the one the batch endpoint visibly
	  honours: authenticated calls come back pointing at a different CDN host.
	- `--auth <key>`, or ROBLOX_OPEN_CLOUD_API_KEY in the environment or `.env`,
	  sends an Open Cloud API key instead.

	Resolved once and reused, so a run cannot end up half authenticated.
]]

local process = require("@lune/process")
local roblox = require("@lune/roblox")

local args = require("./args")
local dotenv = require("./dotenv")
local logger = require("./logger")

export type CredentialKind = "cookie" | "apiKey" | "none"

export type Credential = {
	kind: CredentialKind,
	headers: { [string]: string },
}

local API_KEY_VARIABLE = "ROBLOX_OPEN_CLOUD_API_KEY"
local COOKIE_VARIABLE = "ROBLOSECURITY"
local COOKIE_PREFIX = ".ROBLOSECURITY="
local AUTH_ARGUMENT = "--auth"

local resolved: Credential? = nil

--- Accepts either a bare cookie value or one already in header form.
local function asCookieHeader(cookie: string): string
	if cookie:find(COOKIE_PREFIX, 1, true) then
		return cookie
	end

	return `{COOKIE_PREFIX}{cookie}`
end

local function resolve(): Credential
	if resolved then
		return resolved
	end

	local hasAuthArgument, authValue = args.optionalValue(AUTH_ARGUMENT)

	-- Bare --auth: a cookie from the environment first, so a runner with no
	-- Roblox installation still has a way in, then one from an install here
	if hasAuthArgument and not authValue then
		local suppliedCookie = dotenv.get(COOKIE_VARIABLE)
		local cookie = suppliedCookie
		local source = COOKIE_VARIABLE

		if not cookie then
			local cookieOk, localCookie = pcall(roblox.getAuthCookie)
			cookie = if cookieOk then localCookie else nil
			source = "this machine"
		end

		if not cookie then
			logger.error(
				`Could not read a Roblox auth cookie. Sign in to Roblox Studio here, set {COOKIE_VARIABLE}, `
					.. `or pass an Open Cloud API key with {AUTH_ARGUMENT} <key>.`
			)
			process.exit(1)
		end

		logger.info(`Authenticating with the Roblox cookie from {source}`)

		local credential: Credential = {
			kind = "cookie",
			headers = { Cookie = asCookieHeader(cookie :: string) },
		}

		resolved = credential

		return credential
	end

	if authValue then
		-- Anything on the command line is visible to other processes and tends
		-- to end up in CI logs, so say so rather than accepting it quietly
		logger.warn(
			`Reading an API key from {AUTH_ARGUMENT} exposes it to process listings; `
				.. `prefer {API_KEY_VARIABLE} in the environment or {dotenv.ENV_FILE_PATH}`
		)
	end

	local apiKey = authValue or dotenv.get(API_KEY_VARIABLE)

	if apiKey then
		logger.info(
			`Authenticating with an Open Cloud API key from {if authValue then AUTH_ARGUMENT else API_KEY_VARIABLE}`
		)

		local credential: Credential = { kind = "apiKey", headers = { ["x-api-key"] = apiKey } }
		resolved = credential

		return credential
	end

	local credential: Credential = { kind = "none", headers = {} }
	resolved = credential

	return credential
end

--- Headers to merge into a Roblox web request. Empty when unauthenticated.
local function headers(): { [string]: string }
	return resolve().headers
end

--- Which credential is in use, for logging and for deciding whether to warn.
local function kind(): CredentialKind
	return resolve().kind
end

return {
	headers = headers,
	kind = kind,
	API_KEY_VARIABLE = API_KEY_VARIABLE,
}
