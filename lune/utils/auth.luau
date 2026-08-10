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

--- Roblox bakes this into every `.ROBLOSECURITY` value.
local COOKIE_WARNING_MARKER = "_|WARNING:-DO-NOT-SHARE-THIS"

local resolved: Credential? = nil

--- Accepts either a bare cookie value or one already in header form.
local function asCookieHeader(cookie: string): string
	if cookie:find(COOKIE_PREFIX, 1, true) then
		return cookie
	end

	return `{COOKIE_PREFIX}{cookie}`
end

--- Cookies and API keys are both long opaque strings, so tell them apart by the
--- warning Roblox embeds in a cookie, or by it already being in header form.
--- Anything else is taken to be an API key.
local function looksLikeCookie(value: string): boolean
	return value:find(COOKIE_PREFIX, 1, true) ~= nil or value:find(COOKIE_WARNING_MARKER, 1, true) ~= nil
end

--- Builds a credential from a secret, choosing the header by what it looks
--- like rather than by where it came from, so a cookie handed to the API key
--- variable still authenticates instead of silently failing.
local function credentialFor(secret: string, source: string): Credential
	if looksLikeCookie(secret) then
		logger.info(`Authenticating with a Roblox cookie from {source}`)

		return { kind = "cookie", headers = { Cookie = asCookieHeader(secret) } }
	end

	logger.info(`Authenticating with an Open Cloud API key from {source}`)

	return { kind = "apiKey", headers = { ["x-api-key"] = secret } }
end

local function resolve(): Credential
	if resolved then
		return resolved
	end

	local hasAuthArgument, authValue = args.optionalValue(AUTH_ARGUMENT)
	local credential: Credential

	if authValue then
		-- Anything on the command line is visible to other processes and tends
		-- to end up in CI logs, so say so rather than accepting it quietly
		logger.warn(
			`Reading a credential from {AUTH_ARGUMENT} exposes it to process listings; `
				.. `prefer {API_KEY_VARIABLE} or {COOKIE_VARIABLE} in the environment or {dotenv.ENV_FILE_PATH}`
		)

		credential = credentialFor(authValue, AUTH_ARGUMENT)
	elseif hasAuthArgument then
		-- Bare --auth asks for a cookie: from the environment first, so a runner
		-- with no Roblox installation still has a way in, then from an install
		local cookie = dotenv.get(COOKIE_VARIABLE)
		local source = COOKIE_VARIABLE

		if not cookie then
			local cookieOk, localCookie = pcall(roblox.getAuthCookie)
			cookie = if cookieOk then localCookie else nil
			source = "this machine"
		end

		if not cookie then
			logger.error(
				`Could not read a Roblox auth cookie. Sign in to Roblox Studio here, set {COOKIE_VARIABLE}, `
					.. `or pass a credential with {AUTH_ARGUMENT} <value>.`
			)
			process.exit(1)
		end

		credential = credentialFor(cookie :: string, source)
	else
		-- No flag: use whichever credential the environment happens to carry
		local suppliedKey = dotenv.get(API_KEY_VARIABLE)
		local suppliedCookie = dotenv.get(COOKIE_VARIABLE)

		if suppliedKey then
			credential = credentialFor(suppliedKey, API_KEY_VARIABLE)
		elseif suppliedCookie then
			credential = credentialFor(suppliedCookie, COOKIE_VARIABLE)
		else
			credential = { kind = "none", headers = {} }
		end
	end

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
